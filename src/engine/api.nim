## engine/api.nim
## ──────────────
## Internal command dispatcher for content-authored command strings.
##
## Called by effect tick_commands, armor proc commands, spell on_hit_commands,
## and item use-effect strings.  NOT the player input dispatcher
## (commands/core.nim).
##
## Call initApi() before starting the game loop.
##
## Target selectors
## ────────────────
##   player        — the player
##   enemy.self    — the entity the command is running on (selfId arg)
##   enemy.all     — all living enemies in current combat
##   enemy.<id>    — specific enemy by instance id or label (case-insensitive)
##
## Verbs
## ─────
##   damage        <target> <amount> [stat]
##   add_effect    <target> <effect_id> <duration>
##   remove_effect <target> <effect_id>
##   set_stat      <target> <stat> <value>        (+N / -N for relative)
##   set_health    <target> <value>
##   set_stamina   <target> <value>
##   set_focus     <target> <value>
##   give          <target> <item_id> [amount]    player-only
##   print         [<target>] <text...>
##   pause                                        injects __PAUSE__ sentinel

import std/[json, options, strformat, strutils, sequtils, tables]
import state, content, items, api_types
import conditions as cond
import armor      as armormod
import modifiers  as mods
import skills     as sk

const COMBAT_PAUSE* = "__PAUSE__"

const validStats = ["health", "stamina", "focus", "hunger", "fatigue"]


# ── Forward declarations (runCommand ↔ addEffect are mutually recursive) ──────

proc runCommand*(state: var GameState; cmd: string;
                 selfId: string): seq[string]

proc addEffect*(state: var GameState; selector, effectId: string;
                duration: int; selfId: string): seq[string]


# ── Target helpers ────────────────────────────────────────────────────────────

proc resolveEnemyIdx(state: GameState; eid: string): int =
  ## Find enemy index by id or label. Returns -1 if not found or not in combat.
  if not state.combat.isSome: return -1
  let lower = eid.toLowerAscii
  for i, en in state.combat.get.enemies:
    if en.id == eid or en.label.toLowerAscii == lower:
      return i
  -1


# ── Verb: damage ──────────────────────────────────────────────────────────────

proc cmdDamage*(state: var GameState; sel, selfId: string;
                amount: float; stat: string): seq[string] =
  let s = if stat != "" and stat.toLowerAscii in validStats: stat.toLowerAscii
          else: "health"
  case sel
  of "player":
    case s
    of "health":
      state.player.health = max(0.0, state.player.health - amount)
      result.add &"  You take {int(amount)} damage."
    of "stamina":
      state.player.stamina = max(0.0, state.player.stamina - amount)
      result.add &"  You lose {int(amount)} stamina."
    of "focus":
      state.player.focus = max(0.0, state.player.focus - amount)
      result.add &"  You lose {int(amount)} focus."
    else: discard
  of "enemy.self":
    if selfId != "" and selfId != "player":
      result &= cmdDamage(state, "enemy." & selfId, selfId, amount, s)
  of "enemy.all":
    if state.combat.isSome:
      var cs = state.combat.get
      for i in 0 ..< cs.enemies.len:
        let label = cs.enemies[i].label
        case s
        of "health":  cs.enemies[i].health  = max(0.0, cs.enemies[i].health  - amount)
        of "stamina": cs.enemies[i].stamina = max(0.0, cs.enemies[i].stamina - amount)
        of "focus":   cs.enemies[i].focus   = max(0.0, cs.enemies[i].focus   - amount)
        else: discard
        result.add &"  {label} takes {int(amount)} {s} damage."
      state.combat = some(cs)
  else:
    if sel.startsWith("enemy."):
      let rawId = sel[6..^1]
      let eid   = if rawId == "self": selfId else: rawId
      let idx   = resolveEnemyIdx(state, eid)
      if idx >= 0 and state.combat.isSome:
        var cs = state.combat.get
        let label = cs.enemies[idx].label
        case s
        of "health":  cs.enemies[idx].health  = max(0.0, cs.enemies[idx].health  - amount)
        of "stamina": cs.enemies[idx].stamina = max(0.0, cs.enemies[idx].stamina - amount)
        of "focus":   cs.enemies[idx].focus   = max(0.0, cs.enemies[idx].focus   - amount)
        else: discard
        result.add &"  {label} takes {int(amount)} {s} damage."
        state.combat = some(cs)


