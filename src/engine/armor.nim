## engine/armor.nim
## ─────────────────
## Armor plate iteration and effect proc dispatch.
##
## Plates live in content.armorPlates; player equips them via PlayerState.armor.
## Enemy "plates" are inferred from armor/shield items in their inventory JSON.
## Effect procs fire when a specific effect is applied to a target whose armor
## has a matching effect_procs entry.

import std/[json, random, sequtils, strutils, tables]
import state, content, items, api_types


proc iterEquippedPlates*(state: GameState): seq[ArmorPlateDef] =
  ## All equipped non-empty armor plates for the player.
  for plateId in state.player.armor.values:
    if plateId != "" and plateId in content.armorPlates:
      result.add content.armorPlates[plateId]


proc iterEntityPlates*(entityInv: JsonNode): seq[ArmorPlateDef] =
  ## Armor plates inferred from an enemy's inventory JSON array.
  ## Items of type "armor" or "shield" are treated as worn.
  if entityInv == nil or entityInv.kind != JArray: return
  for entry in entityInv:
    let itemId = if entry.kind == JObject: entry{"item"}.getStr
                 else: entry.getStr
    if itemId == "": continue
    let info = anyItem(itemId)
    if info.itemType.toLowerAscii notin ["armor", "shield"]: continue
    if itemId in content.armorPlates:
      result.add content.armorPlates[itemId]


proc fireEffectProcs*(state: var GameState; effects: var seq[ActiveEffect];
                      plates: seq[ArmorPlateDef]; effectId: string;
                      selfId: string): seq[string] =
  ## Run effect_procs from armor plate perks that react to effectId being applied.
  ## Optionally consumes the trigger effect when consume: true.
  ## Proc format: {"effect": id, "chance": 0-100, "commands": [...], "consume": bool}
  if apiRunCommand == nil: return
  var shouldConsume = false
  for plate in plates:
    for perkId in plate.perks:
      let perkDef = content.getPerk(perkId)
      let procs = perkDef.raw{"effect_procs"}
      if procs == nil or procs.kind != JArray: continue
      for p in procs:
        if p{"effect"}.getStr != effectId: continue
        let chance = p{"chance"}.getInt(100)
        if chance < 100 and rand(99) >= chance: continue
        let cmds = p{"commands"}
        if cmds != nil and cmds.kind == JArray:
          for c in cmds:
            result &= apiRunCommand(state, c.getStr, selfId)
        if p{"consume"}.getBool(false):
          shouldConsume = true
  if shouldConsume:
    effects.keepIf(proc(e: ActiveEffect): bool = e.id != effectId)
