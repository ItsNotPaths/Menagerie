## engine/api_types.nim
## ──────────────────────────────────────────────────────────────────────────
## Hook proc variables that break the api ↔ conditions/armor/modifiers
## circular import cycle.
##
## conditions, armor, and modifiers all need to call api.runCommand /
## api.addEffect, but api.nim imports all three — a cycle Nim forbids.
## Instead those modules call through these module-level proc vars, which
## api.initApi() fills in before the game loop starts.

import state

type
  RunCmdFn* = proc(state: var GameState; cmd: string;
                   selfId: string): seq[string]
  AddEffFn* = proc(state: var GameState; selector, effectId: string;
                   duration: int; selfId: string): seq[string]

var
  apiRunCommand*: RunCmdFn   ## set by api.initApi()
  apiAddEffect*:  AddEffFn   ## set by api.initApi()
