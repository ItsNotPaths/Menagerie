## engine/spells.nim
## ─────────────────
## Spell focus cost and effect application.
##
## Spells are loaded at startup into content.spells — no file I/O here.
## Call content.getSpell(id) to look one up.
##
## applySpellEffects targets are passed as selector strings:
##   "player"        — the player
##   "enemy.<id>"    — a specific enemy instance
##   "<id>"          — shorthand; prefixed with "enemy." automatically

import std/[json, strutils]
import state, content, gameplay_vars
import api


proc getFocusCost*(spDef: SpellDef): float =
  ## Focus cost for casting this spell.
  ## Uses gameplay_var default when the spell's focus_cost field is 0.
  if spDef.focusCost > 0.0: spDef.focusCost
  else: gvFloat("default_focus_cost", 20.0)


proc applySpellEffects*(state: var GameState; spDef: SpellDef;
                        targetIds: seq[string]): seq[string] =
  ## Apply every entry in spDef.effects to each target.
  ## Effects format: [{effect: <id>, ticks: <n>}, ...]
  ## targetIds may be bare enemy instance IDs or full selectors
  ## ("player", "enemy.<id>").  Bare IDs are prefixed with "enemy.".
  if spDef.effects == nil or spDef.effects.kind != JArray: return
  for eff in spDef.effects:
    let effId = eff{"effect"}.getStr
    let ticks = eff{"ticks"}.getInt(gvInt("default_effect_duration", 3))
    if effId == "": continue
    for tid in targetIds:
      let selector =
        if tid == "player" or tid.startsWith("enemy."): tid
        else: "enemy." & tid
      let selfId = if selector.startsWith("enemy."): selector[6..^1] else: "player"
      result &= api.addEffect(state, selector, effId, ticks, selfId)
