## engine/log.nim
## ───────────────
## Rolling log supporting multiple targets, all written to <root>/logs/.
## Each target is opened independently with openLog(target, rootDir).
##
## Call openLog(target, rootDir) once before writing to that target.
## log(target, level, msg) is safe to call from any thread.

import std/[os, times, locks, strutils]

const MaxLines = 1000

type
  LogTarget* = enum Game, Manager, Tools
  LogLevel*  = enum Info, Warn, Error

var
  gPaths: array[LogTarget, string]
  gLines: array[LogTarget, seq[string]]
  gLock:  Lock

initLock(gLock)

const levelStr: array[LogLevel, string] = ["INFO", "WARN", "ERROR"]
const fileNames: array[LogTarget, string] = ["game.log", "manager.log", "tools.log"]


proc openLog*(target: LogTarget; rootDir: string) =
  ## Initialise a log target, writing to <rootDir>/logs/<name>.log.
  ## Creates the logs/ directory if needed.
  ## Call once from the main thread before writing to this target.
  {.cast(gcsafe).}:
    withLock gLock:
      let logsDir = rootDir / "logs"
      createDir(logsDir)
      gPaths[target] = logsDir / fileNames[target]
      if fileExists(gPaths[target]):
        let raw = readFile(gPaths[target]).splitLines
        gLines[target] = if raw.len > 0 and raw[^1] == "": raw[0 ..< raw.len - 1]
                         else: raw
        if gLines[target].len > MaxLines:
          gLines[target] = gLines[target][gLines[target].len - MaxLines .. ^1]


proc log*(target: LogTarget; level: LogLevel; msg: string) {.gcsafe.} =
  let ts   = now().format("yyyy-MM-dd HH:mm:ss")
  let line = "[" & ts & "] [" & levelStr[level] & "] " & msg
  {.cast(gcsafe).}:
    withLock gLock:
      if gPaths[target] == "": return
      gLines[target].add(line)
      if gLines[target].len > MaxLines:
        gLines[target] = gLines[target][gLines[target].len - MaxLines .. ^1]
      try:
        writeFile(gPaths[target], gLines[target].join("\n") & "\n")
      except CatchableError:
        discard   # nowhere useful to report a log-write failure
