## engine/content.nim
## ───────────────────
## Load all game content from content/ at startup into typed tables.
## Never call parseFile during gameplay — query getters instead.
##
## Call loadContent(contentDir) once before starting the game loop.
## contentDir is the path to the content/ directory.

import std/[json, os, tables]

# ── Types ─────────────────────────────────────────────────────────────────────

type
  ItemDef* = object
    id*, displayName*, itemType*, description*: string
    slotCost*, value*, damage*, staminaCost*:   int
    extraSlots*, staminaReq*:                   int   ## container fields
    canEquip*:                                  bool
    effects*:                                   seq[string]   ## command strings

  SpellDef* = object
    id*, displayName*, castType*, description*: string
    damage*, focusCost*:                        float
    duration*, tickCooldown*:                   int
    onHitCommands*:                             seq[string]
    effects*:                                   JsonNode   ## [{effect: id, ticks: N}]

  EffectDef* = object
    id*, displayName*, description*: string
    tickCommands*:                   seq[string]
    onApplyCommands*:                seq[string]
    onExpireCommands*:               seq[string]
    interactions*:                   JsonNode   ## complex interaction list
    ## Perk-only fields (present when modifiers key exists):
    modifiers*:                      JsonNode   ## {modifier_key: float_value}
    onKill*:                         seq[string]
    raw*:                            JsonNode   ## full JSON for on_<event> handler lookup

  NpcDef* = object
    id*, displayName*, faction*:     string
    startingTile*, combatAiPackage*: string
    isHostile*:                      bool
    health*, damage*:                float
    staminaMax*, staminaRegen*:      float
    focusMax*, focusRegen*:          float
    openingDialogue*:                string
    raw*:                            JsonNode   ## full JSON (topics, schedule, inventory, loot)

  RoomDef* = object
    id*, name*, roomType*, description*, image*: string
    raw*:                                        JsonNode   ## enemies, sprite_positions, etc.

  TileDef* = object
    ## A tile is a named location (town/dungeon) with its own room graph.
    id*:        string   ## tile name (filename without .json)
    entryRoom*: string
    rooms*:     seq[string]
    raw*:       JsonNode   ## connections

  ArmorPlateDef* = object
    id*, displayName*, zone*: string
    defense*:                 int
    raw*:                     JsonNode   ## procs array

  ShopDef* = object
    id*:  string
    raw*: JsonNode   ## items array: [{currency_item, cost, receive_item, receive_amount}]

  AiPackageDef* = object
    id*:  string
    raw*: JsonNode   ## action_tables array

  QuestDef* = object
    id*, displayName*: string
    raw*:              JsonNode   ## actions array

  WorldTile* = object
    x*, y*:       int
    tileType*:    string   ## "town" | "road" | "dungeon" | "crossroads" | "ruin" | terrain
    name*:        string   ## named location name; "" for anonymous tiles
    tile*:        string   ## tile def id for locations; "" for plain terrain
    description*: string   ## custom description override
    image*:       string   ## custom image filename override
    deleted*:     bool     ## soft-deleted in world_def export — skip on load

  WorldDef* = object
    worldSeed*: int
    tiles*:     seq[WorldTile]

  AssetIndex* = object
    files*:   Table[string, string]   ## filename → absolute path (all asset types)
    scripts*: Table[string, string]


# ── Module-level content tables ───────────────────────────────────────────────

var
  items*:      Table[string, ItemDef]
  spells*:     Table[string, SpellDef]
  effects*:    Table[string, EffectDef]
  npcs*:       Table[string, NpcDef]
  rooms*:      Table[string, RoomDef]
  tilesDefs*:  Table[string, TileDef]
  armorPlates*: Table[string, ArmorPlateDef]
  shops*:      Table[string, ShopDef]
  aiPackages*: Table[string, AiPackageDef]
  quests*:     Table[string, QuestDef]
  worldDef*:   WorldDef
  assetIndex*: AssetIndex


# ── Internal helpers ──────────────────────────────────────────────────────────

proc strSeq(node: JsonNode): seq[string] =
  if node == nil or node.kind != JArray: return @[]
  for x in node: result.add x.getStr

proc loadJson(path: string): JsonNode =
  try:
    result = parseFile(path)
  except CatchableError as e:
    echo "content: failed to parse " & path & " — " & e.msg
    result = newJNull()


# ── Loaders ───────────────────────────────────────────────────────────────────

proc loadItems(dir: string) =
  for f in walkFiles(dir / "items/*.json"):
    let d = loadJson(f)
    if d.kind != JObject: continue
    let id = d{"id"}.getStr
    if id == "": continue
    items[id] = ItemDef(
      id:          id,
      displayName: d{"display_name"}.getStr(d{"name"}.getStr(id)),
      itemType:    d{"type"}.getStr,
      description: d{"description"}.getStr,
      slotCost:    d{"slot_cost"}.getInt(1),
      value:       d{"value"}.getInt(0),
      damage:      d{"damage"}.getInt(0),
      staminaCost: d{"stamina_cost"}.getInt(0),
      extraSlots:  d{"extra_slots"}.getInt(0),
      staminaReq:  d{"stamina_req"}.getInt(0),
      canEquip:    d{"can_equip"}.getBool(false),
      effects:     strSeq(d{"effects"}),
    )

