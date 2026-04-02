## commands/cmd_debug.nim
## ──────────────────────
## Debug commands — available in any context.
## Call initCmdDebug() from game_loop to register handlers.

import engine/state
import engine/scripting
import engine/api
import commands/core


proc cmdDbLua(state: var GameState; args: seq[string]): CmdResult =
  ## dblua <script.lua>
  ## Runs a script from content/scripts/ and prints its output.
  ## Uses "player" as selfId so enemy.self selectors resolve to nothing.
  if args.len == 0:
    return err("Usage: dblua <script.lua>")
  let scriptName = args[0]
  let lines = api.runCommand(state, scriptName, "player")
  if lines.len == 0:
    return ok("[dblua] " & scriptName & " ran (no output)")
  result = ok(@["[dblua] " & scriptName] & lines)


proc initCmdDebug*() =
  registerAny("dblua", cmdDbLua, hidden = true)
