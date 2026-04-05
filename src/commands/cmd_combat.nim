## commands/cmd_combat.nim
## ───────────────────────
## Combat context commands: look, attack, dodge, block, pass, cast,
## cancel, flee, and all auxiliary spatial spells.
## Call initCmdCombat() from game_loop to register handlers.

import std/[options, strformat, strutils]
import engine/state
import engine/content
import engine/world
import engine/combat
import commands/core


# ── View helpers ──────────────────────────────────────────────────────────────

proc combatView(state: var GameState): CmdResult =
  ## Status lines + option buttons for the current round.
  if not state.combat.isSome:
    return err("No active combat.")
  var lines = enemyStatusLines(state)
  lines.add ""
  lines.add playerResourceLine(state)
  lines.add ""
  lines &= optionButtons(state)
  result = ok(lines)
  result.imagePath = roomImagePath(state)


# ── Commands ──────────────────────────────────────────────────────────────────

proc cmdLookCombat(state: var GameState; args: seq[string]): CmdResult =
  combatView(state)


proc cmdAttackCombat(state: var GameState; args: seq[string]): CmdResult =
  ok(doAttack(state))


proc cmdDodge(state: var GameState; args: seq[string]): CmdResult =
  ok(doDodge(state))


proc cmdBlock(state: var GameState; args: seq[string]): CmdResult =
  ok(doBlock(state))


proc cmdPass(state: var GameState; args: seq[string]): CmdResult =
  ok(doPass(state))


proc cmdFlee(state: var GameState; args: seq[string]): CmdResult =
  let lines = doFlee(state)
  result = ok(lines)
  if state.context != ctxCombat:
    result.imagePath = currentImage(state)


proc cmdCancel(state: var GameState; args: seq[string]): CmdResult =
  combatView(state)


# ── cast ──────────────────────────────────────────────────────────────────────

proc cmdCast(state: var GameState; args: seq[string]): CmdResult =
  let p = state.player
  const castModes = ["smite", "beam", "wave", "trap"]

  if p.spellbook.len == 0:
    return ok("You don't know any spells.")

  # ── cast (no args) → favourites list ──────────────────────────────────────
  if args.len == 0:
    var lines = @["Cast which spell?", ""]
    if p.favourites.len > 0:
      for sid in p.favourites:
        let spDef = content.getSpell(sid)
        let label = if spDef.id != "": spDef.displayName else: sid
        lines.add &"  [[{label}:cast {sid}]]"
    else:
      lines.add "  (no favourites — use [[spells]] to add some)"
    lines.add ""
    lines.add "  [[all spells:cast all]]"
    return ok(lines)

  let first = args[0].toLowerAscii

  # ── cast all → full spellbook ──────────────────────────────────────────────
  if first == "all":
    if p.spellbook.len == 0:
      return ok("You know no spells.")
    var lines = @["All known spells:", ""]
    for sid in p.spellbook:
      let spDef = content.getSpell(sid)
      let label = if spDef.id != "": spDef.displayName else: sid
      lines.add &"  [[{label}:cast {sid}]]"
    return ok(lines)

  # ── cast <spell_id> (no mode) → mode picker ───────────────────────────────
  if first notin castModes:
    let spellId = first
    if spellId notin p.spellbook:
      return err(&"You don't know '{spellId}'.")
    let spDef = content.getSpell(spellId)
    let label = if spDef.id != "": spDef.displayName else: spellId
    return ok(
      &"Cast {label} as:", "",
      &"  [[smite:cast smite {spellId}]]   [[beam:cast beam {spellId}]]" &
      &"   [[wave:cast wave {spellId}]]   [[trap:cast trap {spellId}]]",
      "", "  [[cancel]]",
    )

  # ── cast <mode> <spell_id> [row [dist]] → prompt or fire ──────────────────
  let mode = first
  if args.len < 2:
    return err("Usage: cast <mode> <spell>")
  let spellId = args[1].toLowerAscii

  var row  = -1
  var dist = -1
  if args.len > 2:
    try: row = parseInt(args[2])
    except: return err("Row must be an integer.")
  if args.len > 3:
    try: dist = parseInt(args[3])
    except: return err("Distance must be an integer.")

  # Row not yet given — prompt
  if row < 0:
    if mode in ["smite", "trap"]:
      return CmdResult(
        lines:   @[&"{mode.capitalizeAscii} — row and distance? (e.g. 'cast {mode} {spellId} 3 2')"],
        prefill: &"cast {mode} {spellId} ",
      )
    else:
      return CmdResult(
        lines:   @[&"{mode.capitalizeAscii} — which row? (e.g. 'cast {mode} {spellId} 5')"],
        prefill: &"cast {mode} {spellId} ",
      )

  # dist required for smite/trap but not given
  if mode in ["smite", "trap"] and dist < 0:
    return CmdResult(
      lines:   @[&"{mode.capitalizeAscii} at row {row} — distance? (e.g. 'cast {mode} {spellId} {row} 2')"],
      prefill: &"cast {mode} {spellId} {row} ",
    )

  let distOpt = if dist >= 0: some(dist) else: none(int)
  ok(doCast(state, mode, spellId, row, distOpt))


# ── Auxiliary spatial spells ──────────────────────────────────────────────────

proc cmdPush(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return CmdResult(lines: @["Push — which row?"], prefill: "push ")
  ok(doAuxSpell(state, "push", args))

proc cmdPull(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return CmdResult(lines: @["Pull — which row?"], prefill: "pull ")
  ok(doAuxSpell(state, "pull", args))

proc cmdScatter(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return CmdResult(lines: @["Scatter — which row?"], prefill: "scatter ")
  ok(doAuxSpell(state, "scatter", args))

proc cmdPin(state: var GameState; args: seq[string]): CmdResult =
  if args.len < 2:
    return CmdResult(lines: @["Pin — row and distance? (e.g. 'pin 3 2')"], prefill: "pin " & args.join(" ") & (if args.len > 0: " " else: ""))
  ok(doAuxSpell(state, "pin", args))

proc cmdSwap(state: var GameState; args: seq[string]): CmdResult =
  if args.len < 4:
    return CmdResult(lines: @["Swap — two positions: row1 dist1 row2 dist2 (e.g. 'swap 1 3 2 4')"], prefill: "swap " & args.join(" ") & (if args.len > 0: " " else: ""))
  ok(doAuxSpell(state, "swap", args))

proc cmdBind(state: var GameState; args: seq[string]): CmdResult =
  if args.len < 2:
    return CmdResult(lines: @["Bind — two enemy IDs? (e.g. 'bind goblin orc')"], prefill: "bind " & args.join(" ") & (if args.len > 0: " " else: ""))
  ok(doAuxSpell(state, "bind", args))


# ── Init ──────────────────────────────────────────────────────────────────────

proc initCmdCombat*() =
  register("look",    ctxCombat, cmdLookCombat)
  register("attack",  ctxCombat, cmdAttackCombat)
  register("dodge",   ctxCombat, cmdDodge)
  register("block",   ctxCombat, cmdBlock)
  register("pass",    ctxCombat, cmdPass)
  register("cast",    ctxCombat, cmdCast)
  register("cancel",  ctxCombat, cmdCancel)
  register("flee",    ctxCombat, cmdFlee)
  register("push",    ctxCombat, cmdPush)
  register("pull",    ctxCombat, cmdPull)
  register("scatter", ctxCombat, cmdScatter)
  register("pin",     ctxCombat, cmdPin)
  register("swap",    ctxCombat, cmdSwap)
  register("bind",    ctxCombat, cmdBind)
