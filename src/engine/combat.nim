## engine/combat.nim
## ─────────────────
## Spatial grid combat system.
##
## Turn structure each round
## ─────────────────────────
## 1. beginRound: regen -> effects tick -> traps fire -> enemy phase (move +
##    commit, silent) -> show positions + option buttons.  Player predicts.
## 2. Player action: one of attack / dodge / block / pass / cast / flee / aux.
## 3. resolveRound: player action fires -> committed enemy attacks land
##    (dodge / block apply) -> deaths checked -> beginRound for next round.
##
## Dodge token
## ───────────
## Choosing dodge sets dodgeToken = 1.  During resolution the first enemy hit
## consumes the token and deals 0 damage.  Remaining enemies at melee range
## hit normally.  Token is cleared at round end whether used or not.
##
## Resource trifecta
## ─────────────────
##   dodge  -> stamina out  | health + focus in
##   cast   -> focus out    | stamina + health in
##   block  -> health out   | stamina + focus in
##   attack -> stamina out  | (no recovery — baseline action)
##
## Cast modes
## ──────────
##   smite — single cell (row, dist)           damage × 1.0
##   trap  — delayed charge at (row, dist)     fires next round × 2.0
##   beam  — all enemies on a row              damage × 0.6
##   wave  — all enemies within 1 row of tgt  damage × 0.35

import std/[algorithm, json, options, random, sequtils, strformat, strutils, tables]
import state, content, gameplay_vars, saves
import api
import clock
import conditions as cond
import modifiers  as mods
import items      as itms
import world
import skills     as sk
import spells     as sp

const COMBAT_PAUSE* = api.COMBAT_PAUSE


include "combat_ai.nim"

# ── Enemy phase ───────────────────────────────────────────────────────────────

proc runEnemyPhase(state: var GameState): (seq[string], seq[string]) =
  ## Each enemy takes exactly one action.
  ## Returns (attackingIds, narrationLines).
  ## narrationLines has COMBAT_PAUSE after each enemy block.
  if not state.combat.isSome: return
  var attacking: seq[string]
  var narration: seq[string]
  let cs = state.combat.get

  for i in 0..<cs.enemies.len:
    if cs.enemies[i].anchored > 0:
      narration.add &"  {cs.enemies[i].label} is pinned in place."
      narration.add COMBAT_PAUSE
      continue

    let action = pickAction(cs.enemies[i], state)
    let act    = if action != nil: action{"action"}.getStr("advance") else: "advance"

    let telegraphs = cs.enemies[i].data{"telegraphs"}
    proc telegraph(key, fallback: string): string =
      if telegraphs != nil and telegraphs.kind == JObject:
        let msgs = telegraphs{key}
        if msgs != nil and msgs.kind == JArray and msgs.len > 0:
          return msgs[0].getStr
      fallback

    case act
    of "end_turn":
      narration.add telegraph("end_turn", &"  {cs.enemies[i].label} holds position.")
      narration.add COMBAT_PAUSE

    of "advance":
      cs.enemies[i].distance = max(1, cs.enemies[i].distance - cs.enemies[i].speed)
      narration.add telegraph("advance", &"  {cs.enemies[i].label} advances.")
      narration.add &"    -> row {cs.enemies[i].row}, dist {cs.enemies[i].distance}"
      narration.add COMBAT_PAUSE

    of "retreat":
      let amount = action{"amount"}.getInt(gvInt("retreat_default_distance", 2))
      cs.enemies[i].distance = min(9, cs.enemies[i].distance + amount)
      narration.add telegraph("retreat", &"  {cs.enemies[i].label} falls back.")
      narration.add &"    -> row {cs.enemies[i].row}, dist {cs.enemies[i].distance}"
      narration.add COMBAT_PAUSE

    of "sidestep":
      cs.enemies[i].row = max(1, min(9, action{"row"}.getInt(cs.enemies[i].row)))
      narration.add telegraph("sidestep", &"  {cs.enemies[i].label} shifts position.")
      narration.add &"    -> row {cs.enemies[i].row}, dist {cs.enemies[i].distance}"
      narration.add COMBAT_PAUSE

    of "attack":
      let costS = action{"cost"}{"stamina"}.getFloat(1.0)
      cs.enemies[i].stamina = max(0.0, cs.enemies[i].stamina - costS)
      attacking.add cs.enemies[i].id
      narration.add telegraph("attack", &"  {cs.enemies[i].label} moves to attack!")
      narration.add &"    -> row {cs.enemies[i].row}, dist {cs.enemies[i].distance}"
      narration.add COMBAT_PAUSE

    else:  # cast* and unknowns
      if act.startsWith("cast"):
        let costF = action{"cost"}{"focus"}.getFloat(1.0)
        cs.enemies[i].focus = max(0.0, cs.enemies[i].focus - costF)
        attacking.add cs.enemies[i].id
        narration.add telegraph("cast", &"  {cs.enemies[i].label} begins to cast...")
      else:
        # Unknown — default advance
        cs.enemies[i].distance = max(1, cs.enemies[i].distance - cs.enemies[i].speed)
        narration.add &"  {cs.enemies[i].label} advances."
      narration.add &"    -> row {cs.enemies[i].row}, dist {cs.enemies[i].distance}"
      narration.add COMBAT_PAUSE

  (attacking, narration)


# ── Trap system ───────────────────────────────────────────────────────────────

proc fireTraps(state: var GameState): seq[string] =
  if not state.combat.isSome: return
  let cs = state.combat.get
  var survivors: seq[CombatTrap]

  for trap in cs.traps:
    var t = trap
    dec t.turns
    if t.turns <= 0:
      let hits = cs.enemies.filterIt(it.row == t.row and it.distance == t.distance)
      if hits.len > 0:
        result.add &"  Trap fires — {t.spellId}:"
        let spDef = content.getSpell(t.spellId)
        for e in hits:
          result &= api.cmdDamage(state, "enemy." & e.id, e.id, t.strength, "health")
        if spDef.id != "":
          result &= sp.applySpellEffects(state, spDef,hits.mapIt(it.id))
      else:
        result.add &"  Trap at ({t.row},{t.distance}) expires — no target."
    else:
      survivors.add t

  cs.traps = survivors


include "combat_display.nim"

# ── Weapon / resistance helpers ───────────────────────────────────────────────

