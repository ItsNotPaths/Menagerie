## commands/cmd_town.nim
## ─────────────────────
## Town and dungeon commands: look, move, leave, peek, attack stub.
## Call initCmdTown() from game_loop to register handlers.

import std/[sequtils, strformat, strutils]
import engine/state
import engine/world
import engine/combat
import commands/core


proc cmdLookRoom(state: var GameState; args: seq[string]): CmdResult =
  let lines = roomLines(state)
  let img   = roomImagePath(state)
  result = ok(lines)
  result.imagePath = img

proc cmdMoveRoom(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    let conns = getRoomConnections(state)
    if conns.len == 0:
      return ok("There is nowhere to go from here.")
    let links = conns.mapIt(&"  [[{it}:move {it}]]")
    return ok(@["Where to?", ""] & links)
  let roomId = args[0].toLowerAscii
  let lines  = moveToRoom(state, roomId)
  let img    = roomImagePath(state)
  result = ok(lines)
  result.imagePath = img

proc cmdLeave(state: var GameState; args: seq[string]): CmdResult =
  let lines = leaveLocation(state)
  let (x, y) = state.player.position
  let img    = tileImagePath(state, x, y)
  result = ok(lines)
  result.imagePath = img

proc cmdPeekRoom(state: var GameState; args: seq[string]): CmdResult =
  let conns = getRoomConnections(state)
  if conns.len == 0:
    return ok("There is nowhere to peek.")
  if args.len == 0:
    if conns.len == 1:
      return ok(roomPeekLines(state, conns[0]))
    let links = conns.mapIt(&"  [[{it}:peek {it}]]")
    return ok(@["Peek where?", ""] & links)
  let roomId = args[0].toLowerAscii
  if roomId notin conns:
    return ok()
  ok(roomPeekLines(state, roomId))

proc cmdAttackStart(state: var GameState; args: seq[string]): CmdResult =
  if state.roomQueue.len == 0:
    return err("There is no one here.")
  if not state.roomQueue.anyIt(it.kind == rokEnemy):
    return err("No hostiles here.")
  discard initiateAggression(state)
  result = ok(startCombat(state))
  result.imagePath = roomImagePath(state)


proc initCmdTown*() =
  register("look",   ctxTown,    cmdLookRoom)
  register("move",   ctxTown,    cmdMoveRoom)
  register("leave",  ctxTown,    cmdLeave)
  register("peek",   ctxTown,    cmdPeekRoom)
  register("attack", ctxTown,    cmdAttackStart)
  register("look",   ctxDungeon, cmdLookRoom)
  register("move",   ctxDungeon, cmdMoveRoom)
  register("leave",  ctxDungeon, cmdLeave)
  register("peek",   ctxDungeon, cmdPeekRoom)
  register("attack", ctxDungeon, cmdAttackStart)
