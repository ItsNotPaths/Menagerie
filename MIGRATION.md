# Menagerie — Nim Rewrite Plan

This document maps the Python codebase (`../Menagerie/`) to a Nim/SDL2 rewrite.
It is a living reference: update it as decisions get made.

---

## 1. What Already Exists

The current Nim prototype (`src/`) provides a working SDL2 shell:

| File | Role | Python equivalent |
|---|---|---|
| `src/menagerie.nim` | Entry point | `main.py` |
| `src/ui/text_window.nim` | SDL2 window, split-panel layout, text render, mouse/keyboard | `ui/text_window.py` |
| `src/ui/ipc.nim` | Queue bridge placeholder | `ui/ipc.py` |
| `src/engine/scripting.nim` | Embedded Lua 5.4 (static, no deps) | `engine/scripts.py` |

The SDL2 shell already handles:
- Resizable split-panel layout (sash drag)
- Monospace text rendering with `[[label:cmd]]` link parsing
- Text selection and clipboard copy
- Cursor blink, mouse hover link highlight
- HUD stats overlay on left panel
- Background image loading (SDL2_image, static)
- Lua engine wired to `on_command` / `on_start` callbacks
- Static font embed via `staticRead`
- Docker-based release build (fully static SDL2 binary)

Everything below is engine work that does not exist yet in Nim.

---

## 2. Architecture Overview

The Python codebase has a clean separation that maps well to Nim:

```
Python                          Nim target
──────────────────────────────────────────────────────
state.py        dataclasses  →  src/engine/state.nim      object types, no methods
world.py        tile/NPC     →  src/engine/world.nim
combat.py       turn logic   →  src/engine/combat.nim
dialogue.py     topic system →  src/engine/dialogue.nim
economy.py      shops/barter →  src/engine/economy.nim
items.py        inventory    →  src/engine/items.nim
armor.py        plate procs  →  src/engine/armor.nim
spells.py       spell load   →  src/engine/spells.nim
skills.py       progression  →  src/engine/skills.nim
conditions.py   effects/tick →  src/engine/conditions.nim
modifiers.py    perks/events →  src/engine/modifiers.nim
clock.py        time/ticks   →  src/engine/clock.nim
sneak.py        stealth      →  src/engine/sneak.nim
saves.py        persist      →  src/engine/saves.nim
variables.py    conditions   →  src/engine/variables.nim
gameplay_vars.py constants   →  src/engine/gameplay_vars.nim
api.py          state API    →  src/engine/api.nim
scripts.py      sandboxing   →  (replaced by Lua — already done)
commands/       handlers     →  src/commands/
game_loop.py    dispatcher   →  src/engine/game_loop.nim
ui/ipc.py       queue        →  src/ui/ipc.nim
ui/text_window.py SDL2 win   →  src/ui/text_window.nim   ✓ done
```

The `content/` directory (game runtime data) and `data/base-game/assets/`
(images) carry over unchanged — the Nim binary reads exactly the same files
as the Python binary. `data/base-game/plugins/` is authoring source only.

---

## 3. Data Flow

```
User input (SDL2 KeyDown / MouseButtonUp)
    │
    ▼
ipc.toGame  (channel)
    │
    ▼
game_loop.dispatch(raw, state)
    │  look up handler by (verb, context)
    ▼
Command handler  →  mutates state, returns CmdResult
    │  (lines, image path, tick cost, …)
    ▼
clock.passTicks(state, cost)
    │
    ▼
ipc.toUI  (channel)
    │
    ▼
text_window polls channel every frame
    ├─ prints lines to scrollback
    ├─ loads image into left panel
    └─ redraws HUD stats
```

The Python code uses OS threads + `queue.Queue`.
In Nim, use `Channel[T]` with two threads (SDL2 event/render on main,
game logic on a daemon thread) — same mental model, zero lock contention.

---

## 4. State Module (`src/engine/state.nim`)

Port `state.py` first — everything else depends on it.
Python uses `@dataclass`; Nim uses plain `object` types with no methods.

