# Menagerie — Developer Notes

See `plans/STATUS.md` for the live todo list and implementation status.

**Tests:** `python test_world.py` — covers room loading, tile generation, new_game, dirty lazy-load, save/load roundtrip. Run after non-trivial changes to world/saves. Likely to be replaced with a proper test suite later.

---

## Project Principles

- **Kebab-case for all content IDs.** Item IDs, NPC IDs, effect IDs, spell IDs, variable names — all `like-this`. Snake_case is Python-land only (module names, function names, local variables).
- **Minimal OOP.** Engine modules are collections of functions that operate on `GameState`. No method-heavy class hierarchies. `state.py` holds dataclasses (data shapes only, no logic). Everything else is plain functions.
- **Content drives behavior.** Logic lives in JSON, not Python. Adding a new effect, perk, or armor proc means authoring content — not touching engine code. The engine is a generic interpreter.
- **Flat and readable over clever.** Prefer explicit conditional branches over metaprogramming. A new command is a new `@cmd` function, not a plugin registration system.
- **One mutable state.** `GameState` is the single source of truth passed through every call. No global state, no singletons outside the IPC queues.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Key Design Decisions](#key-design-decisions)
- [Module Responsibilities](#module-responsibilities--quick-reference)
- [Command Registration](#command-registration)
- [Save / State Architecture](#save--state-architecture)
- [Macro-Economy System](#macro-economy-system)
- [Perk & Modifier System](#perk--modifier-system)
  - [Modifier layer](#modget-state-key--float)
  - [Event layer](#modfire_event-state-event-self_entitynone--liststr)
  - [Event context pattern](#event-context--pre-write-pattern)
  - [Registered modifier keys](#registered-modifier-keys)
  - [Adding a new modifier hook point](#adding-a-new-modifier-hook-point)
  - [Adding a new event](#adding-a-new-event)
  - [Skill system](#skill-system)
- [Known Gotchas](#known-gotchas)
- [IPC Messages](#ipc-messages)
- [Panel Refresh System](#panel-refresh-system)
  - [How it works](#how-it-works)
  - [Data flow](#data-flow)
  - [Adding a new panel view](#adding-a-new-panel-view)
  - [Adding a new button action](#adding-a-new-button-action)
  - [Need-to-remembers](#need-to-remembers)

---

## Architecture Overview

```
main.py                  entry point — starts game thread + Tkinter UI thread
engine/
  state.py               dataclasses only: PlayerState, GameState, CombatEnemy, CombatState, Trap
  game_loop.py           game thread — blocks on IPC input queue, dispatches commands
  commands.py            command registry and all player-input handlers (~1460 LOC)
  api.py                 programmatic command surface for content (effects, armor, spells, scripts)
  combat.py              spatial grid combat — enemy phase, player actions, trifecta, aux spells
  world.py               tile generation, room loading, NPC schedule resolution, dirty cache
  saves.py               save/load — ZIP working directory, dirty flush, npc_states persistence
  clock.py               tick system — pass_ticks(), hunger, sleep deprivation
  dialogue.py            Morrowind-style topic dialogue
  economy.py             shop system — category browse, buy/sell
  items.py               inventory helpers — give/take/has/count, equippable handling
  spells.py              spell loading, focus cost, effect application
  conditions.py          effect tick-down, expiry, interaction chains
  armor.py               armor plate loader — event handlers dispatched via modifiers.fire_event
  scripts.py             sandboxed Python executor for content scripts
  variables.py           eval_conditions(), apply_changes()
  sneak.py               stealth, pickpocket, assassination
  travel.py              stub — road pathfinding algorithm lives elsewhere, needs moving here
ui/
  text_window.py         Tkinter window — scrollback, input bar, HUD canvas, panel system
  ipc.py                 two-queue bridge: to_tkinter / to_game
```

Two threads. Game logic thread reads from `ipc.to_game`, writes to `ipc.to_tkinter`. Tkinter thread never touched by game logic directly.

---

## Key Design Decisions

**No wand, no hand limit.** All spells in the player's spellbook are available in combat. Spell cooldowns (per-spell, in turns) are the designed throttle to promote rotation and combos — `duration` field exists in spell JSON but is currently effect application duration (pending refactor to per-effect). A `cooldown` field + round tracking in `CombatState` is the todo.

**Every action passes ticks.** `pass_ticks(n, state)` is called after every command — there are no tick-free zones. Town dialogue, shopping, combat turns all cost ticks.

**`.py` in command fields runs a script.** Any entry in a command list (`tick_commands`, `on_apply_commands`, proc commands, event hook commands, etc.) that ends in `.py` is dispatched to `scripts.run_script_file` rather than parsed as a command verb. This is checked at the top of `api.run_effect_command` before verb dispatch. No special wrapper needed — just put the filename.

**No telegraphs.** Enemy intent is not announced. Players read the grid (position, distance, speed) and predict. Melee enemies attack only at distance 1.

**Content is read-only at runtime.** Engine never writes to `content/`. All mutable state lives in `saves/working/`. Content files are compiled by Inkwell + export drivers, not touched in-engine.

**Variables dict is the single source of truth** for all world state that isn't player inventory. Quest flags, reputation, bounty, world_seed, NPC spawn counter — all flat keys in `state.variables`.

**The macro-economy system lives entirely in `state.variables`.** The active economic event is stored as `_active_economic_event` (a dict with `id`, `tag`, `fluctuation`, `tick_start`, `tick_scope`). `economy.py` reads and expires it on every shop price calculation — no dedicated tick hook needed.

**Weather system removed.** Any weather variables (`rain`, `dryness`) or code reading them should be cleaned up.

---

## Module Responsibilities — Quick Reference

| Module | Owns |
|---|---|
| `state.py` | Data shapes only — no logic |
| `commands.py` | Player-input dispatch, all command handlers |
| `api.py` | Content-callable commands (`damage`, `add_effect`, `give`, etc.) |
| `combat.py` | Enemy AI, grid movement, trifecta resolution, spell casting |
| `world.py` | Tile generation, room loading, NPC seeding, schedule resolution |
| `saves.py` | Serialize/deserialize GameState, dirty flush, working directory |
| `clock.py` | `pass_ticks()` — hunger, sleep deprivation, effects forwarded to conditions.py |
| `conditions.py` | Effect tick-down, on_expire, interaction chains |
| `armor.py` | Plate loader + `iter_equipped_plates()` — procs dispatched via `modifiers.fire_event` |
| `scripts.py` | Sandboxed Python executor — AST-validates before exec |
| `api.py` | Single import surface for scripts and content commands |

`commands.py` and `api.py` are intentionally separate to avoid circular imports — player input goes through `commands.py`, authored content goes through `api.py`.

---

## Command Registration

Commands register via decorator in `commands.py`:

```python
@cmd("my_command", ctx=TOWN)
def _my_command(state: GameState, args: list[str]) -> CmdResult:
    ...
    return ok("Some output line.", "Another line.")
```

`ctx` values: `MENU`, `WORLD`, `TOWN`, `DUNGEON`, `COMBAT`, `ANY`

`ok(*lines)` is shorthand for `CmdResult(lines=[...])`.

For panel views and button actions, see the Panel Refresh System section below.

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

- Dirty dict is lazy-loaded in memory on tile visit, flushed immediately on change
- `.sav` file is a ZIP of the working directory, written on sleep/save
- `npc_states` is fully loaded into memory on save load — single source of truth for NPC locations

**Named NPC** — seeded on new game from `starting_tile`, room resolved at runtime from schedule + tick.
**Spawned instance** — generated on first tile visit, ID = `{type}_{counter}` where counter is `variables["_npc_spawn_counter"]`.

---

## Macro-Economy System

Economic events modify buy prices in shops for a duration. Implementation spans three files.

**Storage** — `state.variables["_active_economic_event"]`:
```python
{
    "id":          "iron_shortage",
    "tag":         "iron",          # matches item tags[]
    "fluctuation": 0.4,             # +40% price
    "tick_scope":  200,             # expires after 200 ticks
    "tick_start":  state.player.tick,
}
```
Stored in `variables.json` — persists automatically with the save system. Only one event active at a time.

**Activation** — `engine/api.py: apply_economic_event(state, event_id, force=False)`

Loads `content/economic_events/{id}.json`, stamps `tick_start`, and writes the dict above. Silently no-ops if an event is already active and `force=False`. Also reachable via `run_effect_command` with verb `economic_event <id> [force]`, so it can be triggered from scripts, effect commands, or dialogue inline_scripts.

**Price application** — `engine/economy.py: _adjusted_cost(state, item_id, base_cost)`

Called from `shop_category_lines` (display) and `buy_trade` (transaction). Checks `_active_event()` first — which lazily expires the event if `tick_scope` has elapsed — then checks the item's `tags` list for the event's `tag`. If matched: `max(1, round(base_cost × (1 + fluctuation)))`. Sell prices are not affected.

**Content** — `content/economic_events/<id>.json`, authored in Inkwell under the Economic Events tab and exported by the Menagerie driver.

---

## Perk & Modifier System

Perks are permanent effects (`ticks_remaining == -1`) stored in `PlayerState.effects`. The system has two layers:

**Modifier layer** — read-only derived values. Any engine code that wants to consult a perk calls `_mod.get(state, "key")`, which multiplicatively accumulates `(1 + value)` across all permanent effects that register a value for that key. Returns `1.0` when nothing modifies the key, so it is always safe to multiply into any calculation with no special-casing.

**Event layer** — side-effect hooks. Engine call sites fire named events via `_mod.fire_event(state, "event", entity)`. Each permanent effect that defines `on_<event>` in its JSON has its handler dispatched: either a list of command strings or a `.py` script filename.

### Flow

```
add_effect player perk_id -1        ← grant a perk (ticks_remaining = -1 = permanent)
remove_effect player perk_id        ← revoke a perk

engine call site:
    base_dmg *= _mod.get(state, "spell_damage_pct")     ← modifier read (returns 1.0 if no perk)
    lines += _mod.fire_event(state, "spell_cast")        ← event dispatch + context write
```

### `_mod.get(state, key) → float`

- Iterates `state.player.effects` — skips any without `ticks_remaining == -1`
- For each permanent effect, loads its JSON and reads `data["modifiers"][key]`
- Result = product of `(1.0 + val)` for all contributing effects
- Two perks at `+0.15` → `1.15 × 1.15 = 1.3225`. A perk at `-0.10` → `0.90`.
- Values outside `[-1, ∞)` are valid but use carefully (negative below −1 inverts sign)

### `_mod.fire_event(state, event, self_entity=None) → list[str]`

1. Calls `_write_event_context(state, event, self_entity)` — writes `_`-prefixed variables to `state.variables`
2. Iterates permanent effects; for each that has `on_<event>`:
   - If handler is a `list[str]` — each entry run as a command via `api.run_effect_command`
   - If handler is `"file.py"` — run as a script via `scripts.run_script_file`
3. Returns all narration lines produced by handlers

### Event context — "pre-write" pattern

Some events need data that only exists at the call site (actual damage dealt, attacker's instance id, etc.). The call site writes these to `state.variables` immediately before calling `fire_event`; `_write_event_context` then fills in whatever it can derive from `self_entity`. This keeps `fire_event`'s signature simple while allowing rich context.

Example:
```python
state.variables["_last_hit_damage_actual"] = dmg          # caller writes
state.variables["_last_block_damage_raw"]  = raw_dmg       # caller writes
lines += _mod.fire_event(state, "block", self_entity=e)    # _write_event_context adds attacker type/id
```

### Registered modifier keys

| Key | Where applied | Effect |
|---|---|---|
| `dodge_stamina_cost_pct` | `combat.do_dodge` | Scales stamina cost of dodging |
| `block_reduction_pct` | `combat.do_block` | Scales total block damage reduction |
| `stamina_regen_pct` | `combat._begin_round` | Scales per-round stamina regen |
| `focus_regen_pct` | `combat._begin_round` | Scales per-round focus regen |
| `melee_damage_pct` | `combat.do_attack` | Scales all melee damage |
| `melee_range` | `combat._fire_pending_action` | Multiplier on effective melee reach |
| `{ws}_damage_pct` | `combat.do_attack` | Weapon-skill-specific damage (longblade_damage_pct, etc.) |
| `spell_damage_pct` | `combat._fire_pending_action` | Scales all spell damage |
| `destruction_damage_pct` | `combat._fire_pending_action` | Scales destruction school damage |
| `sneak_roll_pct` | `sneak._stealth_roll` | Scales stealth detection success probability |
| `pickpocket_roll_pct` | `sneak._pickpocket_roll` | Scales pickpocket success probability |
| `sneak_attack_damage_pct` | `sneak.do_stealth_attack` | Scales stealth attack damage |
| `buy_price_pct` | `economy.buy_trade` | Scales buy prices (negative = cheaper) |
| `sell_price_pct` | `economy.sell_item` | Scales sell prices (positive = higher payout) |
| `xp_gain_pct` | `skills.give_xp` | Scales all XP awarded |

### Adding a new modifier hook point

1. Pick a key name (snake_case, descriptive)
2. At the call site: `value *= _mod.get(state, "your_key")`
3. Add a row to the table above and document in README-USAGE.md
4. Perk authors can now set `"modifiers": {"your_key": 0.2}` in their effect JSON

### Adding a new event

1. Pick an event name (snake_case verb)
2. At the call site: write any context to `state.variables`, then call `_mod.fire_event(state, "your_event", entity)`
3. Add a branch in `_write_event_context` in `modifiers.py` to write any context derivable from `self_entity`
4. Add the event to the key reference comment block in `modifiers.py`
5. Document in README-USAGE.md
6. Perk JSON can now define `"on_your_event": [...]`

### Skill system

Flat integer values (0–`SKILL_CAP`=100) per skill, stored in `PlayerState.skills`. Increased by:
- Level-up pick (`levelup_skill <name>` command — adds `SKILL_BUMP=1`)
- Direct trainer/book call: `train_skill player <skill> <amount> [gold_cost]`

Skills feed into engine calculations via `_skills.skill_pct(state, name)` (0.0–1.0 fraction of cap). Engine call sites apply the fraction directly — e.g. `damage *= 1.0 + skill_pct * 0.5` at skill 100 gives +50%.

Level-up XP threshold: `XP_PER_LEVEL=1000`. Each level-up awards one skill pick and one stat pick (health / stamina / focus). Both are tracked as `pending_*_picks` on `PlayerState` and resolved via the `levelup_skill` / `levelup_stat` commands.

---

## Known Gotchas

**`_load_spell()` is defined twice.** `commands.py` has a local copy returning `None`; `combat.py` has a local copy returning `{}`. `spells.py` already has the canonical `load_spell`. Both locals should be deleted and replaced with an import. See STATUS.md todo #1.

**`combat.py` callers assume `{}` on miss.** When the above is fixed, audit `combat.py` call sites — they don't guard against `None`, they expect an empty dict and will KeyError on actual missing spells.

**NPC `starting_tile` must be set before export.** NPCs without it are silently skipped on new game and load. Expected for spawned enemy types (zombie, draugr) — those are seeded via room files, not starting_tile.

**`stale content/enemies/draugr.json`** — old-format file should be deleted. All entities live in `content/npcs/`.

**Input validation is missing throughout `commands.py`.** Handlers index `args[0]` without length checks. Every new command should guard with `if len(args) < N: return err(...)` before indexing.

**`_tick_down_stamina()` in `clock.py` is a stub (`pass`).** Stamina regen is not wired. Melee attack stamina cost also needs wiring. See STATUS.md todos.

---

## IPC Messages

Game thread → Tkinter thread via `ipc.to_tkinter`:

| Message | Payload | Effect |
|---|---|---|
| `PRINT` | `lines: list[str]` | Append lines to scrollback |
| `PANEL_PRINT` | `lines: list[str]` | Print and track as active panel |
| `PANEL_REPLACE` | `fresh, feedback` | Replace panel in place; falls back to `_print_panel` if no panel is active |
| `PANEL_APPEND` | `lines` | Append to current panel (stale buttons) |
| `LOAD_IMAGE` | `path: str` | Load image from file path |
| `LOAD_IMAGE_PIL` | `image: PIL.Image` | Load in-memory PIL composite |
| `PREFILL` | `text: str` | Pre-load input bar with text |
| `HUD_UPDATE` | `stats: dict` | Redraw stat HUD canvas |

Tkinter thread → game thread via `ipc.to_game`:

| Message | Payload |
|---|---|
| `INPUT` | `text: str` — player's submitted command |

---

## Panel Refresh System

Panels are detail views (item info, spell info, etc.) that update **in place** when the player clicks action buttons (equip, unequip, favourite, consume, etc.) rather than reprinting below.

### How it works

`self._panel` in `GameWindow` tracks the single active panel:

```python
self._panel: dict | None = None
# {"lines": [...], "start": int, "num_lines": int}
```

- `lines` — flat list of all strings currently in the panel (original content + any appended feedback lines)
- `start` — row number in the Text widget where the panel begins (fixed at print time, never changes)
- `num_lines` — current number of rows the panel occupies (updated on each refresh)

A new `PANEL_PRINT` replaces `self._panel` entirely. Only the most recently printed panel is tracked.

### Data flow

```
@cmd handler
  └─ mutate state
  └─ fresh = _detail_view(state, [id]).lines    # regenerate from updated state
  └─ return ok(feedback, panel_append=True, panel_lines=fresh)
        │
        ▼
_push()  →  PANEL_REPLACE(fresh_lines, feedback_lines)
        │
        ▼
_poll_ipc  →  _refresh_panel(fresh + feedback)
              └─ delete start_row → start_row + num_lines
              └─ reinsert via RIGHT-gravity mark (advances past each insert)
              └─ update self._panel["num_lines"]
```

### Adding a new panel view

Return `ok(*lines, is_panel=True)` from the handler. The UI handles the rest.

```python
@cmd("thing_info", ctx=ANY, hidden=True)
def _thing_info(state, args):
    thing_id = args[0]
    lines = [name, "─" * len(name), "", ...]
    lines.append(f"  [[Do Action:action {thing_id}]]")
    return ok(*lines, is_panel=True)
```

### Adding a new button action

Two requirements:
1. `panel_append=True`
2. `panel_lines=` fresh panel lines computed **after** the state mutation

```python
@cmd("action", ctx=ANY, hidden=True)
def _action(state, args):
    thing_id = args[0]
    # 1. mutate state
    state.things[thing_id].active = True
    # 2. regenerate panel from the now-updated state
    fresh = _thing_info(state, [thing_id]).lines
    return ok("Did the thing.", panel_append=True, panel_lines=fresh)
```

If the action **removes the subject** (e.g. consuming the last of an item), pass `panel_lines=None`. The system falls back to `PANEL_APPEND`, appending feedback to the stale panel without regenerating buttons.

```python
    items.take_item(state, item_id)
    fresh = _inventory(state, ["item", item_id]).lines if items.has_item(state, item_id) else None
    return ok(f"You use {name}.", *effect_lines, panel_append=True, panel_lines=fresh)
```

### Need-to-remembers

**Mutation before regeneration.** `panel_lines` must be computed *after* state is mutated. The panel-generator reads live state to produce correct buttons.

**`start_row` is fixed.** It is recorded when the panel is first printed and never updated. Only `num_lines` changes on each refresh. This is safe because all text is appended at `tk.END` — nothing is ever inserted before the panel's row.

**`self._panel` is never explicitly cleared.** A new `PANEL_PRINT` replaces it; everything else leaves it in place. If a panel is buried in scrollback and a button in it is clicked, the refresh still targets the correct rows (by line number). Consider clearing `self._panel = None` on `LOAD_LOCATION` or context changes if stale in-place refreshes become a problem.

**The `>` echo accumulates outside the panel.** `_on_link_click` prints the command echo synchronously before the game thread responds. The echo lands at `tk.END` (after the panel's tracked region) and is never included in `start_row`/`num_lines`. Clicking the same panel multiple times leaves one echo line per click in the scrollback below the panel.

**Feedback is consumed into `num_lines`.** `_refresh_panel` receives `fresh + feedback` concatenated and tracks the total as the new `num_lines`. On the next refresh, feedback from the previous click is deleted as part of the panel. This is the correct behavior for pick-prompt panels (clean replacement each pick), but means confirmation messages disappear when the next button is clicked.

**`PANEL_REPLACE` with no prior panel falls back to `_print_panel`.** When `self._panel is None` — e.g. a level-up pick prompt arrived as regular `PRINT` text rather than via a `skills` panel — the first button click calls `_print_panel` on the fresh content, setting it up as the new active panel. Subsequent clicks replace it correctly. The original prompt text in the scrollback is not removed. To avoid this fallback entirely, commands that produce pick prompts should return `is_panel=True` when picks are pending (so the output is a proper panel from the start, not regular text).

**Silent error swallowing.** `_refresh_panel` is called inside `_poll_ipc`'s broad `except Exception: pass`. Any Tkinter error during the delete/reinsert (wrong index, widget state issue, etc.) is silently dropped and the panel is not updated. If a refresh appears to do nothing, add a temporary `except Exception as e: print(e)` around the `_refresh_panel` call to surface the error.

**Queue length is 1 by design.** Supporting multiple tracked panels would require associating each button link with the specific panel it came from (e.g. embedding a panel ID in the command string). Not currently implemented.

### Relevant files

| File | What to touch |
|---|---|
| `engine/commands.py` | Add `is_panel=True` to panel views; add `panel_append=True, panel_lines=fresh` to button actions |
| `engine/game_loop.py` | `_push()` routes results to the correct IPC message — no changes needed for new commands |
| `ui/text_window.py` | `_print_panel`, `_refresh_panel`, `_poll_ipc` — only touch if changing the refresh mechanism itself |
