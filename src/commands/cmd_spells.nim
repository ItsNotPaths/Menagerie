## commands/cmd_spells.nim
## ───────────────────────
## Spellbook browsing and spell favouriting.
## Call initCmdSpells() from game_loop.

import std/[strformat, strutils]
import engine/state
import engine/content
import commands/core


proc spellInfoLines(state: GameState; spellId: string): seq[string] =
  let def = content.getSpell(spellId)
  if def.id == "":
    result.add &"  {spellId}  (no data file found)"
  else:
    result.add def.displayName
    if def.description.len > 0:
      result.add ""
      result.add &"  {def.description}"
    if def.castType.len > 0: result.add &"  type:       {def.castType}"
    if def.damage > 0:       result.add &"  damage:     {def.damage:.0f}"
    if def.focusCost > 0:    result.add &"  focus cost: {def.focusCost:.0f}"
    if def.duration > 0:     result.add &"  duration:   {def.duration} ticks"
  result.add ""
  if spellId in state.player.favourites:
    result.add &"  [[unfavourite:unfavourite_spell {spellId}]]"
  else:
    result.add &"  [[favourite:favourite_spell {spellId}]]"


proc cmdSpells(state: var GameState; args: seq[string]): CmdResult =
  if state.player.spellbook.len == 0:
    return ok("You know no spells.")
  var lines = @["Your spells:", ""]
  for sid in state.player.spellbook:
    let def   = content.getSpell(sid)
    let label = if def.id != "": def.displayName else: sid
    let star  = if sid in state.player.favourites: " *" else: ""
    lines.add &"  [[{label}{star}:spell_info {sid}]]"
  ok(lines)


proc cmdSpellInfo(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: spell_info <spell_id>")
  let spellId = args[0].toLowerAscii
  CmdResult(panelLines: spellInfoLines(state, spellId))


proc cmdFavouriteSpell(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: favourite_spell <spell_id>")
  let spellId = args[0].toLowerAscii
  if spellId notin state.player.spellbook:
    return err(&"You don't know '{spellId}'.")
  if spellId in state.player.favourites:
    return CmdResult(lines: @[&"'{spellId}' is already a favourite."],
                     panelLines: spellInfoLines(state, spellId), panelAppend: true)
  state.player.favourites.add spellId
  CmdResult(lines: @[&"Added '{spellId}' to favourites."],
            panelLines: spellInfoLines(state, spellId), panelAppend: true)


proc cmdUnfavouriteSpell(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: unfavourite_spell <spell_id>")
  let spellId = args[0].toLowerAscii
  let idx = state.player.favourites.find(spellId)
  if idx < 0:
    return CmdResult(lines: @[&"'{spellId}' is not in favourites."],
                     panelLines: spellInfoLines(state, spellId), panelAppend: true)
  state.player.favourites.delete(idx)
  CmdResult(lines: @[&"Removed '{spellId}' from favourites."],
            panelLines: spellInfoLines(state, spellId), panelAppend: true)


proc initCmdSpells*() =
  registerAny("spells",           cmdSpells)
  registerAny("spell_info",       cmdSpellInfo,       hidden = true)
  registerAny("favourite_spell",  cmdFavouriteSpell,  hidden = true)
  registerAny("unfavourite_spell",cmdUnfavouriteSpell,hidden = true)
