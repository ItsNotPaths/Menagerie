## engine/crafting.nim
## ───────────────────
## Crafting station system.
##
## Flow:
##   craft             → list stations in current room
##   craft <station>   → list items craftable at that station
##   craft_info <station> <item>  → show description + recipe + craft link
##   craft_do <station> <item>    → consume ingredients, give result
##
## Recipe format per item JSON: ["iron-ingotx3", "leatherx1"]
##   Each entry is "<item-id>x<count>".

import std/[json, strformat, strutils]
import state
import content
import items as inv


# ── Helpers ───────────────────────────────────────────────────────────────────

proc parseIngredient(s: string): tuple[id: string; count: int] =
  ## Parse "iron-ingotx3" → ("iron-ingot", 3). Falls back to (s, 1) on error.
  let xi = s.rfind('x')
  if xi <= 0 or xi == s.len - 1:
    return (s, 1)
  var n: int
  try: n = parseInt(s[xi + 1 .. ^1])
  except: return (s, 1)
  if n <= 0: return (s, 1)
  (s[0 ..< xi], n)

proc stationsInRoom(state: GameState): seq[string] =
  let roomId = state.player.currentRoom
  if roomId == "": return @[]
  let room = content.getRoom(roomId)
  if room.id == "": return @[]
  let node = room.raw{"crafting_stations"}
  if node == nil or node.kind != JArray: return @[]
  for s in node: result.add s.getStr


# ── Public API ────────────────────────────────────────────────────────────────

proc craftStationLines*(state: GameState): seq[string] =
  ## List crafting stations available in the current room as clickable links.
  let stations = stationsInRoom(state)
  if stations.len == 0:
    return @["No crafting stations here."]
  result = @["Crafting stations:", ""]
  for s in stations:
    result.add &"  [[{s}:craft {s}]]"


proc craftItemLines*(state: GameState; stationTag: string): seq[string] =
  ## List all items craftable at stationTag in the current room.
  let stations = stationsInRoom(state)
  if stationTag notin stations:
    return @[&"No {stationTag} here."]
  let craftable = content.getCraftingItems(stationTag)
  if craftable.len == 0:
    return @[&"Nothing to craft at the {stationTag}."]
  result = @[stationTag.capitalizeAscii & ":", ""]
  for id in craftable:
    let def = content.getItem(id)
    let name = if def.displayName.len > 0: def.displayName else: id
    result.add &"  [[{name}:craft_info {stationTag} {id}]]"


proc craftInfoLines*(state: GameState; stationTag, itemId: string): seq[string] =
  ## Show item description and recipe with per-ingredient have/need counts.
  let def = content.getItem(itemId)
  if def.id == "":
    return @[&"(Item '{itemId}' not found.)"]
  let name = if def.displayName.len > 0: def.displayName else: itemId
  result = @[name, "-".repeat(40)]
  if def.description.len > 0:
    result.add def.description
    result.add ""
  if def.recipe.len == 0:
    result.add "(No recipe.)"
  else:
    result.add "Recipe:"
    for ing in def.recipe:
      let (ingId, need) = parseIngredient(ing)
      let ingDef = content.getItem(ingId)
      let label  = if ingDef.displayName.len > 0: ingDef.displayName else: ingId
      let have   = inv.countItem(state, ingId)
      let status = if have >= need: "✓" else: &"({have}/{need})"
      result.add &"  {label} ×{need}  {status}"
  result.add ""
  result.add &"  [[Craft:craft_do {stationTag} {itemId}]]"
  result.add &"  [[Back:craft {stationTag}]]"


proc doCraft*(state: var GameState; stationTag, itemId: string): seq[string] =
  ## Validate station presence, check and consume all ingredients, give result.
  let stations = stationsInRoom(state)
  if stationTag notin stations:
    return @[&"No {stationTag} here."]

  let def = content.getItem(itemId)
  if def.id == "":
    return @[&"(Item '{itemId}' not found.)"]

  # Check all ingredients before consuming any
  for ing in def.recipe:
    let (ingId, need) = parseIngredient(ing)
    if inv.countItem(state, ingId) < need:
      let ingDef = content.getItem(ingId)
      let label  = if ingDef.displayName.len > 0: ingDef.displayName else: ingId
      return @[&"You need {need}x {label}."]

  # Consume ingredients
  for ing in def.recipe:
    let (ingId, need) = parseIngredient(ing)
    for _ in 0 ..< need: discard inv.takeItem(state, ingId)

  inv.giveItem(state, itemId)
  let name = if def.displayName.len > 0: def.displayName else: itemId
  @[&"You craft {name}."]
