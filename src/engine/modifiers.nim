## engine/modifiers.nim
## ─────────────────────
## Perk modifier accumulation and event dispatch.
##
## Perks are permanent effects (ticksRemaining == -1) in PlayerState.effects.
## They contribute two things:
##   modifierGet()  — multiplicative float accumulator from "modifiers" fields
##   fireEvent()    — on_<event> handler dispatch for perks and armor plates
##
## Handler values in effect/armor JSON:
##   JArray   — each element is a command string, run via apiRunCommand
##   JString  — Lua script filename (TODO Phase 8); .py not supported

import std/[json, options, strutils, tables]
import state, content, api_types
import armor as armormod


# ── Modifier accumulation ─────────────────────────────────────────────────────

proc modifierGet*(state: GameState; key: string): float =
  ## Multiplicative product of (1 + modifiers[key]) over all permanent effects.
  ## Returns 1.0 when nothing modifies this key.
  ## Two perks at +0.15 → 1.15 × 1.15 = 1.3225.
  result = 1.0
  for eff in state.player.effects:
    if eff.ticksRemaining != -1: continue
    let def = content.getEffect(eff.id)
    if def.modifiers == nil or def.modifiers.kind != JObject: continue
    if def.modifiers.hasKey(key):
      result *= (1.0 + def.modifiers[key].getFloat(0))


# ── Event context ─────────────────────────────────────────────────────────────

proc writeEventContext(state: var GameState; event: string; selfId: string) =
  ## Populate state.variables with context for perk event handlers.
  ## selfId = enemy instance id for kill/hit/etc; "" or "player" otherwise.
  state.variables["_last_event"] = %event
  case event
  of "combat_start":
    state.variables["_kills_this_combat"]            = %0
    state.variables["_damage_taken_this_combat"]     = %0.0
    state.variables["_damage_dealt_this_combat"]     = %0.0
    state.variables["_spells_cast_this_combat"]      = %0
    state.variables["_dodges_this_combat"]           = %0
    state.variables["_blocks_this_combat"]           = %0
    state.variables["_effects_received_this_combat"] = %0
  of "kill":
    state.variables["_last_kill_id"] = %selfId
    if state.combat.isSome:
      for en in state.combat.get.enemies:
        if en.id == selfId:
          state.variables["_last_kill_type"]    = %(en.data{"type"}.getStr)
          state.variables["_last_kill_faction"] = %(en.data{"faction"}.getStr)
          break
    let prev = state.variables.getOrDefault("_kills_this_combat", %0).getInt(0)
    state.variables["_kills_this_combat"] = %(prev + 1)
  of "hit_received":
    state.variables["_last_hit_source_id"] = %selfId
    if state.combat.isSome:
      for en in state.combat.get.enemies:
        if en.id == selfId:
          state.variables["_last_hit_source_type"] = %(en.data{"type"}.getStr)
          state.variables["_last_hit_damage_raw"]  = %(en.data{"damage"}.getFloat(0))
          break
    let actual = state.variables.getOrDefault("_last_hit_damage_actual", %0.0).getFloat(0)
    let prev   = state.variables.getOrDefault("_damage_taken_this_combat",  %0.0).getFloat(0)
    state.variables["_damage_taken_this_combat"] = %(prev + actual)
  of "hit_landed":
    discard   # all vars pre-written by caller (combat.nim)
  of "dodge_chosen":
    let prev = state.variables.getOrDefault("_dodges_this_combat", %0).getInt(0)
    state.variables["_dodges_this_combat"] = %(prev + 1)
  of "dodge_consumed":
    state.variables["_last_dodge_attacker_id"] = %selfId
    if state.combat.isSome:
      for en in state.combat.get.enemies:
        if en.id == selfId:
          state.variables["_last_dodge_attacker_type"] = %(en.data{"type"}.getStr)
          break
  of "block":
    state.variables["_last_block_attacker_id"] = %selfId
    if state.combat.isSome:
      for en in state.combat.get.enemies:
        if en.id == selfId:
          state.variables["_last_block_attacker_type"] = %(en.data{"type"}.getStr)
          break
    let prev = state.variables.getOrDefault("_blocks_this_combat", %0).getInt(0)
    state.variables["_blocks_this_combat"] = %(prev + 1)
  of "spell_cast":
    let prev = state.variables.getOrDefault("_spells_cast_this_combat", %0).getInt(0)
    state.variables["_spells_cast_this_combat"] = %(prev + 1)
  of "effect_received":
    let prev = state.variables.getOrDefault("_effects_received_this_combat", %0).getInt(0)
    state.variables["_effects_received_this_combat"] = %(prev + 1)
  of "level_up":
    state.variables["_new_level"] = %state.player.level
  of "combat_end":
    state.variables["_combat_kills"]            = state.variables.getOrDefault("_kills_this_combat",            %0)
    state.variables["_combat_damage_dealt"]     = state.variables.getOrDefault("_damage_dealt_this_combat",     %0.0)
    state.variables["_combat_damage_taken"]     = state.variables.getOrDefault("_damage_taken_this_combat",     %0.0)
    state.variables["_combat_spells_cast"]      = state.variables.getOrDefault("_spells_cast_this_combat",      %0)
    state.variables["_combat_dodges"]           = state.variables.getOrDefault("_dodges_this_combat",           %0)
    state.variables["_combat_blocks"]           = state.variables.getOrDefault("_blocks_this_combat",           %0)
    state.variables["_combat_effects_received"] = state.variables.getOrDefault("_effects_received_this_combat", %0)
    if state.combat.isSome:
      state.variables["_combat_rounds"] = %state.combat.get.round
  of "flee":
    if state.combat.isSome:
      let cs = state.combat.get
      state.variables["_flee_enemy_count"] = %cs.enemies.len
      var ids: seq[string]
      for en in cs.enemies: ids.add en.id
      state.variables["_flee_enemy_ids"] = %(ids.join(","))
  else: discard


# ── Handler dispatch ──────────────────────────────────────────────────────────

proc dispatchHandler(state: var GameState; handler: JsonNode;
                     selfId: string): seq[string] =
  if handler == nil or handler.kind == JNull: return
  case handler.kind
  of JArray:
    for entry in handler:
      result &= apiRunCommand(state, entry.getStr, selfId)
  of JString:
    let fname = handler.getStr
    if fname.endsWith(".lua"):
      discard   # TODO Phase 8: scripting.callLua(fname, state)
  else: discard


proc fireEvent*(state: var GameState; event: string; selfId: string): seq[string] =
  ## Write event context then dispatch on_<event> for:
  ##   1. Permanent player effects (perks, ticksRemaining == -1)
  ##   2. Equipped armor plates
  if apiRunCommand == nil: return
  writeEventContext(state, event, selfId)
  let key = "on_" & event

  for eff in state.player.effects:
    if eff.ticksRemaining != -1: continue
    let def = content.getEffect(eff.id)
    result &= dispatchHandler(state, def.raw{key}, selfId)

  for plate in armormod.iterEquippedPlates(state):
    result &= dispatchHandler(state, plate.raw{key}, selfId)
