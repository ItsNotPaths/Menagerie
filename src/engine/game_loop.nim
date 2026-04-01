## engine/game_loop.nim
## ────────────────────
## Background game thread.  Owns GameState and drives command dispatch.
## Posts output to toUi; blocks on toGame.recv for player commands.
##
## Call startGameThread(contentDir) from the main thread before ui.main().

import std/[json, strformat, tables]
import state
import content
import world
import clock
import api
import ../commands/core
import ../commands/cmd_world
import ../commands/cmd_town
import ../commands/cmd_universal
import ../commands/cmd_inventory
import ../ui/ipc


# ── HUD builder ───────────────────────────────────────────────────────────────

proc buildStatLines(state: GameState): seq[string] =
  let p   = state.player
  let day = p.tick div ticksPerDay + 1
  @[
    &"Day: {day}  {timeOfDay(state)}",
    &"Level: {p.level}",
    &"HP: {p.health:.0f} / {p.maxHealth:.0f}",
    &"Stamina: {p.stamina:.0f} / {p.maxStamina:.0f}",
    &"Focus: {p.focus:.0f} / {p.maxFocus:.0f}",
    &"Fatigue: {p.fatigue:.0f}",
    &"Hunger: {p.hunger:.0f}",
    &"Gold: {p.gold}",
  ]


# ── Push helpers ──────────────────────────────────────────────────────────────

proc pushLines(lines: seq[string]) =
  for line in lines:
    toUi.send(UiMsg(kind: umPrint, line: line))

proc pushStats(state: GameState) =
  toUi.send(UiMsg(kind: umStats, statLines: buildStatLines(state)))

proc pushResult(res: CmdResult; state: GameState) =
  pushLines(res.lines)
  if res.imagePath != "":
    toUi.send(UiMsg(kind: umLoadLocation, imgPath: res.imagePath))
  if res.panelLines.len > 0:
    if res.panelAppend:
      toUi.send(UiMsg(kind: umPanelAppend, appendLines: res.panelLines))
    else:
      toUi.send(UiMsg(kind: umPanelReplace, replaceLines: res.panelLines))
  pushStats(state)


# ── Game thread ───────────────────────────────────────────────────────────────

proc gameThread(contentDir: string) {.thread.} =
  # Content tables and command registry are GC'd globals, but only written
  # during this thread's own init before entering the recv loop — safe.
  {.cast(gcsafe).}:
    # Load content and build world index
    loadContent(contentDir)
    buildWorldDefIndex()

    # Register command handlers
    initCmdUniversal()
    initCmdWorld()
    initCmdTown()
    initCmdInventory()

    initApi()

    # Initialise game state — start on the world map
    var state = initGameState()
    state.context = ctxWorld
    state.variables["world_seed"] = %worldDef.worldSeed

    # Send welcome message and initial look
    toUi.send(UiMsg(kind: umPrint, line: "Welcome to Menagerie."))
    toUi.send(UiMsg(kind: umPrint, line: ""))
    let lookRes = dispatch("look", state)
    pushResult(lookRes, state)

    # Dispatch loop — blocks until player sends a command
    while true:
      let msg = toGame.recv()
      case msg.kind
      of gmInput:
        let raw = msg.raw
        if raw.len == 0: continue
        let res = dispatch(raw, state)
        pushResult(res, state)


# ── Public entry point ────────────────────────────────────────────────────────

var gThread: Thread[string]

proc startGameThread*(contentDir: string) =
  toUi.open()
  toGame.open()
  createThread(gThread, gameThread, contentDir)
