## commands/cmd_dialogue.nim
## ─────────────────────────
## Dialogue and economy commands: talk, say, shop, buy, sell.
## Call initCmdDialogue() from game_loop to register handlers.

import std/[sequtils, strformat, strutils]
import engine/state
import engine/world
import engine/dialogue as dlg
import engine/economy  as econ
import commands/core


proc cmdTalk(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    let npcsHere = getNpcsInRoom(state).filterIt(not it.hostile)
    if npcsHere.len == 0:
      return ok("No one here to talk to.")
    var lines = @["Talk to whom?", ""]
    for n in npcsHere:
      lines.add &"  [[{n.label}:talk {n.id}]]"
    return ok(lines)
  let npcId = args[0].toLowerAscii
  ok(dlg.openDialogue(state, npcId))


proc cmdSay(state: var GameState; args: seq[string]): CmdResult =
  if args.len < 2:
    return err("say <npc_id> <topic_id>")
  ok(dlg.selectTopic(state, args[0].toLowerAscii, args[1].toLowerAscii))


proc cmdShop(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return ok(econ.shopLines(state))
  ok(econ.shopCategoryLines(state, args[0]))


proc cmdBuy(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Buy what?")
  ok(econ.buyTrade(state, args[0]))


proc cmdSell(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Sell what?")
  ok(econ.sellItem(state, args[0]))


proc initCmdDialogue*() =
  register("talk",  ctxTown,    cmdTalk)
  register("talk",  ctxDungeon, cmdTalk)
  registerAny("say",  cmdSay,  hidden = true)
  registerAny("shop", cmdShop, hidden = true)
  registerAny("buy",  cmdBuy,  hidden = true)
  registerAny("sell", cmdSell, hidden = true)