```nim
# Sketch — not final
type
  InventoryEntry = object
    id:    string
    slots: int
    count: int

  ActiveEffect = object
    id:             string
    ticksRemaining: int   # -1 = permanent (perk)

  PlayerState = object
    position:          (int, int)
    currentRoom:       string
    lastRestPosition:  (int, int)
    lastRestRoom:      string
    health:            float
    maxHealth:         float
    stamina:           float
    maxStamina:        float
    focus:             float
    maxFocus:          float
    hunger:            float
    fatigue:           float
    gold:              int
    level:             int
    xp:                int
    skills:            Table[string, int]
    inventory:         seq[InventoryEntry]
    mainhand:          string
    offhand:           string
    armor:             Table[string, string]   # zone → plate id
    containers:        seq[string]             # equipped container item ids
    favourites:        seq[string]             # quick-slot spells
    itemFavourites:    seq[string]             # quick-slot items
    spellbook:         seq[string]
    spellCooldowns:    Table[string, int]      # spell_id → ticks remaining
    effects:           seq[ActiveEffect]
    pendingSkillPicks: int
    pendingStatPicks:  int
    pendingPerkPicks:  int
    journal:           seq[string]             # one string per page

  CombatEnemy = object
    id:           string
    label:        string
    data:         JsonNode     # raw enemy JSON (for AI, loot, etc.)
    health:       float
    maxHealth:    float
    stamina:      float
    staminaMax:   float
    staminaRegen: float
    focus:        float
    focusMax:     float
    focusRegen:   float
    row:          int          # 1–9 lateral
    distance:     int          # 1–9 depth
    speed:        int
    meleeRange:   int
    anchored:     int          # turns pinned
    effects:      seq[ActiveEffect]

  CombatTrap = object
    row, distance: int
    spellId:       string
    strength:      float
    turns:         int

  CombatState = object
    enemies:          seq[CombatEnemy]
    round:            int
    lastResult:       string   # "hit"|"kill"|"stagger"|"flee"
    traps:            seq[CombatTrap]
    dodgeToken:       int
    blocking:         bool
    playerLastAction: string   # used by enemy AI conditions
    pendingAction:    string
    attackingIds:     seq[string]

  GameContext = enum
    ctxMenu, ctxWorld, ctxTown, ctxDungeon, ctxCombat, ctxDialogue

  GameState = object
    player:    PlayerState
    context:   GameContext
    variables: Table[string, JsonNode]   # quest flags, NPC positions, counters
    dirty:     Table[string, JsonNode]   # keyed "x_y", per-tile mutable state
    npcStates: Table[string, JsonNode]
    roomQueue: seq[RoomOccupant]
    combat:    Option[CombatState]
    sneaking:  bool
    tick:      int
```

**Key decisions:**
- `variables` and `dirty` hold `JsonNode` values (mixed types like Python `dict`).
  Alternatively, use `RootRef` variant objects — decide before starting saves.
- `world_seed` lives in `variables["world_seed"]` (an int), not as a root field.
  This matches Python exactly — seed is set on new-game and persisted as a variable.
- `Option[CombatState]` replaces Python `None` for absent combat.
- All game logic takes `state: var GameState` as first argument (mirrors Python
  pattern of passing `state` to every function).
- `RoomOccupant` (used in `roomQueue`) should be: `object { id, label: string; kind: enum{npcKind, enemyKind} }`.

---

## 5. Content Loading

**The pipeline is:**

```
data/base-game/plugins/   ← authoring source (Inkwell tool writes these)
        │
        │  mod_manager.py + export drivers  (dev tool, not game runtime)
        ▼
content/                  ← game reads this; built output, not source
```

The Nim game **only reads `content/`** (and `data/base-game/assets/` for images).
It never touches `data/base-game/plugins/`. The export step is a Python dev tool.

**Content directory** (`content/<type>/<id>.json`):
One file per entity — items, spells, effects/perks, NPCs, rooms, tiles,
armor_plates, shops, AI packages, quests, economic_events, gameplay_vars, world_def,
asset_index.

Load all of it at startup into typed Nim records; never parse JSON mid-game.

