## engine/world.nim
## ─────────────────
## Tile generation, location loading, room descriptions, occupant queue.
##
## get_tile(state, x, y) checks world_def first for hand-placed tiles,
## then falls back to deterministic procedural wilderness generation.
##
## On first entry to a located tile (ruin/town/dungeon), a dirty entry is
## created in-memory and enemies are spawned into npc_states.

import std/[json, options, random, sequtils, strformat, strutils, tables]
import engine/state
import engine/content
import engine/clock
import engine/saves

# ── Terrain constants ─────────────────────────────────────────────────────────

const surveyRange* = 5

let terrainTicks = {
  "forest": 8, "plains": 4, "mountain": 16, "swamp": 12, "desert": 8,
  "road":   4, "ruin":   8, "dungeon":  8,  "town":  4,
}.toTable

let tileDefaultImages = {
  "town":      "town.png",      "dungeon":    "dungeon.png",
  "road":      "road.png",      "crossroads": "crossroad.png",
  "ruin":      "ruin.png",
  "forest":    "wilderness.png", "plains":   "wilderness.png",
  "mountain":  "wilderness.png", "swamp":    "wilderness.png",
  "desert":    "wilderness.png",
}.toTable

let descriptors = {
  "forest": @[
    "Thick canopy blocks most of the sky.",
    "Gnarled roots push up through the earth.",
    "Dense pines spiral overhead.",
    "Fallen timber crosses the path.",
    "Birdsong echoes from somewhere above.",
    "Undergrowth thickens here, slowing progress.",
    "Light filters through the canopy in thin beams.",
  ],
  "plains": @[
    "Tall grass sways in the wind.",
    "The horizon stretches flat and pale.",
    "Dry earth cracks underfoot.",
    "A crow circles in the distance.",
    "The wind carries dust and nothing else.",
    "An old stone marker leans at the roadside.",
    "The sky here feels very large.",
  ],
  "mountain": @[
    "Loose shale slides underfoot.",
    "The air is thin and cold.",
    "Jagged rock faces the rising sun.",
    "A narrow ledge winds upward.",
    "Distant peaks vanish into cloud.",
    "Wind cuts hard between the crags.",
    "Snow lingers in the shadowed hollows.",
  ],
  "swamp": @[
    "Standing water reflects a grey sky.",
    "The ground gives slightly with each step.",
    "Reeds cluster at the water's edge.",
    "Something stirs beneath the surface.",
    "Rotting wood juts from the mire.",
    "The air smells of peat and still water.",
    "Insects hang in clouds above the water.",
  ],
  "desert": @[
    "The sun beats down without mercy.",
    "Sand shifts across the cracked ground.",
    "Heat haze blurs the distance.",
    "Bleached bones mark an old trail.",
    "The silence here is absolute.",
    "A dry riverbed cuts through the flats.",
    "The ground radiates heat long after sundown.",
  ],
  "road": @[
    "The road stretches on ahead.",
    "Worn ruts mark the passage of countless carts.",
    "The packed earth holds firm underfoot.",
    "A stone marker at the roadside is too weathered to read.",
    "The road bends gently here.",
    "Wheel ruts cut deep into the road's surface.",
    "The road is quiet. Nothing stirs.",
  ],
}.toTable

const roadTileTypes = ["road", "crossroads", "town", "dungeon", "ruin"]
const stopTileTypes = ["town", "dungeon", "crossroads"]


# ── TileInfo ──────────────────────────────────────────────────────────────────
## Runtime description of a single map tile.

type
  TileInfo* = object
    tileType*:    string   ## "forest" | "plains" | "road" | "town" | "dungeon" | "ruin" | …
    name*:        string   ## named location name (empty for wilderness)
    tileDef*:     string   ## tile preset id (links to content/tiles/<id>.json)
    description*: string   ## custom description override
    image*:       string   ## custom image filename override


# ── World-def lookup ──────────────────────────────────────────────────────────

var worldDefIndex: Table[string, WorldTile]


proc buildWorldDefIndex*() =
  ## Build lookup table from content.worldDef. Call once after loadContent().
  worldDefIndex.clear()
  for t in content.worldDef.tiles:
    if not t.deleted:
      worldDefIndex[&"{t.x}_{t.y}"] = t


