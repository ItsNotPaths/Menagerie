## commands/cmd_menu.nim
## ─────────────────────
## Commands active only in the main menu context (ctxMenu).
## The game starts here; new/continue/load transition to ctxWorld.
## Call initCmdMenu() from game_loop.

import std/[strformat, strutils]
import engine/state
import engine/world
import engine/saves
import commands/core


proc menuLines*(): seq[string] =
  @["Menagerie", "",
    "  [[new]]   [[continue]]   [[load]]   [[exit]]"]


proc cmdMenuLook(state: var GameState; args: seq[string]): CmdResult =
  ok(menuLines())


proc cmdNew(state: var GameState; args: seq[string]): CmdResult =
  saves.newGame(state)
  if state.context == ctxCharCreate:
    return CmdResult(lines: @["A new journey awaits.", "",
                               "Choose your background with [[list_classes]]."],
                     prefill: "list_classes")
  let lines = @["A new journey begins.", ""] & world.currentLines(state)
  CmdResult(lines: lines, imagePath: currentImage(state))


proc cmdContinue(state: var GameState; args: seq[string]): CmdResult =
  let name = saves.mostRecentSave()
  if name == "":
    return err("No saves found. Use [[new]] to start a game.")
  try:
    saves.loadGame(name, state)
    let lines = @[&"Resuming {name.replace(\"_\", \" \")}.", ""] & world.currentLines(state)
    return CmdResult(lines: lines, imagePath: currentImage(state))
  except IOError as e:
    return err(e.msg)


proc cmdLoad(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    let sl = saves.listSaves()
    var lines = @["Load which save? (type: load <name>)", ""]
    for e in sl.auto:   lines.add &"  [[load {e.name}:{e.display}]]"
    for e in sl.manual: lines.add &"  [[load {e.name}:{e.display}]]"
    if sl.auto.len == 0 and sl.manual.len == 0:
      lines.add "  (no saves found)"
    return ok(lines)
  let name = args.join("_")
  try:
    saves.loadGame(name, state)
    let lines = @[&"Loaded {name.replace(\"_\", \" \")}.", ""] & world.currentLines(state)
    return CmdResult(lines: lines, imagePath: currentImage(state))
  except IOError as e:
    return err(e.msg)


proc initCmdMenu*() =
  register("look",     ctxMenu, cmdMenuLook)
  register("new",      ctxMenu, cmdNew)
  register("continue", ctxMenu, cmdContinue)
  register("load",     ctxMenu, cmdLoad)