```nim
# src/engine/content.nim
type
  ItemDef = object
    id, displayName, itemType: string
    slotCost, value, damage:   int
    staminaCost:               int
    canEquip:                  bool

var items: Table[string, ItemDef]

proc loadContent*(contentDir: string) =
  for f in walkFiles(contentDir / "items/*.json"):
    let d = parseFile(f)
    items[d["id"].getStr] = ItemDef(...)
```

Modules that need content call getters (`getItem`, `getSpell`, etc.)
backed by module-level tables loaded once on startup.

**Phase 1 content types to load:**
items, spells, effects/perks, NPCs, rooms, tiles, armor_plates, shops,
AI packages, quests, economic_events, gameplay_vars, world_def, asset_index.

---

## 6. IPC Channel (`src/ui/ipc.nim`)

Replace the empty placeholder with two typed channels:

```nim
# src/ui/ipc.nim
import json

type
  UiMsgKind = enum
    umPrint, umPanelPrint, umPanelAppend, umPanelReplace,
    umLoadLocation, umRenderSprites, umStats, umJournalOpen

  SpriteEntry = object
    path: string
    nx, ny: float   # normalised position [0,1]

  UiMsg = object
    case kind: UiMsgKind
    of umPrint:         line: string; tag: string
    of umPanelPrint:    lines: seq[string]
    of umPanelAppend:   appendLines: seq[string]
    of umPanelReplace:  replaceLines, regularLines: seq[string]
    of umLoadLocation:  path: string
    of umRenderSprites: sprites: seq[SpriteEntry]
    of umStats:         statLines: seq[string]   # always 8 lines: day/time, level, health, stamina, focus, fatigue, hunger, gold
    else: discard

  GameMsgKind = enum gmInput
  GameMsg = object
    case kind: GameMsgKind
    of gmInput: raw: string

var
  toUi*:   Channel[UiMsg]
  toGame*: Channel[GameMsg]
```

`text_window.nim` polls `toUi` each frame; input bar posts to `toGame`.

---

## 7. Command System (`src/commands/`)

Python uses a decorator registry (`@cmd("look", ctx=WORLD)`).
In Nim, use a plain `Table[(string, GameContext), HandlerProc]` built at startup.

```nim
# src/commands/core.nim
type
  CmdResult = object
    lines:        seq[string]
    imagePath:    string        # send LOAD_LOCATION + RENDER_SPRITES if set
    ticks:        int
    panelLines:   seq[string]   # replace right-panel display (shop, inventory views)
    panelAppend:  bool          # append panelLines instead of replace

  HandlerProc = proc(state: var GameState; args: seq[string]): CmdResult

var registry: Table[(string, GameContext), HandlerProc]

proc register*(verb: string; ctx: GameContext; h: HandlerProc) =
  registry[(verb, ctx)] = h

proc dispatch*(raw: string; state: var GameState): CmdResult =
  let parts = raw.strip.splitWhitespace
  if parts.len == 0: return
  let key = (parts[0], state.context)
  if key in registry:
    result = registry[key](state, parts[1..^1])
  else:
    result.lines = @["Unknown command."]
```

Each context gets its own file (`src/commands/cmd_world.nim`,
`src/commands/cmd_combat.nim`, etc.) that calls `register` in its `init` proc.
`game_loop.nim` calls all init procs before starting the loop.

**Aliases** (`n` → `go north`, `i` → `inventory`, etc.) are a small preprocessing
step in `dispatch` before the table lookup.

---

## 8. Migration Phases

> **Phase ordering note**: Phases 1–2 are pure library code (no UI). Build and
> unit-test them with `nim c` + `echo` before wiring the channels in Phase 3.
> After Phase 3 the game is playable end-to-end (move + look), even if most
> content is stub output. All later phases add depth without breaking the loop.

### Phase 1 — State & Content Loading
*Goal: compile and load all JSON content into typed structures.*

