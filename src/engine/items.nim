## engine/items.nim
## ─────────────────
## Inventory helpers: give, take, query, slot capacity.
## Uses content tables loaded at startup — no file I/O during gameplay.
##
## Equippable items are stored as individual inventory entries (count = 1 each)
## so the same item can appear in both mainhand and offhand.
## Non-equippable items stack (count is incremented on an existing entry).

import std/[sequtils, tables]
import state
import content
import gameplay_vars


# ── Unified item lookup ───────────────────────────────────────────────────────

type
  ItemInfo* = object
    id*, displayName*, itemType*, zone*: string
    slotCost*, damage*, staminaCost*:    int
    defense*, extraSlots*, staminaReq*:  int
    canEquip*:                           bool
    effects*:                            seq[string]


proc anyItem*(id: string): ItemInfo =
  ## Look up id in items first, then armor_plates.
  ## Returns an empty ItemInfo (id = "") if not found.
  if id in content.items:
    let d = content.items[id]
    result = ItemInfo(
      id:          id,
      displayName: d.displayName,
      itemType:    d.itemType,
      slotCost:    d.slotCost,
      damage:      d.damage,
      staminaCost: d.staminaCost,
      extraSlots:  d.extraSlots,
      staminaReq:  d.staminaReq,
      canEquip:    d.canEquip,
      effects:     d.effects,
    )
  elif id in content.armorPlates:
    let d = content.armorPlates[id]
    result = ItemInfo(
      id:          id,
      displayName: d.displayName,
      itemType:    "armor",
      zone:        d.zone,
      defense:     d.defense,
      slotCost:    1,
      canEquip:    true,
    )


# ── Core inventory ops ────────────────────────────────────────────────────────

proc giveItem*(state: var GameState; itemId: string) =
  ## Add one copy of itemId to inventory.
  let info = anyItem(itemId)
  if not info.canEquip:
    for i in 0 ..< state.player.inventory.len:
      if state.player.inventory[i].id == itemId:
        inc state.player.inventory[i].count
        return
  state.player.inventory.add InventoryEntry(
    id:    itemId,
    slots: info.slotCost,
    count: 1,
  )


proc takeItem*(state: var GameState; itemId: string): bool =
  ## Remove one copy of itemId. Returns false if not found.
  let info = anyItem(itemId)
  if info.canEquip:
    var equipped: seq[string] = @[state.player.mainhand, state.player.offhand]
    for v in state.player.armor.values(): equipped.add v
    for c in state.player.containers:    equipped.add c
    var fallback = -1
    for i in 0 ..< state.player.inventory.len:
      if state.player.inventory[i].id == itemId:
        if itemId notin equipped:
          state.player.inventory.delete(i)
          return true
        if fallback < 0: fallback = i
    if fallback >= 0:
      state.player.inventory.delete(fallback)
      return true
    return false
  for i in 0 ..< state.player.inventory.len:
    if state.player.inventory[i].id == itemId:
      dec state.player.inventory[i].count
      if state.player.inventory[i].count <= 0:
        state.player.inventory.delete(i)
      return true
  false


proc hasItem*(state: GameState; itemId: string): bool =
  state.player.inventory.anyIt(it.id == itemId)


proc countItem*(state: GameState; itemId: string): int =
  for e in state.player.inventory:
    if e.id == itemId: result += e.count


proc countAvailable*(state: GameState; itemId: string): int =
  ## Copies in inventory not currently occupying an equipped slot.
  var equipped = 0
  if state.player.mainhand == itemId: inc equipped
  if state.player.offhand  == itemId: inc equipped
  for v in state.player.armor.values():
    if v == itemId: inc equipped
  for c in state.player.containers:
    if c == itemId: inc equipped
  max(0, countItem(state, itemId) - equipped)


# ── Slot capacity ─────────────────────────────────────────────────────────────

const baseSlotDefault = 20

proc containerSlotCap*(state: GameState): int =
  result = gvInt("base_inventory_slots", baseSlotDefault)
  for iid in state.player.containers:
    result += anyItem(iid).extraSlots


proc slotsUsed*(state: GameState): int =
  for e in state.player.inventory:
    result += e.slots * e.count


proc containerStaminaUsed*(state: GameState): int =
  for iid in state.player.containers:
    result += anyItem(iid).staminaReq


proc containerStaminaCap*(state: GameState): int =
  int(state.player.maxStamina)


# ── Overflow handling ─────────────────────────────────────────────────────────

proc dropOverflowItems*(state: var GameState): seq[string] =
  ## Remove trailing inventory items until within slot capacity.
  ## Returns display names of everything dropped.
  while slotsUsed(state) > containerSlotCap(state):
    if state.player.inventory.len == 0: break
    let last = state.player.inventory[^1]
    result.add anyItem(last.id).displayName
    state.player.inventory.setLen(state.player.inventory.len - 1)
