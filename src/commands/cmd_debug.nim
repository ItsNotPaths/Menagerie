## commands/cmd_debug.nim
## ──────────────────────
## Debug commands — available in any context, all hidden from the help list.
## Call initCmdDebug() from game_loop to register handlers.

import std/[json, options, strformat, strutils, tables, algorithm]
import engine/state
import engine/content
import engine/clock
import engine/world
import engine/items
import engine/skills
import engine/saves
import engine/scripting
import engine/api
import commands/core


# ── dbwhere ───────────────────────────────────────────────────────────────────

proc cmdDbWhere(state: var GameState; args: seq[string]): CmdResult =
  let (x, y) = state.player.position
  let wd     = world.getWorldDefTile(x, y)
  var label  = &"({x}, {y})"
  if wd.isSome:
    let w = wd.get
    let name = if w.name != "": w.name elif w.tile != "": w.tile else: w.tileType
    label &= &"  [{name}]"
  let key       = &"{x}_{y}"
  let source    = if wd.isSome: "world_def" else: "procedural"
  let day       = state.player.tick div ticksPerDay
  let hour      = (state.player.tick mod ticksPerDay) div ticksPerHour
  var lines = @[
    "-- position ----------------------------------",
    &"  tile:         {label}",
    &"  source:       {source}",
    &"  dirty file:   saves/working/dirty/{key}.json",
    &"  current room: {(if state.player.currentRoom != \"\": state.player.currentRoom else: \"(none)\")}",
    &"  context:      {state.context}",
    &"  tick:         {state.player.tick}  (day {day}, hour {hour})",
  ]
  if wd.isSome and wd.get.tile != "":
    lines.insert(&"  tile file:    content/tiles/{wd.get.tile}.json", 3)
  ok(lines)


# ── dbtile ────────────────────────────────────────────────────────────────────

proc cmdDbTile(state: var GameState; args: seq[string]): CmdResult =
  var x, y: int
  if args.len >= 2:
    try:
      x = parseInt(args[0])
      y = parseInt(args[1])
    except ValueError:
      return err("Usage: dbtile [x y]")
  else:
    (x, y) = state.player.position

  let key       = &"{x}_{y}"
  let worldSeed = state.variables.getOrDefault("world_seed", %0).getInt
  let wdOpt     = world.getWorldDefTile(x, y)
  let tile      = world.getTile(state, x, y)
  let source    = if wdOpt.isSome: "world_def"
                  else: &"procedural (seed={worldSeed})"

  var lines = @[&"-- tile ({x}, {y})  {source} --"]

  if wdOpt.isSome:
    let w = wdOpt.get
    lines.add &"  type:        {w.tileType}"
    if w.name != "":        lines.add &"  name:        {w.name}"
    if w.tile != "":        lines.add &"  tile:        {w.tile}"
    if w.description != "": lines.add &"  description: {w.description}"
    if w.image != "":       lines.add &"  image:       {w.image}"
  else:
    lines.add &"  generated:   type={tile.tileType}  tileDef={tile.tileDef}"

  # Tile composition file
  let tileName = if wdOpt.isSome and wdOpt.get.tile != "": wdOpt.get.tile
                 elif key in state.dirty and state.dirty[key]{"tile"} != nil:
                   state.dirty[key]["tile"].getStr
                 else: tile.tileDef
  if tileName != "":
    let td = content.getTileDef(tileName)
    let exists = if td.id != "": "found" else: "missing"
    lines.add &"  tile file:   content/tiles/{tileName}.json  ({exists})"
    if td.id != "":
      lines.add &"    entry_room:  {td.entryRoom}"
      lines.add &"    rooms:       {td.rooms}"

  # Dirty data
  lines.add &"  dirty file:  saves/working/dirty/{key}.json"
  if key in state.dirty:
    lines.add "  dirty:"
    let d = state.dirty[key]
    if d.kind == JObject:
      for k, v in d: lines.add &"    {k}: {v}"
  else:
    lines.add "  dirty:       (none -- not yet visited)"

  ok(lines)


# ── dbstate ───────────────────────────────────────────────────────────────────