- [ ] `src/engine/state.nim` — all game state types (see §4)
- [ ] `src/engine/gameplay_vars.nim` — load `gameplay_vars.json`, typed getters
- [ ] `src/engine/variables.nim` — `evalConditions`, `applyChanges` (pure functions, no state)
- [ ] `src/engine/content.nim` — load all content types: items, spells, effects/perks, NPCs, rooms, tiles, armor_plates, shops, AI packages, quests, economic_events, world_def, asset_index; merge individual files + Inkwell plugin bundles into same tables
- [ ] Verify all content files parse without errors

### Phase 2 — World & Clock
*Goal: player can move around the world map and enter locations (console output).*

- [ ] `src/engine/clock.nim` — tick system, time-of-day, fatigue/hunger drain, stat regen, effective stat caps
- [ ] `src/engine/world.nim` — procedural + hand-placed tile generation (seed from `variables["world_seed"]`), room loading, asset resolution, NPC schedule, dirty tile lazy-load, room queue rebuild
- [ ] `src/commands/core.nim` — registry, dispatch, alias expansion
- [ ] `src/commands/cmd_world.nim` — `go`, `look`, `survey`, `camp`, `wait`
- [ ] `src/commands/cmd_town.nim` — `go`, `look`, `enter`, `sleep`
- [ ] `src/commands/cmd_universal.nim` — `help`, `wait`

### Phase 3 — IPC & Game Loop
*Goal: game logic on background thread; SDL2 shell driven by real engine.*

- [ ] `src/ui/ipc.nim` — typed channels (see §6); compile with `--mm:orc` (required for heap types across threads)
- [ ] `src/engine/game_loop.nim` — daemon thread, `dispatch` loop, `_push` (send lines + image + sprites + 8-line HUD stats), dynamic stat lines replacing current hardcoded HUD
- [ ] Connect `text_window.nim` input bar → `toGame`; poll `toUi` each frame
- [ ] Wire `LOAD_LOCATION` + `RENDER_SPRITES` so left panel updates on room enter

### Phase 4 — Inventory & Items
*Goal: player can pick up, equip, drop, and use items.*

- [ ] `src/engine/items.nim` — `giveItem`, `takeItem`, `hasItem`, `countItem`, inventory queries, container slots
- [ ] `src/commands/cmd_inventory.nim` — `equip`, `unequip`, `drop`, `use`, `inventory`

### Phase 5 — Effects, Conditions, Modifiers
*Goal: status effects tick down; perks fire events.*

- [ ] `src/engine/conditions.nim` — `hasEffect`, `tickEffects`, `checkInteractions`
- [ ] `src/engine/modifiers.nim` — `get` (multiplicative accumulator), `fireEvent`, perk event dispatch
- [ ] `src/engine/armor.nim` — plate iteration, `fireEffectProcs`, event hooks

### Phase 6 — Combat
*Goal: full spatial grid combat loop.*

- [ ] `src/engine/spells.nim` — spell loading, `applySpellEffects`
- [ ] `src/engine/skills.nim` — skill values, `skillPct`, `giveXp`, levelup picks
- [ ] `src/engine/combat.nim` — round structure, enemy AI (action tables + conditions), resource economy, trap system, dodge token, death handling, telegraph messages
- [ ] `src/commands/cmd_combat.nim` — `attack`, `dodge`, `block`, `pass`, `flee`, `cast`, `smite`, `beam`, `wave`, `trap`, positional commands

### Phase 7 — Dialogue & Economy
*Goal: NPC conversations and shops work end-to-end.*

- [ ] `src/engine/dialogue.nim` — `openDialogue`, `selectTopic`, `endDialogue`, link token conversion, opening conditions
- [ ] `src/engine/economy.nim` — `openShop`, `buyTrade`, `sellItem`, mercantile scaling, economic events
- [ ] `src/commands/cmd_dialogue.nim` — `talk`, `say`, `farewell`
- [ ] `src/commands/cmd_economy.nim` — `shop`, `buy`, `sell`

### Phase 8 — Stealth & Scripting
*Goal: sneak mode works; Lua scripts drive content events.*

