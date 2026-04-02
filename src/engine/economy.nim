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
  0


# ── Economic event helpers ────────────────────────────────────────────────────

proc activeEvent(state: var GameState): JsonNode =
  ## Return the active economic event if still within its tick_scope, else expire it.
  let ev = state.variables.getOrDefault("_active_economic_event", newJNull())
  if ev.kind != JObject: return newJNull()
  let elapsed = state.player.tick - ev{"tick_start"}.getInt(0)
  if elapsed >= ev{"tick_scope"}.getInt(0):
    state.variables.del("_active_economic_event")
    return newJNull()
  ev

proc adjustedCost(state: var GameState; itemId: string; baseCost: int): int =
  ## Scale buy price by the active economic event if the item's tags match.
  let ev = activeEvent(state)
  if ev.kind != JObject: return baseCost
  let itemNode = state.variables.getOrDefault("__dummy", newJNull())   # unused
  var tags: seq[string]
  if itemId in content.items:
    let raw = content.items[itemId]
    discard raw   # tags not in typed ItemDef — check raw JSON not available here
    # economic events require item tags which are not stored in typed content;
    # fall back to base cost (events not yet authored in content)
  baseCost


# ── Public API ────────────────────────────────────────────────────────────────

proc shopLines*(state: GameState): seq[string] =
  ## Top-level shop view: category links + player sell panel.
  let shopId = state.variables.getOrDefault("_active_shop", newJNull()).getStr
  if shopId == "" or shopId notin content.shops:
    return @["(No shop active.)"]
  let shopRaw = content.shops[shopId].raw
  let tradeArr = shopRaw{"items"}
  if tradeArr == nil or tradeArr.kind != JArray:
    return @["  (Nothing for sale.)", "", "  [[Leave:farewell]]"]

  # Collect ordered unique categories
  var seen: seq[string]
  for trade in tradeArr:
    let t = itemType(trade{"receive_item"}.getStr)
    if t notin seen: seen.add t

  var lines: seq[string]
  if seen.len > 0:
    for c in seen: lines.add &"  [[{c.capitalizeAscii}:shop {c}]]"
  else:
    lines.add "  (Nothing for sale.)"

  # Sell panel: player inventory items that have a value
  var sellLines: seq[string]
  for e in state.player.inventory:
    let v = itemValue(e.id)
    if v > 0:
      sellLines.add &"  [[{itemDisplay(e.id)} -- {v} currency:sell {e.id}]]"
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
  shopLines(state)


proc shopCategoryLines*(state: GameState; category: string): seq[string] =
  ## List trades for a given category.
  let shopId = state.variables.getOrDefault("_active_shop", newJNull()).getStr
  if shopId == "" or shopId notin content.shops:
    return @["(No shop active.)"]
  let tradeArr = content.shops[shopId].raw{"items"}
  if tradeArr == nil or tradeArr.kind != JArray:
    return @[&"  (nothing in {category.capitalizeAscii})"]

  var lines: seq[string]
  for trade in tradeArr:
    let itemId = trade{"receive_item"}.getStr
    if itemType(itemId) != category.toLowerAscii: continue
    let amount  = trade{"receive_amount"}.getInt(1)
    let curId   = trade{"currency_item"}.getStr(currencyId)
    let cost    = trade{"cost"}.getInt(1)
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

  # Mercantile skill reduces buy price (1.5x at 0, 1.0x at 100)
  let mercPct = sk.skillPct(state, "mercantile")
  var cost    = max(1, int(round(baseCost.float * (1.5 - mercPct * 0.5))))
  # modifier: "buy_price_pct" — negative = cheaper
  cost = max(1, int(round(cost.float * mods.modifierGet(state, "buy_price_pct"))))

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

  # Mercantile skill increases sell value (0.5x at 0, 1.0x at 100)
  let mercPct = sk.skillPct(state, "mercantile")
  var val     = max(1, int(round(baseVal.float * (0.5 + mercPct * 0.5))))
  # modifier: "sell_price_pct" — positive = higher payout
  val = max(1, int(round(val.float * mods.modifierGet(state, "sell_price_pct"))))

  discard takeItem(state, itemId)
  for _ in 0 ..< val: giveItem(state, currencyId)

  @[&"You sell {itemDisplay(itemId)} for {val} currency."]