proc getWorldDefTile*(x, y: int): Option[WorldTile] =
  let key = &"{x}_{y}"
  if key in worldDefIndex: some(worldDefIndex[key])
  else: none(WorldTile)


# ── Deterministic tile RNG ────────────────────────────────────────────────────

proc tileRng(x, y, worldSeed: int): Rand =
  let seed = ((x * 73856093) xor (y * 19349663) xor worldSeed) and 0x7FFFFFFF
  initRand(seed)


proc weightedChoice(rng: var Rand; items: openArray[string]; weights: openArray[int]): string =
  var total = 0
  for w in weights: inc total, w
  var roll = rng.rand(total - 1)
  for i, w in weights:
    if roll < w: return items[i]
    roll -= w
  items[^1]


proc generateTile*(x, y, worldSeed: int): TileInfo =
  ## Deterministically generate wilderness terrain for (x, y).
  const types   = ["forest", "plains", "mountain", "swamp", "desert"]
  const weights = [40, 25, 15, 12, 8]
  var rng = tileRng(x, y, worldSeed)
  TileInfo(tileType: weightedChoice(rng, types, weights))


# ── Tile access ───────────────────────────────────────────────────────────────

proc getTile*(state: GameState; x, y: int): TileInfo =
  ## Return tile info for (x, y). Checks world_def first, then generates.
  let wd = getWorldDefTile(x, y)
  if wd.isSome:
    let t = wd.get
    return TileInfo(
      tileType:    t.tileType,
      name:        t.name,
      tileDef:     t.tile,
      description: t.description,
      image:       t.image,
    )
  let worldSeed = state.variables.getOrDefault("world_seed", newJInt(0)).getInt
  generateTile(x, y, worldSeed)


proc movementTicks*(state: GameState; x, y: int): int =
  ## Tick cost to move onto tile (x, y).
  terrainTicks.getOrDefault(getTile(state, x, y).tileType, 8)


# ── Asset resolution ──────────────────────────────────────────────────────────

proc resolveAsset(category, filename: string): string =
  case category
  of "rooms":   content.assetIndex.rooms.getOrDefault(filename, "")
  of "tiles":   content.assetIndex.tiles.getOrDefault(filename, "")
  of "sprites": content.assetIndex.sprites.getOrDefault(filename, "")
  else: ""


proc tileImagePath*(state: GameState; x, y: int): string =
  ## Return image path for a world tile. "" if none found.
  let tile = getTile(state, x, y)
  if tile.image != "":
    return resolveAsset("tiles", tile.image)
  let filename = tileDefaultImages.getOrDefault(tile.tileType, "")
  if filename == "": return ""
  resolveAsset("tiles", filename)


proc roomImagePath*(state: GameState): string =
  ## Return image path for the player's current room. "" if none.
  let roomId = state.player.currentRoom
  if roomId == "": return ""
  let room = content.getRoom(roomId)
  if room.image == "": return ""
  resolveAsset("rooms", room.image)


# ── Category helpers ──────────────────────────────────────────────────────────

proc categoryForType(tileType: string): string =
  case tileType
  of "ruin":      "ruins"
  of "dungeon":   "dungeons"
  of "town":      "towns"
  of "encounter": "encounters"
  else: "ruins"


proc currentCategory(state: GameState): string =
  ## Room category for wherever the player currently is.
  if state.variables.getOrDefault("_in_encounter", newJBool(false)).getBool:
    return "encounters"
  let (x, y) = state.player.position
  let tile = getTile(state, x, y)
  categoryForType(tile.tileType)


# ── NPC schedule resolution ───────────────────────────────────────────────────

