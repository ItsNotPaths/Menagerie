## commands/cmd_charselect.nim
## ───────────────────────────
## Character creation context — active after newGame() when ≥1 class is defined.
## Player picks a class with `choose <id>` then transitions to ctxWorld.
## Call initCmdCharSelect() from game_loop.

import std/[algorithm, sequtils, strformat, strutils, tables]
import engine/state
import engine/content
import engine/world
import engine/saves
import commands/core


proc cmdListClasses(state: var GameState; args: seq[string]): CmdResult =
  var ids = toSeq(content.classes.keys)
  ids.sort()
  var lines = @["Choose a class:", ""]
  for id in ids:
    let cd = content.classes[id]
    let name = if cd.displayName != "": cd.displayName else: id
    lines.add &"  [[{name}:choose {id}]]"
    if cd.description != "":
      lines.add &"    {cd.description}"
    lines.add ""
  ok(lines)


proc cmdChooseClass(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Choose which class? Use [[list_classes]] to see options.")
  let id = args[0].toLowerAscii
  if id notin content.classes:
    return err(&"Unknown class '{id}'. Use [[list_classes]] to see options.")
  let cd = content.getClass(id)
  saves.applyClass(state, cd)
  state.context = ctxWorld
  saves.flushToWorking(state)
  let lines = @[&"You begin your journey as a {cd.displayName}.", ""] &
              world.currentLines(state)
  CmdResult(lines: lines, imagePath: currentImage(state))


proc cmdSaveBlockedInCharCreate(state: var GameState; args: seq[string]): CmdResult =
  err("Choose a class before saving. Use [[list_classes]] to see options.")


proc initCmdCharSelect*() =
  register("list_classes", ctxCharCreate, cmdListClasses)
  register("choose",       ctxCharCreate, cmdChooseClass)
  register("save",         ctxCharCreate, cmdSaveBlockedInCharCreate)
