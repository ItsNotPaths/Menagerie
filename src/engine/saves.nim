## engine/saves.nim
## ────────────────
## Save/load system. working/ is a transient staging directory — written during
## play (write-through) and zipped on save. Cleared silently on launch.
##
## Slot types
## ──────────
##   auto_1..5  — 5 rotating autosave slots, oldest overwritten on each autosave
##   <name>     — unlimited named manual saves, player-chosen string
##
## File layout
## ───────────
##   saves/
##       working/
##           player.json
##           variables.json
##           npc_states.json
##           dirty/
##               <x>_<y>.json
##       auto_1.sav
##       my_run.sav
##
## Dirty data flow
## ───────────────
##   On load:   state.dirty starts empty — files stay on disk until visited
##   On visit:  loadDirtyTile(state, key) pulls the file into state.dirty[key]
##              if no file exists, world.initLocatedDirty creates one
##   On change: flushDirty(state, key) writes state.dirty[key] back immediately
##   On save:   flushToWorking writes all in-memory dirty entries; zip picks up everything

import std/[json, os, strutils, times, algorithm, tables, random]
import zippy/ziparchives
import zippy/ziparchives_v1
import state
import content
import skills
import gameplay_vars


const
  savesDir*   = "saves"
  workingDir* = savesDir / "working"
  dirtyDir*   = workingDir / "dirty"
  autoSlots   = 5


# ── Path helpers ──────────────────────────────────────────────────────────────

proc savPath(name: string): string = savesDir / name & ".sav"
proc autoName(n: int): string      = "auto_" & $n


# ── JSON helpers ──────────────────────────────────────────────────────────────

proc writeJson(path: string; data: JsonNode) =
  createDir(parentDir(path))
  writeFile(path, data.pretty(2))


# ── Table[string, JsonNode] helpers ──────────────────────────────────────────

proc tableToJson(t: Table[string, JsonNode]): JsonNode =
  result = newJObject()
  for k, v in t:
    result[k] = v

proc jsonToTable(j: JsonNode): Table[string, JsonNode] =
  if j == nil or j.kind != JObject: return
  for k, v in j:
    result[k] = v


# ── PlayerState serialization ─────────────────────────────────────────────────

proc playerToJson(p: PlayerState): JsonNode =
  result = newJObject()
  result["position"]          = %[p.position[0], p.position[1]]
  result["currentRoom"]       = %p.currentRoom
  result["lastRestPosition"]  = %[p.lastRestPosition[0], p.lastRestPosition[1]]
  result["lastRestRoom"]      = %p.lastRestRoom
  result["tick"]              = %p.tick
  result["gold"]              = %p.gold
  result["health"]            = %p.health
  result["stamina"]           = %p.stamina
  result["focus"]             = %p.focus
  result["hunger"]            = %p.hunger
  result["fatigue"]           = %p.fatigue
  result["mainhand"]          = %p.mainhand
  result["offhand"]           = %p.offhand
  result["level"]             = %p.level
  result["xp"]                = %p.xp
  result["maxHealth"]         = %p.maxHealth
  result["maxStamina"]        = %p.maxStamina
  result["maxFocus"]          = %p.maxFocus
  result["pendingSkillPicks"] = %p.pendingSkillPicks
  result["pendingStatPicks"]  = %p.pendingStatPicks
  result["pendingPerkPicks"]  = %p.pendingPerkPicks

  let invArr = newJArray()
  for e in p.inventory:
    invArr.add %*{"id": e.id, "slots": e.slots, "count": e.count}
  result["inventory"] = invArr

  let armorObj = newJObject()
  for zone, plate in p.armor:
    armorObj[zone] = %plate
  result["armor"] = armorObj

  result["containers"]     = %p.containers
  result["favourites"]     = %p.favourites
  result["itemFavourites"] = %p.itemFavourites
  result["spellbook"]      = %p.spellbook
  result["journal"]        = %p.journal

  let effectsArr = newJArray()
  for e in p.effects:
    effectsArr.add %*{"id": e.id, "ticksRemaining": e.ticksRemaining}
  result["effects"] = effectsArr

  let cdObj = newJObject()
  for spell, ticks in p.spellCooldowns:
    cdObj[spell] = %ticks
  result["spellCooldowns"] = cdObj

  let skillsObj = newJObject()
  for name, val in p.skills:
    skillsObj[name] = %val
  result["skills"] = skillsObj


