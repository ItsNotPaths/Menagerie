## commands/cmd_inventory.nim
## ───────────────────────────
## inventory, equip, unequip, consume, favourite_item, unfavourite_item.
## Call initCmdInventory() from game_loop to register handlers.

import std/[sequtils, strformat, strutils, tables]
import engine/state
import engine/content
import engine/items
import commands/core
import engine/api

const invCategories  = ["weapon", "armor", "consumable", "container",
                        "material", "quest", "currency"]
const armorSlotOrder = ["head", "chest", "hands", "legs", "feet", "back", "neck", "ring"]


proc equippedLines(p: PlayerState): seq[string] =
  if p.mainhand != "":
    result.add &"  Mainhand : {anyItem(p.mainhand).displayName}"
  if p.offhand != "":
    result.add &"  Offhand  : {anyItem(p.offhand).displayName}"
  for slot in armorSlotOrder:
    let aid = p.armor.getOrDefault(slot, "")
    if aid != "":
      result.add &"  {slot.capitalizeAscii:<9}: {anyItem(aid).displayName}"
  for cid in p.containers:
    result.add &"  Container: {anyItem(cid).displayName}"


proc itemDetailLines(state: GameState; itemId: string): seq[string] =
  let info = anyItem(itemId)
  let p    = state.player
  var desc = ""
  if itemId in content.items: desc = content.items[itemId].description.strip

  result.add info.displayName
  result.add "-".repeat(info.displayName.len)
  result.add ""
  if desc != "":
    result.add &"  {desc}"
    result.add ""
  result.add &"  Slots: {info.slotCost}   ×{countItem(state, itemId)}"
  if info.damage > 0:      result.add &"  Damage:       {info.damage}"
  if info.staminaCost > 0: result.add &"  Stamina Cost: {info.staminaCost}"
  if info.defense > 0:     result.add &"  Defense:      {info.defense}"
  result.add ""
  if info.extraSlots > 0:
    result.add &"  Slots granted:  +{info.extraSlots}"
  if info.staminaReq > 0:
    let used = containerStaminaUsed(state)
    let cap  = containerStaminaCap(state)
    result.add &"  Stamina req:    {info.staminaReq}  ({used}/{cap} used)"

  if info.itemType == "consumable":
    result.add &"  [[Consume:consume {itemId}]]"
  elif info.itemType == "container":
    let equippedCount = p.containers.count(itemId)
    let available     = countAvailable(state, itemId)
    if equippedCount > 0:
      let badge = if equippedCount > 1: &"  ×{equippedCount}" else: ""
      result.add &"  Equipped{badge}"
      result.add ""
    if available > 0:
      result.add &"  [[Equip:equip container {itemId}]]"
    if equippedCount > 0:
      result.add &"  [[Unequip:unequip container {itemId}]]"
  elif info.itemType == "armor":
    let zone   = info.zone
    let inSlot = zone != "" and p.armor.getOrDefault(zone, "") == itemId
    if inSlot:
      result.add &"  Equipped: {zone.capitalizeAscii}"
      result.add ""
    if zone != "":
      if inSlot:
        result.add &"  [[Unequip:unequip {zone}]]"
      else:
        result.add &"  [[Equip {zone.capitalizeAscii}:equip {zone} {itemId}]]"
  elif info.canEquip:
    let inMainhand = p.mainhand == itemId
    let inOffhand  = p.offhand  == itemId
    if inMainhand or inOffhand:
      var slots: seq[string]
      if inMainhand: slots.add "Mainhand"
      if inOffhand:  slots.add "Offhand"
      result.add &"  Equipped: {slots.join(\"  +  \")}"
      result.add ""
    let mhLink = if inMainhand: "[[Unequip Mainhand:unequip mainhand]]"
                 else: &"[[Equip Mainhand:equip mainhand {itemId}]]"
    let ohLink = if inOffhand: "[[Unequip Offhand:unequip offhand]]"
                 else: &"[[Equip Offhand:equip offhand {itemId}]]"
    result.add &"  {mhLink}   {ohLink}"

  result.add ""
  if itemId in p.itemFavourites:
    result.add &"  [[unfavourite:unfavourite_item {itemId}]]"
  else:
    result.add &"  [[favourite:favourite_item {itemId}]]"


