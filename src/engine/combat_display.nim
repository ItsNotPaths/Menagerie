## engine/combat_display.nim
## ─────────────────────────
## Read-only display helpers for combat: status lines, resource line,
## weapon stats, and action option buttons.
## Included (not imported) by combat.nim; also imported directly by
## cmd_combat.nim for the procs marked with *.
##
## Public surface (used outside combat.nim):
##   enemyStatusLines*   — grid status for each enemy
##   playerResourceLine* — compact HP / stamina / focus line
##   weaponStats*        — (totalDamage, totalStaminaCost) from equipped weapons
##   optionButtons*      — action button links for the current round

# ── Display helpers ───────────────────────────────────────────────────────────

proc bar(current, maximum: float; width = 10): string =
  let filled = if maximum > 0: int(current / maximum * width.float) else: 0
  let f = max(0, min(width, filled))
  "/".repeat(f) & "=".repeat(width - f)


proc enemyStatusLines*(state: GameState): seq[string] =
  if not state.combat.isSome: return
  for e in state.combat.get.enemies:
    result.add &"  {e.label:<18} row {e.row}  dist {e.distance}" &
               &"  {bar(e.health, e.maxHealth)}  {int(e.health)}/{int(e.maxHealth)} HP"


proc playerResourceLine*(state: GameState): string =
  let p = state.player
  &"  Health {int(p.health):>3}   Stamina {int(p.stamina):>3}   Focus {int(p.focus):>3}"


proc weaponStats*(player: PlayerState): (float, float) =
  ## (totalDamage, totalStaminaCost) from equipped mainhand + offhand.
  ## Falls back to base constants when nothing is equipped.
  var totalDmg  = 0.0
  var totalCost = 0.0
  var anyEquipped = false
  for itemId in [player.mainhand, player.offhand]:
    if itemId == "": continue
    anyEquipped = true
    let info = itms.anyItem(itemId)
    totalDmg  += info.damage.float
    totalCost += info.staminaCost.float
  if not anyEquipped or totalDmg  == 0.0: totalDmg  = gvFloat("base_player_damage", 12.0)
  if not anyEquipped or totalCost == 0.0: totalCost = gvFloat("attack_stamina_cost", 15.0)
  (totalDmg, totalCost)


proc optionButtons*(state: GameState): seq[string] =
  ## Action buttons shown at the start of each round.
  if not state.combat.isSome: return
  let p = state.player
  let dodgeCost = gvFloat("dodge_stamina_cost", 15.0)
  let blockCost = gvFloat("block_health_cost",  10.0)
  let (_, atkCost) = weaponStats(p)

  var physical: seq[string]
  if p.stamina >= atkCost:  physical.add "[[attack]]"
  if p.stamina >= dodgeCost: physical.add "[[dodge]]"
  if p.health  >  blockCost: physical.add "[[block]]"
  physical.add "[[pass]]"
  physical.add "[[flee]]"
  physical.add "[[cast]]"

  var spells: seq[string]
  spells.add "[[push]]"; spells.add "[[pull]]"; spells.add "[[scatter]]"
  spells.add "[[bind]]"; spells.add "[[pin]]";  spells.add "[[swap]]"

  result.add "  " & physical.join("   ")
  result.add ""
  result.add "  " & spells.join("   ")
  result.add ""
  result.add "  [[inventory]]"