# ── Verb: set_stat ────────────────────────────────────────────────────────────

proc cmdSetStat(state: var GameState; sel, selfId, stat, valueStr: string): seq[string] =
  let s = stat.toLowerAscii
  if s notin validStats: return
  let trimmed = valueStr.strip
  let relative = trimmed.len > 0 and trimmed[0] in {'+', '-'}
  var amt: float
  try: amt = parseFloat(trimmed)
  except: return
  if sel == "player":
    case s
    of "health":
      let v = if relative: state.player.health + amt else: amt
      state.player.health = max(0.0, min(state.player.maxHealth, v))
    of "stamina":
      let v = if relative: state.player.stamina + amt else: amt
      state.player.stamina = max(0.0, min(state.player.maxStamina, v))
    of "focus":
      let v = if relative: state.player.focus + amt else: amt
      state.player.focus = max(0.0, min(state.player.maxFocus, v))
    of "hunger":
      let v = if relative: state.player.hunger + amt else: amt
      state.player.hunger = max(0.0, min(100.0, v))
    of "fatigue":
      let v = if relative: state.player.fatigue + amt else: amt
      state.player.fatigue = max(0.0, min(100.0, v))
    else: discard
  # TODO Phase 6: enemy stat mutation


# ── Verb: add_effect ──────────────────────────────────────────────────────────

proc addEffect*(state: var GameState; selector, effectId: string;
                duration: int; selfId: string): seq[string] =
  ## Apply an effect to the resolved target.
  ## Refresh: update tick count to max(existing, new), fire armor procs.
  ## New: on_apply_commands → display message → interactions → armor procs →
  ##      effect_received event → first tick fires immediately.
  let def = content.getEffect(effectId)
  let sel = selector.toLowerAscii

  if sel == "player":
    # Refresh existing
    for i in 0 ..< state.player.effects.len:
      if state.player.effects[i].id == effectId:
        state.player.effects[i].ticksRemaining =
          max(state.player.effects[i].ticksRemaining, duration)
        let plates = armormod.iterEquippedPlates(state)
        result &= armormod.fireEffectProcs(state, state.player.effects,
                                           plates, effectId, "player")
        return

    # New application
    state.player.effects.add ActiveEffect(id: effectId, ticksRemaining: duration)
    for cmd in def.onApplyCommands:
      result &= runCommand(state, cmd, "player")
    if def.displayName != "":
      result.add &"  You: {def.displayName} applied."

    result &= cond.checkInteractions(state, state.player.effects, "player", effectId)
    let plates = armormod.iterEquippedPlates(state)
    result &= armormod.fireEffectProcs(state, state.player.effects,
                                       plates, effectId, "player")
    state.variables["_last_effect_received"] = %effectId
    state.variables["_last_effect_duration"] = %duration
    result &= mods.fireEvent(state, "effect_received", "player")

    # First tick fires on the turn the effect is gained
    for i in 0 ..< state.player.effects.len:
      if state.player.effects[i].id == effectId:
        for cmd in def.tickCommands:
          result &= runCommand(state, cmd, "player")
        state.player.effects[i].ticksRemaining =
          max(0, state.player.effects[i].ticksRemaining - 1)
        if state.player.effects[i].ticksRemaining <= 0:
          for cmd in def.onExpireCommands:
            result &= runCommand(state, cmd, "player")
          state.player.effects.delete(i)
        break

  elif sel.startsWith("enemy.") and state.combat.isSome:
    let rawId = sel[6..^1]
    let eid   = if rawId == "self": selfId else: rawId
    let idx   = resolveEnemyIdx(state, eid)
    if idx < 0: return
    var cs = state.combat.get

    # Refresh existing
    for i in 0 ..< cs.enemies[idx].effects.len:
      if cs.enemies[idx].effects[i].id == effectId:
        cs.enemies[idx].effects[i].ticksRemaining =
          max(cs.enemies[idx].effects[i].ticksRemaining, duration)
        state.combat = some(cs)
        return

    # New application
    cs.enemies[idx].effects.add ActiveEffect(id: effectId, ticksRemaining: duration)
    let label = cs.enemies[idx].label
    state.combat = some(cs)
    for cmd in def.onApplyCommands:
      result &= runCommand(state, cmd, eid)
    if def.displayName != "":
      result.add &"  {label}: {def.displayName} applied."

    if state.combat.isSome:
      var cs2 = state.combat.get
      result &= cond.checkInteractions(state, cs2.enemies[idx].effects,
                                       "enemy." & eid, effectId)
      # First tick
      for i in 0 ..< cs2.enemies[idx].effects.len:
        if cs2.enemies[idx].effects[i].id == effectId:
          for cmd in def.tickCommands:
            result &= runCommand(state, cmd, eid)
          if state.combat.isSome:
            var cs3 = state.combat.get
            cs3.enemies[idx].effects[i].ticksRemaining =
              max(0, cs3.enemies[idx].effects[i].ticksRemaining - 1)
            if cs3.enemies[idx].effects[i].ticksRemaining <= 0:
              for cmd in def.onExpireCommands:
                result &= runCommand(state, cmd, eid)
              cs3.enemies[idx].effects.delete(i)
            state.combat = some(cs3)
          break