proc playerFromJson(j: JsonNode): PlayerState =
  result = initPlayerState()

  if "position" in j:
    result.position = (j["position"][0].getInt, j["position"][1].getInt)
  if "currentRoom" in j:
    result.currentRoom = j["currentRoom"].getStr
  if "lastRestPosition" in j:
    result.lastRestPosition = (j["lastRestPosition"][0].getInt, j["lastRestPosition"][1].getInt)
  if "lastRestRoom" in j:
    result.lastRestRoom = j["lastRestRoom"].getStr
  if "tick" in j:
    result.tick = j["tick"].getInt
  if "gold" in j:
    result.gold = j["gold"].getInt
  if "health" in j:
    result.health = j["health"].getFloat
  if "stamina" in j:
    result.stamina = j["stamina"].getFloat
  if "focus" in j:
    result.focus = j["focus"].getFloat
  if "hunger" in j:
    result.hunger = j["hunger"].getFloat
  if "fatigue" in j:
    result.fatigue = j["fatigue"].getFloat
  if "mainhand" in j:
    result.mainhand = j["mainhand"].getStr
  if "offhand" in j:
    result.offhand = j["offhand"].getStr
  if "level" in j:
    result.level = j["level"].getInt
  if "xp" in j:
    result.xp = j["xp"].getFloat
  if "maxHealth" in j:
    result.maxHealth = j["maxHealth"].getFloat
  if "maxStamina" in j:
    result.maxStamina = j["maxStamina"].getFloat
  if "maxFocus" in j:
    result.maxFocus = j["maxFocus"].getFloat
  if "pendingSkillPicks" in j:
    result.pendingSkillPicks = j["pendingSkillPicks"].getInt
  if "pendingStatPicks" in j:
    result.pendingStatPicks = j["pendingStatPicks"].getInt
  if "pendingPerkPicks" in j:
    result.pendingPerkPicks = j["pendingPerkPicks"].getInt

  if "inventory" in j:
    for e in j["inventory"]:
      result.inventory.add InventoryEntry(
        id:    e["id"].getStr,
        slots: e["slots"].getInt,
        count: e["count"].getInt,
      )

  if "armor" in j:
    for zone, plate in j["armor"]:
      result.armor[zone] = plate.getStr

  if "containers" in j:
    for v in j["containers"]:     result.containers.add v.getStr
  if "favourites" in j:
    for v in j["favourites"]:     result.favourites.add v.getStr
  if "itemFavourites" in j:
    for v in j["itemFavourites"]: result.itemFavourites.add v.getStr
  if "spellbook" in j:
    for v in j["spellbook"]:      result.spellbook.add v.getStr
  if "journal" in j:
    for v in j["journal"]:        result.journal.add v.getStr

  if "effects" in j:
    for e in j["effects"]:
      result.effects.add ActiveEffect(
        id:             e["id"].getStr,
        ticksRemaining: e["ticksRemaining"].getInt,
      )

  if "spellCooldowns" in j:
    for spell, ticks in j["spellCooldowns"]:
      result.spellCooldowns[spell] = ticks.getInt

  if "skills" in j:
    for name, val in j["skills"]:
      result.skills[name] = val.getInt


# ── Working directory I/O ─────────────────────────────────────────────────────

proc flushToWorking*(state: GameState) =
  ## Write all working-directory files from current state.
  createDir(workingDir)
  createDir(dirtyDir)
  writeJson(workingDir / "player.json",     playerToJson(state.player))
  writeJson(workingDir / "variables.json",  tableToJson(state.variables))
  writeJson(workingDir / "npc_states.json", tableToJson(state.npcStates))
  for key, data in state.dirty:
    writeJson(dirtyDir / key & ".json", data)