proc cmdDbState(state: var GameState; args: seq[string]): CmdResult =
  let p = state.player
  var lines = @["-- player state ----------------------------------"]
  lines.add &"  position:           ({p.position[0]}, {p.position[1]})"
  lines.add &"  currentRoom:        {p.currentRoom}"
  lines.add &"  lastRestPosition:   ({p.lastRestPosition[0]}, {p.lastRestPosition[1]})"
  lines.add &"  lastRestRoom:       {p.lastRestRoom}"
  lines.add &"  tick:               {p.tick}"
  lines.add &"  gold:               {p.gold}"
  lines.add &"  health:             {p.health:.1f} / {p.maxHealth:.1f}"
  lines.add &"  stamina:            {p.stamina:.1f} / {p.maxStamina:.1f}"
  lines.add &"  focus:              {p.focus:.1f} / {p.maxFocus:.1f}"
  lines.add &"  hunger:             {p.hunger:.1f}"
  lines.add &"  fatigue:            {p.fatigue:.1f}"
  lines.add &"  level:              {p.level}  ({p.xp:.0f} / {XP_PER_LEVEL} xp)"
  lines.add &"  mainhand:           {p.mainhand}"
  lines.add &"  offhand:            {p.offhand}"
  lines.add &"  pendingSkillPicks:  {p.pendingSkillPicks}"
  lines.add &"  pendingStatPicks:   {p.pendingStatPicks}"
  lines.add &"  pendingPerkPicks:   {p.pendingPerkPicks}"
  lines.add &"  inventory ({p.inventory.len}):"
  for e in p.inventory: lines.add &"    {e.id} x{e.count}  ({e.slots} slots)"
  lines.add &"  armor:"
  for zone, plate in p.armor: lines.add &"    {zone}: {plate}"
  lines.add &"  containers:  {p.containers}"
  lines.add &"  spellbook:   {p.spellbook}"
  lines.add &"  effects ({p.effects.len}):"
  for e in p.effects: lines.add &"    {e.id}  ({e.ticksRemaining} ticks)"
  lines.add &"  skills:"
  for name in SKILL_NAMES:
    lines.add &"    {name:<16} {skillVal(state, name)}"
  ok(lines)


# ── dbvars ────────────────────────────────────────────────────────────────────

proc cmdDbVars(state: var GameState; args: seq[string]): CmdResult =
  let filt  = if args.len > 0: args[0].toLowerAscii else: ""
  var lines = @["-- variables ---------------------------------"]
  var keys: seq[string]
  for k in state.variables.keys: keys.add k
  keys.sort()
  for k in keys:
    if filt == "" or filt in k.toLowerAscii:
      lines.add &"  {k}: {state.variables[k]}"
  if lines.len == 1:
    lines.add if filt != "": &"  (no variables matching '{filt}')"
              else: "  (empty)"
  ok(lines)


# ── dbdirty ───────────────────────────────────────────────────────────────────

proc cmdDbDirty(state: var GameState; args: seq[string]): CmdResult =
  if state.dirty.len == 0:
    return ok("-- dirty -------------------------------------", "  (empty)")
  var lines = @["-- dirty -------------------------------------"]
  for key, entry in state.dirty:
    lines.add &"  {key}: {entry}"
  ok(lines)


# ── dbteleport / dbtp ─────────────────────────────────────────────────────────

proc cmdDbTeleport(state: var GameState; args: seq[string]): CmdResult =
  if args.len < 2:
    return err("Usage: dbteleport <x> <y>")
  var x, y: int
  try:
    x = parseInt(args[0])
    y = parseInt(args[1])
  except ValueError:
    return err("x and y must be integers.")
  state.player.position    = (x, y)
  state.player.currentRoom = ""
  state.context            = ctxWorld
  ok(@[&"Teleported to ({x}, {y})."] & world.tileLines(state, x, y))


# ── dblearnspell ──────────────────────────────────────────────────────────────

