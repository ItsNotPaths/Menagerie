## engine/gameplay_vars.nim
## ────────────────────────
## Loads content/gameplay_vars.json once at startup and exposes gvFloat / gvInt
## for typed lookups across the engine.
## Falls back to hardcoded defaults if the file is missing or a key is absent.
##
## Usage:
##   loadGameplayVars(contentDir)          # call once at startup
##   let cost = gvFloat("dodge_stamina_cost", 15.0)
##   let dur  = gvInt("pin_duration", 2)

import std/[json, os]
import log

var gvData: JsonNode = newJNull()

proc loadGameplayVars*(contentDir: string) =
  let path = contentDir / "gameplay_vars.json"
  if not fileExists(path):
    log(Game, Warn, "gameplay_vars: file not found at " & path & " (using hardcoded defaults)")
    return
  try:
    gvData = parseFile(path)
  except CatchableError as e:
    log(Game, Error, "gameplay_vars: malformed " & path & " — " & e.msg & " (using hardcoded defaults)")
    gvData = newJNull()

proc gvFloat*(key: string; default: float): float =
  if gvData.kind == JObject and gvData.hasKey(key):
    gvData[key].getFloat(default)
  else:
    default

proc gvInt*(key: string; default: int): int =
  if gvData.kind == JObject and gvData.hasKey(key):
    gvData[key].getInt(default)
  else:
    default

proc gvStr*(key: string; default: string): string =
  if gvData.kind == JObject and gvData.hasKey(key):
    gvData[key].getStr(default)
  else:
    default
