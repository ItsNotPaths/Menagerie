## engine/sneak.nim
## ─────────────────
## Stealth / sneak system.
##
## Flow
## ────
##   sneak              — toggle sneak mode
##   sneak move         — rotate room_queue target; rolls stealth on use
##   pickpocket         — roll (sneak + pickpocket) to open target inventory
##   sneak_item npc id  — view item detail from NPC inventory, shows steal button
##   steal npc id       — take item from NPC
##   stealth_attack     — deal sneak_attack_mult * weapon damage; conditional detection

import std/[json, random, strutils, tables]
import state, content, items, modifiers, skills, saves
import combat as cbt
import world as wld


# ── Roll helpers ──────────────────────────────────────────────────────────────

proc stealthRoll*(state: GameState): bool =
  ## True = stay hidden, False = detected.
  var prob = skillPct(state, "sneak")
  prob *= modifierGet(state, "sneak_roll_pct")
  rand(1.0) < min(1.0, prob)


proc pickpocketRoll*(state: GameState): bool =
  ## True = success. Uses combined sneak + pickpocket skill.
  var prob = (skillPct(state, "sneak") + skillPct(state, "pickpocket")) / 2.0
  prob *= modifierGet(state, "pickpocket_roll_pct")
  rand(1.0) < min(1.0, prob)


# ── Sneak buttons ─────────────────────────────────────────────────────────────

proc sneakButtons*(state: GameState): seq[string] =
  if state.roomQueue.len > 0:
    result.add "  [[sneak move:sneak move]]  [[pickpocket]]  [[stealth_attack:stealth_attack]]"
  result.add "  [[sneak:sneak]]"


# ── Rotate target ─────────────────────────────────────────────────────────────

proc rotateTarget*(state: var GameState): seq[string] =
  if state.roomQueue.len == 0:
    return @["There is no one here to target.", "", "  [[sneak:sneak]]"]

  if not stealthRoll(state):
    state.sneaking = false
    return @["You stumble while repositioning -- you've been noticed!", "Stealth broken."]

  let front = state.roomQueue[0]
  state.roomQueue = state.roomQueue[1 .. ^1] & @[front]
  result = @["You reposition quietly.",
             "Target: " & state.roomQueue[0].label,
             ""]
  result &= sneakButtons(state)


# ── Pickpocket ────────────────────────────────────────────────────────────────

proc doPickpocket*(state: var GameState): seq[string] =
  if state.roomQueue.len == 0:
    return @["There is no one here to pickpocket.", "", "  [[sneak:sneak]]"]

  let target  = state.roomQueue[0]
  let npcId   = target.id
  let label   = target.label
  let loc     = state.npcStates.getOrDefault(npcId, newJNull())
  let baseId  = loc{"spawned_from"}.getStr(npcId)
  let npc     = content.getNpc(baseId)

  if pickpocketRoll(state):
    let inventory = npc.raw{"inventory"}
    if inventory == nil or inventory.len == 0:
      return @[label & " has nothing to steal.", ""] & sneakButtons(state)

    result = @[label & "'s belongings:", ""]
    for entry in inventory:
      let itemId =
        if entry.kind == JObject: entry{"item"}.getStr("")
        else: entry.getStr("")
      if itemId == "": continue
      let info   = anyItem(itemId)
      let amount =
        if entry.kind == JObject: entry{"amount"}.getInt(1)
        else: 1
      let qty = if amount > 1: " x" & $amount else: ""
      result.add "  [[" & info.displayName & qty & ":sneak_item " & npcId & " " & itemId & "]]"
    result &= @[""] & sneakButtons(state)

  else:
    state.sneaking = false
    result = @["You were caught reaching into " & label & "'s pockets!"]

    let faction = npc.faction
    if faction != "":
      let key = "bounty_" & faction
      let cur = state.variables.getOrDefault(key, %0).getInt(0)
      state.variables[key] = %(cur + 1)
      saves.flushVariables(state)

    state.npcStates.mgetOrPut(npcId, newJObject())["hostile"] = %true
    saves.flushNpcStates(state)
    wld.populateRoomQueue(state)
    result &= cbt.startCombat(state)