proc getNpcRoom(npc: JsonNode; tileId: string; currentTick: int; defaultRoom: string): string =
  ## Return the room ID the NPC should be in at currentTick (schedule-resolved).
  let dayT = currentTick mod ticksPerDay
  let schedule = npc{"schedule"}
  if schedule == nil or schedule.kind != JObject: return defaultRoom
  let tileSchedule = schedule{tileId}
  if tileSchedule == nil or tileSchedule.kind != JArray or tileSchedule.len == 0:
    return defaultRoom
  # Find the highest-tick entry that does not exceed dayT
  var bestTick = -1
  var bestRoom = defaultRoom
  var wrapTick = -1
  var wrapRoom = defaultRoom
  for entry in tileSchedule:
    let t = entry{"tick"}.getInt(-1)
    let r = entry{"room"}.getStr
    if t > wrapTick:
      wrapTick = t
      wrapRoom = r
    if t <= dayT and t > bestTick:
      bestTick = t
      bestRoom = r
  if bestTick < 0: wrapRoom else: bestRoom


# ── NPC / occupant resolution ─────────────────────────────────────────────────

type OccupantInfo = tuple[id: string; label: string; hostile: bool]

proc getNpcsInRoom*(state: GameState): seq[OccupantInfo] =
  ## Return (id, label, isHostile) for every entity in the player's current room.
  if state.npcStates.len == 0: return
  let (x, y) = state.player.position
  let key = &"{x}_{y}"
  let roomId = state.player.currentRoom
  if roomId == "": return

  let inEncounter = state.variables.getOrDefault("_in_encounter", newJBool(false)).getBool
  let spawnedKey = if inEncounter: "@encounter" else: key

  # Determine tile_id for named NPC schedule resolution
  let dirty = state.dirty.getOrDefault(key, newJNull())
  let tileId = if dirty.kind == JObject: dirty{"tile"}.getStr else: ""

  var entryRoom = roomId
  if tileId != "":
    let td = content.getTileDef(tileId)
    if td.id != "": entryRoom = td.entryRoom

  for npcId, loc in state.npcStates:
    if loc.kind != JObject: continue
    if not loc{"alive"}.getBool(true): continue

    if loc.hasKey("spawned_from"):
      # Spawned instance: tile_key + explicit room must match
      if loc{"tile"}.getStr != spawnedKey: continue
      if loc{"room"}.getStr != roomId: continue
      let baseId = loc{"spawned_from"}.getStr
      let npc = content.getNpc(baseId)
      let label = if npc.id != "": npc.displayName else: baseId
      result.add (npcId, label, true)
    else:
      # Named NPC: tile matches by tile name, room resolved from schedule
      if loc{"tile"}.getStr != tileId or tileId == "": continue
      let npc = content.getNpc(npcId)
      if npc.id == "": continue
      let scheduledRoom = getNpcRoom(npc.raw, tileId, state.player.tick, entryRoom)
      if scheduledRoom != roomId: continue
      let label = npc.displayName
      let hasBounty = state.variables.getOrDefault(&"bounty_{npc.faction}", newJInt(0)).getInt > 0
      let hostile = npc.isHostile or hasBounty or loc{"hostile"}.getBool(false)
      result.add (npcId, label, hostile)


proc populateRoomQueue*(state: var GameState) =
  ## Rebuild state.roomQueue from occupants in the current room.
  state.roomQueue = @[]
  for (npcId, label, hostile) in getNpcsInRoom(state):
    let kind = if hostile: rokEnemy else: rokNpc
    state.roomQueue.add RoomOccupant(id: npcId, label: label, kind: kind)


# ── Combat spawn helpers ──────────────────────────────────────────────────────

proc rollStartPosition*(npcRaw: JsonNode): (int, int) =
  ## Roll an initial combat grid position from an NPC template's hint fields.
  ## Template fields (all optional, read from npc.raw):
  ##   starting_row / starting_distance  — fixed values, override range
  ##   row_range      [min, max]         — random in range (default [1, 9])
  ##   distance_range [min, max]         — random in range (default [3, 7])
  let row =
    if npcRaw != nil and npcRaw{"starting_row"} != nil:
      npcRaw{"starting_row"}.getInt(5)
    else:
      let rng = if npcRaw != nil: npcRaw{"row_range"} else: nil
      let lo = if rng != nil and rng.kind == JArray and rng.len >= 1: rng[0].getInt(1) else: 1
      let hi = if rng != nil and rng.kind == JArray and rng.len >= 2: rng[1].getInt(9) else: 9
      rand(lo..hi)
  let dist =
    if npcRaw != nil and npcRaw{"starting_distance"} != nil:
      npcRaw{"starting_distance"}.getInt(5)
    else:
      let rng = if npcRaw != nil: npcRaw{"distance_range"} else: nil
      let lo = if rng != nil and rng.kind == JArray and rng.len >= 1: rng[0].getInt(3) else: 3
      let hi = if rng != nil and rng.kind == JArray and rng.len >= 2: rng[1].getInt(7) else: 7
      rand(lo..hi)
  (max(1, min(9, row)), max(1, min(9, dist)))


