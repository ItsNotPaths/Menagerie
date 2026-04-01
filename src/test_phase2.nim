## test_phase2.nim
## ──────────────────
## Smoke-test Phase 2: clock, world, commands.
## Compile: nim c --path:src -r src/test_phase2.nim
## Remove before shipping.

import std/[json, os, strutils]
import engine/state
import engine/gameplay_vars
import engine/content
import engine/clock
import engine/world
import commands/core
import commands/cmd_world
import commands/cmd_town
import commands/cmd_universal

const contentDir = "/run/media/paths/SSS-Core/Nim Projects/Menagerie-nim/content"

proc runTest() =
  echo "── Phase 2 smoke test ──"
  loadGameplayVars(contentDir)
  loadContent(contentDir)
  buildWorldDefIndex()

  initCmdWorld()
  initCmdTown()
  initCmdUniversal()

  var state = initGameState()
  state.context = ctxWorld

  echo "\n[clock] timeOfDay at tick=0: ", timeOfDay(state)
  passTicks(state, 10)
  echo "[clock] timeOfDay at tick=10: ", timeOfDay(state)

  echo "\n[world] tile at (0,0): ", getTile(state, 0, 0).tileType
  echo "[world] tile lines at (0,0):"
  for l in tileLines(state, 0, 0):
    echo "  ", l

  echo "\n[dispatch] look:"
  let r1 = dispatch("look", state)
  for l in r1.lines: echo "  ", l

  echo "\n[dispatch] go north:"
  let r2 = dispatch("go north", state)
  for l in r2.lines: echo "  ", l
  echo "  (ticks: ", r2.ticks, "  pos: ", state.player.position, ")"

  echo "\n[dispatch] survey north:"
  let r3 = dispatch("survey north", state)
  for l in r3.lines: echo "  ", l

  echo "\n[dispatch] status:"
  let r4 = dispatch("status", state)
  for l in r4.lines: echo "  ", l

  echo "\n[dispatch] help:"
  let r5 = dispatch("help", state)
  for l in r5.lines: echo "  ", l

  echo "\n[dispatch] unknown command:"
  let r6 = dispatch("xyzzy", state)
  echo "  error=", r6.isError, "  line=", r6.lines[0]

  echo "\n── Phase 2 smoke test complete ──"

runTest()