proc enemyAttackDamage(enemy: CombatEnemy): float =
  ## Base damage + first weapon found in enemy inventory.
  result = enemy.data{"damage"}.getFloat(gvFloat("base_enemy_damage", 8.0))
  let inv = enemy.data{"inventory"}
  if inv == nil or inv.kind != JArray: return
  for entry in inv:
    let itemId = entry{"item"}.getStr.strip
    if itemId == "": continue
    let info = itms.anyItem(itemId)
    if info.itemType.toLowerAscii == "weapon":
      result += info.damage.float
      return


proc shieldReduction(player: PlayerState): float =
  for itemId in [player.mainhand, player.offhand]:
    if itemId == "": continue
    let info = itms.anyItem(itemId)
    if info.itemType.toLowerAscii == "shield":
      result += info.defense.float   ## shield_strength maps to defense in ItemInfo


proc applyResistances(enemy: CombatEnemy; damage: float; damageType: string): float  # forward decl

proc spellLabel(spDef: SpellDef): string =
  if spDef.displayName != "": spDef.displayName else: spDef.id

proc announceWeaponSpells(weaponId: string; hits: seq[CombatEnemy]): seq[string] =
  ## Narration only — describes which spells the weapon is about to trigger.
  ## Wielder spells flow into the attacker; recipient spells flow into the
  ## hit enemies. Called *before* damage so the announcement reads naturally.
  if weaponId == "" or weaponId notin content.items: return
  let def = content.items[weaponId]
  for spellId in def.wielderSpells:
    let spDef = content.getSpell(spellId)
    if spDef.id == "": continue
    result.add &"  Your attack channels {spellLabel(spDef)} into you."
  if hits.len == 0: return
  let names = hits.mapIt(it.label).join(", ")
  for spellId in def.recipientSpells:
    let spDef = content.getSpell(spellId)
    if spDef.id == "": continue
    result.add &"  Your attack inflicts {spellLabel(spDef)} upon {names}."

proc applyWeaponSpells(state: var GameState; weaponId: string;
                       hits: seq[CombatEnemy]): seq[string] =
  ## Apply wielder_spells to the player and recipient_spells to each hit enemy.
  ## Runs status effects, on_hit_commands, and the spell's authored damage
  ## (spells like "death" carry raw damage instead of an effects array).
  if weaponId == "" or weaponId notin content.items: return
  let def = content.items[weaponId]

  for spellId in def.wielderSpells:
    let spDef = content.getSpell(spellId)
    if spDef.id == "": continue
    result &= sp.applySpellEffects(state, spDef, @["player"])
    for cmdStr in spDef.onHitCommands:
      result &= api.runCommand(state, cmdStr, "player")
    if spDef.damage != 0.0:
      result &= api.cmdDamage(state, "player", "player", spDef.damage, "health")

  if hits.len == 0: return
  let hitIds = hits.mapIt(it.id)
  for spellId in def.recipientSpells:
    let spDef = content.getSpell(spellId)
    if spDef.id == "": continue
    result &= sp.applySpellEffects(state, spDef, hitIds)
    for cmdStr in spDef.onHitCommands:
      for eid in hitIds:
        result &= api.runCommand(state, cmdStr, eid)
    if spDef.damage != 0.0:
      for e in hits:
        let dmg = applyResistances(e, spDef.damage, spellId)
        result &= api.cmdDamage(state, "enemy." & e.id, e.id, dmg, "health")


proc resolvedWeaponSkill(itemId: string): string =
  ## Derive the skill from damage_type + hand_type:
  ##   bow                     -> archery (regardless of hand_type)
  ##   one_handed + blade      -> shortblade
  ##   two_handed + blade      -> longblade
  ##   one_handed + blunt      -> shortblunt
  ##   two_handed + blunt      -> longblunt
  if itemId notin content.items: return "longblade"
  let def = content.items[itemId]
  if def.damageType == "bow": return "archery"
  let twoHanded = def.handType == "two_handed"
  case def.damageType
  of "blunt": (if twoHanded: "longblunt" else: "shortblunt")
  else:       (if twoHanded: "longblade" else: "shortblade")


proc applyResistances(enemy: CombatEnemy; damage: float; damageType: string): float =
  ## Scales `damage` by the enemy's resistance modifier for `damageType`.
  ## Resistances are authored as an array: [{"effect": "bleed", "modifier": 2.0}, ...]
  ## A modifier > 1 means vulnerable; < 1 means resistant. Missing entry = no change.
  result = damage
  let resNode = enemy.data{"resistances"}
  if resNode == nil or resNode.kind != JArray: return
  for entry in resNode:
    if entry{"effect"}.getStr == damageType:
      result = damage * entry{"modifier"}.getFloat(1.0)
      return


# ── Kill helpers ──────────────────────────────────────────────────────────────

proc killEnemy(state: var GameState; enemy: CombatEnemy): (seq[string], seq[string]) =
  ## Drop loot, apply bounty, fire death_script and kill event.
  ## Returns (eventLines, droppedItemIds) so callers can summarise loot.
  let dropped = world.dropEntityLoot(state, enemy.id)
  # Bounty: only for non-hostile NPCs (civilians attacked by player)
  let faction = enemy.data{"faction"}.getStr
  if faction != "" and not enemy.data{"is_hostile"}.getBool(false):
    let prev = state.variables.getOrDefault(&"bounty_{faction}", %0).getInt(0)
    state.variables[&"bounty_{faction}"] = %(prev + 3)
    saves.flushVariables(state)
  saves.flushNpcStates(state)
  result[1] = dropped
  let deathScript = enemy.data{"death_script"}.getStr
  if deathScript != "":
    result[0] &= api.runCommand(state, deathScript, enemy.id)
  result[0] &= mods.fireEvent(state, "kill", enemy.id)


proc lootSummary(itemIds: seq[string]): string =
  var counts: Table[string, int]
  for id in itemIds: counts[id] = counts.getOrDefault(id, 0) + 1
  var parts: seq[string]
  for id, n in counts:
    parts.add(if n > 1: &"{id} x{n}" else: id)
  parts.join(", ")


# ── Nemesis ───────────────────────────────────────────────────────────────────

const nemesisPrefixes = [
  "monstrous", "fearless", "relentless", "brutal", "vicious",
  "cunning", "savage", "wicked", "loathsome", "wretched",
  "dreadful", "hateful", "vengeful", "feral", "ravenous",
]

