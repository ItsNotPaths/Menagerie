## commands/cmd_universal.nim
## ───────────────────────────
## Commands available in all contexts: help, wait, sleep, status.
## Call initCmdUniversal() from game_loop to register handlers.

import std/[json, sequtils, strformat, strutils]
import engine/state
import engine/clock
import engine/content
import engine/gameplay_vars
import engine/world
import engine/saves
import engine/skills
import engine/api
import commands/core


proc cmdHelp(state: var GameState; args: seq[string]): CmdResult =
  let ctx     = state.context
  let ctxList = registeredVerbs(ctx)
  let anyList = anyVerbs()
  var lines: seq[string]
  for v in ctxList:
    lines.add &"  [[{v}]]"
  if anyList.len > 0:
    lines.add ""
    for v in anyList:
      if v notin ctxList:
        lines.add &"  [[{v}]]"
  ok(lines)


proc cmdWait(state: var GameState; args: seq[string]): CmdResult =
  if state.context in [ctxTown, ctxDungeon] and not roomAllowsWait(state):
    return err("You cannot wait here — the area is not clear.")
  var hours = 1
  if args.len > 0:
    var parsed = 0
    try:
      parsed = parseInt(args[0])
    except ValueError:
      return err("Usage: wait [hours]")
    hours = parsed
  let minH = gvInt("wait_min_hours", 1)
  let maxH = gvInt("wait_max_hours", 24)
  hours = max(minH, min(hours, maxH))
  let suf = if hours == 1: "" else: "s"
  okTicks(hours * ticksPerHour, &"You wait {hours} hour{suf}.")


proc cmdSleep(state: var GameState; args: seq[string]): CmdResult =
  if state.player.currentRoom == "":
    return err("You can't sleep here.")
  let room = getRoom(state.player.currentRoom)
  if room.id == "" or room.raw == nil or room.raw{"type"}.getStr != "rest":
    return err("You can't sleep here.")
  if args.len == 0:
    return CmdResult(lines: @["Sleep for how many hours?"], prefill: "sleep ")
  var hours = 0
  try:
    hours = parseInt(args[0])
  except ValueError:
    return err("Usage: sleep <hours>")
  hours = max(1, min(hours, gvInt("wait_max_hours", 24)))
  let cost = gvInt("sleep_cost", 10)
  if state.player.gold < cost:
    return err(&"Sleeping here costs {cost} gold. You have {state.player.gold}.")
  state.player.gold -= cost
  state.player.lastRestPosition = state.player.position
  state.player.lastRestRoom     = state.player.currentRoom
  saves.flushPlayer(state)
  let restorePH = gvFloat("fatigue_sleep_restore_per_hour", 60.0)
  state.player.fatigue = min(100.0, state.player.fatigue + float(hours) * restorePH)
  let suf = if hours == 1: "" else: "s"
  okTicks(hours * ticksPerHour, &"You pay {cost} gold and sleep for {hours} hour{suf}.")


proc cmdStatus(state: var GameState; args: seq[string]): CmdResult =
  let p   = state.player
  let day = p.tick div ticksPerDay + 1
  ok(
    &"Day {day}  {timeOfDay(state)}",
    &"  Level    {p.level}  ({p.xp:.0f} XP)",
    &"  Health   {p.health:.0f}    Stamina  {p.stamina:.0f}    Focus  {p.focus:.0f}",
    &"  Gold     {p.gold}       Hunger   {p.hunger:.0f}",
  )


# ── Save command (available in any context during play) ───────────────────────

proc cmdSave(state: var GameState; args: seq[string]): CmdResult =
  let name = if args.len > 0: args.join(" ") else: ""
  let slot = saves.saveGame(state, name)
  ok(&"Game saved to slot '{slot}'.")


# ── Skills / level-up commands ───────────────────────────────────────────────

proc skillsLines(state: GameState): seq[string] =
  let p = state.player
  result.add &"  Level {p.level}  ({p.xp.int}/{XP_PER_LEVEL} XP)"
  result.add ""
  for name in SKILL_NAMES:
    let val = skillVal(state, name)
    result.add &"  {toTitleCase(name):<18} {val:>3}"
  if p.pendingSkillPicks > 0:
    result.add ""
    result &= skillPickPrompt(state)
  if p.pendingStatPicks > 0:
    result.add ""
    result &= statPickPrompt(state)
  if p.pendingPerkPicks > 0:
    result.add ""
    result &= perkPickPrompt()