# ── Verb: remove_effect ───────────────────────────────────────────────────────

proc removeEffect(state: var GameState; sel, selfId, effectId: string): seq[string] =
  let s = sel.toLowerAscii
  if s == "player":
    let before = state.player.effects.len
    state.player.effects.keepIf(proc(e: ActiveEffect): bool = e.id != effectId)
    if state.player.effects.len < before:
      result.add &"  You: {effectId} removed."
  elif s.startsWith("enemy.") and state.combat.isSome:
    let rawId = s[6..^1]
    let eid   = if rawId == "self": selfId else: rawId
    let idx   = resolveEnemyIdx(state, eid)
    if idx >= 0:
      var cs = state.combat.get
      let before = cs.enemies[idx].effects.len
      cs.enemies[idx].effects.keepIf(proc(e: ActiveEffect): bool = e.id != effectId)
      if cs.enemies[idx].effects.len < before:
        result.add &"  {cs.enemies[idx].label}: {effectId} removed."
      state.combat = some(cs)


# ── Verb: give ────────────────────────────────────────────────────────────────

proc cmdGive(state: var GameState; sel, itemId: string; amount: int): seq[string] =
  if sel != "player": return
  let def = content.getItem(itemId)
  for _ in 0 ..< max(1, amount):
    giveItem(state, itemId)
  let qty = if amount > 1: &" ×{amount}" else: ""
  result.add &"  You receive {def.displayName}{qty}."


# ── Main dispatcher ───────────────────────────────────────────────────────────