# ── Dirty tile initialisation ─────────────────────────────────────────────────

proc spawnTileEnemies(state: var GameState; tileKey: string; tileDef: TileDef; tileType: string) =
  ## Spawn persistent npc_states entries for every enemy listed in tile's rooms.
  let cat = categoryForType(tileType)
  for roomId in tileDef.rooms:
    let room = content.getRoom(roomId)
    if room.id == "": continue
    let enemies = room.raw{"enemies"}
    if enemies == nil or enemies.kind != JArray: continue
    for enemyType in enemies:
      let eId = enemyType.getStr
      if eId == "": continue
      let counter = state.variables.getOrDefault("_npc_spawn_counter", newJInt(0)).getInt + 1
      state.variables["_npc_spawn_counter"] = %counter
      saves.flushVariables(state)
      let instanceId = &"{eId}_{counter}"
      let npc = content.getNpc(eId)
      let baseHealth = if npc.id != "": npc.health else: 20.0
      let (row, dist) = rollStartPosition(if npc.id != "": npc.raw else: nil)
      state.npcStates[instanceId] = %*{
        "tile":         tileKey,
        "room":         roomId,
        "alive":        true,
        "health":       baseHealth,
        "spawned_from": eId,
        "row":          row,
        "distance":     dist,
      }


proc initLocatedDirty*(state: var GameState; key: string; tile: TileInfo) =
  ## Create initial dirty entry for a located tile on first visit.
  state.dirty[key] = %*{"tile": tile.tileDef, "items": []}
  if tile.tileDef != "":
    let td = content.getTileDef(tile.tileDef)
    if td.id != "":
      spawnTileEnemies(state, key, td, tile.tileType)


# ── Room connections ──────────────────────────────────────────────────────────

proc getRoomConnections*(state: GameState): seq[string] =
  ## Return room IDs connected to the player's current room.
  let (x, y) = state.player.position
  let key = &"{x}_{y}"
  let dirty = state.dirty.getOrDefault(key, newJNull())
  let tileName = if dirty.kind == JObject: dirty{"tile"}.getStr else: ""
  let roomId = state.player.currentRoom
  if tileName == "" or roomId == "": return @[]
  let td = content.getTileDef(tileName)
  if td.id == "": return @[]
  let conns = td.raw{"connections"}
  if conns == nil or conns.kind != JObject: return @[]
  let roomConns = conns{roomId}
  if roomConns == nil or roomConns.kind != JArray: return @[]
  for r in roomConns: result.add r.getStr


proc roomAllowsWait*(state: GameState): bool =
  ## True if no hostile occupants are present in the current room.
  if state.player.currentRoom == "": return true
  not getNpcsInRoom(state).anyIt(it.hostile)


# ── Tile lines ────────────────────────────────────────────────────────────────

proc tileLines*(state: GameState; x, y: int): seq[string] =
  ## Text description lines for a world tile at (x, y).
  let tile = getTile(state, x, y)
  let worldSeed = state.variables.getOrDefault("world_seed", newJInt(0)).getInt

  case tile.tileType
  of "forest", "plains", "mountain", "swamp", "desert":
    let pool = descriptors[tile.tileType]
    var rng  = tileRng(x, y, worldSeed)
    let desc = if tile.description != "": tile.description
               else: pool[rng.rand(pool.len - 1)]
    @[tile.tileType.capitalizeAscii, desc]

  of "ruin":
    let desc = if tile.description != "": tile.description
               else: "The crumbled remains of an old structure stand here."
    @[desc, "[[enter]]"]

  of "town", "dungeon":
    let name = if tile.name != "": tile.name.capitalizeAscii else: tile.tileType.capitalizeAscii
    var lines = @[name]
    if tile.description != "": lines.add tile.description
    lines.add "[[enter]]"
    lines

  of "road":
    let pool = descriptors["road"]
    var rng  = tileRng(x, y, worldSeed)
    let desc = pool[rng.rand(pool.len - 1)]
    @["Road", desc]

  of "crossroads":
    let name = if tile.name != "": tile.name.replace("-", " ") else: "A crossroads"
    var lines = @[name]
    if tile.description != "": lines.add tile.description
    lines.add "[[enter]]"
    lines

  else:
    @[&"Featureless ground. ({x}, {y})"]


