## engine/log.nim
## ───────────────
## Rolling game log.  Writes INFO / WARN / ERROR lines to game.log next to the
## binary, keeping at most 1 000 lines (oldest are dropped first).
##
## Call openLog(dir) once from the main thread before starting the game thread.
## logInfo / logWarn / logError are safe to call from any thread.

import std/[os, times, locks, strutils]

const MaxLines = 1000

var
  gLogPath = ""
  gLines: seq[string]
  gLock:  Lock

initLock(gLock)


proc openLog*(dir: string) =
  ## Initialise the log, loading and trimming any existing game.log in `dir`.
  ## Call once from the main thread before spawning the game thread.
  {.cast(gcsafe).}:
    withLock gLock:
      gLogPath = dir / "game.log"
      if fileExists(gLogPath):
        let raw = readFile(gLogPath).splitLines
        gLines = if raw.len > 0 and raw[^1] == "": raw[0 ..< raw.len - 1]
                 else: raw
        if gLines.len > MaxLines:
          gLines = gLines[gLines.len - MaxLines .. ^1]


proc writeLog(level, msg: string) {.gcsafe.} =
  let ts   = now().format("yyyy-MM-dd HH:mm:ss")
  let line = "[" & ts & "] [" & level & "] " & msg
  {.cast(gcsafe).}:
    withLock gLock:
      if gLogPath == "": return
      gLines.add(line)
      if gLines.len > MaxLines:
        gLines = gLines[gLines.len - MaxLines .. ^1]
      try:
        writeFile(gLogPath, gLines.join("\n") & "\n")
      except CatchableError:
        discard   # nowhere useful to report a log-write failure


proc logInfo*(msg: string)  {.gcsafe.} = writeLog("INFO",  msg)
proc logWarn*(msg: string)  {.gcsafe.} = writeLog("WARN",  msg)
proc logError*(msg: string) {.gcsafe.} = writeLog("ERROR", msg)
