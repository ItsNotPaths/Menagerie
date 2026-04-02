## commands/cmd_sneak.nim
## ──────────────────────
## Sneak-mode commands: sneak (toggle + move), pickpocket, sneak_item, steal,
## stealth_attack.
## Call initCmdSneak() from game_loop to register handlers.

import engine/state
import engine/world
import engine/sneak
import commands/core


proc cmdSneak(state: var GameState; args: seq[string]): CmdResult =
  if args.len > 0 and args[0] == "move":
    if not state.sneaking:
      return err("You are not sneaking.")
    return ok(sneak.rotateTarget(state))

  if state.sneaking:
    state.sneaking = false
    var lines = @["You step out of the shadows.", ""] & roomLines(state)
    result = ok(lines)
    result.imagePath = roomImagePath(state)
  else:
    state.sneaking = true
    var lines = @["You slip into the shadows.", ""] & roomLines(state)
    result = ok(lines)
    result.imagePath = roomImagePath(state)


proc cmdPickpocket(state: var GameState; args: seq[string]): CmdResult =
  if not state.sneaking:
    return err("You must be sneaking to pickpocket.")
  ok(sneak.doPickpocket(state))


proc cmdSneakItem(state: var GameState; args: seq[string]): CmdResult =
  if args.len < 2:
    return err("Usage: sneak_item <npc_id> <item_id>")
  ok(sneak.npcItemLines(state, args[0], args[1]))


proc cmdSteal(state: var GameState; args: seq[string]): CmdResult =
  if args.len < 2:
    return err("Usage: steal <npc_id> <item_id>")
  ok(sneak.doSteal(state, args[0], args[1]))


proc cmdStealthAttack(state: var GameState; args: seq[string]): CmdResult =
  if not state.sneaking:
    return err("You must be sneaking to perform a stealth attack.")
  ok(sneak.doStealthAttack(state))


proc initCmdSneak*() =
  register("sneak",            ctxTown,    cmdSneak)
  register("sneak",            ctxDungeon, cmdSneak)
  register("pickpocket",       ctxTown,    cmdPickpocket)
  register("pickpocket",       ctxDungeon, cmdPickpocket)
  register("sneak_item",       ctxTown,    cmdSneakItem,    hidden = true)
  register("sneak_item",       ctxDungeon, cmdSneakItem,    hidden = true)
  register("steal",            ctxTown,    cmdSteal,        hidden = true)
  register("steal",            ctxDungeon, cmdSteal,        hidden = true)
  register("stealth_attack",   ctxTown,    cmdStealthAttack)
  register("stealth_attack",   ctxDungeon, cmdStealthAttack)