proc applyNemesis(state: var GameState; enemyId: string): string =
  ## Give the killing enemy a random nemesis prefix.  Returns new label.
  var baseLabel = state.npcStates.getOrDefault(enemyId, newJNull()){"spawned_from"}.getStr(enemyId)
  for pfx in nemesisPrefixes:
    if baseLabel.startsWith(pfx & " "):
      baseLabel = baseLabel[pfx.len + 1..^1]
      break
  let prefix   = nemesisPrefixes[rand(nemesisPrefixes.len - 1)]
  let newLabel = &"{prefix} {baseLabel}"
  if enemyId in state.npcStates and state.npcStates[enemyId].kind == JObject:
    state.npcStates[enemyId]["label_override"] = %newLabel
    state.npcStates[enemyId]["nemesis"]        = %true
    saves.flushNpcStates(state)
  # Update label in active combat
  if state.combat.isSome:
    let cs = state.combat.get
    for i in 0..<cs.enemies.len:
      if cs.enemies[i].id == enemyId:
        cs.enemies[i].label = newLabel
        break
  newLabel


# ── Player death ──────────────────────────────────────────────────────────────

proc playerDeath(state: var GameState; killerId: string): seq[string] =
  ## All on-death side-effects after "You have fallen." is already printed.
  let p = addr state.player
  # Currency penalty
  let lossPct = gvFloat("death_gold_loss", 0.2)
  let lost    = int(itms.countItem(state, "currency").float * lossPct)
  if lost > 0:
    for _ in 0 ..< lost: discard itms.takeItem(state, "currency")
    result.add &"You lost {lost} gold."
  # Nemesis
  if killerId != "":
    let newLabel = applyNemesis(state, killerId)
    result.add &"The {newLabel} looms over your body."
    saves.flushNpcStates(state)
  # Respawn: advance time, restore minimal stats, teleport to last rest
  clock.passTicks(state, gvInt("death_respawn_ticks", 30))
  p.health  = gvFloat("death_respawn_health",  10.0)
  p.stamina = gvFloat("death_respawn_stamina", 10.0)
  p.focus   = gvFloat("death_respawn_focus",   10.0)
  state.combat = none(CombatState)
  if p.lastRestRoom != "":
    p.position     = p.lastRestPosition
    p.currentRoom  = p.lastRestRoom
    saves.flushPlayer(state)
    let tile = world.getTile(state, p.position[0], p.position[1])
    state.context = if tile.tileType == "town": ctxTown else: ctxDungeon
    world.populateRoomQueue(state)
  else:
    # Never slept — leave to the world map
    saves.flushPlayer(state)
    result &= world.leaveLocation(state)
  result.add "You wake up, battered and disoriented."
  result &= world.currentLines(state)


# ── Round begin ───────────────────────────────────────────────────────────────

proc endCombat*(state: var GameState): seq[string]   # forward decl


proc beginRound(state: var GameState): seq[string] =
  ## Start a new round: regen -> tick effects -> traps -> enemy phase ->
  ## show positions and action options.
  if not state.combat.isSome: return
  let cs = state.combat.get
  inc cs.round

  # ── Regen ─────────────────────────────────────────────────────────────────
  let regenS = gvFloat("player_regen_stamina", 20.0)
  let regenF = gvFloat("player_regen_focus",   15.0)
  state.player.stamina = min(clock.effectiveStatCap(state, state.player.maxStamina),
                             state.player.stamina + regenS * mods.modifierGet(state, "stamina_regen_pct"))
  state.player.focus   = min(clock.effectiveStatCap(state, state.player.maxFocus),
                             state.player.focus   + regenF * mods.modifierGet(state, "focus_regen_pct"))
  # Decrement spell cooldowns
  var newCooldowns: Table[string, int]
  for sid, cd in state.player.spellCooldowns:
    if cd - 1 > 0: newCooldowns[sid] = cd - 1
  state.player.spellCooldowns = newCooldowns
  # Enemy regen
  if state.combat.isSome:
    let cs2 = state.combat.get
    for i in 0..<cs2.enemies.len:
      cs2.enemies[i].stamina = min(cs2.enemies[i].staminaMax, cs2.enemies[i].stamina + cs2.enemies[i].staminaRegen)
      cs2.enemies[i].focus   = min(cs2.enemies[i].focusMax,   cs2.enemies[i].focus   + cs2.enemies[i].focusRegen)

  result.add &"-- Round {state.combat.get.round} ------------------------------"

  # ── Tick player effects ────────────────────────────────────────────────────
  var playerEffLines = cond.tickEffects(state, state.player.effects, "player")
  for ln in playerEffLines:
    result.add ln
    result.add COMBAT_PAUSE

  # ── Tick enemy effects ─────────────────────────────────────────────────────
  if state.combat.isSome:
    let enemyCount = state.combat.get.enemies.len
    for i in 0..<enemyCount:
      if not state.combat.isSome: break
      let cs3 = state.combat.get
      if i >= cs3.enemies.len: break
      let eid = cs3.enemies[i].id
      var effs = cs3.enemies[i].effects
      let effLines = cond.tickEffects(state, effs, "enemy." & eid,
                                     cs3.enemies[i].data{"resistances"})
      for ln in effLines:
        result.add ln
        result.add COMBAT_PAUSE
      # Write effects back by id (health changes went through cmdDamage independently)
      if state.combat.isSome:
        let cs4 = state.combat.get
        for j in 0..<cs4.enemies.len:
          if cs4.enemies[j].id == eid:
            cs4.enemies[j].effects = effs
            break

  # ── Deaths from effect ticks ───────────────────────────────────────────────
  if state.combat.isSome:
    let cs5 = state.combat.get
    let effectKilled = cs5.enemies.filterIt(it.health <= 0)
    for e in effectKilled:
      result.add &"  {e.label} succumbs to their wounds."
      result.add COMBAT_PAUSE
      let (evLines, dropped) = killEnemy(state, e)
      result &= evLines
      if dropped.len > 0:
        result.add &"    Dropped: {lootSummary(dropped)}"
        result.add COMBAT_PAUSE
    if state.combat.isSome:
      cs5.enemies.keepIf(proc(e: CombatEnemy): bool = e.health > 0)
      if cs5.enemies.len == 0:
        result.add ""
        result &= endCombat(state)
        return

  # ── Traps ──────────────────────────────────────────────────────────────────
  let trapLines = fireTraps(state)
  for ln in trapLines:
    result.add ln
    result.add COMBAT_PAUSE
  if trapLines.len > 0 and state.combat.isSome:
    let cs7 = state.combat.get
    let trapKilled = cs7.enemies.filterIt(it.health <= 0)
    for e in trapKilled:
      result.add &"  {e.label} destroyed by trap."
      result.add COMBAT_PAUSE
      let (evLines, dropped) = killEnemy(state, e)
      result &= evLines
      if dropped.len > 0:
        result.add &"    Dropped: {lootSummary(dropped)}"
        result.add COMBAT_PAUSE
    cs7.enemies.keepIf(proc(e: CombatEnemy): bool = e.health > 0)
    if cs7.enemies.len == 0:
      result.add ""
      result &= endCombat(state)
      return

  # ── Show positions and action options ─────────────────────────────────────
  result &= enemyStatusLines(state)
  result.add ""
  result.add playerResourceLine(state)
  result.add ""
  result &= optionButtons(state)


