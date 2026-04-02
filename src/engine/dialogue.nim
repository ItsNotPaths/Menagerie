## engine/dialogue.nim
## ────────────────────
## Morrowind-style topic dialogue. NPC data lives in content/npcs/ (loaded at
## startup into content.npcs; raw JSON available via npc.raw).
##
## Flow
## ────
## 1. openDialogue(state, npcId)         — evaluate opening_conditions, print
##                                         greeting, list visible topic links
## 2. selectTopic(state, npcId, topicId) — apply variable_changes, return lines
##
## Topic links embed the npcId so no session state is required.
## Condition / change format: see engine/variables.nim

import std/[json, re, strformat, strutils, tables]
import state
import content
import variables as vars
import economy   as econ
import api_types

# ── Link rendering ────────────────────────────────────────────────────────────

let topicLinkRe = re(r"\[\[([^\]:\[]+):([^\]]+)\]\]")

proc renderLinks(text, npcId: string): string =
  ## Rewrite [[display:topic_id]] → [[display:say npcId topic_id]] so the UI
  ## fires the right command on click.  Plain [[cmd]] tokens are unchanged.
  result = text.replacef(topicLinkRe, "[[$1:say " & npcId & " $2]]")


# ── Topic list ────────────────────────────────────────────────────────────────

proc condSeq(node: JsonNode): seq[JsonNode] =
  if node == nil or node.kind != JArray: return @[]
  for x in node: result.add x

proc topicLines(npcRaw: JsonNode; variables: Table[string, JsonNode];
                npcId: string): seq[string] =
  ## Visible topics as clickable links. No farewell — just close the window.
  let topics = npcRaw{"topics"}
  if topics == nil or topics.kind != JArray: return @[]

  var visible: seq[(string, string)]   # (displayName, topicId)
  for t in topics:
    if t{"hidden_from_menu"}.getBool(false): continue
    if not vars.evalConditions(condSeq(t{"variable_conditions"}), variables): continue
    visible.add (t{"display_name"}.getStr, t{"topic"}.getStr)

  if visible.len == 0: return @[]

  result = @[""]
  for (disp, tid) in visible:
    result.add &"  [[{disp}:say {npcId} {tid}]]"


# ── Public API ────────────────────────────────────────────────────────────────

proc openDialogue*(state: var GameState; npcId: string): seq[string] =
  ## Print greeting and visible topic links. No session state set.
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

  result = @[npc.displayName, repeat('-', 40)]
  result.add renderLinks(opening, npcId)
  result &= topicLines(npc.raw, state.variables, npcId)


proc selectTopic*(state: var GameState; npcId, topicId: string): seq[string] =
  ## Select a topic. Applies variable_changes, returns lines.
  if npcId notin content.npcs:
    return @[&"(NPC '{npcId}' not found.)"]
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

  # Run inline_script commands
  let scriptNode = topicNode{"inline_script"}
  if scriptNode != nil and scriptNode.kind == JArray:
    for cmd in scriptNode:
      let line = cmd.getStr
      if line.len > 0:
        result &= apiRunCommand(state, line, npcId)

  let text = renderLinks(topicNode{"dialogue_text"}.getStr, npcId)

  # Shop trigger
  let shopId = topicNode{"shop"}.getStr
  if shopId != "":
    result = if text.strip.len > 0: @[text] else: @[]
    result.add ""
    result &= econ.openShop(state, shopId)
    return

  result = @[text]
  if topicNode{"show_topics"}.getBool(true):
    result &= topicLines(npc.raw, state.variables, npcId)