# ── Room lines ────────────────────────────────────────────────────────────────

proc roomLines*(state: GameState): seq[string] =
  ## Description lines for the player's current room inside a location.
  let (x, y) = state.player.position
  let roomId = state.player.currentRoom
  if roomId == "": return @["(No location data.)"]

  let room = content.getRoom(roomId)
  if room.id == "":
    return @[&"(Room '{roomId}' not found.)"]

  result = @[room.name, "-".repeat(40), room.description]

  let occupants = getNpcsInRoom(state)
  let friendly  = occupants.filterIt(not it.hostile)
  let enemies   = occupants.filterIt(it.hostile)

  if friendly.len > 0:
    result.add ""
    for (npcId, label, _) in friendly:
      result.add &"[[{label}:talk {npcId}]]"

  if enemies.len > 0:
    result.add ""
    for (npcId, label, _) in enemies:
      let loc  = state.npcStates.getOrDefault(npcId, newJNull())
      let row  = if loc.kind == JObject: loc{"row"}.getInt(-1)      else: -1
      let dist = if loc.kind == JObject: loc{"distance"}.getInt(-1) else: -1
      let posStr = if row >= 0 and dist >= 0: &"  row {row}  dist {dist}" else: ""
      result.add &"  {label}{posStr}"

  if state.sneaking:
    if state.roomQueue.len > 0:
      let target = state.roomQueue[0]
      result.add ""
      result.add &"[ Sneaking — Target: {target.label} ]"
      result.add ""
      result.add "  [[move:sneak move]]  [[pickpocket]]  [[stealth attack:stealth_attack]]"
    else:
      result.add ""
      result.add "[ Sneaking — no targets ]"
      result.add ""
    result.add "  [[leave sneak:sneak]]"
  else:
    result.add ""
    if enemies.len > 0:
      result.add "  [[start:attack]]"
    elif friendly.len == 0:
      result.add "The area is clear."
    if friendly.len > 0:
      result.add "  [[sneak]]"

  if room.raw{"type"}.getStr == "rest":
    result.add ""
    result.add "  [[sleep]]"


proc currentLines*(state: GameState): seq[string] =
  ## All description lines for wherever the player currently is.
  if state.context == ctxWorld:
    let (x, y) = state.player.position
    return tileLines(state, x, y)
  roomLines(state)


# ── Location entry / exit ─────────────────────────────────────────────────────

proc enterLocation*(state: var GameState): seq[string] =
  ## Enter a locatable tile at the player's current position.
  let (x, y) = state.player.position
  let tile = getTile(state, x, y)

  if tile.tileType notin ["ruin", "dungeon", "town"]:
    return @["There is nothing here to enter."]

  let key = &"{x}_{y}"

  # Lazy-load from disk on first visit; init fresh if no saved state exists
  if key notin state.dirty:
    if not saves.loadDirtyTile(state, key):
      initLocatedDirty(state, key, tile)

  let dirty = state.dirty.getOrDefault(key, newJNull())
  let tileName = if dirty.kind == JObject: dirty{"tile"}.getStr else: ""
  if tileName == "":
    return @["(Tile preset not set — world_def 'tile' field missing.)"]

  let td = content.getTileDef(tileName)
  if td.id == "":
    return @[&"(Tile preset '{tileName}' not found.)"]

  state.player.currentRoom = td.entryRoom
  state.context = if tile.tileType == "town": ctxTown else: ctxDungeon
  populateRoomQueue(state)

  roomLines(state)


proc leaveLocation*(state: var GameState): seq[string] =
  ## Return to the world map from a location.
  state.player.currentRoom = ""
  state.context = ctxWorld
  let (x, y) = state.player.position
  tileLines(state, x, y)


