## ui/term_ui.nim
## ──────────────
## Terminal frontend for Menagerie.  Activated with the -t flag.
## Reads commands from stdin, prints output to stdout.
## Communicates with the game thread over the same IPC channels as the SDL2 UI.

import std/[os, strutils]
import ipc
import ../engine/log

proc renderLinks(raw: string): string =
  ## Transform [[label:cmd]] → "label > cmd" and [[cmd]] → "cmd".
  result = ""
  var pos = 0
  while pos < raw.len:
    let linkStart = raw.find("[[", pos)
    if linkStart < 0:
      result.add raw[pos .. ^1]
      break
    result.add raw[pos ..< linkStart]
    let linkEnd = raw.find("]]", linkStart + 2)
    if linkEnd < 0:
      result.add raw[linkStart .. ^1]
      break
    let inner = raw[linkStart + 2 ..< linkEnd]
    let colon = inner.find(':')
    if colon >= 0:
      result.add inner[0 ..< colon] & " > " & inner[colon + 1 .. ^1]
    else:
      result.add inner
    pos = linkEnd + 2

proc printLine(line: string) =
  echo renderLinks(line)

proc handleMsg(msg: UiMsg; showStats = false): bool =
  ## Print a message. Returns true if this message ends a response (umStats or umQuit).
  case msg.kind
  of umPrint:
    printLine msg.line
  of umStats:
    if showStats:
      for s in msg.statLines:
        if s != "=-=-=-=":
          printLine s
    return true   # stats are always the last thing pushResult sends
  of umPanelReplace:
    for line in msg.replaceLines: printLine line
  of umPanelAppend:
    for line in msg.appendLines: printLine line
  of umPrefill:
    discard   # not useful in terminal mode
  of umQuit:
    return true
  of umLoadLocation, umRenderSprites, umJournalOpen:
    discard   # SDL-only, no-op in terminal
  return false

proc drainUntilStats(showStats = false): bool =
  ## Block-drain toUi until umStats (→ true) or umQuit (→ false).
  ## Called after each command is sent so the response is fully printed
  ## before the next prompt appears.
  while true:
    let (avail, msg) = toUi.tryRecv()
    if not avail:
      os.sleep(10)
      continue
    let done = handleMsg(msg, showStats)
    if done:
      return msg.kind != umQuit

proc drainUntilQuiet(quietMs = 120): bool =
  ## Drain toUi until no message arrives for quietMs milliseconds.
  ## Used once at startup to consume the menu splash (which has no umStats).
  ## Returns false if umQuit was seen.
  var silenceMs = 0
  while silenceMs < quietMs:
    let (avail, msg) = toUi.tryRecv()
    if avail:
      silenceMs = 0
      if handleMsg(msg) and msg.kind == umQuit:
        return false
    else:
      os.sleep(10)
      silenceMs += 10
  return true

proc termMain*() =
  log(Game, Info, "Terminal mode active")

  # Wait for the game thread to send the initial menu splash
  if not drainUntilQuiet():
    return

  var running = true
  while running:
    stdout.write("> ")
    stdout.flushFile()

    let line =
      try: stdin.readLine()
      except EOFError: "quit"

    if line.len == 0: continue

    toGame.send(GameMsg(kind: gmInput, raw: line))

    # Block until the game thread finishes responding (ends with umStats or umQuit).
    # Only display the stats block when the player explicitly asked for it.
    let isStatusCmd = line.splitWhitespace()[0] == "status"
    running = drainUntilStats(showStats = isStatusCmd)