proc loadSpells(dir: string) =
  for f in walkFiles(dir / "spells/*.json"):
    let d = loadJson(f)
    if d.kind != JObject: continue
    let id = d{"id"}.getStr
    if id == "": continue
    spells[id] = SpellDef(
      id:            id,
      displayName:   d{"display_name"}.getStr(d{"name"}.getStr(id)),
      castType:      d{"cast_type"}.getStr,
      description:   d{"description"}.getStr,
      damage:        d{"damage"}.getFloat(0),
      focusCost:     d{"focus_cost"}.getFloat(0),
      duration:      d{"duration"}.getInt(0),
      tickCooldown:  d{"tick_cooldown"}.getInt(0),
      onHitCommands: strSeq(d{"on_hit_commands"}),
      effects:       if d.hasKey("effects"): d["effects"] else: newJArray(),
    )

proc loadEffects(dir: string) =
  for f in walkFiles(dir / "effects/*.json"):
    let d = loadJson(f)
    if d.kind != JObject: continue
    let id = d{"id"}.getStr
    if id == "": continue
    effects[id] = EffectDef(
      id:               id,
      displayName:      d{"display_name"}.getStr(d{"name"}.getStr(id)),
      description:      d{"description"}.getStr,
      tickCommands:     strSeq(d{"tick_commands"}),
      onApplyCommands:  strSeq(d{"on_apply_commands"}),
      onExpireCommands: strSeq(d{"on_expire_commands"}),
      interactions:     if d.hasKey("interactions"): d["interactions"] else: newJArray(),
      modifiers:        if d.hasKey("modifiers"): d["modifiers"] else: newJNull(),
      onKill:           strSeq(d{"on_kill"}),
      raw:              d,
    )

proc loadNpcs(dir: string) =
  for f in walkFiles(dir / "npcs/*.json"):
    let d = loadJson(f)
    if d.kind != JObject: continue
    let id = d{"id"}.getStr
    if id == "": continue
    let stam = d{"stamina"}
    let foc  = d{"focus"}
    npcs[id] = NpcDef(
      id:              id,
      displayName:     d{"display_name"}.getStr(d{"name"}.getStr(id)),
      faction:         d{"faction"}.getStr,
      startingTile:    d{"starting_tile"}.getStr,
      combatAiPackage: d{"combat_ai_package"}.getStr,
      isHostile:       d{"is_hostile"}.getBool(false),
      health:          d{"health"}.getFloat(100),
      damage:          d{"damage"}.getFloat(0),
      staminaMax:      if stam != nil and stam.kind == JObject: stam{"max"}.getFloat(0) else: 0,
      staminaRegen:    if stam != nil and stam.kind == JObject: stam{"regen"}.getFloat(0) else: 0,
      focusMax:        if foc != nil and foc.kind == JObject: foc{"max"}.getFloat(0) else: 0,
      focusRegen:      if foc != nil and foc.kind == JObject: foc{"regen"}.getFloat(0) else: 0,
      openingDialogue: d{"opening_dialogue"}.getStr,
      raw:             d,
    )

proc loadRooms(dir: string) =
  for f in walkFiles(dir / "rooms/**/*.json"):
    let d = loadJson(f)
    if d.kind != JObject: continue
    # room id = filename without extension
    let id = f.splitFile.name
    rooms[id] = RoomDef(
      id:       id,
      name:     d{"name"}.getStr(id),
      roomType: d{"type"}.getStr,
      description: d{"description"}.getStr,
      image:    d{"image"}.getStr,
      raw:      d,
    )

proc loadTiles(dir: string) =
  for f in walkFiles(dir / "tiles/*.json"):
    let d = loadJson(f)
    if d.kind != JObject: continue
    let id = f.splitFile.name
    var roomList: seq[string]
    if d.hasKey("rooms") and d["rooms"].kind == JArray:
      for r in d["rooms"]: roomList.add r.getStr
    tilesDefs[id] = TileDef(
      id:        id,
      entryRoom: d{"entry_room"}.getStr,
      rooms:     roomList,
      raw:       d,
    )

proc loadArmorPlates(dir: string) =
  for f in walkFiles(dir / "armor_plates/*.json"):
    let d = loadJson(f)
    if d.kind != JObject: continue
    let id = d{"id"}.getStr
    if id == "": continue
    armorPlates[id] = ArmorPlateDef(
      id:          id,
      displayName: d{"display_name"}.getStr(d{"name"}.getStr(id)),
      zone:        d{"zone"}.getStr,
      defense:     d{"defense"}.getInt(0),
      raw:         d,
    )