proc loadFromWorking(): GameState =
  ## Read working/ into a fresh GameState. dirty starts empty — tile files
  ## are loaded lazily on first visit via loadDirtyTile.
  result = initGameState()
  let pj = try: parseFile(workingDir / "player.json")
           except CatchableError as e:
             echo "saves.loadFromWorking: cannot read player.json — " & e.msg
             raise
  result.player = playerFromJson(pj)

  let vPath = workingDir / "variables.json"
  if fileExists(vPath):
    try:
      result.variables = jsonToTable(parseFile(vPath))
    except CatchableError as e:
      echo "saves.loadFromWorking: malformed variables.json — " & e.msg

  let nPath = workingDir / "npc_states.json"
  if fileExists(nPath):
    try:
      result.npcStates = jsonToTable(parseFile(nPath))
    except CatchableError as e:
      echo "saves.loadFromWorking: malformed npc_states.json — " & e.msg

  result.context = ctxWorld


# ── Granular flush helpers ────────────────────────────────────────────────────

proc flushPlayer*(state: GameState) =
  ## Write player.json immediately. Call after death-respawn, sleep, etc.
  createDir(workingDir)
  writeJson(workingDir / "player.json", playerToJson(state.player))


proc flushVariables*(state: GameState) =
  ## Write variables.json immediately. Call after bounty / spawn counter writes.
  createDir(workingDir)
  writeJson(workingDir / "variables.json", tableToJson(state.variables))


proc flushNpcStates*(state: GameState) =
  ## Write npc_states.json immediately. Call on any NPC/instance state change.
  createDir(workingDir)
  writeJson(workingDir / "npc_states.json", tableToJson(state.npcStates))


proc flushDirty*(state: GameState; key: string) =
  ## Write a single dirty-tile entry immediately. Call on any tile mutation.
  createDir(dirtyDir)
  writeJson(dirtyDir / key & ".json", state.dirty[key])


# ── Lazy dirty-tile load ──────────────────────────────────────────────────────

proc loadDirtyTile*(state: var GameState; key: string): bool =
  ## Pull dirty/<key>.json into state.dirty if it exists on disk.
  ## Returns true if a file was found and loaded.
  ## Called by world.enterLocation on first visit to a tile key not yet in memory.
  let path = dirtyDir / key & ".json"
  if fileExists(path):
    try:
      state.dirty[key] = parseFile(path)
      return true
    except CatchableError as e:
      echo "saves.loadDirtyTile: malformed " & path & " — " & e.msg
  return false


# ── ZIP helpers ───────────────────────────────────────────────────────────────

proc zipWorking(dest: string) =
  ## Create a ZIP of workingDir with paths relative to workingDir (no "working/" prefix).
  createDir(parentDir(dest))
  let archive = ZipArchive()
  for path in walkDirRec(workingDir):
    let rel = relativePath(path, workingDir).replace('\\', '/')
    archive.contents[rel] = ArchiveEntry(kind: ekFile, contents: readFile(path))
  archive.writeZipArchive(dest)


proc unzipToWorking(src: string) =
  ## Extract ZIP to workingDir. extractAll requires dest not to exist.
  if dirExists(workingDir): removeDir(workingDir)
  createDir(savesDir)   # parent of working/ must exist for extractAll
  extractAll(src, workingDir)


# ── Working-dir management ────────────────────────────────────────────────────

proc clearWorking() =
  if dirExists(workingDir): removeDir(workingDir)
  createDir(workingDir)
  createDir(dirtyDir)


proc workingHasContent*(): bool =
  fileExists(workingDir / "player.json")


# ── Auto-slot rotation ────────────────────────────────────────────────────────

proc nextAutoSlot(): string =
  for n in 1..autoSlots:
    let p = savPath(autoName(n))
    if not fileExists(p): return autoName(n)
  # All slots full — overwrite oldest
  var slots: seq[(float, int)]
  for n in 1..autoSlots:
    slots.add (getLastModificationTime(savPath(autoName(n))).toUnixFloat, n)
  slots.sort()
  autoName(slots[0][1])


# ── Name sanitizer ────────────────────────────────────────────────────────────

proc sanitizeName(name: string): string =
  for c in name:
    if c.isAlphaNumeric or c in {'-', '_', ' '}:
      result.add c
  result = result.strip().replace(' ', '_')
  if result == "": result = "manual"


# ── NPC state seeding ─────────────────────────────────────────────────────────