# ── Combat entry ─────────────────────────────────────────────────────────────

proc startCombat*(state: var GameState): seq[string] =
  ## Enroll hostile enemies from roomQueue (+ faction-mates), init CombatState,
  ## fire combat_start event, then begin round 1.
  let (px, py) = state.player.position
  let tileKey  = &"{px}_{py}"

  # Collect hostile factions from the queue
  var hostileFactions: seq[string]
  for occ in state.roomQueue:
    if occ.kind == rokEnemy:
      let loc    = state.npcStates.getOrDefault(occ.id, newJNull())
      let baseId = loc{"spawned_from"}.getStr(occ.id)
      let npc    = content.getNpc(baseId)
      let f      = npc.faction
      if f != "" and f notin hostileFactions:
        hostileFactions.add f

  # Build enrolled set: hostile queue entries + faction-mates anywhere on tile
  var enrolledIds: seq[string]
  for occ in state.roomQueue:
    if occ.kind == rokEnemy and occ.id notin enrolledIds:
      enrolledIds.add occ.id

  if hostileFactions.len > 0:
    for npcId, loc in state.npcStates:
      if npcId in enrolledIds: continue
      if not loc{"alive"}.getBool(true): continue
      if loc.kind != JObject: continue
      let inTile =
        if loc.hasKey("spawned_from"): loc{"tile"}.getStr == tileKey
        else:
          let tileName = state.dirty.getOrDefault(tileKey, newJNull()){"tile"}.getStr
          tileName != "" and loc{"tile"}.getStr == tileName
      if not inTile: continue
      let baseId = loc{"spawned_from"}.getStr(npcId)
      let npc    = content.getNpc(baseId)
      if npc.faction in hostileFactions:
        enrolledIds.add npcId

  if enrolledIds.len == 0:
    return @["There are no enemies here to fight."]

  # Build CombatEnemy list
  var enemies: seq[CombatEnemy]
  for npcId in enrolledIds:
    let loc    = state.npcStates.getOrDefault(npcId, newJNull())
    let baseId = loc{"spawned_from"}.getStr(npcId)
    let npc    = content.getNpc(baseId)
    if npc.id == "": continue

    let templateHp  = npc.health * (
      if loc{"nemesis"}.getBool(false): gvFloat("nemesis_health_mult", 1.5) else: 1.0)
    let currentHp   = loc{"health"}.getFloat(templateHp)

    let (row, dist) =
      if loc.hasKey("row") and loc.hasKey("distance"):
        (loc{"row"}.getInt(5), loc{"distance"}.getInt(5))
      else:
        world.rollStartPosition(npc.raw)

    var queueLabel = ""
    for occ in state.roomQueue:
      if occ.id == npcId: queueLabel = occ.label; break
    let displayLabel = loc{"label_override"}.getStr(
      if queueLabel != "": queueLabel else: npc.displayName)

    enemies.add CombatEnemy(
      id:           npcId,
      label:        displayLabel,
      health:       currentHp,
      maxHealth:    templateHp,
      stamina:      npc.staminaMax,
      staminaMax:   npc.staminaMax,
      staminaRegen: npc.staminaRegen,
      focus:        npc.focusMax,
      focusMax:     npc.focusMax,
      focusRegen:   npc.focusRegen,
      data:         npc.raw,
      row:          row,
      distance:     dist,
      speed:        npc.raw{"speed"}.getInt(gvInt("enemy_default_speed", 1)),
      meleeRange:   npc.raw{"melee_range"}.getInt(gvInt("enemy_default_melee_range", 1)),
    )

  if enemies.len == 0:
    return @["There are no enemies here to fight."]

  state.combat  = some(CombatState(enemies: enemies, round: 0,
                                   pendingAction: newJNull()))
  state.context = ctxCombat
  result &= mods.fireEvent(state, "combat_start", "")

  let count = enemies.len
  result.add &"Combat — {count} {(if count == 1: \"enemy\" else: \"enemies\")}."
  result.add ""
  result &= beginRound(state)


# ── End combat ────────────────────────────────────────────────────────────────

proc endCombat*(state: var GameState): seq[string] =
  result &= mods.fireEvent(state, "combat_end", "")
  state.combat = none(CombatState)

  if state.variables.getOrDefault("_in_encounter", newJBool(false)).getBool:
    result.add "The fight is over."
    result &= world.leaveEncounterRoom(state)
    return

  world.populateRoomQueue(state)
  let (x, y) = state.player.position
  let tile   = world.getTile(state, x, y)
  state.context = if tile.tileType == "town": ctxTown else: ctxDungeon
  result.add "The fight is over. The area is clear."


# ── Player actions ────────────────────────────────────────────────────────────

proc findEnemyIdx(cs: CombatState; idOrLabel: string): int =
  let lower = idOrLabel.toLowerAscii
  for i, e in cs.enemies:
    if e.id == idOrLabel or e.label.toLowerAscii == lower: return i
  -1

proc findAtIdx(cs: CombatState; row, dist: int): int =
  for i, e in cs.enemies:
    if e.row == row and e.distance == dist: return i
  -1


proc resolveRound(state: var GameState): seq[string]  # forward decl


