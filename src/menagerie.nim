import std/os
import engine/game_loop
import engine/log
import ui/text_window

proc findContentDir(): string =
  ## content/ must sit next to the binary (release) or in CWD (dev).
  let app = getAppDir() / "content"
  if dirExists(app): return app
  let cwd = getCurrentDir() / "content"
  if dirExists(cwd): return cwd
  log(Game, Error, "Cannot find content/ directory (checked: " &
      getAppDir() / "content" & ", " & getCurrentDir() / "content" & ")")
  quit("Cannot find content/ directory.", 1)

openLog(Game, getAppDir())
startGameThread(findContentDir())
main()
