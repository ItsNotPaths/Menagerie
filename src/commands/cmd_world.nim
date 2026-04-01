## commands/cmd_world.nim
## ────────────────────────
## World-map commands: go, look, survey, travel, peek, enter.
## Call initCmdWorld() from game_loop to register handlers.

import std/[strformat, strutils, tables]
import engine/state
import engine/world
import commands/core

let goDirs = {
  "north": (0,  1), "n": (0,  1),
  "south": (0, -1), "s": (0, -1),
  "east":  (1,  0), "e": (1,  0),
  "west":  (-1, 0), "w": (-1, 0),
}.toTable

let surveyLongDir = {"n": "north", "s": "south", "e": "east", "w": "west"}.toTable


proc cmdLook(state: var GameState; args: seq[string]): CmdResult =
  result = ok(currentLines(state))
  result.imagePath = currentImage(state)


proc cmdGo(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Go where? (north / south / east / west)")
  let dir = args[0].toLowerAscii
  if dir notin goDirs:
    return err(&"Unknown direction '{args[0]}'. Try north / south / east / west.")
  let (dx, dy) = goDirs[dir]
  let (x, y)   = state.player.position
  let nx = x + dx; let ny = y + dy
  let ticks = movementTicks(state, nx, ny)
  state.player.position = (nx, ny)
  let lines = @[&"You head {dir}."] & tileLines(state, nx, ny)
  result = okTicks(ticks, lines)
  result.imagePath = tileImagePath(state, nx, ny)


proc cmdSurvey(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Survey which direction? (north / south / east / west)")
  result = okTicks(2, surveyLines(state, args[0]))


proc cmdPeekWorld(state: var GameState; args: seq[string]): CmdResult =
  ok(peekLines(state))


proc cmdEnter(state: var GameState; args: seq[string]): CmdResult =
  result = ok(enterLocation(state))
  result.imagePath = roomImagePath(state)


proc cmdTravel(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    let (x, y) = state.player.position
    let roadTypes = ["road", "crossroads", "town", "dungeon"]
    let dirList = [("North", 0, 1), ("South", 0, -1), ("East", 1, 0), ("West", -1, 0)]
    var links: seq[string]
    for (label, ddx, ddy) in dirList:
      let t = getTile(state, x + ddx, y + ddy)
      if t.tileType in roadTypes:
        links.add &"  [[{label}:travel {label.toLowerAscii}]]"
    if links.len == 0:
      return err("There is no road here.")
    return ok(@["Travel which direction?", ""] & links)

  let direction = args[0].toLowerAscii
  if direction notin ["north", "south", "east", "west", "n", "s", "e", "w"]:
    return err(&"Unknown direction '{args[0]}'. Try north / south / east / west.")

  var steps = 2000
  if args.len >= 2:
    try: steps = max(1, parseInt(args[1]))
    except ValueError: return err(&"'{args[1]}' is not a number.")

  let (lines, ticks) = travelRoad(state, direction, steps)
  let (x, y) = state.player.position
  result = okTicks(ticks, lines)
  result.imagePath = tileImagePath(state, x, y)


proc initCmdWorld*() =
  register("look",   ctxWorld, cmdLook)
  register("go",     ctxWorld, cmdGo)
  register("move",   ctxWorld, cmdGo)
  register("survey", ctxWorld, cmdSurvey)
  register("peek",   ctxWorld, cmdPeekWorld)
  register("enter",  ctxWorld, cmdEnter)
  register("travel", ctxWorld, cmdTravel)