proc doAttack*(state: var GameState; bowRows: seq[int] = @[]): seq[string] =
  ## Unified attack: each equipped weapon contributes one strike. Bows
  ## (damage_type = "bow") need ammo and a row in `bowRows` (in mainhand→offhand
  ## order). Non-bow weapons swing at melee range. Each bow consumes one arrow.
  if not state.combat.isSome: return @["No active combat."]

  var strikes   = newJArray()
  var totalCost = 0.0
  var bowIdx    = 0

  for itemId in [state.player.mainhand, state.player.offhand]:
    if itemId == "": continue
    if itemId notin content.items: continue
    let def = content.items[itemId]
    if def.itemType.toLowerAscii in ["shield", "armor"]: continue
    if def.damage == 0: continue
    let ws = resolvedWeaponSkill(itemId)

    if def.damageType == "bow":
      let ammoId = state.player.ammo
      if ammoId == "" or ammoId notin content.items: continue
      let ammo = content.items[ammoId]
      let baseDmg = def.damage.float + ammo.damage.float
      var dmg = baseDmg * (1.0 + sk.skillPct(state, "archery") * 0.25)
      dmg *= mods.modifierGet(state, "archery_damage_pct")
      let row = if bowIdx < bowRows.len: bowRows[bowIdx] else: 0
      strikes.add %*{"weapon": itemId, "damage": dmg, "ranged": true,
                     "row": row, "ammo": ammoId, "ammo_label": ammo.displayName}
      discard takeItem(state, ammoId)
      if not hasItem(state, ammoId): state.player.ammo = ""
      inc bowIdx
    else:
      var dmg = def.damage.float * (1.0 + sk.skillPct(state, ws) * 0.5)
      dmg *= mods.modifierGet(state, &"{ws}_damage_pct") * mods.modifierGet(state, "melee_damage_pct")
      strikes.add %*{"weapon": itemId, "damage": dmg, "ranged": false}

    totalCost += def.staminaCost.float

  # Unarmed fallback
  if strikes.len == 0:
    strikes.add %*{"weapon": "", "damage": gvFloat("base_player_damage", 12.0), "ranged": false}
    totalCost = gvFloat("attack_stamina_cost", 15.0)

  if state.player.stamina < totalCost:
    return @[&"Not enough stamina to attack. ({int(state.player.stamina)} / {int(totalCost)} needed)"]

  state.player.stamina -= totalCost
  let cs = state.combat.get
  cs.playerLastAction = "attack"
  cs.pendingAction    = %*{"type": "attack", "strikes": strikes}
  result.add "You ready your weapon."
  result &= resolveRound(state)


proc doDodge*(state: var GameState): seq[string] =
  if not state.combat.isSome: return @["No active combat."]
  let dodgeCost = gvFloat("dodge_stamina_cost", 15.0) * mods.modifierGet(state, "dodge_stamina_cost_pct")
  if state.player.stamina < dodgeCost:
    return @[&"Not enough stamina to dodge. ({int(state.player.stamina)} / {int(dodgeCost)} needed)"]
  state.player.stamina = max(0.0, state.player.stamina - dodgeCost)
  state.player.health  = min(clock.effectiveStatCap(state, state.player.maxHealth),
                             state.player.health + gvFloat("dodge_health_gain", 5.0))
  state.player.focus   = min(clock.effectiveStatCap(state, state.player.maxFocus),
                             state.player.focus  + gvFloat("dodge_focus_gain", 8.0))
  let cs = state.combat.get
  cs.dodgeToken       = 1
  cs.playerLastAction = "dodge"
  result.add "You ready yourself to dodge."
  result &= mods.fireEvent(state, "dodge_chosen", "player")
  result &= resolveRound(state)


proc doBlock*(state: var GameState): seq[string] =
  if not state.combat.isSome: return @["No active combat."]
  let blockCost = gvFloat("block_health_cost", 10.0)
  if state.player.health <= blockCost:
    return @[&"Not enough health to block. ({int(state.player.health)} remaining)"]
  state.player.health  = max(0.0, state.player.health  - blockCost)
  state.player.stamina = min(clock.effectiveStatCap(state, state.player.maxStamina),
                             state.player.stamina + gvFloat("block_stamina_gain", 12.0))
  state.player.focus   = min(clock.effectiveStatCap(state, state.player.maxFocus),
                             state.player.focus   + gvFloat("block_focus_gain",  10.0))
  # Derive block reduction: 0.3 at skill 0, 0.7 at skill 100
  let blockReduction = (0.3 + sk.skillPct(state, "block") * 0.4) *
                       mods.modifierGet(state, "block_reduction_pct")
  state.variables["block_reduction"] = %blockReduction
  let cs = state.combat.get
  cs.blocking         = true
  cs.playerLastAction = "block"
  result.add "You brace for impact."
  result &= resolveRound(state)


proc doPass*(state: var GameState): seq[string] =
  if not state.combat.isSome: return @["No active combat."]
  let cs = state.combat.get
  cs.playerLastAction = "pass"
  resolveRound(state)


proc doCast*(state: var GameState; mode, spellId: string;
             row: int; dist: Option[int]): seq[string] =
  if not state.combat.isSome: return @["No active combat."]
  const castModes = ["smite", "trap", "beam", "wave"]
  if spellId notin state.player.spellbook:
    return @[&"You don't know the spell '{spellId}'."]
  if mode notin castModes:
    return @[&"Unknown cast mode '{mode}'. Use: smite  trap  beam  wave"]
  if mode in ["smite", "trap"] and dist.isNone:
    return @[&"'{mode}' needs row and distance.  e.g.  cast {mode} {spellId} <row> <dist>"]
  let spDef = content.getSpell(spellId)
  if spDef.id == "":
    return @[&"Spell data for '{spellId}' not found."]
  let focusCost = sp.getFocusCost(spDef)
  if state.player.focus < focusCost:
    return @[&"Not enough focus. ({int(state.player.focus)} / {int(focusCost)} needed)"]
  let cd = state.player.spellCooldowns.getOrDefault(spellId, 0)
  if cd > 0:
    return @[&"'{spellId}' is on cooldown for {cd} more turn(s)."]
  state.player.focus   = max(0.0, state.player.focus - focusCost)
  if spDef.tickCooldown > 0:
    state.player.spellCooldowns[spellId] = spDef.tickCooldown
  state.player.stamina = min(clock.effectiveStatCap(state, state.player.maxStamina),
                             state.player.stamina + gvFloat("cast_stamina_gain", 10.0))
  state.player.health  = min(clock.effectiveStatCap(state, state.player.maxHealth),
                             state.player.health  + gvFloat("cast_health_gain",  5.0))
  state.variables["_last_spell_id"]  = %spellId
  state.variables["_last_cast_mode"] = %mode
  let cs = state.combat.get
  cs.playerLastAction = "cast"
  cs.pendingAction    = %*{"type": "cast", "mode": mode, "spell_id": spellId,
                           "row": row, "dist": (if dist.isSome: dist.get else: -1)}
  result.add &"You prepare to cast {spellId} ({mode})."
  result &= mods.fireEvent(state, "spell_cast", "player")
  result &= resolveRound(state)


