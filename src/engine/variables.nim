## engine/variables.nim
## ─────────────────────
## Pure evaluation helpers for GameState.variables.
##
## Condition format (AND logic — all conditions must pass; empty list always passes):
##   [{"var": "quest_done", "op": "eq", "value": 1}, ...]
##   Ops: eq  ne  gt  gte  lt  lte
##
## Change format:
##   [{"var": "quest_wheat_done", "op": "set", "value": 1}, ...]
##   Ops: set  add  sub

import std/[json, strutils, tables]
import log

proc evalConditions*(conditions: seq[JsonNode]; variables: Table[string, JsonNode]): bool =
  ## Returns true when every condition passes (AND). Empty list always passes.
  for c in conditions:
    let varName = c{"var"}.getStr
    let op      = if c.hasKey("op"): c["op"].getStr else: "eq"
    let target  = c{"value"}
    let val     = if varName in variables: variables[varName] else: newJNull()

    case op
    of "eq":
      if val != target: return false
    of "ne":
      if val == target: return false
    of "gt":
      if val.kind == JNull: return false
      if val.getFloat(0) <= target.getFloat(0): return false
    of "gte":
      if val.kind == JNull: return false
      if val.getFloat(0) < target.getFloat(0): return false
    of "lt":
      if val.kind == JNull: return false
      if val.getFloat(0) >= target.getFloat(0): return false
    of "lte":
      if val.kind == JNull: return false
      if val.getFloat(0) > target.getFloat(0): return false
    else: discard
  return true

proc evalConditionStr*(cond: string; variables: Table[string, JsonNode]): bool =
  ## Evaluate a free-form "var op value" condition string. Empty → true.
  ## Numeric ops: > < >= <=. Equality ops: = != (string or numeric match).
  ## Unrecognisable format → true (fail-open).
  let s = cond.strip()
  if s == "": return true
  var opStr = ""; var sepIdx = -1
  for op in [">=", "<=", "!="]:
    let i = s.find(op)
    if i >= 0: opStr = op; sepIdx = i; break
  if sepIdx < 0:
    for op in [">", "<", "="]:
      let i = s.find(op)
      if i >= 0: opStr = op; sepIdx = i; break
  if sepIdx < 0:
    log(Game, Warn, "evalConditionStr: no operator found in condition: " & cond)
    return false
  let varName = s[0 ..< sepIdx].strip()
  let rhs     = s[sepIdx + opStr.len .. ^1].strip()
  let val     = variables.getOrDefault(varName, newJNull())
  let valF    = val.getFloat(0)
  let rhsF    = try: rhs.parseFloat except ValueError: 0.0
  case opStr
  of "=":
    if val.kind in {JInt, JFloat}: return valF == rhsF
    return val.getStr == rhs
  of "!=":
    if val.kind in {JInt, JFloat}: return valF != rhsF
    return val.getStr != rhs
  of ">":  return val.kind != JNull and valF > rhsF
  of "<":  return val.kind != JNull and valF < rhsF
  of ">=": return val.kind != JNull and valF >= rhsF
  of "<=": return val.kind != JNull and valF <= rhsF
  else: true


proc applyChanges*(changes: seq[JsonNode]; variables: var Table[string, JsonNode]) =
  ## Apply a list of variable changes to the variables table in-place.
  for c in changes:
    let key = c{"var"}.getStr
    let op  = if c.hasKey("op"): c["op"].getStr else: "set"
    let val = c["value"]
    case op
    of "set":
      variables[key] = val
    of "add":
      let cur = if key in variables: variables[key].getFloat(0) else: 0.0
      variables[key] = newJFloat(cur + val.getFloat(0))
    of "sub":
      let cur = if key in variables: variables[key].getFloat(0) else: 0.0
      variables[key] = newJFloat(cur - val.getFloat(0))
    else: discard
