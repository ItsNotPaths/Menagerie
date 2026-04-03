## engine/combat_ai.nim
## ────────────────────
## AI action-table evaluator for combat enemies.
## Included (not imported) by combat.nim; operates on GameState / CombatEnemy
## and has full access to the parent module's imports.
##
## Condition DSL (space-separated tokens per clause, clauses joined by " AND ")
## ─────────────────────────────────────────────────────────────────────────────
##   fallback                        always true
##   self_health    <op> <rhs>       enemy HP as percentage of max (0–100)
##   self_stamina   <op> <rhs>       enemy current stamina
##   self_focus     <op> <rhs>       enemy current focus
##   self_dist      <op> <rhs>       enemy distance from player
##   self_row       <op> <rhs>       enemy row number
##   enemies_at_dist1  <op> <rhs>    count of enemies within melee range
##   player_health  <op> <rhs>       player health (absolute)
##   player_stamina <op> <rhs>       player stamina
##   player_focus   <op> <rhs>       player focus
##   player_has:<effect_id>          true if player has that effect
##   player_last_action:<action>     true if player's last action matches
##   var.<name>     <op> <rhs>       arbitrary variable from state.variables
##
##   Operators: < <= > >= == !=

# ── AI package / condition evaluation ────────────────────────────────────────

proc getActionTables(npcRaw: JsonNode): JsonNode =
  ## Return the action_tables node, loading from ai_package if needed.
  ## Returns nil when no tables are defined (caller uses default advance).
  if npcRaw == nil: return nil
  let inline = npcRaw{"action_tables"}
  if inline != nil and inline.kind == JArray and inline.len > 0:
    return inline
  let pkg = npcRaw{"combat_ai_package"}.getStr
  if pkg != "":
    let def = content.getAiPackage(pkg)
    if def.id != "":
      let tables = def.raw{"action_tables"}
      if tables != nil and tables.kind == JArray:
        return tables
  nil


proc countAtDist1(cs: CombatState): int =
  for e in cs.enemies:
    if e.distance <= e.meleeRange: inc result


proc evalSingle(condition: string; enemy: CombatEnemy; state: GameState;
                curStamina, curFocus: float): bool =
  let c = condition.strip
  if c == "fallback": return true
  if c.startsWith("player_has:"):
    let effId = c[11..^1]
    return cond.hasEffect(state.player.effects, effId)
  if c.startsWith("player_last_action:"):
    let act = c[19..^1]
    return state.combat.isSome and state.combat.get.playerLastAction == act

  let parts = c.splitWhitespace
  if parts.len == 3:
    var rhs: float
    try: rhs = parseFloat(parts[2])
    except: return false
    let lhs = parts[0]; let op = parts[1]
    let lhsVal =
      case lhs
      of "self_health":      (if enemy.maxHealth > 0: enemy.health / enemy.maxHealth * 100.0 else: 0.0)
      of "self_stamina":     curStamina
      of "self_focus":       curFocus
      of "self_dist":        enemy.distance.float
      of "self_row":         enemy.row.float
      of "enemies_at_dist1": (if state.combat.isSome: countAtDist1(state.combat.get).float else: 0.0)
      of "player_health":    state.player.health
      of "player_stamina":   state.player.stamina
      of "player_focus":     state.player.focus
      else:
        if lhs.startsWith("var."):
          let varName = lhs[4..^1]
          try:   state.variables.getOrDefault(varName, %0.0).getFloat(0.0)
          except: return false
        else: return false
    case op
    of "<":  return lhsVal <  rhs
    of "<=": return lhsVal <= rhs
    of ">":  return lhsVal >  rhs
    of ">=": return lhsVal >= rhs
    of "==": return lhsVal == rhs
    of "!=": return lhsVal != rhs
    else: return false

  false


proc evalCondition(condition: string; enemy: CombatEnemy; state: GameState;
                   curStamina, curFocus: float): bool =
  for part in condition.split(" AND "):
    if not evalSingle(part, enemy, state, curStamina, curFocus): return false
  true


proc pickAction(enemy: CombatEnemy; state: GameState): JsonNode =
  ## Walk action tables and return the chosen action node.
  ## Returns nil when no table matches — caller uses default advance.
  let tables = getActionTables(enemy.data)
  if tables == nil: return nil
  for blk in tables:
    let condition = blk{"condition"}.getStr("fallback")
    if evalCondition(condition, enemy, state, enemy.stamina, enemy.focus):
      let actions = blk{"actions"}
      if actions == nil or actions.kind != JArray or actions.len == 0: continue
      var weights: seq[int]
      for a in actions: weights.add a{"weight"}.getInt(1)
      var total = 0
      for w in weights: inc total, w
      var roll = rand(total - 1)
      for i in 0..<actions.len:
        roll -= weights[i]
        if roll < 0: return actions[i]
      return actions[actions.len - 1]
  nil