proc doAuxSpell*(state: var GameState; aux: string; args: seq[string]): seq[string] =
  if not state.combat.isSome: return @["No active combat."]
  let cs = state.combat.get
  cs.playerLastAction = "cast"
  cs.pendingAction    = %*{"type": "aux", "aux": aux, "args": args}
  resolveRound(state)


# ── Aux spell dispatch ────────────────────────────────────────────────────────

proc applyAux(state: var GameState; aux: string; args: seq[string]): seq[string] =
  if not state.combat.isSome: return @[&"No active combat for aux '{aux}'."]
  let cs = state.combat.get

  case aux
  of "push":
    if args.len == 0: return @["push requires a row number."]
    let row = try: parseInt(args[0]) except: return @["push: invalid row."]
    var targets: seq[string]
    for i in 0..<cs.enemies.len:
      if cs.enemies[i].row == row:
        cs.enemies[i].distance = min(9, cs.enemies[i].distance + gvInt("push_distance", 5))
        targets.add cs.enemies[i].label
    if targets.len == 0: return @[&"No enemies on row {row}."]
    return @[&"You push row {row} — {targets.join(\", \")} hurled back."]

  of "pull":
    if args.len == 0: return @["pull requires a row number."]
    let row = try: parseInt(args[0]) except: return @["pull: invalid row."]
    var closest = -1
    for i in 0..<cs.enemies.len:
      if cs.enemies[i].row == row:
        if closest < 0 or cs.enemies[i].distance < cs.enemies[closest].distance:
          closest = i
    if closest < 0: return @[&"No enemies on row {row}."]
    if cs.enemies[closest].distance == 1:
      return @[&"{cs.enemies[closest].label} is already at melee range — pull has no effect."]
    cs.enemies[closest].distance = gvInt("pull_target_distance", 2)
    let lbl = cs.enemies[closest].label
    return @[&"You pull {lbl} to distance {cs.enemies[closest].distance}."]

  of "scatter":
    if args.len == 0: return @["scatter requires a row number."]
    let row = try: parseInt(args[0]) except: return @["scatter: invalid row."]
    var moved: seq[string]
    for i in 0..<cs.enemies.len:
      if cs.enemies[i].row == row:
        var opts: seq[int]
        if row - 1 >= 1: opts.add row - 1
        if row + 1 <= 9: opts.add row + 1
        if opts.len > 0:
          cs.enemies[i].row = opts[rand(opts.len - 1)]
          moved.add &"  {cs.enemies[i].label} -> row {cs.enemies[i].row}"
    if moved.len == 0: return @[&"No enemies on row {row}."]
    return @[&"You scatter row {row}:"] & moved

  of "pin":
    if args.len < 2: return @["pin requires row and distance."]
    let (row, dist) = try: (parseInt(args[0]), parseInt(args[1]))
                      except: return @["pin: invalid arguments."]
    let idx = findAtIdx(cs, row, dist)
    if idx < 0: return @[&"No enemy at row {row}, dist {dist}."]
    cs.enemies[idx].anchored = gvInt("pin_duration", 2)
    let lbl = cs.enemies[idx].label
    return @[&"You pin {lbl} in place."]

  of "swap":
    if args.len < 4: return @["swap requires two positions: swap <row1> <dist1> <row2> <dist2>"]
    let (r1, d1, r2, d2) = try: (parseInt(args[0]), parseInt(args[1]),
                                  parseInt(args[2]), parseInt(args[3]))
                            except: return @["swap: invalid arguments."]
    let ia = findAtIdx(cs, r1, d1)
    let ib = findAtIdx(cs, r2, d2)
    if ia < 0: return @[&"No enemy at row {r1}, dist {d1}."]
    if ib < 0: return @[&"No enemy at row {r2}, dist {d2}."]
    let lblA = cs.enemies[ia].label; let lblB = cs.enemies[ib].label
    cs.enemies[ia].row = r2; cs.enemies[ia].distance = d2
    cs.enemies[ib].row = r1; cs.enemies[ib].distance = d1
    return @[&"You swap {lblA} and {lblB}."]

  of "bind":
    if args.len < 2: return @["bind requires two enemy IDs."]
    let ia = findEnemyIdx(cs, args[0])
    let ib = findEnemyIdx(cs, args[1])
    if ia < 0 or ib < 0: return @[&"Could not find both enemies: {args[0]}, {args[1]}"]
    let midRow  = max(1, min(9, (cs.enemies[ia].row + cs.enemies[ib].row) div 2))
    let midDist = max(1, min(9, (cs.enemies[ia].distance + cs.enemies[ib].distance) div 2))
    let lblA = cs.enemies[ia].label; let lblB = cs.enemies[ib].label
    cs.enemies[ia].row = midRow; cs.enemies[ia].distance = midDist
    cs.enemies[ib].row = midRow; cs.enemies[ib].distance = midDist
    return @[&"You bind {lblA} and {lblB} at row {midRow}, dist {midDist}."]

  else:
    return @[&"Unknown auxiliary spell '{aux}'."]


# ── Pending action resolution ─────────────────────────────────────────────────