proc cmdInventory(state: var GameState; args: seq[string]): CmdResult =
  let p = state.player

  # inventory item <id> — panel detail view
  if args.len >= 1 and args[0] == "item":
    if args.len < 2:
      return err("Usage: inventory item <item_id>")
    let itemId = args[1].toLowerAscii
    if not hasItem(state, itemId):
      return err(&"You don't have '{itemId}'.")
    let info = anyItem(itemId)
    if info.id == "":
      return err(&"Unknown item '{itemId}'.")
    return CmdResult(panelLines: itemDetailLines(state, itemId))

  # inventory <category> — category listing
  if args.len >= 1:
    let category   = args[0].toLowerAscii
    let typeAlias  = {"shield": "armor"}.toTable
    var catItems: seq[InventoryEntry]
    for e in p.inventory:
      var t = anyItem(e.id).itemType.toLowerAscii
      t = typeAlias.getOrDefault(t, t)
      if t == category: catItems.add e
    if catItems.len == 0:
      return CmdResult(lines: @[&"  (no {category} items)"])

    var labelQueues = initTable[string, seq[string]]()
    if p.mainhand != "": labelQueues.mgetOrPut(p.mainhand, @[]).add "[MH]"
    if p.offhand  != "": labelQueues.mgetOrPut(p.offhand,  @[]).add "[OH]"
    for aslot, aid in p.armor:
      labelQueues.mgetOrPut(aid, @[]).add &"[{aslot.capitalizeAscii}]"

    var lines: seq[string]
    for entry in catItems:
      let name  = anyItem(entry.id).displayName
      let qty   = if entry.count > 1: &"  ×{entry.count}" else: ""
      var badge = ""
      if labelQueues.hasKey(entry.id):
        var q = labelQueues[entry.id]
        if q.len > 0:
          badge = &"  {q[0]}"
          q.del(0)
          labelQueues[entry.id] = q
      lines.add &"  [[{name}:inventory item {entry.id}]]{qty}{badge}"
    return CmdResult(lines: lines)

  # inventory — top-level browser
  let used = slotsUsed(state)
  let cap  = containerSlotCap(state)
  var lines: seq[string]
  lines.add &"Inventory  [{used} / {cap} slots]"

  let presentFavs = p.itemFavourites.filterIt(hasItem(state, it))
  if presentFavs.len > 0:
    lines.add ""
    for iid in presentFavs:
      let name  = anyItem(iid).displayName
      let count = countItem(state, iid)
      let qty   = if count > 1: &"  ×{count}" else: ""
      lines.add &"  ★ [[{name}:inventory item {iid}]]{qty}"

  lines.add ""
  for c in invCategories:
    lines.add &"  [[{c.capitalizeAscii}:inventory {c}]]"

  let eqLines = equippedLines(p)
  if eqLines.len > 0:
    lines.add ""
    for l in eqLines: lines.add l

  CmdResult(lines: lines)


proc cmdEquip(state: var GameState; args: seq[string]): CmdResult =
  if args.len < 2:
    return err("Usage: equip <mainhand|offhand|slot|container> <item_id>")
  let slot   = args[0].toLowerAscii
  let itemId = args[1].toLowerAscii
  let info   = anyItem(itemId)
  if info.id == "":
    return err(&"Unknown item '{itemId}'.")
  if not hasItem(state, itemId):
    return err(&"You don't have '{itemId}'.")
  let p    = addr state.player
  let name = info.displayName

  if slot == "container":
    if info.itemType != "container":
      return err(&"{name} is not a container.")
    if countAvailable(state, itemId) < 1:
      return err(&"No unequipped copy of {name} available.")
    let req  = info.staminaReq
    let used = containerStaminaUsed(state)
    let cap  = containerStaminaCap(state)
    if used + req > cap:
      return err(&"Not enough stamina budget. ({name} needs {req}, {used}/{cap} already used)")
    p[].containers.add itemId
    let extra   = info.extraSlots
    let newUsed = containerStaminaUsed(state)
    let newCap  = containerStaminaCap(state)
    let fresh   = itemDetailLines(state, itemId)
    return CmdResult(
      lines:      @[&"Equipped {name}. (+{extra} slots | stamina {newUsed}/{newCap})"],
      panelLines: fresh, panelAppend: true)

  elif slot in ["mainhand", "offhand"]:
    if not info.canEquip:
      return err(&"{name} cannot be equipped.")
    if countAvailable(state, itemId) < 1:
      return err(&"No unequipped copy of {name} available.")
    if slot == "mainhand": p[].mainhand = itemId
    else:                  p[].offhand  = itemId

  elif slot in armorSlotOrder:
    if info.itemType != "armor":
      return err(&"{name} is not an armor piece.")
    for s in armorSlotOrder:
      if p[].armor.getOrDefault(s, "") == itemId:
        p[].armor.del(s)
    p[].armor[slot] = itemId

  else:
    return err(&"Unknown slot '{slot}'.")

  let fresh = itemDetailLines(state, itemId)
  CmdResult(lines: @[&"Equipped {name} in {slot}."],
            panelLines: fresh, panelAppend: true)