proc leaveEncounterRoom*(state: var GameState): seq[string] =
  ## Discard temporary encounter state and return player to the world map.
  ## Removes all @encounter npc_states entries and clears encounter variables.
  var toRemove: seq[string]
  for k, v in state.npcStates:
    if v.kind == JObject and v{"tile"}.getStr == "@encounter":
      toRemove.add k
  for k in toRemove:
    state.npcStates.del k
  state.variables.del "_in_encounter"
  state.variables.del "_pending_encounter"
  state.player.currentRoom = ""
  state.context = ctxWorld
  let (x, y) = state.player.position
  tileLines(state, x, y)


proc dropEntityLoot*(state: var GameState; entityId: string): seq[string] =
  ## Mark entity dead in npc_states and collect loot item IDs.
  ## Returns seq of item IDs (may contain duplicates for stacks).
  ## Caller formats the summary line; items are appended to tile dirty state.
  ##
  ## Loot priority:
  ##   1. loot_table [{item, amount, chance}] — rolled per entry
  ##   2. inventory  [{item, amount}|string]  — all guaranteed (fallback)
  ##
  ## Saves flush is deferred to Phase 9.
  if entityId in state.npcStates:
    if state.npcStates[entityId].kind == JObject:
      state.npcStates[entityId]["alive"] = %false
      saves.flushNpcStates(state)

  let loc    = state.npcStates.getOrDefault(entityId, newJNull())
  let baseId = if loc.kind == JObject: loc{"spawned_from"}.getStr(entityId) else: entityId
  let npc    = content.getNpc(baseId)
  if npc.id == "": return

  var dropped: seq[string]

  let lootTable = npc.raw{"loot_table"}
  if lootTable != nil and lootTable.kind == JArray and lootTable.len > 0:
    for entry in lootTable:
      if entry{"deleted"}.getBool(false): continue
      let itemId = entry{"item"}.getStr.strip
      let amount = max(1, entry{"amount"}.getInt(1))
      let chance = entry{"chance"}.getInt(100)
      if itemId != "" and rand(1..100) <= chance:
        for _ in 1..amount: dropped.add itemId
  else:
    let inv = npc.raw{"inventory"}
    if inv != nil and inv.kind == JArray:
      for entry in inv:
        case entry.kind
        of JString:
          let itemId = entry.getStr.strip
          if itemId != "": dropped.add itemId
        of JObject:
          let itemId = entry{"item"}.getStr.strip
          let amount = max(1, entry{"amount"}.getInt(1))
          if itemId != "":
            for _ in 1..amount: dropped.add itemId
        else: discard

  if dropped.len > 0:
    let (x, y) = state.player.position
    let key = &"{x}_{y}"
    if key notin state.dirty:
      state.dirty[key] = %*{"items": newJArray()}
    if state.dirty[key]{"items"} == nil or state.dirty[key]{"items"}.kind != JArray:
      state.dirty[key]["items"] = newJArray()
    for iid in dropped:
      state.dirty[key]["items"].add %iid
    saves.flushDirty(state, key)

  dropped


proc moveToRoom*(state: var GameState; roomId: string): seq[string] =
  ## Navigate to a connected room. Returns description or error lines.
  let connections = getRoomConnections(state)
  if roomId notin connections:
    let avail = if connections.len > 0: connections.join(", ") else: "none"
    return @[&"'{roomId}' is not connected here.", &"Connected: {avail}"]
  state.player.currentRoom = roomId
  populateRoomQueue(state)
  roomLines(state)


# ── Peek ──────────────────────────────────────────────────────────────────────