proc firePendingAction(state: var GameState): seq[string] =
  if not state.combat.isSome: return
  let cs = state.combat.get
  let pa = cs.pendingAction
  cs.pendingAction = newJNull()
  if pa == nil or pa.kind == JNull: return

  let paType = pa{"type"}.getStr
  if paType == "":  return

  case paType
  of "attack":
    if not state.combat.isSome: return
    let cs2 = state.combat.get
    let reachMult = mods.modifierGet(state, "melee_range")
    let atRange = cs2.enemies.filterIt(it.distance.float <= it.meleeRange.float * reachMult)
    let pen = max(1, state.variables.getOrDefault("arrow_penetration", %1).getInt(1))

    let strikesNode = pa{"strikes"}
    if strikesNode == nil or strikesNode.kind != JArray or strikesNode.len == 0: return

    var totalDealt      = 0.0
    var lastTargetId    = ""
    var lastTargetCount = 0

    for s in strikesNode:
      let weaponId = s{"weapon"}.getStr("")
      let rawDmg   = s{"damage"}.getFloat(0.0)
      let ranged   = s{"ranged"}.getBool(false)

      if ranged:
        let row    = s{"row"}.getInt(0)
        let ammoId = s{"ammo"}.getStr("")
        let label  = s{"ammo_label"}.getStr("arrow")
        var inRow = cs2.enemies.filterIt(it.row == row)
        if inRow.len == 0:
          result.add &"  Your {label} sails through row {row} — no targets."
          continue
        inRow.sort(proc(a, b: CombatEnemy): int = cmp(a.distance, b.distance))
        let hits = inRow[0 ..< min(pen, inRow.len)]
        let pierceNote = if pen > 1 and hits.len > 1: &" (pierces {hits.len})" else: ""
        result.add &"  Your {label} strikes {hits.mapIt(it.label).join(\", \")}{pierceNote}."
        result &= announceWeaponSpells(weaponId, hits)
        if ammoId != "":
          result &= announceWeaponSpells(ammoId, hits)
        for e in hits:
          let dmg = applyResistances(e, rawDmg, "physical")
          result &= api.cmdDamage(state, "enemy." & e.id, e.id, dmg, "health")
          totalDealt += dmg
        result &= mods.fireEvent(state, "hit_landed", "player")
        result &= applyWeaponSpells(state, weaponId, hits)
        if ammoId != "":
          result &= applyWeaponSpells(state, ammoId, hits)
        lastTargetId    = hits[0].id
        lastTargetCount = hits.len
      else:
        if atRange.len == 0:
          result.add "  Your swing finds no one in range."
          continue
        result.add &"  You strike {atRange.mapIt(it.label).join(\", \")}."
        result &= announceWeaponSpells(weaponId, atRange)
        for e in atRange:
          let dmg = applyResistances(e, rawDmg, "physical")
          result &= api.cmdDamage(state, "enemy." & e.id, e.id, dmg, "health")
          totalDealt += dmg
        result &= mods.fireEvent(state, "hit_landed", "player")
        result &= applyWeaponSpells(state, weaponId, atRange)
        lastTargetId    = atRange[0].id
        lastTargetCount = atRange.len

    state.variables["_last_hit_damage_dealt"]    = %totalDealt
    state.variables["_last_hit_target_id"]       = %lastTargetId
    state.variables["_last_hit_target_count"]    = %lastTargetCount
    let prevDealt = state.variables.getOrDefault("_damage_dealt_this_combat", %0.0).getFloat(0.0)
    state.variables["_damage_dealt_this_combat"] = %(prevDealt + totalDealt)

  of "cast":
    let mode    = pa{"mode"}.getStr
    let spellId = pa{"spell_id"}.getStr
    let row     = pa{"row"}.getInt(0)
    let distVal = pa{"dist"}.getInt(-1)
    let spDef   = content.getSpell(spellId)
    var baseDmg = spDef.damage
    if baseDmg == 0.0: baseDmg = gvFloat("base_cast_damage", 10.0)
    baseDmg *= 1.0 + sk.skillPct(state, "destruction") * 0.5
    baseDmg *= mods.modifierGet(state, "spell_damage_pct") *
               mods.modifierGet(state, "destruction_damage_pct")

    const castMultTable = [("smite", 1.0), ("trap", 2.0), ("beam", 0.6), ("wave", 0.35)]
    var mult = 1.0
    for (m, v) in castMultTable:
      if m == mode: mult = v; break

    if mode == "trap":
      let strength = baseDmg * mult
      if state.combat.isSome:
        let cs3 = state.combat.get
        cs3.traps.add CombatTrap(row: row, distance: distVal, spellId: spellId,
                                 strength: strength, turns: gvInt("trap_turn_delay", 1))
      result.add &"You set a {spellId} trap at row {row}, dist {distVal}."
    else:
      if not state.combat.isSome: return
      let cs4 = state.combat.get
      let targets =
        case mode
        of "smite": cs4.enemies.filterIt(it.row == row and it.distance == distVal)
        of "beam":  cs4.enemies.filterIt(it.row == row)
        else:       cs4.enemies.filterIt(abs(it.row - row) <= gvInt("wave_adjacent_range", 1))
      let damage = baseDmg * mult
      if targets.len == 0:
        result.add &"  {spellId} ({mode}) finds no targets."
      else:
        result.add &"  {spellId} ({mode}):"
        var totalDealt = 0.0
        for e in targets:
          let dmg = applyResistances(e, damage, spellId)
          result &= api.cmdDamage(state, "enemy." & e.id, e.id, dmg, "health")
          totalDealt += dmg
        state.variables["_last_hit_damage_dealt"]    = %totalDealt
        state.variables["_last_hit_target_id"]       = %(if targets.len > 0: targets[0].id else: "")
        state.variables["_last_hit_target_count"]    = %targets.len
        let prevDealt = state.variables.getOrDefault("_damage_dealt_this_combat", %0.0).getFloat(0.0)
        state.variables["_damage_dealt_this_combat"] = %(prevDealt + totalDealt)
        result &= mods.fireEvent(state, "hit_landed", "player")
        result &= sp.applySpellEffects(state, spDef,targets.mapIt(it.id))
        for cmdStr in spDef.onHitCommands:
          for e in targets:
            result &= api.runCommand(state, cmdStr, e.id)

  of "aux":
    let auxName = pa{"aux"}.getStr
    var argsList: seq[string]
    let argsNode = pa{"args"}
    if argsNode != nil and argsNode.kind == JArray:
      for a in argsNode: argsList.add a.getStr
    result &= applyAux(state, auxName, argsList)


# ── Round resolution ──────────────────────────────────────────────────────────

