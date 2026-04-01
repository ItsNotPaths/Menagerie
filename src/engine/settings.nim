## engine/settings.nim
## ───────────────────
## Thin loader for settings.txt (key=value, one per line, # comments ignored).
## Call loadSettings(path) once at startup; then use get/getFloat/getInt.
##
## Engine keys
## ───────────
##   combat_pause   seconds between combat narration lines (default 0.5)
##   travel_pause   seconds between road travel steps      (default 0.3)
##   auto_slots     autosave slot count                     (default 5)

import std/[strutils, tables]

var data: Table[string, string]


proc loadSettings*(path: string) =
  ## Parse settings.txt into the module-level table.
  ## Safe to call multiple times (replaces previous data).
  data.clear()
  try:
    for rawLine in lines(path):
      let line = rawLine.strip()
      if line.len == 0 or line.startsWith("#"): continue
      let eq = line.find('=')
      if eq < 0: continue
      data[line[0..<eq].strip()] = line[eq+1..^1].strip()
  except IOError:
    discard   # missing settings.txt is fine — defaults apply


proc get*(key: string; default = ""): string =
  data.getOrDefault(key, default)


proc getFloat*(key: string; default: float): float =
  let raw = data.getOrDefault(key, "")
  if raw == "": return default
  try: parseFloat(raw) except ValueError: default


proc getInt*(key: string; default: int): int =
  let raw = data.getOrDefault(key, "")
  if raw == "": return default
  try: parseInt(raw) except ValueError: default


# ── Named engine settings ─────────────────────────────────────────────────────

proc combatPauseMs*(): int =
  ## Milliseconds to sleep between consecutive combat narration lines.
  int(getFloat("combat_pause", 0.5) * 1000)

proc travelPauseMs*(): int =
  ## Milliseconds to sleep between road travel steps.
  int(getFloat("travel_pause", 0.3) * 1000)
