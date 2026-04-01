## engine/dialogue.nim
## ────────────────────
## Morrowind-style topic dialogue. NPC data lives in content/npcs/ (loaded at
## startup into content.npcs; raw JSON available via npc.raw).
##
## Flow
## ────
## 1. openDialogue(state, npcId)  — evaluate opening_conditions, print greeting,
##                                  list visible topics, set _talking_to variable
## 2. selectTopic(state, topicId) — apply variable_changes, return dialogue lines
## 3. endDialogue(state)          — clear _talking_to / _active_shop
##
## Condition / change format: see engine/variables.nim

import std/[json, re, strformat, strutils, tables]
import state
import content
import variables as vars
import economy   as econ

# ── Link rendering ────────────────────────────────────────────────────────────

let topicLinkRe = re(r"\[\[([^\]:\[]+):([^\]]+)\]\]")

proc renderLinks(text: string): string =
  ## Rewrite [[display:topic_id]] → [[display:say topic_id]] so the UI sends
  ## the right command on click.  Plain [[cmd]] tokens (no colon) are unchanged.
  result = text.replacef(topicLinkRe, "[[$1:say $2]]")


# ── Topic list ────────────────────────────────────────────────────────────────

proc condSeq(node: JsonNode): seq[JsonNode] =
  if node == nil or node.kind != JArray: return @[]
  for x in node: result.add x

proc topicLines(npcRaw: JsonNode; variables: Table[string, JsonNode]): seq[string] =
  ## Visible topics as clickable links + Farewell.
  let topics = npcRaw{"topics"}
  if topics == nil or topics.kind != JArray:
    return @["", "  [[Farewell:farewell]]"]

  var visible: seq[(string, string)]   # (displayName, topicId)
  for t in topics:
    if t{"hidden_from_menu"}.getBool(false): continue
    if not vars.evalConditions(condSeq(t{"variable_conditions"}), variables): continue
    visible.add (t{"display_name"}.getStr, t{"topic"}.getStr)

  if visible.len == 0:
    return @["", "  [[Farewell:farewell]]"]

  result = @[""]
  for (disp, tid) in visible:
    result.add &"  [[{disp}:say {tid}]]"
  result.add "  [[Farewell:farewell]]"


# ── Public API ────────────────────────────────────────────────────────────────

proc openDialogue*(state: var GameState; npcId: string): seq[string] =
  ## Begin dialogue. Sets _talking_to. Returns lines to print.
  if npcId notin content.npcs:
    return @[&"(NPC '{npcId}' not found in content/npcs/.)"]
  let npc = content.npcs[npcId]

  # First matching conditional opening wins; fall back to opening_dialogue
  var opening = npc.openingDialogue
  let opConds = npc.raw{"opening_conditions"}
  if opConds != nil and opConds.kind == JArray:
    for entry in opConds:
      if vars.evalConditions(condSeq(entry{"conditions"}), state.variables):
        opening = entry{"text"}.getStr(opening)
        break

  state.variables["_talking_to"] = %npcId

  result = @[npc.displayName, repeat('-', 40)]
  result.add renderLinks(opening)
  result &= topicLines(npc.raw, state.variables)


proc selectTopic*(state: var GameState; topicId: string): seq[string] =
  ## Select a topic for the active NPC. Applies variable_changes, returns lines.
  let npcId = state.variables.getOrDefault("_talking_to", newJNull()).getStr
  if npcId == "" or npcId notin content.npcs:
    return @["(No active NPC.)"]
  let npc = content.npcs[npcId]

  # Find the topic
  let topics = npc.raw{"topics"}
  if topics == nil or topics.kind != JArray:
    return @[&"(Unknown topic '{topicId}'.)"]

  var topicNode: JsonNode
  for t in topics:
    if t{"topic"}.getStr == topicId:
      topicNode = t
      break
  if topicNode == nil:
    return @[&"(Unknown topic '{topicId}'.)"]

  # Re-validate conditions (stale links in scroll history can still be clicked)
  if not vars.evalConditions(condSeq(topicNode{"variable_conditions"}), state.variables):
    return @[]

  # Apply changes
  var changes: seq[JsonNode]
  let changesNode = topicNode{"variable_changes"}
  if changesNode != nil and changesNode.kind == JArray:
    for c in changesNode: changes.add c
  vars.applyChanges(changes, state.variables)

  let text = renderLinks(topicNode{"dialogue_text"}.getStr)

  # Shop trigger
  let shopId = topicNode{"shop"}.getStr
  if shopId != "":
    result = if text.strip.len > 0: @[text] else: @[]
    result.add ""
    result &= econ.openShop(state, shopId)
    return

  result = @[text]
  if topicNode{"show_topics"}.getBool(true):
    result &= topicLines(npc.raw, state.variables)


proc endDialogue*(state: var GameState) =
  ## Clear active conversation state.
  state.variables.del("_talking_to")
  state.variables.del("_active_shop")
