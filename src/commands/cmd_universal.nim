## commands/cmd_universal.nim
## ───────────────────────────
## Commands available in all contexts: help, wait, sleep, status.
## Call initCmdUniversal() from game_loop to register handlers.

import std/[json, strformat, strutils]
import engine/state
import engine/clock
import engine/content
import engine/gameplay_vars
import engine/world
import commands/core


proc cmdHelp(state: var GameState; args: seq[string]): CmdResult =
  let ctx     = state.context
  let ctxList = registeredVerbs(ctx)
  let anyList = anyVerbs()
  var lines: seq[string]
  for v in ctxList:
    lines.add &"  [[{v}]]"
  if anyList.len > 0:
    lines.add ""
    for v in anyList:
      if v notin ctxList:
        lines.add &"  [[{v}]]"
  ok(lines)


proc cmdWait(state: var GameState; args: seq[string]): CmdResult =
  if state.context in [ctxTown, ctxDungeon] and not roomAllowsWait(state):
    return err("You cannot wait here — the area is not clear.")
  var hours = 1
  if args.len > 0:
    var parsed = 0
    try:
      parsed = parseInt(args[0])
    except ValueError:
      return err("Usage: wait [hours]")
    hours = parsed
  let minH = gvInt("wait_min_hours", 1)
  let maxH = gvInt("wait_max_hours", 24)
  hours = max(minH, min(hours, maxH))
  let suf = if hours == 1: "" else: "s"
  okTicks(hours * ticksPerHour, &"You wait {hours} hour{suf}.")


proc cmdSleep(state: var GameState; args: seq[string]): CmdResult =
  if state.player.currentRoom == "":
    return err("You can't sleep here.")
  let room = getRoom(state.player.currentRoom)
  if room.id == "" or room.raw == nil or room.raw{"type"}.getStr != "rest":
    return err("You can't sleep here.")
  if args.len == 0:
    return ok("Sleep for how many hours?")
  var hours = 0
  try:
    hours = parseInt(args[0])
  except ValueError:
    return err("Usage: sleep <hours>")
  hours = max(1, min(hours, gvInt("wait_max_hours", 24)))
  let cost = gvInt("sleep_cost", 10)
  if state.player.gold < cost:
    return err(&"Sleeping here costs {cost} gold. You have {state.player.gold}.")
  state.player.gold -= cost
  state.player.lastRestPosition = state.player.position
  state.player.lastRestRoom     = state.player.currentRoom
  # SAVES_WIRE flush_player
  let restorePH = gvFloat("fatigue_sleep_restore_per_hour", 60.0)
  state.player.fatigue = min(100.0, state.player.fatigue + float(hours) * restorePH)
  let suf = if hours == 1: "" else: "s"
  okTicks(hours * ticksPerHour, &"You pay {cost} gold and sleep for {hours} hour{suf}.")


proc cmdStatus(state: var GameState; args: seq[string]): CmdResult =
  let p   = state.player
  let day = p.tick div ticksPerDay + 1
  ok(
    &"Day {day}  {timeOfDay(state)}",
    &"  Level    {p.level}  ({p.xp:.0f} XP)",
    &"  Health   {p.health:.0f}    Stamina  {p.stamina:.0f}    Focus  {p.focus:.0f}",
    &"  Gold     {p.gold}       Hunger   {p.hunger:.0f}",
  )


# ── Save / load stubs (Phase 9) ───────────────────────────────────────────────
# SAVES_WIRE on_save
proc cmdSave(state: var GameState; args: seq[string]): CmdResult =
  ok("(save not yet implemented)")  # Phase 9: saves.flushToWorking(state); saves.zipWorking()

# SAVES_WIRE on_load
proc cmdLoad(state: var GameState; args: seq[string]): CmdResult =
  ok("(load not yet implemented)")  # Phase 9: saves.loadFromWorking(state)

# SAVES_WIRE on_new_game
proc cmdNew(state: var GameState; args: seq[string]): CmdResult =
  ok("(new game not yet implemented)")  # Phase 9: saves.clearWorking(); initGameState()

# SAVES_WIRE on_continue
proc cmdContinue(state: var GameState; args: seq[string]): CmdResult =
  ok("(continue not yet implemented)")  # Phase 9: saves.loadFromWorking(state) if save exists


proc initCmdUniversal*() =
  registerAny("help",     cmdHelp)
  registerAny("wait",     cmdWait)
  registerAny("status",   cmdStatus)
  registerAny("save",     cmdSave)
  registerAny("load",     cmdLoad)
  registerAny("new",      cmdNew)
  registerAny("continue", cmdContinue)
  register("sleep", ctxTown,    cmdSleep)
  register("sleep", ctxDungeon, cmdSleep)