proc cmdSkills(state: var GameState; args: seq[string]): CmdResult =
  CmdResult(panelLines: skillsLines(state))


proc cmdLevelupSkill(state: var GameState; args: seq[string]): CmdResult =
  if state.player.pendingSkillPicks <= 0:
    return err("No skill pick pending.")
  if args.len == 0:
    return ok(skillPickPrompt(state))
  let name = args[0].toLowerAscii
  if name notin SKILL_NAMES:
    return err(&"Unknown skill '{name}'. Type [[skills]] to see options.")
  trainSkill(state, name, SKILL_BUMP)
  dec state.player.pendingSkillPicks
  let newVal = skillVal(state, name)
  CmdResult(lines: @[&"  {toTitleCase(name)} improved to {newVal}."],
            panelLines: skillsLines(state), panelAppend: true)


proc cmdLevelupStat(state: var GameState; args: seq[string]): CmdResult =
  if state.player.pendingStatPicks <= 0:
    return err("No stat pick pending.")
  if args.len == 0:
    return ok(statPickPrompt(state))
  let stat = args[0].toLowerAscii
  case stat
  of "health":  state.player.maxHealth  += STAT_BUMP
  of "stamina": state.player.maxStamina += STAT_BUMP
  of "focus":   state.player.maxFocus   += STAT_BUMP
  else:
    return err("Choose: [[health:levelup_stat health]]  [[stamina:levelup_stat stamina]]  [[focus:levelup_stat focus]]")
  dec state.player.pendingStatPicks
  let newMax = case stat
    of "health":  state.player.maxHealth
    of "stamina": state.player.maxStamina
    else:         state.player.maxFocus
  CmdResult(lines: @[&"  Max {toTitleCase(stat)} increased to {newMax.int}."],
            panelLines: skillsLines(state), panelAppend: true)


proc cmdLevelupPerk(state: var GameState; args: seq[string]): CmdResult =
  if state.player.pendingPerkPicks <= 0:
    return err("No perk pick pending.")
  if args.len == 0:
    return err("Usage: levelup_perk <perk_id>")
  let perkId   = args[0].toLowerAscii
  let spendPick = if args.len > 1: args[1].toLowerAscii notin ["false", "0", "no"] else: true
  let duration  = if args.len > 2: (try: parseInt(args[2]) except ValueError: -1) else: -1
  if spendPick: dec state.player.pendingPerkPicks
  discard api.runCommand(state, &"add_effect player {perkId} {duration}", "player")
  CmdResult(lines: @[&"  Perk granted: {perkId}."],
            panelLines: skillsLines(state), panelAppend: true)


proc cmdPerks(state: var GameState; args: seq[string]): CmdResult =
  let perks = state.player.effects.filterIt(it.ticksRemaining == -1)
  var lines: seq[string]
  if perks.len == 0:
    lines.add "  No perks active."
  else:
    for e in perks:
      let def = content.getEffect(e.id)
      let name = if def.displayName.len > 0: def.displayName else: e.id
      lines.add &"  {name}"
      if def.description.len > 0:
        lines.add &"    {def.description}"
      if def.modifiers != nil and def.modifiers.kind == JObject:
        var mods: seq[string]
        for k, v in def.modifiers.pairs:
          let fv = v.getFloat
          let sign = if fv >= 0.0: "+" else: ""
          mods.add &"{k} {sign}{fv}"
        if mods.len > 0:
          lines.add &"    Modifiers: {mods.join(\", \")}"
      lines.add ""
  if state.player.pendingPerkPicks > 0:
    lines &= perkPickPrompt()
  ok(lines)


# ── Exit ─────────────────────────────────────────────────────────────────────

proc cmdExit(state: var GameState; args: seq[string]): CmdResult =
  CmdResult(lines: @["Farewell."], quit: true)


proc initCmdUniversal*() =
  registerAny("help",     cmdHelp)
  registerAny("wait",     cmdWait)
  registerAny("status",   cmdStatus)
  registerAny("save",  cmdSave)
  register("sleep", ctxTown,    cmdSleep)
  register("sleep", ctxDungeon, cmdSleep)
  registerAny("skills",        cmdSkills)
  registerAny("levelup_skill", cmdLevelupSkill, hidden = true)
  registerAny("levelup_stat",  cmdLevelupStat,  hidden = true)
  registerAny("levelup_perk",  cmdLevelupPerk,  hidden = true)
  registerAny("perks",         cmdPerks)
  registerAny("exit",          cmdExit)
