## engine/economy.nim
## ──────────────────
## Shop system: browse by category, buy, and sell.
##
## Shops live in content/shops/ and are triggered from NPC dialogue topics
## that carry a "shop" field. The active shop is tracked in
## state.variables["_active_shop"] for the duration of the dialogue.
##
## Trade structure (per shop item):
##   {"currency_item": "currency", "cost": 5, "receive_item": "iron-sword", "receive_amount": 1}
##
## Sell system:
##   Items with value > 0 can be sold to any shop for that many "currency" items.

import std/[json, math, strformat, strutils, tables]
import state
import content
import items
import modifiers as mods
import skills    as sk

const currencyId = "currency"

const typeAliases = {"shield": "armor"}.toTable


# ── Internal helpers ──────────────────────────────────────────────────────────

proc itemDisplay(itemId: string): string =
  if itemId in content.items:     return content.items[itemId].displayName
  if itemId in content.armorPlates: return content.armorPlates[itemId].displayName
  itemId

proc itemType(itemId: string): string =
  var t = "misc"
  if itemId in content.items: t = content.items[itemId].itemType.toLowerAscii
  typeAliases.getOrDefault(t, t)

proc itemValue(itemId: string): int =
  if itemId in content.items: return content.items[itemId].value
  if itemId in content.armorPlates:
    result = content.armorPlates[itemId].value
    for perkId in content.armorPlates[itemId].perks:
      if perkId in content.perks:
        result += content.perks[perkId].value
    return
  0


type EconEventMode* = enum
  eemReplace  ## restart the matching event's timer from now
  eemExtend   ## add the new tick_scope to the matching event's remaining ticks


# ── Economic event helpers ────────────────────────────────────────────────────

proc pruneExpiredEvents*(state: var GameState) =
  ## Remove economic events that have exceeded their tick_scope.
  var evList = state.variables.getOrDefault("_active_economic_events", newJArray())
  if evList.kind != JArray: evList = newJArray()
  var kept = newJArray()
  for ev in evList:
    let elapsed = state.player.tick - ev{"tick_start"}.getInt(0)
    if elapsed < ev{"tick_scope"}.getInt(0):
      kept.add ev
  state.variables["_active_economic_events"] = kept

proc getActiveEvents(state: GameState): JsonNode =
  ## Return the current active economic event list (read-only, no pruning).
  ## Call pruneExpiredEvents first to keep the list current.
  let evList = state.variables.getOrDefault("_active_economic_events", newJArray())
  if evList.kind == JArray: evList else: newJArray()

type TradeDir* = enum tdBuy, tdSell

proc calcTradePrice(state: GameState; baseCost: int; dir: TradeDir): int =
  ## Apply mercantile skill and price modifier to baseCost.
  ## tdBuy:  low mercantile = pay more  (multiplier 1.0–1.5)
  ## tdSell: low mercantile = earn less (multiplier 0.5–1.0)
  ## At 100% mercantile both directions converge to 1× base.
  let mercPct = sk.skillPct(state, "mercantile")
  let mult = case dir
    of tdBuy:  1.5 - mercPct * 0.5
    of tdSell: 0.5 + mercPct * 0.5
  result = max(1, int(round(baseCost.float * mult)))
  let modKey = case dir
    of tdBuy:  "buy_price_pct"
    of tdSell: "sell_price_pct"
  result = max(1, int(round(result.float * mods.modifierGet(state, modKey))))

proc adjustedCost*(state: GameState; itemId: string; baseCost: int;
                   dir: TradeDir): int =
  ## Final trade price: mercantile + modifier, then additive economic events.
  ## Event fluctuations are summed (not chained) before applying to the price.
  ## Call pruneExpiredEvents before a shop session to keep the event list fresh.
  result = calcTradePrice(state, baseCost, dir)
  let evList = getActiveEvents(state)
  if evList.len == 0: return
  var itemTags: seq[string]
  if itemId in content.items:
    itemTags.add content.items[itemId].itemType.toLowerAscii
  elif itemId in content.armorPlates:
    itemTags.add "armor"
  var eventPct = 0.0
  for ev in evList:
    let evId  = ev{"id"}.getStr
    let evTag = ev{"tag"}.getStr
    if evTag == "": continue
    let matched =
      if evId in content.economicEvents:
        content.economicEvents[evId].tag in itemTags
      else:
        evTag in itemTags
    if matched:
      eventPct += ev{"fluctuation"}.getFloat(0.0)
  if eventPct != 0.0:
    result = max(1, int(round(result.float * (1.0 + eventPct))))


proc applyEconomicEvent*(state: var GameState; eventId: string;
                         mode: EconEventMode = eemReplace) =
  ## Activate an economic event by id.  If an event with the same id is already
  ## active, `mode` determines what happens:
  ##   eemReplace — restart its timer (tick_start = now, tick_scope unchanged)
  ##   eemExtend  — add the event's tick_scope to its remaining ticks
  if eventId notin content.economicEvents: return
  let def  = content.economicEvents[eventId]
  pruneExpiredEvents(state)
  let evList = getActiveEvents(state)
  ## Check if this event is already running
  for i in 0 ..< evList.len:
    if evList[i]{"id"}.getStr == eventId:
      case mode
      of eemReplace:
        evList[i]["tick_start"] = %state.player.tick
      of eemExtend:
        let remaining = evList[i]{"tick_scope"}.getInt(0) -
                        (state.player.tick - evList[i]{"tick_start"}.getInt(0))
        evList[i]["tick_start"] = %state.player.tick
        evList[i]["tick_scope"] = %(max(0, remaining) + def.tickScope)
      state.variables["_active_economic_events"] = evList
      return
  ## Not already active — append a new entry
  let entry = %*{
    "id":          eventId,
    "tag":         def.tag,
    "fluctuation": def.fluctuation,
    "tick_scope":  def.tickScope,
    "tick_start":  state.player.tick,
  }
  evList.add entry
  state.variables["_active_economic_events"] = evList