proc buildNpcStates(): Table[string, JsonNode] =
  ## Scan content NPCs and create initial npc_states from starting_tile fields.
  for id, npc in content.npcs:
    if npc.startingTile != "":
      result[id] = %*{"tile": npc.startingTile, "alive": true}


proc catchupNpcStates*(state: var GameState): bool =
  ## Add any named NPCs missing from npcStates (e.g. new content after save).
  ## Returns true if anything was added — caller should flushNpcStates.
  for id, npc in content.npcs:
    if npc.startingTile != "" and id notin state.npcStates:
      state.npcStates[id] = %*{"tile": npc.startingTile, "alive": true}
      result = true


# ── Public API ────────────────────────────────────────────────────────────────

proc clearWorkingOnLaunch*() =
  ## Clear the working directory at startup. Any leftover content is discarded,
  ## not zipped. Called once before the menu is shown.
  clearWorking()


proc newGame*(state: var GameState) =
  ## Initialise state for a fresh playthrough. Generates world seed, sets
  ## stat defaults from gameplay_vars, writes working directory.
  clearWorking()
  state.player            = initPlayerState()
  state.player.health     = gvFloat("player_health",      100.0)
  state.player.maxHealth  = gvFloat("player_health_max",  100.0)
  state.player.stamina    = gvFloat("player_stamina",     100.0)
  state.player.maxStamina = gvFloat("player_stamina_max", 100.0)
  state.player.focus      = gvFloat("player_focus",        50.0)
  state.player.maxFocus   = gvFloat("player_focus_max",    50.0)
  state.player.gold       = gvInt("new_game_gold",          50)
  state.player.hunger     = gvFloat("new_game_hunger",     100.0)
  for name in skills.SKILL_NAMES:
    state.player.skills[name] = 0
  state.variables  = {"world_seed": %rand(2147483647), "_npc_spawn_counter": %0}.toTable
  state.dirty      = initTable[string, JsonNode]()
  state.npcStates  = buildNpcStates()
  state.context    = ctxWorld
  flushToWorking(state)


proc saveGame*(state: GameState; name: string = ""): string =
  ## Flush state to working/ and zip to a .sav file.
  ##   name=""    → rotating auto slot
  ##   name=<str> → named manual slot (string is sanitised)
  ## Returns the slot name used.
  flushToWorking(state)
  createDir(savesDir)
  let slot = if name == "": nextAutoSlot() else: sanitizeName(name)
  zipWorking(savPath(slot))
  result = slot


proc loadGame*(name: string; state: var GameState) =
  ## Unpack saves/<name>.sav into working/ and populate state in-place.
  ## Raises IOError if the save doesn't exist.
  let path = savPath(name)
  if not fileExists(path):
    raise newException(IOError, "Save not found: " & name)
  unzipToWorking(path)
  let loaded      = loadFromWorking()
  state.player    = loaded.player
  state.variables = loaded.variables
  state.dirty     = loaded.dirty
  state.npcStates = loaded.npcStates
  state.context   = ctxWorld
  if catchupNpcStates(state):
    flushNpcStates(state)


proc autosave*(state: GameState) =
  ## Write a rotating auto-slot save.
  discard saveGame(state)


proc mostRecentSave*(): string =
  ## Return the name of the most recently written non-recovery .sav, or "".
  createDir(savesDir)
  var best = ("", 0.0)
  for f in walkFiles(savesDir / "*.sav"):
    let stem = splitFile(f).name
    if not stem.startsWith("recovery_"):
      let t = getLastModificationTime(f).toUnixFloat
      if t > best[1]: best = (stem, t)
  result = best[0]


proc listSaves*(): tuple[auto, manual: seq[tuple[name, display: string; modified: float]]] =
  ## Return auto and manual save lists, newest-first within each group.
  createDir(savesDir)
  let autoNames = block:
    var s: seq[string]
    for n in 1..autoSlots: s.add autoName(n)
    s
  var all: seq[tuple[name, display: string; modified: float]]
  for f in walkFiles(savesDir / "*.sav"):
    let stem = splitFile(f).name
    all.add (stem, stem.replace('_', ' '), getLastModificationTime(f).toUnixFloat)
  all.sort(proc(a, b: auto): int = cmp(b.modified, a.modified))
  for e in all:
    if e.name in autoNames: result.auto.add e
    else:                    result.manual.add e
