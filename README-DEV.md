# Menagerie — Developer Notes

See `plans/STATUS.md` for the live todo list and implementation status.

**Build (dev):** `nim c -r src/menagerie.nim` (uses root `nim.cfg` — dynamic SDL2 via distrobox)
**Build (release):** `./docker-build/build.sh --game` (Docker, Ubuntu 20.04, statically linked SDL2)
**Build (mod manager):** `./docker-build/build.sh --manager`

---

## Project Principles

- **Kebab-case for all content IDs.** Item IDs, NPC IDs, effect IDs, spell IDs, variable names — all `like-this`. Snake_case is Nim-land only (module names, proc names, local variables).
- **Minimal OOP.** Engine modules are collections of procs that operate on `GameState`. No deep object hierarchies. `state.nim` holds object types (data shapes only, no logic). Everything else is plain procs.
- **Content drives behavior.** Logic lives in JSON, not Nim. Adding a new effect, perk, or armor proc means authoring content — not touching engine code. The engine is a generic interpreter.
- **Flat and readable over clever.** Prefer explicit conditional branches over metaprogramming. A new command is a `register` call + a handler proc, not a plugin registration system.
- **One mutable state.** `GameState` is the single source of truth passed by `var` reference through every call. No global state outside the IPC channels.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Key Design Decisions](#key-design-decisions)
- [Module Responsibilities](#module-responsibilities--quick-reference)
- [Command Registration](#command-registration)
- [Save / State Architecture](#save--state-architecture)
- [Macro-Economy System](#macro-economy-system)
- [Perk & Modifier System](#perk--modifier-system)
- [IPC Messages](#ipc-messages)
- [Panel System](#panel-system)
- [Mod Manager & Export Drivers](#mod-manager--export-drivers)

---

## Architecture Overview

```
src/
  menagerie.nim              entry point — opens IPC channels, starts threads
  engine/
    state.nim                object types only: PlayerState, GameState, CombatEnemy, CombatState, Trap
    game_loop.nim            game thread — blocks on toGame channel, dispatches commands
    api.nim                  programmatic command surface for content (effects, armor, spells, scripts)
    api_types.nim            shared types for the api surface
    combat.nim               spatial grid combat — enemy phase, player actions, trifecta, aux spells
    combat_ai.nim            included by combat.nim — AI condition DSL evaluator, action-table picker
    combat_display.nim       included by combat.nim — status lines, weapon stats, option buttons
    world.nim                tile generation, room loading, NPC schedule resolution, dirty cache
    saves.nim                save/load — ZIP working directory, dirty flush, npc_states persistence
    clock.nim                tick system — passTicks(), hunger, sleep deprivation
    dialogue.nim             Morrowind-style topic dialogue
    economy.nim              shop system — category browse, buy/sell
    items.nim                inventory helpers — give/take/has/count, equippable handling
    spells.nim               spell loading, focus cost, effect application
    conditions.nim           effect tick-down, expiry, interaction chains
    armor.nim                armor plate loader — event handlers dispatched via modifiers
    scripting.nim            embedded Lua 5.4 bridge (onelua.c statically compiled in)
    variables.nim            evalConditions(), applyChanges()
    modifiers.nim            perk modifier layer and event dispatch
    skills.nim               skill values, XP, level-up
    sneak.nim                stealth, pickpocket, assassination
    content.nim              content loader helpers
    settings.nim             settings persistence
    gameplay_vars.nim        gameplay variable helpers
  commands/
    core.nim                 CmdResult type, registry, dispatch, aliases
    cmd_combat.nim           combat context handlers
    cmd_debug.nim            debug/admin commands
    cmd_dialogue.nim         dialogue handlers
    cmd_inventory.nim        inventory, equip, inspect
    cmd_journal.nim          journal commands
    cmd_menu.nim             main menu context
    cmd_sneak.nim            stealth commands
    cmd_spells.nim           spellbook and spell commands
    cmd_town.nim             town context commands
    cmd_universal.nim        ANY-context commands (look, wait, help, etc.)
    cmd_world.nim            world travel commands
  ui/
    text_window.nim          SDL2 window — scrollback, input bar, HUD canvas, panel system
    journal.nim              included by text_window.nim — journal overlay rendering and input
    ipc.nim                  typed channels: toUi / toGame

world-tools/
  drivers/                   Lua 5.4 export drivers (called by mod manager at export time)
  mod_manager/               mod manager SDL2 binary source
    mod_manager.nim          UI — tabs, plugin list, buttons
    plugin_db.nim            modpack scanner, load_order.json persistence
    lua_runner.nim           Lua C API bindings, pushJson/luaToJson, DriverState
```

Two threads. Game logic thread reads from `toGame`, writes to `toUi`. SDL2 UI thread polls `toUi.tryRecv` each frame and never touches game state directly.

---

## Key Design Decisions

**Statically linked Lua 5.4.** The game engine embeds Lua 5.4 via `onelua.c` (amalgamation). The mod manager also embeds its own instance for running export drivers. Both use the same `{.compile: "...onelua.c".}` + `{.passC: "-DMAKE_LIB".}` pattern. Content scripts are Lua; the engine is Nim.

**No wand, no hand limit.** All spells in the player's spellbook are available in combat. Spell cooldowns (per-spell, in turns) are the designed throttle — `duration` field exists in spell JSON but is currently effect application duration (pending refactor to per-spell cooldown).

**Every action passes ticks.** `passTicks(n, state)` is called after every command — there are no tick-free zones. Town dialogue, shopping, combat turns all cost ticks.

**`.lua` in command fields runs a script.** Any entry in a command list (`tick_commands`, `on_apply_commands`, etc.) that ends in `.lua` is dispatched to the Lua bridge rather than parsed as a command verb.

**No telegraphs.** Enemy intent is not announced. Players read the grid (position, distance, speed) and predict. Melee enemies attack only at distance 1.

**Content is read-only at runtime.** Engine never writes to `content/`. All mutable state lives in `saves/working/`. Content files are compiled by Inkwell + Lua export drivers, not touched in-engine.

**Variables dict is the single source of truth** for all world state that isn't player inventory. Quest flags, reputation, bounty, world_seed, NPC spawn counter — all flat keys in `state.variables`.

---

## Module Responsibilities — Quick Reference

| Module | Owns |
|---|---|
| `state.nim` | Data shapes only — no logic |
| `game_loop.nim` | Game thread, receives player input, dispatches to command registry |
| `commands/core.nim` | `CmdResult` type, registry, dispatch, aliases |
| `commands/cmd_*.nim` | Player-input handlers by context |
| `api.nim` | Content-callable commands (`damage`, `add_effect`, `give`, `give_xp`, `add_bounty`, `set_hostile`, `journal_write`, `journal_append`, etc.) |
| `combat.nim` | Grid movement, trifecta resolution, player actions, aux spells, start/end/flee |
| `combat_ai.nim` | AI condition DSL — `evalCondition`, `pickAction` (included by combat.nim) |
| `combat_display.nim` | Status lines, weapon stats, option buttons (included by combat.nim) |
| `world.nim` | Tile generation, room loading, NPC seeding, schedule resolution |
| `saves.nim` | Serialize/deserialize GameState, dirty flush, working directory |
| `clock.nim` | `passTicks()` — hunger, sleep deprivation, forwards to conditions |
| `conditions.nim` | Effect tick-down, on_expire, interaction chains |
| `armor.nim` | Plate loader + iteration — procs dispatched via `modifiers.fireEvent` |
| `scripting.nim` | Lua 5.4 bridge — `callScript`, `callEffect` |
| `modifiers.nim` | `modGet()` accumulator, `fireEvent()` dispatcher |

`commands/` and `api.nim` are intentionally separate to avoid circular imports — player input goes through the command registry, authored content goes through `api.nim`.

---

## Command Registration

Commands register in context-specific files and are dispatched by `commands/core.nim`:

```nim
# in e.g. commands/cmd_town.nim
proc registerTown*() =
  register("buy", ctxTown, cmdBuy)
  register("sell", ctxTown, cmdSell)

proc cmdBuy(state: var GameState; args: seq[string]): CmdResult =
  ...
  return ok("You buy the item.")
```

Contexts: `ctxMenu`, `ctxWorld`, `ctxTown`, `ctxDungeon`, `ctxCombat` — plus ANY (falls back via `anyRegistry`).

`ok(*lines)`, `err(*lines)`, `okTicks(n, *lines)`, `okImg(path, *lines)` are the result constructors.

---

## Save / State Architecture

```
saves/working/           always current, written on the fly
  player.json            PlayerState (stats, inventory, spellbook, favourites, position, tick)
  variables.json         flat dict — all world state
  npc_states.json        id → state for every named NPC and spawned instance
  dirty/
    <x>_<y>.json         per-tile mutable state (items, cleared rooms, dead NPCs)
```

- Dirty dict is lazy-loaded on tile visit, flushed immediately on change
- `.sav` file is a ZIP of the working directory, written on sleep/save
- `npc_states` is fully loaded into memory on save load — single source of truth for NPC locations

**Named NPC** — seeded on new game from `starting_tile`, room resolved at runtime from schedule + tick.
**Spawned instance** — generated on first tile visit, ID = `{type}_{counter}` where counter is `variables["_npc_spawn_counter"]`.

---

## Macro-Economy System

Economic events modify buy prices in shops for a duration.

**Storage** — `state.variables["_active_economic_event"]` as a serialised dict:
```
id, tag, fluctuation, tick_scope, tick_start
```
Stored in `variables.json` — persists automatically with the save system. Only one event active at a time.

**Activation** — `api.nim: applyEconomicEvent(state, eventId, force=false)`

Loads `content/economic_events/{id}.json`, stamps `tick_start`. Silently no-ops if an event is active and `force=false`. Also reachable via command verb `economic_event <id> [force]`.

**Price application** — `economy.nim: adjustedCost(state, itemId, baseCost)` — checks for active event, matches item `tags` list, returns `max(1, round(baseCost × (1 + fluctuation)))`. Sell prices not affected.

---

## Perk & Modifier System

Perks are permanent effects (`ticksRemaining == -1`) stored in `PlayerState.effects`. Two layers:

**Modifier layer** — read-only derived values. `modifiers.modGet(state, "key")` multiplicatively accumulates `(1 + value)` across all permanent effects that define that key. Returns `1.0` when nothing modifies the key — always safe to multiply in.

**Event layer** — side-effect hooks. `modifiers.fireEvent(state, "event", entity)` dispatches `on_<event>` handlers from each active perk: either a command list or a `.lua` filename.

```nim
# modifier read
baseDmg *= modGet(state, "spell_damage_pct")

# event dispatch
lines.add fireEvent(state, "spell_cast")
```

See `README-USAGE.md` for the full modifier key and perk event reference.

---

## IPC Messages

Game thread → SDL2 UI thread via `toUi`:

| Message | Payload | Effect |
|---|---|---|
| `umPrint` | `line, tag` | Append line to scrollback |
| `umLoadLocation` | `imgPath` | Load background image into left panel |
| `umRenderSprites` | `sprites: seq[SpriteEntry]` | Overlay sprites on left panel |
| `umStats` | `statLines: seq[string]` | Redraw HUD stat canvas |
| `umPanelReplace` | `replaceLines` | Replace scrollback with panel view |
| `umPanelAppend` | `appendLines` | Append lines to active panel |
| `umJournalOpen` | `jPages, jIdx` | Open journal overlay |
| `umQuit` | — | Shut down SDL2 window |

SDL2 UI thread → game thread via `toGame`:

| Message | Payload |
|---|---|
| `gmInput` | `raw: string` — player's submitted command |
| `gmJournalSave` | `savedPages: seq[string]` — journal content after edit |

---

## Panel System

Panels are detail views (item info, spell info, etc.) that update in place when the player clicks action buttons, rather than reprinting below. The SDL2 UI tracks the active panel by line range and replaces it on `umPanelReplace`.

**To add a new panel view:** return `CmdResult` with `panelLines` populated. Use `umPanelReplace` to display it.

**To add a button action:** after mutating state, regenerate the panel from updated state and return it as `panelLines` with `panelAppend = true`.

---

## Mod Manager & Export Drivers

The mod manager is a separate SDL2 binary (`world-tools/mod_manager/mod_manager.nim`). It runs next to `menagerie` in the release directory and is built with `--manager`.

**Plugin layout:**
```
data/<modpack>/
  load_order.json              keyed by tool_id, stores plugin paths in order
  <PluginFolder>/
    <plugin>.json              must contain meta.tool matching a tool_id
    assets/<cat>/              room/tile/sprite assets
    scripts/                   Lua scripts
```

**Tool IDs:** `world-tool`, `room-editor`, `gameplay-vars`, `inkwell`

**Driver interface (`world-tools/drivers/<name>/<name>.lua`):**
```lua
-- most drivers
function export(plugins, scripts_dir, output_dir, kwargs) → int

-- assets driver
function export(folder_paths, content_dir) → int
```

Nim-side helpers injected as Lua globals: `write_file`, `read_file`, `make_dirs`, `path_join`, `path_dirname`, `path_basename`, `path_exists`, `is_dir`, `is_file`, `list_dir`, `copy_file`, `remove_file`, `remove_dir`, `json_encode`, `print`.