# ── Script API ────────────────────────────────────────────────────────────────
# All procs here are wired as api.nim verbs and are Lua-callable.

proc shopLines*(state: var GameState): seq[string] =
  ## Top-level shop view: category links + player sell panel.
  let shopId = state.variables.getOrDefault("_active_shop", newJNull()).getStr
  if shopId == "" or shopId notin content.shops:
    return @["(No shop active.)"]
  let shopRaw = content.shops[shopId].raw
  let tradeArr = shopRaw{"items"}
  if tradeArr == nil or tradeArr.kind != JArray:
    return @["  (Nothing for sale.)", "", "  [[Leave:farewell]]"]

  # Collect ordered unique categories, excluding currency items
  var seen: seq[string]
  for trade in tradeArr:
    let t = itemType(trade{"receive_item"}.getStr)
    if t == "currency": continue
    if t notin seen: seen.add t

  var lines: seq[string]
  if seen.len > 0:
    for c in seen: lines.add &"  [[{c.capitalizeAscii}:shop {c}]]"
  else:
    lines.add "  (Nothing for sale.)"

  # Sell panel: player inventory items that have a value
  var sellLines: seq[string]
  for e in state.player.inventory:
    if itemType(e.id) == "currency": continue
    let v = itemValue(e.id)
    if v > 0:
      sellLines.add &"  [[{itemDisplay(e.id)} -- {adjustedCost(state, e.id, v, tdSell)} {itemDisplay(currencyId)}:sell {e.id}]]"
  if sellLines.len > 0:
    lines.add ""
    lines.add "Your items:"
    lines &= sellLines

  lines.add ""
  lines.add "  [[Leave:farewell]]"
  lines


proc openShop*(state: var GameState; shopId: string): seq[string] =
  ## Store the active shop and return the top-level display.
  if shopId notin content.shops:
    return @[&"(Shop '{shopId}' not found.)"]
  state.variables["_active_shop"] = %shopId
  pruneExpiredEvents(state)
  shopLines(state)


proc shopCategoryLines*(state: var GameState; category: string): seq[string] =
  ## List trades for a given category, prices include mercantile + economic events.
  let shopId = state.variables.getOrDefault("_active_shop", newJNull()).getStr
  if shopId == "" or shopId notin content.shops:
    return @["(No shop active.)"]
  let tradeArr = content.shops[shopId].raw{"items"}
  if tradeArr == nil or tradeArr.kind != JArray:
    return @[&"  (nothing in {category.capitalizeAscii})"]

  var lines: seq[string]
  for trade in tradeArr:
    let itemId = trade{"receive_item"}.getStr
    let iType  = itemType(itemId)
    if iType == "currency" or iType != category.toLowerAscii: continue
    let amount  = trade{"receive_amount"}.getInt(1)
    let curId   = trade{"currency_item"}.getStr(currencyId)
    let cost    = adjustedCost(state, itemId, trade{"cost"}.getInt(1), tdBuy)
    let qty     = if amount != 1: &"{amount}x " else: ""
    lines.add &"  [[{qty}{itemDisplay(itemId)} -- {cost} {itemDisplay(curId)}:buy {itemId}]]"

  if lines.len == 0:
    return @[&"  (nothing in {category.capitalizeAscii})"]
  lines


proc buyTrade*(state: var GameState; itemId: string): seq[string] =
  ## Execute a buy by receive_item ID.
  let shopId = state.variables.getOrDefault("_active_shop", newJNull()).getStr
  if shopId == "" or shopId notin content.shops:
    return @["(No shop active.)"]
  let tradeArr = content.shops[shopId].raw{"items"}
  if tradeArr == nil or tradeArr.kind != JArray:
    return @[&"('{itemId}' not available here.)"]

  var tradeNode: JsonNode
  for trade in tradeArr:
    if trade{"receive_item"}.getStr == itemId:
      tradeNode = trade
      break
  if tradeNode == nil:
    return @[&"('{itemId}' not available here.)"]

  let curId    = tradeNode{"currency_item"}.getStr(currencyId)
  let baseCost = tradeNode{"cost"}.getInt(1)
  let rAmt     = tradeNode{"receive_amount"}.getInt(1)

  var cost = adjustedCost(state, itemId, baseCost, tdBuy)

  if countItem(state, curId) < cost:
    return @[&"You need {cost} {itemDisplay(curId)}."]

  for _ in 0 ..< cost: discard takeItem(state, curId)
  for _ in 0 ..< rAmt: giveItem(state, itemId)

  let qty = if rAmt != 1: &"{rAmt}x " else: ""
  @[&"You purchase {qty}{itemDisplay(itemId)}."]


proc sellItem*(state: var GameState; itemId: string): seq[string] =
  ## Sell an inventory item for its value in currency.
  if not hasItem(state, itemId):
    return @["You don't have that."]

  let baseVal = itemValue(itemId)
  if baseVal <= 0:
    return @[&"{itemDisplay(itemId)} has no trade value."]

  let val = adjustedCost(state, itemId, baseVal, tdSell)

  discard takeItem(state, itemId)
  for _ in 0 ..< val: giveItem(state, currencyId)

  @[&"You sell {itemDisplay(itemId)} for {val} {itemDisplay(currencyId)}."]