- [ ] `src/engine/sneak.nim` — stealth rolls, pickpocket, rotate target, stealth attack
- [ ] Wire Lua scripts into the event pipeline
  - `on_command`, `on_start` already work in the shell
  - Add: `on_kill`, `on_effect_received`, `on_level_up`, etc.
  - Expose the full `api.*` command set to Lua as globals
- [ ] Replace Python flat-string `scripts.py` sandbox with Lua — already architecturally done

### Phase 9 — Saves
*Goal: save and load a full game.*

- [ ] `src/engine/saves.nim` — `flushToWorking`, `zipWorking`, `loadFromWorking`, `clearWorkingOnLaunch`, autosave rotation
- [ ] `src/commands/cmd_universal.nim` — `save`, `load`, `new`, `continue`
- [ ] Verify dirty tile write-through (`flushDirty` on each mutation)

### Phase 10 — Polish
*Goal: feature parity with Python version.*

- [ ] Journal system (in-game editable journal in the text panel; `journal` field already in PlayerState)
- [ ] Command history (↑/↓ in input bar — SDL2 KeyDown already handled, just needs a `seq[string]` history buffer)
- [ ] Menu context (`new`, `continue`, `load`, `exit`) — needs save system from Phase 9
- [ ] NPC schedule reload at tick boundary (`clock.passTicks` triggers it)
- [ ] Save versioning / migration
- [ ] Screen-reader / accessibility pass

---

## 9. Key Design Decisions for Nim

### 9.1 Static Typing vs. Python's `dict` State

Python's `state.variables` is a flat `dict[str, Any]` used for quest flags,
NPC positions, economy event state, talking-to tracking, etc.
In Nim, the cleanest approach is to keep it as `Table[string, JsonNode]`
(using `std/json`) so arbitrary content can write to it without changing
Nim types. Alternatively, a `RootRef` variant type gives more safety but
requires every new variable type to be declared.

**Recommendation**: start with `Table[string, JsonNode]` to unblock content
work; refactor to typed variants if performance becomes an issue.

### 9.2 Sandboxed Scripts → Lua

Python `scripts.py` implements a custom sandboxed `exec()` with an AST
whitelist. That was necessary because Python content authors needed to write
logic inline.

In Nim this is replaced entirely by the already-embedded Lua engine.
Content scripts (currently `.py` files in `content/`) should be migrated to
`.lua`. The `engine.` Lua global is the entry point; expose all API verbs
there (e.g. `engine.damage`, `engine.give`, `engine.add_effect`, `engine.msg`).

### 9.3 Effect & Perk Callbacks

Python perks store `on_kill`, `on_hit_received`, etc. as lists of command
strings or `.py` script paths. In Nim these can be either Lua function names
(preferred) or flat command strings processed by a small dispatcher.

Suggested approach:
- Each effect/perk JSON gains a `lua_hooks` table: `{"on_kill": "perk_shadow_hunter_kill"}`
- The corresponding `.lua` file defines that function
- `modifiers.fireEvent` calls `scripting.callGlobal(hookName)` with context vars pre-pushed

### 9.4 Threading

Use Nim's `Channel[T]` (global scope) with two threads:
- **Main thread** — SDL2 events, rendering (required by SDL2 on most platforms)
- **Game thread** — blocks on `toGame.recv()`, processes one command at a time

No mutexes needed: game thread is the sole writer to `GameState`.

**Critical**: compile with `--mm:orc` (or `--gc:orc` on older Nim).
The default refc GC is not safe for passing `string`/`seq` types across threads
via channels. ORC uses atomic reference counting and is thread-safe.
Add `--mm:orc` to `nim.cfg` (dev) and `docker-build/nim.cfg` (release).

### 9.5 JSON Content Loading

Use `std/json` + `std/jsonutils` (or `jsony` from Nimble) to parse content.
Load all content in `loadContent(dataDir)` at startup before the game loop.
Never call `parseFile` during gameplay.

### 9.6 Deterministic World Generation

Python generates wilderness tiles deterministically from `(x, y, worldSeed)`.
Port this using Nim's `std/random` with `Rand` seeded per-tile:
```nim
proc terrainAt(x, y, seed: int): TerrainType =
  var rng = initRand(seed xor (x * 1000003) xor (y * 999983))
  # same distribution as Python version
```