proc runCommand*(state: var GameState; cmd: string;
                 selfId: string): seq[string] =
  ## Parse and dispatch a single content command string.
  ## selfId resolves "enemy.self" selectors ("player" | enemy id | "").
  let parts = cmd.strip.splitWhitespace
  if parts.len == 0: return
  let verb = parts[0].toLowerAscii
  case verb
  of "damage":
    # damage <target> <amount> [stat]
    if parts.len < 3: return
    var amount: float
    try: amount = parseFloat(parts[2])
    except: return
    let stat = if parts.len > 3: parts[3].toLowerAscii else: "health"
    return cmdDamage(state, parts[1].toLowerAscii, selfId, amount, stat)

  of "add_effect":
    # add_effect <target> <effect_id> <duration>
    if parts.len < 4: return
    var duration: int
    try: duration = parseInt(parts[3])
    except: return
    return addEffect(state, parts[1].toLowerAscii, parts[2], duration, selfId)

  of "remove_effect":
    # remove_effect <target> <effect_id>
    if parts.len < 3: return
    return removeEffect(state, parts[1].toLowerAscii, selfId, parts[2])

  of "set_stat":
    # set_stat <target> <stat> <value>
    if parts.len < 4: return
    return cmdSetStat(state, parts[1].toLowerAscii, selfId, parts[2], parts[3])

  of "set_health", "set_stamina", "set_focus":
    # set_<stat> <target> <value>
    if parts.len < 3: return
    return cmdSetStat(state, parts[1].toLowerAscii, selfId, verb[4..^1], parts[2])

  of "give":
    # give <target> <item_id> [amount]
    if parts.len < 3: return
    var amount = 1
    if parts.len > 3:
      try: amount = parseInt(parts[3])
      except: discard
    return cmdGive(state, parts[1].toLowerAscii, parts[2], amount)

  of "print":
    const knownTargets = ["player", "world", "enemy.self", "enemy.all"]
    if parts.len >= 3 and parts[1].toLowerAscii in knownTargets:
      return @["  " & parts[2..^1].join(" ").strip(chars = {'"', '\''})]
    elif parts.len >= 2:
      return @["  " & parts[1..^1].join(" ").strip(chars = {'"', '\''})]

  of "pause":
    return @[COMBAT_PAUSE]

  of "give_xp":
    # give_xp <target> <amount>   (target must be "player")
    if parts.len < 3: return
    if parts[1].toLowerAscii != "player": return
    var amount: float
    try: amount = parseFloat(parts[2])
    except: return
    return sk.giveXp(state, amount)

  of "train_skill":
    # train_skill <target> <skill_name> <amount>
    if parts.len < 4: return
    if parts[1].toLowerAscii != "player": return
    var amount: int
    try: amount = parseInt(parts[3])
    except: return
    sk.trainSkill(state, parts[2].toLowerAscii, amount)

  of "cast", "cast_spell":
    # Fire a spell inline from a content proc (armor proc, effect command, etc.).
    # No focus cost, no cooldown, no round resolution — bare damage + effects only.
    # cast       <mode> <spell_id> <row> [dist]
    # cast_spell <spell_id> <mode> <row> [dist]
    if parts.len < 4: return
    let (mode, spellId, rowIdx) =
      if verb == "cast":      (parts[1].toLowerAscii, parts[2], 3)
      else:                   (parts[2].toLowerAscii, parts[1], 3)
    const castMults = [("smite", 1.0), ("beam", 0.6), ("wave", 0.35)]
    var mult = 0.0
    for (m, v) in castMults:
      if m == mode: mult = v; break
    if mult == 0.0 or not state.combat.isSome: return
    var row, dist: int
    try:
      row  = parseInt(parts[rowIdx])
      dist = if parts.len > rowIdx + 1: parseInt(parts[rowIdx + 1]) else: 0
    except: return
    let cs = state.combat.get
    var targetIds: seq[string]
    for e in cs.enemies:
      let hit = case mode
        of "smite": e.row == row and e.distance == dist
        of "beam":  e.row == row
        else:       abs(e.row - row) <= 1
      if hit: targetIds.add e.id
    let spDef  = content.getSpell(spellId)
    let damage = spDef.damage * mult
    if targetIds.len == 0:
      result.add &"  {spellId} ({mode}) finds no targets."
    else:
      result.add &"  {spellId} ({mode}) [proc]:"
      for eid in targetIds:
        result &= cmdDamage(state, "enemy." & eid, selfId, damage, "health")
      # Apply spell effects inline (avoids importing spells.nim → api circular dep).
      # spells.nim applySpellEffects does the same thing via apiAddEffect hook.
      if spDef.effects != nil and spDef.effects.kind == JArray:
        for eff in spDef.effects:
          let effId = eff{"effect"}.getStr
          let ticks = eff{"ticks"}.getInt(3)
          if effId == "": continue
          for eid in targetIds:
            result &= addEffect(state, "enemy." & eid, effId, ticks, eid)

  else: discard


# ── Initialisation ────────────────────────────────────────────────────────────

proc initApi*() =
  ## Wire hook variables so conditions, armor, and modifiers can call back
  ## into this module without a circular import. Call once before game loop.
  apiRunCommand = runCommand
  apiAddEffect  = addEffect