proc peekLines*(state: GameState): seq[string] =
  ## Preview the entry room of the tile at the player's position.
  let (x, y) = state.player.position
  let tile = getTile(state, x, y)
  if tile.tileType notin ["ruin", "dungeon", "town"]:
    return @["Nothing here to peer into."]

  let key = &"{x}_{y}"
  let dirty = state.dirty.getOrDefault(key, newJNull())
  let tileName = if dirty.kind == JObject: dirty{"tile"}.getStr else: ""
  if tileName == "": return @["(Tile preset not configured.)"]

  let td = content.getTileDef(tileName)
  if td.id == "": return @[&"(Tile file '{tileName}' not found.)"]
  if td.entryRoom == "": return @["(No entry room defined.)"]

  let room = content.getRoom(td.entryRoom)
  if room.id == "": return @[&"(Room '{td.entryRoom}' not found.)"]

  result = @["You peer inside.", room.name, "-".repeat(40), room.description]

  var friendlyLines: seq[string]
  var enemyLines:    seq[string]

  for npcId, loc in state.npcStates:
    if loc.kind != JObject: continue
    if not loc{"alive"}.getBool(true): continue
    if loc.hasKey("spawned_from"):
      if loc{"tile"}.getStr != key or loc{"room"}.getStr != td.entryRoom: continue
      let baseId = loc{"spawned_from"}.getStr
      let npc = content.getNpc(baseId)
      let label = if npc.id != "": npc.displayName else: baseId
      enemyLines.add &"  {label}"
    else:
      if loc{"tile"}.getStr != tileName: continue
      let npc = content.getNpc(npcId)
      if npc.id == "": continue
      if getNpcRoom(npc.raw, tileName, state.player.tick, td.entryRoom) != td.entryRoom: continue
      let label = npc.displayName
      if npc.isHostile: enemyLines.add &"  {label}"
      else: friendlyLines.add &"  {label}"

  if friendlyLines.len > 0:
    result.add ""
    result.add friendlyLines
  if enemyLines.len > 0:
    result.add ""
    result.add enemyLines
  if enemyLines.len == 0:
    result.add ""
    result.add "The area looks clear."


proc roomPeekLines*(state: GameState; roomId: string): seq[string] =
  ## Preview a connected room without entering it.
  let (x, y) = state.player.position
  let key = &"{x}_{y}"
  let dirty = state.dirty.getOrDefault(key, newJNull())
  let tileId = if dirty.kind == JObject: dirty{"tile"}.getStr else: ""

  let td = if tileId != "": content.getTileDef(tileId) else: TileDef()
  let entryRoom = if td.id != "": td.entryRoom else: roomId

  let room = content.getRoom(roomId)
  if room.id == "": return @[&"(Room '{roomId}' not found.)"]

  result = @[&"You peer into {room.name}.", "-".repeat(40), room.description]

  var friendly: seq[string]
  var enemies:  seq[string]

  for npcId, loc in state.npcStates:
    if loc.kind != JObject: continue
    if not loc{"alive"}.getBool(true): continue
    if loc.hasKey("spawned_from"):
      if loc{"tile"}.getStr != key or loc{"room"}.getStr != roomId: continue
      let baseId = loc{"spawned_from"}.getStr
      let npc = content.getNpc(baseId)
      let label = if npc.id != "": npc.displayName else: baseId
      enemies.add label
    else:
      if loc{"tile"}.getStr != tileId or tileId == "": continue
      let npc = content.getNpc(npcId)
      if npc.id == "": continue
      if getNpcRoom(npc.raw, tileId, state.player.tick, entryRoom) != roomId: continue
      let label = npc.displayName
      if npc.isHostile: enemies.add label
      else: friendly.add label

  if friendly.len > 0:
    result.add ""
    result.add friendly.mapIt(&"  {it}")
  if enemies.len > 0:
    result.add ""
    result.add enemies.mapIt(&"  {it}")
  if enemies.len == 0:
    result.add ""
    result.add "The area looks clear."


# ── Survey ────────────────────────────────────────────────────────────────────

proc surveyLines*(state: GameState; direction: string): seq[string] =
  ## Text preview of the next surveyRange tiles in direction.
  const dirs = {
    "north": (0,  1), "n": (0,  1),
    "south": (0, -1), "s": (0, -1),
    "east":  (1,  0), "e": (1,  0),
    "west":  (-1, 0), "w": (-1, 0),
  }.toTable
  const longDir = {"n": "north", "s": "south", "e": "east", "w": "west"}.toTable
  let dir = direction.toLowerAscii
  if dir notin dirs: return @[&"Unknown direction '{direction}'."]
  let (dx, dy) = dirs[dir]
  let long = longDir.getOrDefault(dir, dir)
  let (x, y) = state.player.position
  result = @[&"You survey to the {long}."]
  for i in 1..surveyRange:
    let tx = x + dx * i; let ty = y + dy * i
    let tile = getTile(state, tx, ty)
    let name = if tile.name != "": tile.name else: tile.tileType
    let label = if tile.tileType in ["town", "dungeon", "crossroads", "ruin"]:
                  name.replace("-", " ")
                else:
                  name.capitalizeAscii
    result.add &"  {i}. {label}"