proc cmdDbLearnSpell(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: dblearnspell <spell_id>")
  let spellId = args[0].toLowerAscii
  if content.getSpell(spellId).id == "":
    return err(&"Unknown spell '{spellId}'.")
  if spellId in state.player.spellbook:
    return ok(&"'{spellId}' is already in your spellbook.")
  state.player.spellbook.add spellId
  ok(&"Learned spell: {spellId}")


# ── dbgive ────────────────────────────────────────────────────────────────────

proc cmdDbGive(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: dbgive <item_id> [count]")
  let itemId = args[0].toLowerAscii
  if anyItem(itemId).id == "":
    return err(&"Unknown item '{itemId}'.")
  var count = 1
  if args.len > 1:
    try: count = max(1, parseInt(args[1]))
    except ValueError: return err("Count must be an integer.")
  for _ in 0 ..< count:
    giveItem(state, itemId)
  let label = anyItem(itemId).displayName
  ok(&"Given: {label} x{count}")


# ── dbtake ────────────────────────────────────────────────────────────────────

proc cmdDbTake(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: dbtake <item_id>")
  let itemId = args[0].toLowerAscii
  if takeItem(state, itemId):
    ok(&"Removed '{itemId}' from inventory.")
  else:
    err(&"'{itemId}' not in inventory.")


# ── dbkill ────────────────────────────────────────────────────────────────────

proc cmdDbKill(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: dbkill <entity_id>")
  let entityId = args[0].toLowerAscii
  let dropped  = world.dropEntityLoot(state, entityId)
  saves.flushNpcStates(state)
  let loot = if dropped.len > 0: "Dropped: " & dropped.join(", ") else: "Dropped nothing."
  ok(&"Killed {entityId}.", loot)


# ── dbsave ────────────────────────────────────────────────────────────────────

proc cmdDbSave(state: var GameState; args: seq[string]): CmdResult =
  let name = if args.len > 0: args.join("_") else: ""
  let slot = saves.saveGame(state, name)
  ok(&"Saved to '{slot}'.")


# ── dbgivexp ──────────────────────────────────────────────────────────────────

proc cmdDbGiveXp(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: dbgivexp <amount>")
  var amount: float
  try: amount = parseFloat(args[0])
  except ValueError: return err("Amount must be a number.")
  let before  = state.player.level
  let lines   = skills.giveXp(state, amount)
  let header  = &"  +{amount:.0f} XP  (level {before} -> {state.player.level}  {state.player.xp.int}/{XP_PER_LEVEL})"
  ok(@[header] & lines)


# ── dblevelup ────────────────────────────────────────────────────────────────

proc cmdDbLevelUp(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err(&"Usage: dblevelup <skill>   Skills: {SKILL_NAMES.join(\", \")}")
  let name = args[0].toLowerAscii
  if name notin SKILL_NAMES:
    return err(&"Unknown skill '{name}'.  Skills: {SKILL_NAMES.join(\", \")}")
  skills.trainSkill(state, name, SKILL_BUMP)
  ok(&"  {name.replace(\"_\", \" \").capitalizeAscii} -> {skillVal(state, name)}")


# ── dbgrantperk ───────────────────────────────────────────────────────────────

proc cmdDbGrantPerk(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: dbgrantperk <perk_id> [duration=-1]")
  let perkId   = args[0]
  let duration = if args.len > 1: args[1] else: "-1"
  let lines    = api.runCommand(state, &"add_effect player {perkId} {duration}", "player")
  ok(@[&"  Perk granted (no pick spent): {perkId}"] & lines)


# ── dbseed ────────────────────────────────────────────────────────────────────

proc cmdDbSeed(state: var GameState; args: seq[string]): CmdResult =
  if args.len > 0:
    var seed: int
    try: seed = parseInt(args[0])
    except ValueError: return err("Seed must be an integer.")
    state.variables["world_seed"] = %seed
    saves.flushVariables(state)
    return ok(&"World seed set to {seed}.")
  let seed = state.variables.getOrDefault("world_seed", newJNull())
  let display = if seed.kind == JInt: $seed.getInt else: "(not set)"
  ok(&"World seed: {display}")


# ── dblua (existing) ─────────────────────────────────────────────────────────

proc cmdDbLua(state: var GameState; args: seq[string]): CmdResult =
  if args.len == 0:
    return err("Usage: dblua <script.lua>")
  let lines = api.runCommand(state, args[0], "player")
  if lines.len == 0:
    return ok(&"[dblua] {args[0]} ran (no output)")
  ok(@[&"[dblua] {args[0]}"] & lines)


# ── registration ──────────────────────────────────────────────────────────────

proc initCmdDebug*() =
  registerAny("dbwhere",     cmdDbWhere,     hidden = true)
  registerAny("dbtile",      cmdDbTile,      hidden = true)
  registerAny("dbstate",     cmdDbState,     hidden = true)
  registerAny("dbvars",      cmdDbVars,      hidden = true)
  registerAny("dbdirty",     cmdDbDirty,     hidden = true)
  registerAny("dbteleport",  cmdDbTeleport,  hidden = true)
  registerAny("dbtp",        cmdDbTeleport,  hidden = true)
  registerAny("dblearnspell",cmdDbLearnSpell,hidden = true)
  registerAny("dbgive",      cmdDbGive,      hidden = true)
  registerAny("dbtake",      cmdDbTake,      hidden = true)
  registerAny("dbkill",      cmdDbKill,      hidden = true)
  registerAny("dbsave",      cmdDbSave,      hidden = true)
  registerAny("dbgivexp",    cmdDbGiveXp,    hidden = true)
  registerAny("dblevelup",   cmdDbLevelUp,   hidden = true)
  registerAny("dbgrantperk", cmdDbGrantPerk, hidden = true)
  registerAny("dbseed",      cmdDbSeed,      hidden = true)
  registerAny("dblua",       cmdDbLua,       hidden = true)