proc resolveRound(state: var GameState): seq[string] =
  if not state.combat.isSome: return

  result.add "-- Resolution ----------------------------"

  # ── Enemy phase ──────────────────────────────────────────────────────────
  let (attackingIds, enemyNarration) = runEnemyPhase(state)
  # Decrement anchor counts
  if state.combat.isSome:
    let cs = state.combat.get
    for i in 0..<cs.enemies.len:
      if cs.enemies[i].anchored > 0: dec cs.enemies[i].anchored
  result.add ""
  result &= enemyNarration

  # ── Player action fires against new positions ─────────────────────────────
  let actionLines = firePendingAction(state)
  if actionLines.len > 0:
    for ln in actionLines:
      result.add ln
      result.add COMBAT_PAUSE
    result.add ""

  # ── Enemy attacks land ────────────────────────────────────────────────────
  if not state.combat.isSome: return
  let cs = state.combat.get
  let blocking   = cs.blocking
  var killerId   = ""

  for e in cs.enemies:
    if e.id notin attackingIds: continue
    if e.distance > e.meleeRange: continue

    let rawDmg = enemyAttackDamage(e)
    var dmg    = rawDmg

    if cs.dodgeToken > 0:
      dec cs.dodgeToken
      state.variables["_last_dodge_damage_avoided"] = %rawDmg
      let dodgeEv = mods.fireEvent(state, "dodge_consumed", e.id)
      result.add &"  {e.label}'s strike — you dodge it cleanly."
      for ln in dodgeEv: result.add &"    -> {ln.strip}"
      result.add COMBAT_PAUSE
      continue

    let strikeLine =
      if blocking:
        let blockPct = block:
          var v = state.variables.getOrDefault("block_reduction",
                    %gvFloat("block_reduction", 0.5)).getFloat(0.5)
          max(0.0, min(1.0, v))
        dmg *= (1.0 - blockPct)
        &"  {e.label} strikes — you block."
      else:
        &"  {e.label} strikes you."

    let shieldRed = shieldReduction(state.player)
    if shieldRed > 0.0: dmg = max(0.0, dmg - shieldRed)

    state.variables["_last_hit_damage_actual"] = %dmg
    if blocking:
      state.variables["_last_block_damage_raw"]   = %rawDmg
      state.variables["_last_block_damage_taken"] = %dmg
      state.variables["_last_block_mitigated"]    = %(rawDmg - dmg)

    let hpBefore    = state.player.health
    let dmgLines    = api.cmdDamage(state, "player", e.id, dmg, "health").mapIt(&"    -> {it.strip}")
    let blockLines  = if blocking: mods.fireEvent(state, "block", e.id).mapIt(&"    -> {it.strip}") else: @[]
    let hitLines    = mods.fireEvent(state, "hit_received", e.id).mapIt(&"    -> {it.strip}")

    result.add strikeLine
    result &= dmgLines
    result &= blockLines
    result &= hitLines
    result.add COMBAT_PAUSE

    if state.player.health <= 0 and hpBefore > 0:
      killerId = e.id

  # Clear per-round flags
  cs.dodgeToken    = 0
  cs.blocking      = false
  cs.pendingAction = newJNull()

  # ── Player death ──────────────────────────────────────────────────────────
  if state.player.health <= 0:
    state.player.health = 0
    result.add ""
    result.add "You have fallen."
    result &= playerDeath(state, killerId)
    return

  # ── Enemy deaths ──────────────────────────────────────────────────────────
  if state.combat.isSome:
    let cs2 = state.combat.get
    let killed = cs2.enemies.filterIt(it.health <= 0)
    for e in killed:
      result.add &"  {e.label} is dead."
      result.add COMBAT_PAUSE
      let (evLines, dropped) = killEnemy(state, e)
      result &= evLines
      if dropped.len > 0:
        result.add &"    Dropped: {lootSummary(dropped)}"
        result.add COMBAT_PAUSE
    cs2.enemies.keepIf(proc(e: CombatEnemy): bool = e.health > 0)

  if not state.combat.isSome or state.combat.get.enemies.len == 0:
    result.add ""
    result &= endCombat(state)
    return

  result.add ""
  result &= beginRound(state)


# ── Initiate aggression ───────────────────────────────────────────────────────

proc initiateAggression*(state: var GameState): seq[string] =
  ## Player attacks a peaceful NPC.  Mark hostile, apply faction bounty,
  ## rebuild queue, start combat.
  if state.roomQueue.len == 0: return @["There is no one here to attack."]
  let target  = state.roomQueue[0]
  let npcId   = target.id
  let loc     = state.npcStates.getOrDefault(npcId, newJNull())
  let baseId  = loc{"spawned_from"}.getStr(npcId)
  let npc     = content.getNpc(baseId)
  let label   = target.label
  let faction = npc.faction

  if npcId in state.npcStates and state.npcStates[npcId].kind == JObject:
    state.npcStates[npcId]["hostile"] = %true
    saves.flushNpcStates(state)

  if faction != "":
    let prev = state.variables.getOrDefault(&"bounty_{faction}", %0).getInt(0)
    state.variables[&"bounty_{faction}"] = %(prev + 1)
    saves.flushVariables(state)

  world.populateRoomQueue(state)
  result.add &"You attack {label}!"
  result &= startCombat(state)


# ── Flee ──────────────────────────────────────────────────────────────────────

proc doFlee*(state: var GameState): seq[string] =
  if not state.combat.isSome: return @["No active combat."]
  let fleeCost = gvFloat("flee_stamina_cost", 15.0)
  if state.player.stamina < fleeCost:
    return @[&"Not enough stamina to flee. ({int(state.player.stamina)} / {int(fleeCost)} needed)"]
  state.player.stamina -= fleeCost

  # Persist enemy positions before clearing combat
  let cs = state.combat.get
  for e in cs.enemies:
    if e.id in state.npcStates and state.npcStates[e.id].kind == JObject:
      state.npcStates[e.id]["health"]   = %e.health
      state.npcStates[e.id]["row"]      = %e.row
      state.npcStates[e.id]["distance"] = %e.distance
  saves.flushNpcStates(state)

  let (x, y) = state.player.position
  let tile   = world.getTile(state, x, y)
  let isTown = tile.tileType == "town"
  let fleeLn = mods.fireEvent(state, "flee", "player")

  if state.variables.getOrDefault("_in_encounter", newJBool(false)).getBool:
    state.combat = none(CombatState)
    result.add "You escape into the open road."
    result &= fleeLn
    result &= world.leaveEncounterRoom(state)
  elif isTown:
    let factions = block:
      var fs: seq[string]
      for e in cs.enemies:
        let f = e.data{"faction"}.getStr
        if f != "" and f notin fs: fs.add f
      fs
    for f in factions:
      let prev = state.variables.getOrDefault(&"bounty_{f}", %0).getInt(0)
      state.variables[&"bounty_{f}"] = %(prev + 1)
    saves.flushVariables(state)
    state.combat = none(CombatState)
    result.add "You flee into the open."
    result &= fleeLn
    result &= world.leaveLocation(state)
  else:
    state.combat = none(CombatState)
    state.context = ctxDungeon
    result.add "You break from the fight and retreat."
    result &= fleeLn