# ── NPC item detail ───────────────────────────────────────────────────────────

proc npcItemLines*(state: GameState; npcId, itemId: string): seq[string] =
  let info = anyItem(itemId)
  if info.id == "":
    return @["Unknown item '" & itemId & "'."]

  let desc = content.items.getOrDefault(itemId).description
  let sep  = "-".repeat(info.displayName.len)
  result = @[info.displayName, sep, ""]
  if desc != "":
    result &= @["  " & desc, ""]
  result.add "  Slots: " & $info.slotCost
  if info.damage > 0:
    result.add "  Damage: " & $info.damage
  result &= @[
    "",
    "  [[Steal:steal " & npcId & " " & itemId & "]]",
    "",
    "  [[back:pickpocket]]",
  ]


# ── Steal ─────────────────────────────────────────────────────────────────────

proc doSteal*(state: var GameState; npcId, itemId: string): seq[string] =
  let loc    = state.npcStates.getOrDefault(npcId, newJNull())
  let baseId = loc{"spawned_from"}.getStr(npcId)
  let npc    = content.getNpc(baseId)
  let label  = if npc.displayName != "": npc.displayName else: npcId

  let info = anyItem(itemId)
  if info.id == "":
    return @["Unknown item '" & itemId & "'."]

  items.giveItem(state, itemId)
  result = @["You lift " & info.displayName & " from " & label & "."] &
           sneakButtons(state)


# ── Stealth attack ────────────────────────────────────────────────────────────

proc doStealthAttack*(state: var GameState): seq[string] =
  if state.roomQueue.len == 0:
    return @["There is no one here to attack.", "", "  [[sneak:sneak]]"]

  let target  = state.roomQueue[0]
  let npcId   = target.id
  let label   = target.label
  let loc     = state.npcStates.getOrDefault(npcId, newJNull())
  let baseId  = loc{"spawned_from"}.getStr(npcId)
  let npc     = content.getNpc(baseId)

  let mult      = state.variables.getOrDefault("sneak_attack_mult", %2.0).getFloat(2.0)
  let (weapDmg, _) = cbt.weaponStats(state.player)
  var damage    = weapDmg * mult
  damage       *= modifierGet(state, "sneak_attack_damage_pct")

  let templateHp = npc.health
  let currentHp  = loc{"health"}.getFloat(templateHp)
  let newHp      = currentHp - damage

  result = @["You strike " & label & " from the shadows for " & $damage.int & " damage!"]

  if newHp <= 0:
    let dropped = wld.dropEntityLoot(state, npcId)
    if npc.faction != "" and not npc.isHostile:
      let key = "bounty_" & npc.faction
      let cur = state.variables.getOrDefault(key, %0).getInt(0)
      state.variables[key] = %(cur + 3)
      saves.flushVariables(state)

    state.npcStates.mgetOrPut(npcId, newJObject())["health"] = %0.0
    saves.flushNpcStates(state)

    result.add label & " crumples silently."
    result &= dropped

    state.roomQueue = block:
      var q: seq[RoomOccupant]
      for occ in state.roomQueue:
        if occ.id != npcId: q.add occ
      q

    if state.roomQueue.len > 0:
      result &= @["", "Target: " & state.roomQueue[0].label, ""]
    else:
      result &= @["", "The room is silent.", ""]
    result &= sneakButtons(state)

  else:
    state.npcStates.mgetOrPut(npcId, newJObject())["health"] = %newHp
    saves.flushNpcStates(state)
    result.add label & " has " & $newHp.int & " health remaining."

    if stealthRoll(state):
      result &= @["You remain unseen.", ""] & sneakButtons(state)
    else:
      state.sneaking = false
      result.add "You've been spotted!"
      state.npcStates.mgetOrPut(npcId, newJObject())["hostile"] = %true
      saves.flushNpcStates(state)
      wld.populateRoomQueue(state)
      result &= cbt.startCombat(state)