proc cmdUnequip(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: unequip <mainhand|offhand|slot|container> [item_id]")
  let slot = args[0].toLowerAscii
  let p    = addr state.player

  if slot == "container":
    if args.len < 2:
      return err("Usage: unequip container <item_id>")
    let itemId = args[1].toLowerAscii
    let idx    = p[].containers.find(itemId)
    if idx < 0:
      return err(&"'{itemId}' is not equipped as a container.")
    let name = anyItem(itemId).displayName
    p[].containers.del(idx)
    let newCap     = containerSlotCap(state)
    let stamUsed   = containerStaminaUsed(state)
    let stamCap    = containerStaminaCap(state)
    let overflowed = dropOverflowItems(state)
    var lines      = @[&"Unequipped {name}. (cap now {newCap} | stamina {stamUsed}/{stamCap})"]
    if overflowed.len > 0:
      lines.add ""
      lines.add "Your inventory is over the new limit:"
      for d in overflowed: lines.add &"  {d}"
    let fresh = itemDetailLines(state, itemId)
    return CmdResult(lines: lines, panelLines: fresh, panelAppend: true)

  if slot == "mainhand":
    if p[].mainhand == "":
      return err("Nothing equipped in mainhand.")
    let itemId = p[].mainhand
    let name   = anyItem(itemId).displayName
    p[].mainhand = ""
    let fresh = itemDetailLines(state, itemId)
    return CmdResult(lines: @[&"Unequipped {name} from mainhand."],
                     panelLines: fresh, panelAppend: true)

  if slot == "offhand":
    if p[].offhand == "":
      return err("Nothing equipped in offhand.")
    let itemId = p[].offhand
    let name   = anyItem(itemId).displayName
    p[].offhand = ""
    let fresh = itemDetailLines(state, itemId)
    return CmdResult(lines: @[&"Unequipped {name} from offhand."],
                     panelLines: fresh, panelAppend: true)

  if slot in armorSlotOrder:
    let itemId = p[].armor.getOrDefault(slot, "")
    if itemId == "":
      return err(&"Nothing equipped in {slot}.")
    let name = anyItem(itemId).displayName
    p[].armor.del(slot)
    let fresh = itemDetailLines(state, itemId)
    return CmdResult(lines: @[&"Unequipped {name} from {slot}."],
                     panelLines: fresh, panelAppend: true)

  err(&"Unknown slot '{slot}'.")


proc cmdConsume(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: consume <item_id>")
  let itemId = args[0].toLowerAscii
  if not hasItem(state, itemId):
    return err(&"You don't have '{itemId}'.")
  let info = anyItem(itemId)
  if info.id == "":
    return err(&"Unknown item '{itemId}'.")
  if info.itemType != "consumable":
    return err(&"'{info.displayName}' is not a consumable.")
  var effectLines: seq[string]
  for cmdStr in info.effects:
    effectLines &= api.runCommand(state, cmdStr, "player")
  discard takeItem(state, itemId)
  let fresh = if hasItem(state, itemId): itemDetailLines(state, itemId) else: @[]
  var lines = @[&"You use {info.displayName}."]
  lines.add effectLines
  CmdResult(lines: lines, panelLines: fresh, panelAppend: true)


proc cmdFavouriteItem(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: favourite_item <item_id>")
  let itemId = args[0].toLowerAscii
  if not hasItem(state, itemId):
    return err(&"You don't have '{itemId}'.")
  if itemId in state.player.itemFavourites:
    let fresh = itemDetailLines(state, itemId)
    return CmdResult(lines: @[&"'{itemId}' is already a favourite."],
                     panelLines: fresh, panelAppend: true)
  state.player.itemFavourites.add itemId
  let fresh = itemDetailLines(state, itemId)
  CmdResult(lines: @[&"Added '{itemId}' to favourites."],
            panelLines: fresh, panelAppend: true)


proc cmdUnfavouriteItem(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: unfavourite_item <item_id>")
  let itemId = args[0].toLowerAscii
  let idx    = state.player.itemFavourites.find(itemId)
  if idx < 0:
    let fresh = itemDetailLines(state, itemId)
    return CmdResult(lines: @[&"'{itemId}' is not in favourites."],
                     panelLines: fresh, panelAppend: true)
  state.player.itemFavourites.del(idx)
  let fresh = itemDetailLines(state, itemId)
  CmdResult(lines: @[&"Removed '{itemId}' from favourites."],
            panelLines: fresh, panelAppend: true)


proc initCmdInventory*() =
  registerAny("inventory",       cmdInventory)
  registerAny("equip",           cmdEquip,          hidden = true)
  registerAny("unequip",         cmdUnequip,        hidden = true)
  registerAny("consume",         cmdConsume,        hidden = true)
  registerAny("favourite_item",  cmdFavouriteItem,  hidden = true)
  registerAny("unfavourite_item",cmdUnfavouriteItem,hidden = true)
