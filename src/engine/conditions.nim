## engine/conditions.nim
## ──────────────────────────────────────────────────────────────────────────
## Effect tick-down, expiry, and interaction chains.
##
## All procs take effects as `var seq[ActiveEffect]` so they work identically
## for player and enemy targets without duck typing.
##
## selfId is the selector string used when dispatching tick/expire commands
## so that "enemy.self" resolves correctly inside command strings.
## Use "player" for the player; "enemy.<id>" for a named enemy instance.

import std/[json, sequtils, sets, strutils, strformat]
import state, content, gameplay_vars, api_types, log


proc hasEffect*(effects: seq[ActiveEffect]; effectId: string): bool =
  ## True when effectId is currently active (not dead/expired) in the effects seq.
  effects.anyIt(it.id == effectId and it.ticksRemaining != 0)


proc resistMult(resistances: JsonNode; effectId: string): float =
  ## Returns the resistance modifier for effectId, or 1.0 if none authored.
  result = 1.0
  if resistances == nil or resistances.kind != JArray: return
  for entry in resistances:
    if entry{"effect"}.getStr == effectId:
      return entry{"modifier"}.getFloat(1.0)


proc scaleCmd(cmd: string; mult: float): string =
  ## Scales the amount in a "damage <target> <amount> [stat]" command string.
  ## All other command verbs are returned unchanged.
  if mult == 1.0: return cmd
  let parts = cmd.splitWhitespace
  if parts.len >= 3 and parts[0].toLowerAscii == "damage":
    var amount: float
    try: amount = parseFloat(parts[2])
    except: return cmd
    result = &"{parts[0]} {parts[1]} {amount * mult:.4f}"
    if parts.len > 3: result &= " " & parts[3 .. ^1].join(" ")
  else:
    result = cmd


proc tickEffects*(state: var GameState; effects: var seq[ActiveEffect];
                  selfId: string; resistances: JsonNode = nil): seq[string] =
  ## Per-round tick: fire tick_commands for every live non-permanent effect,
  ## decrement duration, fire on_expire_commands for those that reach 0.
  ## Expired effects (ticksRemaining == 0) are left in the list for index
  ## stability; call pruneEffects at room transitions to clean up.
  ## Permanent effects (ticksRemaining == -1) are skipped entirely.
  if apiRunCommand == nil: return
  for i in 0 ..< effects.len:
    if effects[i].ticksRemaining == -1: continue  # permanent
    if effects[i].ticksRemaining == 0: continue   # already expired
    let def = content.getEffect(effects[i].id)
    let mult = resistMult(resistances, effects[i].id)
    for cmd in def.tickCommands:
      result &= apiRunCommand(state, scaleCmd(cmd, mult), selfId)
    effects[i].ticksRemaining = max(0, effects[i].ticksRemaining - 1)
    if effects[i].ticksRemaining == 0:
      for cmd in def.onExpireCommands:
        result &= apiRunCommand(state, cmd, selfId)


proc pruneEffects*(effects: var seq[ActiveEffect]) =
  ## Remove all expired effects (ticksRemaining == 0). Call at room transitions
  ## to keep the list compact without invalidating indices during gameplay.
  effects.keepIf(proc(e: ActiveEffect): bool = e.ticksRemaining != 0)


proc checkInteractions*(state: var GameState; effects: var seq[ActiveEffect];
                        selfId: string; newEffectId: string): seq[string] =
  ## Check for interaction reactions triggered by a newly applied effect.
  ## All matching reactions fire (not just the first).
  ## If reaction D itself adds an effect, that effect's interactions are
  ## evaluated recursively via the apiAddEffect call.
  ##
  ## Pass 1 — new effect's own interactions field:
  ##   JArray  [{effect_id, result_id, duration, consumes}]
  ##           fires for every entry whose effect_id is already on the target
  ##   JObject {existing_id: {result, duration, consumes}}
  ##           same semantics, alternate author syntax
  ##
  ## Pass 2 — each existing effect's JObject interactions:
  ##   fires for every existing effect that lists newEffectId as a key
  if apiAddEffect == nil or apiRunCommand == nil: return

  var currentIds: HashSet[string]
  for e in effects:
    if e.ticksRemaining != 0: currentIds.incl e.id

  # ── Pass 1: new effect's own interactions ─────────────────────────────────
  let newDef = content.getEffect(newEffectId)
  let ix = newDef.interactions
  if ix != nil and ix.kind != JNull:

    if ix.kind == JArray:
      for entry in ix:
        if entry{"effect_id"}.getStr notin currentIds: continue
        let resultId = entry{"result_id"}.getStr
        let dur = entry{"duration"}.getInt(gvInt("default_interaction_duration", 3))
        if entry.hasKey("consumes") and entry["consumes"].kind == JArray:
          var cs: HashSet[string]
          for c in entry["consumes"]: cs.incl c.getStr
          effects.keepIf(proc(e: ActiveEffect): bool = e.id notin cs)
        if resultId != "":
          result &= apiAddEffect(state, selfId, resultId, dur, selfId)

    elif ix.kind == JObject:
      for existingId, ixEntry in ix.pairs:
        if existingId notin currentIds: continue
        let resultId = ixEntry{"result"}.getStr
        let dur = ixEntry{"duration"}.getInt(gvInt("default_interaction_duration", 3))
        if ixEntry.hasKey("consumes") and ixEntry["consumes"].kind == JArray:
          var cs: HashSet[string]
          for c in ixEntry["consumes"]: cs.incl c.getStr
          effects.keepIf(proc(e: ActiveEffect): bool = e.id notin cs)
        if resultId != "":
          result &= apiAddEffect(state, selfId, resultId, dur, selfId)

  # ── Pass 2: existing effects' dict-keyed interactions ─────────────────────
  # Snapshot so keepIf below doesn't affect iteration order
  let snapshot = effects
  for e in snapshot:
    if e.ticksRemaining == 0: continue  # skip dead
    if e.id == newEffectId: continue
    let def = content.getEffect(e.id)
    let eix = def.interactions
    if eix == nil or eix.kind != JObject: continue
    if not eix.hasKey(newEffectId): continue
    let ixEntry  = eix[newEffectId]
    let resultId = ixEntry{"result"}.getStr
    let dur      = ixEntry{"duration"}.getInt(3)
    if ixEntry.hasKey("consumes") and ixEntry["consumes"].kind == JArray:
      var cs: HashSet[string]
      for c in ixEntry["consumes"]: cs.incl c.getStr
      effects.keepIf(proc(e: ActiveEffect): bool = e.id notin cs)
    if resultId != "":
      result &= apiAddEffect(state, selfId, resultId, dur, selfId)
