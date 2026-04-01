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

import std/[json, sequtils, sets]
import state, content, gameplay_vars, api_types


proc hasEffect*(effects: seq[ActiveEffect]; effectId: string): bool =
  ## True when effectId is currently active in the given effects seq.
  effects.anyIt(it.id == effectId)


proc tickEffects*(state: var GameState; effects: var seq[ActiveEffect];
                  selfId: string): seq[string] =
  ## Per-round tick: fire tick_commands for every non-permanent effect,
  ## decrement duration, fire on_expire_commands for those that reach 0,
  ## then remove expired entries.
  ## Permanent effects (ticksRemaining == -1) are skipped entirely.
  if apiRunCommand == nil: return
  var expiredIdx: seq[int]
  for i in 0 ..< effects.len:
    if effects[i].ticksRemaining == -1: continue
    let def = content.getEffect(effects[i].id)
    for cmd in def.tickCommands:
      result &= apiRunCommand(state, cmd, selfId)
    effects[i].ticksRemaining = max(0, effects[i].ticksRemaining - 1)
    if effects[i].ticksRemaining <= 0:
      for cmd in def.onExpireCommands:
        result &= apiRunCommand(state, cmd, selfId)
      expiredIdx.add i
  for i in countdown(expiredIdx.high, 0):
    effects.delete(expiredIdx[i])


proc checkInteractions*(state: var GameState; effects: var seq[ActiveEffect];
                        selfId: string; newEffectId: string): seq[string] =
  ## Check for interaction reactions triggered by a newly applied effect.
  ## Only one reaction fires per call (first match across both passes wins).
  ##
  ## Pass 1 — new effect's own interactions field:
  ##   JArray  [{effect_id, result_id, duration, consumes}]
  ##           fires when effect_id is already on target
  ##   JObject {existing_id: {result, duration, consumes}}
  ##           same semantics, alternate author syntax
  ##
  ## Pass 2 — each existing effect's JObject interactions:
  ##   fires when newEffectId appears as a key
  if apiAddEffect == nil or apiRunCommand == nil: return

  var currentIds: HashSet[string]
  for e in effects: currentIds.incl e.id

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
        return

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
        return

  # ── Pass 2: existing effects' dict-keyed interactions ─────────────────────
  # Snapshot so keepIf below doesn't affect iteration order
  let snapshot = effects
  for e in snapshot:
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
    return