proc loadShops(dir: string) =
  for f in walkFiles(dir / "shops/*.json"):
    let d = loadJson(f)
    if d.kind != JObject: continue
    let id = d{"id"}.getStr
    if id == "": continue
    shops[id] = ShopDef(id: id, raw: d)

proc loadAiPackages(dir: string) =
  for f in walkFiles(dir / "ai_packages/*.json"):
    let d = loadJson(f)
    if d.kind != JObject: continue
    let id = d{"id"}.getStr
    if id == "": continue
    aiPackages[id] = AiPackageDef(id: id, raw: d)

proc loadQuests(dir: string) =
  for f in walkFiles(dir / "quests/*.json"):
    let d = loadJson(f)
    if d.kind != JObject: continue
    let id = d{"id"}.getStr
    if id == "": continue
    quests[id] = QuestDef(
      id:          id,
      displayName: d{"display_name"}.getStr(id),
      raw:         d,
    )

proc loadWorldDef(dir: string) =
  let path = dir / "world/world_def.json"
  if not fileExists(path): return
  let d = loadJson(path)
  if d.kind != JObject: return
  worldDef.worldSeed = d{"world_seed"}.getInt(0)
  if d.hasKey("tiles") and d["tiles"].kind == JArray:
    for t in d["tiles"]:
      worldDef.tiles.add WorldTile(
        x:           t{"x"}.getInt(0),
        y:           t{"y"}.getInt(0),
        tileType:    t{"type"}.getStr,
        name:        t{"name"}.getStr,
        tile:        t{"tile"}.getStr,
        description: t{"description"}.getStr,
        image:       t{"image"}.getStr,
        deleted:     t{"deleted"}.getBool(false),
      )

proc loadAssetIndex(dir: string) =
  let path = dir / "asset_index.json"
  if not fileExists(path): return
  let d = loadJson(path)
  if d.kind != JObject: return
  if d.hasKey("files") and d["files"].kind == JObject:
    for k, v in d["files"]: assetIndex.files[k] = v.getStr
  if d.hasKey("scripts") and d["scripts"].kind == JObject:
    for k, v in d["scripts"]: assetIndex.scripts[k] = v.getStr


# ── Public API ────────────────────────────────────────────────────────────────

proc loadContent*(contentDir: string) =
  ## Load all content from contentDir at startup. Call once before game loop.
  loadItems(contentDir)
  loadSpells(contentDir)
  loadEffects(contentDir)
  loadNpcs(contentDir)
  loadRooms(contentDir)
  loadTiles(contentDir)
  loadArmorPlates(contentDir)
  loadShops(contentDir)
  loadAiPackages(contentDir)
  loadQuests(contentDir)
  loadWorldDef(contentDir)
  loadAssetIndex(contentDir)
  echo "content: loaded " &
    $items.len & " items, " &
    $spells.len & " spells, " &
    $effects.len & " effects, " &
    $npcs.len & " npcs, " &
    $rooms.len & " rooms, " &
    $tilesDefs.len & " tile defs, " &
    $armorPlates.len & " armor plates, " &
    $shops.len & " shops, " &
    $aiPackages.len & " ai packages, " &
    $quests.len & " quests, " &
    $worldDef.tiles.len & " world tiles"

proc getItem*(id: string): ItemDef =
  if id in items: items[id]
  else:
    echo "content: item not found: " & id
    ItemDef(id: id)

proc getSpell*(id: string): SpellDef =
  if id in spells: spells[id]
  else:
    echo "content: spell not found: " & id
    SpellDef(id: id)

proc getEffect*(id: string): EffectDef =
  if id in effects: effects[id]
  else:
    echo "content: effect not found: " & id
    EffectDef(id: id)

proc getNpc*(id: string): NpcDef =
  if id in npcs: npcs[id]
  else:
    echo "content: npc not found: " & id
    NpcDef(id: id)

proc getRoom*(id: string): RoomDef =
  if id in rooms: rooms[id]
  else:
    echo "content: room not found: " & id
    RoomDef(id: id)

proc getTileDef*(id: string): TileDef =
  if id in tilesDefs: tilesDefs[id]
  else:
    echo "content: tile def not found: " & id
    TileDef(id: id)

proc getArmorPlate*(id: string): ArmorPlateDef =
  if id in armorPlates: armorPlates[id]
  else:
    echo "content: armor plate not found: " & id
    ArmorPlateDef(id: id)

proc getShop*(id: string): ShopDef =
  if id in shops: shops[id]
  else:
    echo "content: shop not found: " & id
    ShopDef(id: id)

proc getAiPackage*(id: string): AiPackageDef =
  if id in aiPackages: aiPackages[id]
  else:
    echo "content: ai package not found: " & id
    AiPackageDef(id: id)

proc getQuest*(id: string): QuestDef =
  if id in quests: quests[id]
  else:
    echo "content: quest not found: " & id
    QuestDef(id: id)