# ── Road travel ───────────────────────────────────────────────────────────────

const travelPause* = "\x00TRAVEL_PAUSE"   ## sentinel for game_loop sleep

proc travelRoad*(state: var GameState; direction: string; steps: int): (seq[string], int) =
  ## Auto-travel along the road for up to steps road tiles.
  ## Returns (output_lines, total_ticks).
  const dirs = {
    "north": (0,  1), "n": (0,  1),
    "south": (0, -1), "s": (0, -1),
    "east":  (1,  0), "e": (1,  0),
    "west":  (-1, 0), "w": (-1, 0),
  }.toTable
  const deltaToDir = {
    (0, 1): "North", (0, -1): "South", (1, 0): "East", (-1, 0): "West",
  }.toTable
  ## Search order: N, E, S, W
  const searchOrder = [(0, 1), (1, 0), (0, -1), (-1, 0)]

  let dir = direction.toLowerAscii
  if dir notin dirs:
    return (@[&"Unknown direction '{direction}'."], 0)
  let (dx, dy) = dirs[dir]
  let (x, y) = state.player.position

  let here = getTile(state, x, y)
  if here.tileType notin roadTileTypes:
    return (@["You are not on a road."], 0)

  let (nx, ny) = (x + dx, y + dy)
  let firstTile = getTile(state, nx, ny)
  if firstTile.tileType notin roadTileTypes:
    return (@[&"No road to the {direction} from here."], 0)

  var lines: seq[string]
  var prevX = x; var prevY = y
  var curX  = nx; var curY  = ny
  state.player.position = (curX, curY)
  var totalTicks = terrainTicks.getOrDefault(firstTile.tileType, 4)

  lines.add &"-> {deltaToDir.getOrDefault((dx, dy), direction.capitalizeAscii)}"

  if firstTile.tileType in stopTileTypes:
    let name = (if firstTile.name != "": firstTile.name else: firstTile.tileType).replace("-", " ")
    lines.add travelPause
    lines.add ""
    lines.add &"You arrive at {name}."
    lines.add ""
    lines.add tileLines(state, curX, curY)
    return (lines, totalTicks)

  for _ in 1..<steps:
    var nextX = -999999; var nextY = -999999; var nextDirStr = ""
    for (ddx, ddy) in searchOrder:
      let (cx, cy) = (curX + ddx, curY + ddy)
      if cx == prevX and cy == prevY: continue
      let t = getTile(state, cx, cy)
      if t.tileType in roadTileTypes:
        nextX = cx; nextY = cy
        nextDirStr = deltaToDir.getOrDefault((ddx, ddy), "")
        break

    if nextX == -999999:
      lines.add travelPause
      lines.add ""
      lines.add "The road ends here."
      lines.add ""
      lines.add tileLines(state, curX, curY)
      return (lines, totalTicks)

    prevX = curX; prevY = curY
    curX  = nextX; curY  = nextY
    state.player.position = (curX, curY)
    let moveTile = getTile(state, curX, curY)
    inc totalTicks, terrainTicks.getOrDefault(moveTile.tileType, 4)

    lines.add travelPause
    lines.add &"-> {nextDirStr}"

    if moveTile.tileType in stopTileTypes:
      let name = (if moveTile.name != "": moveTile.name else: moveTile.tileType).replace("-", " ")
      lines.add travelPause
      lines.add ""
      lines.add &"You arrive at {name}."
      lines.add ""
      lines.add tileLines(state, curX, curY)
      return (lines, totalTicks)

  # Finished all steps
  lines.add travelPause
  lines.add ""
  lines.add tileLines(state, curX, curY)
  (lines, totalTicks)
