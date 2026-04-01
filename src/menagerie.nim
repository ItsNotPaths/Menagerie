import std/os
import engine/game_loop
import ui/text_window

proc findContentDir(): string =
  ## content/ must sit next to the binary (release) or in CWD (dev).
  let app = getAppDir() / "content"
  if dirExists(app): return app
  let cwd = getCurrentDir() / "content"
  if dirExists(cwd): return cwd
  quit("Cannot find content/ directory.", 1)

startGameThread(findContentDir())
main()
