import std/os
import engine/game_loop
import engine/log
import ui/text_window
import ui/term_ui

proc findContentDir(): string =
  ## content/ must sit next to the binary (release) or in CWD (dev).
  let app = getAppDir() / "content"
  if dirExists(app): return app
  let cwd = getCurrentDir() / "content"
  if dirExists(cwd): return cwd
  log(Game, Error, "Cannot find content/ directory (checked: " &
      getAppDir() / "content" & ", " & getCurrentDir() / "content" & ")")
  quit("Cannot find content/ directory.", 1)

let terminalMode = "-t" in commandLineParams()

openLog(Game, getAppDir())
startGameThread(findContentDir())
if terminalMode:
  termMain()
else:
  main()