### 9.7 Save Format

Keep plain JSON (same as Python) so saves are cross-compatible during
the transition period.

Python uses `zipfile` (stdlib, `ZIP_DEFLATED`). Nim has no stdlib ZIP writer.
Options:
- `zippy` (Nimble) — pure Nim, supports deflate, no system dep
- `zip` (Nimble) — wraps libzip, needs system lib (bad for static build)
- Shell out: `zip -rj dest.sav working/` — simplest, avoids a dep

**Recommendation**: use `zippy` for the static Docker build target.

---

## 10. Module Dependency Order

To avoid circular imports, build bottom-up:

```
gameplay_vars  ← no deps
variables      ← json
state          ← json, tables
content        ← state, json
clock          ← state, gameplay_vars
items          ← state, content
armor          ← state, content
spells         ← state, content
skills         ← state, gameplay_vars
conditions     ← state, content, api (forward ref)
modifiers      ← state, content, scripting
api            ← state, items, armor, spells, conditions, modifiers, scripting
world          ← state, content, variables, clock, api
combat         ← state, content, api, conditions, modifiers, spells, skills, armor
dialogue       ← state, content, variables, api, economy
economy        ← state, content, items, modifiers, skills
sneak          ← state, world, combat, api, modifiers
saves          ← state, world (for dirty flush)
game_loop      ← all engine, commands, ipc, clock
```

`api.nim` and `conditions.nim` have a mutual dependency (each calls the other).
Break it with a forward declaration or split into `api_types.nim` +
`api_impl.nim`.

---

## 11. Content That Needs Migrating

Beyond Nim source code, some Python-specific content files will need updates:

| What | Python format | Nim target |
|---|---|---|
| `content/scripts/*.py` | Pseudo-command syntax (not real Python) | Trivial — port to `.lua` |
| NPC `script:` fields in JSON | `.py` file path references | Change extension to `.lua` |
| Effect/perk event hooks | `on_kill: ["damage player 5"]` command strings | Add `lua_hooks` table (see §9.3) |
| `content/ai_packages/*.json` | Python AI condition syntax | Same format — port condition evaluator to Nim |

**Notes on content scripts**: The two files in `content/scripts/` (`death_satchel.py`,
`town-villager_dialogue_town.py`) are pseudo-command text files, not real Python.
They're trivial to migrate — essentially already Lua-ready.

**`mod_manager.py`**: A Tkinter-based authoring GUI that manages content packs and
runs export drivers. It is a **dev tool only** — nothing to port. The Nim runtime
reads the export output in `content/`; it never sees `data/base-game/plugins/`.

Everything else (rooms, tiles, items, spells, effects, shops, npcs, armor_plates,
gameplay_vars) is pure JSON with no Python-specific syntax — load as-is.

---

## 12. What to Build, What to Drop

**Keep:**
- Split-panel SDL2 UI (done)
- Static Lua embedding (done)
- Content-driven JSON data (no changes)
- Multiplicative modifier system (clean, port exactly)
- Spatial grid combat (core differentiator, port exactly)
- Dirty-tile write-through saves (important for correctness)
- Effect interaction chains (recursive, elegant)
- NPC schedule system (data-driven NPC positioning)

**Simplify:**
- Python sandboxing → Lua (already done architecturally)
- Tkinter IPC → SDL2 native (already done)
- Dynamic `@dataclass` field access → static Nim object fields
- `isinstance` dispatch → `case` on variant types

**Drop for now:**
- Journal system (nice to have, not core)
- PIL image compositing (SDL2 can composite sprites natively)
- Python `log.py` → use `std/logging` or just `echo` + file append
- Economic events (implement later; infrastructure is simple)

**Improve over Python:**
- No GIL, true parallelism possible in future
- Static binary via Docker build (already working)
- Lua scripting better integrated than Python sandbox
- SDL2 gives direct hardware rendering vs. Tkinter canvas

---

*Last updated: 2026-03-31 (reviewed)*
