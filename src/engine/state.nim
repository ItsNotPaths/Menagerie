## engine/state.nim
## ─────────────────
## GameState and all sub-types — the live runtime truth.
## Plain data containers, no methods.  All game logic receives
## `state: var GameState` as its first argument.

import std/[tables, json, options]

type
  InventoryEntry* = object
    id*:    string
    slots*: int   ## slot cost this item occupies in carry capacity
    count*: int   ## stack count (most items are 1)

  ActiveEffect* = object
    id*:             string
    ticksRemaining*: int   ## -1 = permanent (perk)

  PlayerState* = object
    # ── Position ──────────────────────────────────────────────────────────────
    position*:         (int, int)   ## (x, y) on world tile grid
    currentRoom*:      string       ## room id when inside a location ("" = world)
    lastRestPosition*: (int, int)   ## position of last sleep (respawn anchor)
    lastRestRoom*:     string       ## room of last sleep ("" = world map)

    # ── Time ──────────────────────────────────────────────────────────────────
    tick*:             int          ## total ticks elapsed this playthrough

    # ── Resources ─────────────────────────────────────────────────────────────
    gold*:             int
    health*:           float
    stamina*:          float
    focus*:            float   ## casting resource; spent on spells
    hunger*:           float   ## 100 = full, 0 = starving
    fatigue*:          float   ## 100 = rested, 0 = tired, -100 = exhausted

    # ── Loadout ───────────────────────────────────────────────────────────────
    inventory*:        seq[InventoryEntry]
    mainhand*:         string    ## item id in main hand ("" = empty)
    offhand*:          string    ## item id in off hand  ("" = empty)
    armor*:            Table[string, string]   ## zone → plate id
    containers*:       seq[string]             ## equipped container item ids
    favourites*:       seq[string]             ## quick-access spell list
    itemFavourites*:   seq[string]             ## quick-access item list
    spellbook*:        seq[string]

    # ── Active effects ────────────────────────────────────────────────────────
    effects*:          seq[ActiveEffect]

    # ── Spell cooldowns ───────────────────────────────────────────────────────
    spellCooldowns*:   Table[string, int]   ## spell_id → ticks remaining

    # ── Progression ───────────────────────────────────────────────────────────
    level*:            int
    xp*:               float
    skills*:           Table[string, int]   ## "longblade" → 0..SKILL_CAP

    # ── Stat caps (base maximums; grown by level-up stat picks) ───────────────
    maxHealth*:        float
    maxStamina*:       float
    maxFocus*:         float

    # ── Pending level-up picks ─────────────────────────────────────────────────
    pendingSkillPicks*: int
    pendingStatPicks*:  int
    pendingPerkPicks*:  int

    # ── Journal ───────────────────────────────────────────────────────────────
    journal*:          seq[string]   ## page N is journal[N-1]


  CombatEnemy* = object
    id*:           string
    label*:        string
    health*:       float
    maxHealth*:    float
    stamina*:      float
    staminaMax*:   float
    staminaRegen*: float
    focus*:        float
    focusMax*:     float
    focusRegen*:   float
    data*:         JsonNode   ## raw enemy JSON (action_tables, damage, loot, etc.)

    # ── Spatial position ──────────────────────────────────────────────────────
    row*:          int    ## lane 1–9
    distance*:     int    ## distance from player 1–9; 1 = melee range
    speed*:        int    ## cells closed per advance action
    meleeRange*:   int    ## distance at which melee attacks land
    anchored*:     int    ## turns remaining pinned; 0 = free
    effects*:      seq[ActiveEffect]


  CombatTrap* = object
    row*:      int
    distance*: int
    spellId*:  string
    strength*: float   ## base damage after cast-mode multiplier applied
    turns*:    int     ## rounds until expiry if never triggered (0 = expires this round)


  CombatState* = object
    enemies*:          seq[CombatEnemy]
    round*:            int
    lastResult*:       string     ## "hit" | "kill" | "stagger" | "flee"
    traps*:            seq[CombatTrap]
    attackingIds*:     seq[string]   ## enemy ids committed to attack this round

    # ── Per-round action state ─────────────────────────────────────────────────
    dodgeToken*:       int     ## 1 = absorbs next enemy hit this round
    blocking*:         bool    ## player chose block; halves incoming this round
    playerLastAction*: string  ## recorded for AI condition checks next round
    pendingAction*:    JsonNode
    ## queued player offensive action — fired after enemy phase
    ## {"type":"attack"} | {"type":"cast",...} | {"type":"aux",...} | null = none


  RoomOccupantKind* = enum
    rokNpc, rokEnemy

  RoomOccupant* = object
    id*:    string
    label*: string
    kind*:  RoomOccupantKind


  GameContext* = enum
    ctxMenu, ctxWorld, ctxTown, ctxDungeon, ctxCombat, ctxDialogue


  GameState* = object
    player*:    PlayerState

    ## Flat table: quest flags, reputation, world_seed, region state, etc.
    variables*: Table[string, JsonNode]

    ## In-memory dirty cache: keyed "x_y", loaded lazily on location visit.
    dirty*:     Table[string, JsonNode]

    ## Unified NPC/instance tracker, written to npc_states.json.
    npcStates*: Table[string, JsonNode]

    ## Ordered occupant list for the current room.
    ## attack / pickpocket target is [0]; sneak-mode dodge rotates it.
    roomQueue*: seq[RoomOccupant]

    ## Current command context — controls which handlers are active.
    context*:   GameContext

    ## True while player is in sneak mode (town/dungeon only). Not serialised.
    sneaking*:  bool

    ## Active combat session. None when not in combat. Not serialised.
    combat*:    Option[CombatState]


proc initPlayerState*(): PlayerState =
  result.position          = (0, 0)
  result.currentRoom       = ""
  result.lastRestPosition  = (0, 0)
  result.lastRestRoom      = ""
  result.tick              = 0
  result.gold              = 0
  result.health            = 100.0
  result.stamina           = 100.0
  result.focus             = 50.0
  result.hunger            = 100.0
  result.fatigue           = 100.0
  result.mainhand          = ""
  result.offhand           = ""
  result.level             = 1
  result.xp                = 0.0
  result.maxHealth         = 100.0
  result.maxStamina        = 100.0
  result.maxFocus          = 50.0
  result.pendingSkillPicks = 0
  result.pendingStatPicks  = 0
  result.pendingPerkPicks  = 0

proc initGameState*(): GameState =
  result.player  = initPlayerState()
  result.context = ctxMenu
