## commands/core.nim
## ──────────────────
## Command registry and dispatch. Each context's command file registers
## handlers with `register`; `dispatch` looks them up by (verb, context).
##
## Aliases are expanded before dispatch (e.g. "n" → "go north").

import std/[algorithm, strformat, strutils, tables]
import engine/state
import engine/clock
import engine/world
import engine/saves


# ── Result type ───────────────────────────────────────────────────────────────

type
  CmdResult* = object
    lines*:       seq[string]   ## text output for the scrollback
    imagePath*:   string        ## load this image into the left panel ("" = no change)
    ticks*:       int           ## ticks consumed (0 = no time passes)
    panelLines*:  seq[string]   ## replace right panel with these lines (empty = no change)
    panelAppend*: bool          ## append panelLines instead of replacing
    isError*:     bool
    quit*:        bool          ## signal game thread to shut down


proc ok*(lines: varargs[string]): CmdResult =
  CmdResult(lines: @lines)

proc okImg*(imagePath: string; lines: varargs[string]): CmdResult =
  CmdResult(lines: @lines, imagePath: imagePath)

proc okTicks*(ticks: int; lines: varargs[string]): CmdResult =
  CmdResult(lines: @lines, ticks: ticks)

proc err*(lines: varargs[string]): CmdResult =
  CmdResult(lines: @lines, isError: true)


# ── Handler type ──────────────────────────────────────────────────────────────

type HandlerProc* = proc(state: var GameState; args: seq[string]): CmdResult {.nimcall.}


# ── Registry ──────────────────────────────────────────────────────────────────

## Primary key: (verb, context). ANY context = ctxMenu used as wildcard sentinel.
## We store ANY handlers separately and fall back to them when no ctx match found.
var ctxRegistry: Table[(string, GameContext), HandlerProc]
var anyRegistry: Table[string, HandlerProc]
var hiddenVerbs: seq[string]   ## verbs omitted from help output


proc register*(verb: string; ctx: GameContext; h: HandlerProc; hidden = false) =
  ctxRegistry[(verb, ctx)] = h
  if hidden and verb notin hiddenVerbs: hiddenVerbs.add verb


proc registerAny*(verb: string; h: HandlerProc; hidden = false) =
  ## Register a handler that fires in any context.
  anyRegistry[verb] = h
  if hidden and verb notin hiddenVerbs: hiddenVerbs.add verb


proc isHidden*(verb: string): bool = verb in hiddenVerbs

proc registeredVerbs*(ctx: GameContext): seq[string] =
  ## All non-hidden verbs active in ctx (ctx-specific + any).
  for (v, c) in ctxRegistry.keys:
    if c == ctx and v notin hiddenVerbs: result.add v
  for v in anyRegistry.keys:
    if v notin hiddenVerbs and (v, ctx) notin ctxRegistry: result.add v
  result.sort()

proc anyVerbs*(): seq[string] =
  ## All non-hidden any-context verbs (for help display).
  for v in anyRegistry.keys:
    if v notin hiddenVerbs: result.add v
  result.sort()


# ── Aliases ───────────────────────────────────────────────────────────────────

const aliases* = {
  "n":   "go north",
  "s":   "go south",
  "e":   "go east",
  "w":   "go west",
  "l":   "look",
  "j":   "journal",
  "i":   "inventory",
  "inv": "inventory",
  "h":   "help",
  "?":   "help",
}.toTable


# ── Dispatch ──────────────────────────────────────────────────────────────────

const maxInputLen = 512
const maxArgs     = 8


proc currentImage*(state: GameState): string =
  ## Return the appropriate image path for wherever the player currently is.
  case state.context
  of ctxTown, ctxDungeon, ctxCombat:
    roomImagePath(state)
  of ctxWorld:
    let (x, y) = state.player.position
    tileImagePath(state, x, y)
  else:
    ""


proc dispatch*(raw: string; state: var GameState): CmdResult =
  if raw.len > maxInputLen:
    return err("Input too long.")

  let expanded = aliases.getOrDefault(raw.strip.toLowerAscii, raw.strip)
  let parts    = expanded.splitWhitespace
  if parts.len == 0:
    return CmdResult()

  let verb    = parts[0].toLowerAscii
  let allArgs = parts[1..^1]
  let args    = allArgs[0..min(allArgs.len - 1, maxArgs - 1)]
  let ctx     = state.context

  let handler =
    if (verb, ctx) in ctxRegistry: ctxRegistry[(verb, ctx)]
    elif verb in anyRegistry:      anyRegistry[verb]
    else: nil

  if handler == nil:
    return err(&"Unknown command: '{verb}'. Type [[help]] for a list.")

  result = handler(state, args)

  if result.ticks > 0:
    passTicks(state, result.ticks)
    saves.autosave(state)

  # After a combat-ending command restore the correct image
  if ctx == ctxCombat and state.context != ctxCombat and result.imagePath == "":
    result.imagePath = currentImage(state)
