# Menagerie — Content & Tools Guide

Text-based RPG. Nim / SDL2 — statically linked binary, no install requirements.

**Run:** `./menagerie`

Plans and design docs are in `plans/`. `plans/STATUS.md` is the live project state.

---

## Table of Contents

- [How Content Works](#how-content-works)
- [Content Folders](#content-folders-engine-reads-these)
- [NPC & Enemy Fields](#npc--enemy-fields-contentnpcsidJson)
- [Dialogue](#dialogue)
- [Items](#items-contentitemsidJson)
- [Spells](#spells-contentspellsidJson)
- [Effects](#effects-contenteffectsidJson)
- [Perks](#perks)
  - [Authoring a perk](#authoring-a-perk)
  - [Modifier keys](#modifier-keys)
  - [Perk events](#perk-events)
  - [Reading event variables in scripts](#reading-event-variables-in-scripts)
- [Armor Plates](#armor-plates-contentarmor_platesidJson)
  - [Event hooks](#event-hooks)
  - [Effect procs](#effect-procs)
- [AI Packages](#ai-packages-contentai_packagesidJson)
  - [Condition Syntax](#condition-syntax)
  - [Action Types](#action-types)
- [Shops](#shops-contentshopsidJson)
- [Economic Events](#economic-events-contenteconomic_eventsidJson)
- [Quest Variables](#quest-variables)
- [Command API](#command-api)
  - [Target Selectors](#target-selectors)
  - [Commands](#commands)
- [Scripts](#scripts)
  - [Flat Command Syntax](#flat-command-syntax)
  - [Lua Logic](#lua-logic)
  - [Available Functions](#available-functions)
  - [Restrictions](#restrictions-sandbox)

---

## How Content Works

The engine is a pure interpreter. All creative content lives in `content/` as compiled JSON. The engine reads these files at runtime and never writes back to them. To change content, you author in the tools and export — you do not edit `content/` directly.

```
world-tools/drivers/    Lua 5.4 export drivers (world, rooms, gameplay_vars, menagerie, assets)
inkwell/                NPC, dialogue, items, effects, armor, quests, AI packages (external tool)
mod_manager             SDL2 binary; manages plugin load order per tool, one-click Export All
```

Plugin source files live in `data/<modpack>/<PluginFolder>/<plugin>.json`. Running **Export All** in the mod manager calls each Lua driver in load order and writes everything to `content/`.

---

## Content Folders (engine reads these)

| Folder | Contents |
|---|---|
| `content/npcs/` | NPC + enemy JSON (all entities in one folder) |
| `content/items/` | Item definitions |
| `content/spells/` | Spell definitions |
| `content/effects/` | Status effect definitions |
| `content/armor_plates/` | Armor plate definitions |
| `content/ai_packages/` | Combat AI packages |
| `content/shops/` | Shop definitions |
| `content/economic_events/` | Economic event definitions |
| `content/quests/` | Quest variable definitions |
| `content/scripts/` | `.lua` script files referenced by content |
| `content/rooms/` | Room definitions |
| `content/tiles/` | Tile composition files for named locations |
| `content/world/` | `world_def.json` — road network and named tile placement |
| `content/images/` | Room/location images |

---

## NPC & Enemy Fields (`content/npcs/<id>.json`)

Named NPCs (blacksmith, farmer) and spawned enemies (zombie, draugr) live in the same folder. The distinction:

- **Named NPC** — unique, has `starting_tile`, room resolved from schedule at runtime
- **Spawned instance** — template, no `starting_tile`, placed by room files, gets ID `{type}_{counter}` on first spawn

> **Gotcha:** do not set `starting_tile` on a spawned enemy type. If you do, the engine places it on the tile as a named NPC *and* spawns a separate instance from the room's `enemies` array — putting two in combat instead of one.

| Field | Description |
|---|---|
| `id` | Unique identifier — must match filename |
| `name` | Internal name |
| `display_name` | Shown to player |
| `mob_type` | `"npc"` or `"enemy"` |
| `faction` | Faction ID string — drives bounty system and combat enrollment |
| `is_hostile` | `true` → attacks on sight |
| `health` | Max health |
| `damage` | Base melee damage |
| `stamina` | `{"max": N, "regen": N}` |
| `focus` | `{"max": N, "regen": N}` |
| `starting_tile` | Tile ID for named NPCs only — leave empty for spawned enemy templates. Setting this on a room enemy type causes it to appear twice in combat (once as a named NPC, once as a spawned instance). |
| `schedule` | Dict of `tile_id → [{tick, room}, ...]` — room resolved at runtime |
| `combat_ai_package` | ID of AI package in `content/ai_packages/` |
| `loot_table` | `[{"item": id, "amount": N, "chance": 0-100}, ...]` — rolled on death |
| `inventory` | Items the NPC carries (weapons used in combat, items for trade) |
| `dialogue` | Inline dialogue definition or reference |
| `death_script` | Filename of `.lua` script in `content/scripts/` — runs on death |

---

## Dialogue

Morrowind-style topic system. Built in Inkwell. Topics are menu items the player can select.

| Field | Description |
|---|---|
| `topic` | Internal ID |
| `display_name` | Label shown in topic menu |
| `dialogue_text` | Text printed when selected |
| `variable_conditions` | `[{"var": "key", "op": "gte", "value": 5}]` — hide topic if not met |
| `variable_changes` | `[{"var": "key", "op": "set/add/sub", "value": N}]` — run on selection |
| `inline_script` | Array of flat command lines run on selection |
| `show_topics` | List of topic IDs to reveal after this selection |
| `hidden_from_menu` | `true` → topic doesn't appear in menu (only reachable via `show_topics`) |
| `shop` | Shop ID to open (`content/shops/<id>.json`) |

---

## Items (`content/items/<id>.json`)

| Field | Description |
|---|---|
| `id` | Must match filename |
| `name` / `display_name` | Internal / shown name |
| `type` | `"weapon"` \| `"shield"` \| `"armor"` \| `"consumable"` \| `"material"` \| `"quest"` \| `"currency"` |
| `slot_cost` | Inventory slots occupied (0 for currency) |
| `value` | Base trade value |
| `can_equip` | `true` → stored as individual entries (never stacked); can be in both hands |
| `damage` | Weapon: damage added to melee attack |
| `stamina_cost` | Weapon: stamina cost per attack |
| `shield_strength` | Shield: flat damage reduction on all incoming hits while equipped |
| `effects` | Consumable: list of command strings run on use — item removed after |
| `on_use_commands` | Same as `effects` (alternate field name) |
| `tags` | List of plain string tags — used by the macro-economy system to match price fluctuation events (e.g. `["iron", "weapon", "sword"]`) |
| `description` | Flavor text |

---

## Spells (`content/spells/<id>.json`)

| Field | Description |
|---|---|
| `id` | Must match filename |
| `name` / `display_name` | Internal / shown name |
| `cast_type` | `"enemy"` (damage spell) \| `"aux"` (positional, no focus cost) |
| `damage` | Base damage — smite multiplier is 1.0, beam 0.6, wave 0.35 |
| `focus_cost` | Focus spent to cast (default 20; aux spells ignore this) |
| `duration` | Spell-global effect duration in ticks (to be refactored to per-effect) |
| `effects` | `[{"effect": "<id>", "ticks": N}, ...]` — applied to each target hit |
| `on_hit_commands` | Command strings run on each target hit |
| `on_hit_script` | Filename of `.lua` script in `content/scripts/` run on each hit |
| `upgrades` | Future — upgrade definitions |
| `relations` | `{"other_spell_id": weight}` — for archetype-weighted spell discovery |

**Cast modes** (chosen at cast time):

| Mode | Damage mult | Targets |
|---|---|---|
| `smite` | 100% | Single enemy at `row` + `dist` |
| `beam` | 60% | All enemies on `row` |
| `wave` | 35% | All enemies within ±1 row |
| `trap` | 200% (delayed) | Single cell — fires next round if occupied |

Note: individual spell cooldowns are designed but not yet implemented.

---

## Effects (`content/effects/<id>.json`)

| Field | Description |
|---|---|
| `id` | Must match filename |
| `name` / `display_name` | Internal / shown name |
| `tick_commands` | Commands run each tick while active |
| `on_apply_commands` | Commands run once when first applied |
| `on_expire_commands` | Commands run once when duration reaches 0 |
| `interactions` | List of interaction objects (see below) |
| `description` | Flavor text |
| `modifiers` | *(perk only)* Dict of float modifier values — see Perks section |
| `on_<event>` | *(perk only)* Event handler — list of commands or `"script.lua"` — see Perk Events |

**Interactions** — fire when this effect is applied to a target that already has another effect:

```json
"interactions": [
  {
    "effect_id": "bleed",
    "result_id": "bloodchryst",
    "duration": 100,
    "consumes": ["bleed"]
  }
]
```

If the target has `bleed` when this effect is applied, `bloodchryst` is added for 100 ticks and `bleed` is removed. First match wins.

---

## Perks

Perks are **permanent effects** — regular effect JSON files granted with a duration of `-1`. The engine identifies permanents by `ticks_remaining == -1` and never ticks them down.

**Grant / revoke:**
```
add_effect player perk_id -1       ← permanent (perk)
remove_effect player perk_id
```

These can be called from any script, dialogue `inline_script`, or item `on_use_commands`.

### Authoring a perk

```json
{
  "id": "perk_iron_skin",
  "display_name": "Iron Skin",
  "description": "Your skin hardens. You block more damage and recover faster.",
  "modifiers": {
    "block_reduction_pct": 0.20,
    "stamina_regen_pct":   0.10
  },
  "on_kill": [
    "set_stat player health +5",
    "print The kill invigorates you."
  ]
}
```

- `modifiers` — float delta values applied multiplicatively. `0.20` means ×1.20 on top of the base. Multiple perks with the same key stack: two at `+0.15` → `1.15 × 1.15 = 1.3225`. Negative values reduce: `-0.10` → ×0.90.
- `on_<event>` — runs when that engine event fires while this perk is active. Value is either a list of command strings (same surface as `tick_commands`) or a single `"filename.lua"` string pointing to a script in `content/scripts/`.

### Modifier keys

All modifier values are multiplicative deltas (`0.0` = no change, `0.2` = +20%, `-0.1` = −10%).

| Key | Affects | Notes |
|---|---|---|
| `dodge_stamina_cost_pct` | Dodge stamina cost | Negative = cheaper dodge |
| `block_reduction_pct` | Block damage absorption | Scales on top of skill-derived reduction |
| `stamina_regen_pct` | Per-round stamina regen in combat | |
| `focus_regen_pct` | Per-round focus regen in combat | |
| `melee_damage_pct` | All melee attacks | |
| `melee_range` | Effective melee reach | Multiplier on enemy melee_range threshold |
| `longblade_damage_pct` | Longblade attacks only | |
| `shortblade_damage_pct` | Shortblade attacks only | |
| `longblunt_damage_pct` | Longblunt attacks only | |
| `shortblunt_damage_pct` | Shortblunt attacks only | |
| `archery_damage_pct` | Archery attacks only | *(future)* |
| `spell_damage_pct` | All spells | |
| `destruction_damage_pct` | Destruction school spells only | Stacks with `spell_damage_pct` |
| `sneak_roll_pct` | Stealth detection roll probability | |
| `pickpocket_roll_pct` | Pickpocket success probability | |
| `sneak_attack_damage_pct` | Stealth attack damage | |
| `buy_price_pct` | Shop buy prices | Negative = cheaper |
| `sell_price_pct` | Shop sell prices | Positive = higher payout |
| `xp_gain_pct` | All XP awarded | |

### Perk events

Engine call sites fire named events at key moments. When an event fires, the engine writes context variables to the global variable store before running your handler — read them like any other variable in scripts.

**Handler formats:**
```json
"on_kill": ["set_stat player health +5", "print You feel renewed."]
"on_kill": "on_kill_handler.lua"
```

#### Event reference

---

**`combat_start`** — fires at the beginning of every combat encounter.

Context written (all reset to 0):

| Variable | Type | Description |
|---|---|---|
| `_kills_this_combat` | int | Kill counter for this fight |
| `_damage_taken_this_combat` | float | Cumulative damage taken |
| `_damage_dealt_this_combat` | float | Cumulative damage dealt |
| `_spells_cast_this_combat` | int | Spell cast counter |
| `_dodges_this_combat` | int | Successful dodge counter |
| `_blocks_this_combat` | int | Blocked hit counter |

---

**`kill`** — fires when an enemy dies. `self_entity` = the killed enemy.

| Variable | Type | Description |
|---|---|---|
| `_last_kill_id` | str | Instance id of the killed enemy (e.g. `zombie_21`) |
| `_last_kill_type` | str | Enemy `type` field from NPC JSON |
| `_last_kill_faction` | str | Enemy `faction` field |
| `_kills_this_combat` | int | Incremented |

---

**`hit_received`** — fires after each enemy melee hit lands on the player.

| Variable | Type | Description |
|---|---|---|
| `_last_hit_source_id` | str | Attacker instance id |
| `_last_hit_source_type` | str | Attacker `type` field |
| `_last_hit_damage_raw` | float | Attacker base damage stat (before block/shield reductions) |
| `_last_hit_damage_actual` | float | Actual HP lost (post block + shield reductions) |
| `_damage_taken_this_combat` | float | Cumulative, incremented by actual damage |

---

**`hit_landed`** — fires after the player's attack or spell deals damage.

| Variable | Type | Description |
|---|---|---|
| `_last_hit_damage_dealt` | float | Total damage dealt this swing or cast |
| `_last_hit_target_id` | str | Instance id of the first/primary target |
| `_last_hit_target_count` | int | Number of targets hit (1 for melee, N for AoE spells) |
| `_damage_dealt_this_combat` | float | Cumulative, incremented by this hit |

---

**`dodge_chosen`** — fires when the player selects dodge as their action. No attacker is known yet — the token hasn't been consumed.

| Variable | Type | Description |
|---|---|---|
| `_dodges_this_combat` | int | Incremented |

---

**`dodge_consumed`** — fires when the dodge token is actually spent absorbing a hit during resolution. `self_entity` = the attacker whose strike was dodged.

| Variable | Type | Description |
|---|---|---|
| `_last_dodge_attacker_id` | str | Attacker instance id |
| `_last_dodge_attacker_type` | str | Attacker `type` field |
| `_last_dodge_damage_avoided` | float | Raw damage that would have landed |

---

**`block`** — fires once per enemy hit that was blocked during resolution. `self_entity` = the attacker. If multiple enemies attack while you are blocking, this fires once per hit.

| Variable | Type | Description |
|---|---|---|
| `_last_block_attacker_id` | str | Attacker instance id |
| `_last_block_attacker_type` | str | Attacker `type` field |
| `_last_block_damage_raw` | float | Raw damage before block and shield |
| `_last_block_damage_taken` | float | Actual HP lost after all reductions |
| `_last_block_mitigated` | float | Amount absorbed (raw − taken) |
| `_blocks_this_combat` | int | Incremented |

---

**`spell_cast`** — fires when a spell is committed (before resolution, when focus is spent).

| Variable | Type | Description |
|---|---|---|
| `_last_spell_id` | str | Spell id that was cast |
| `_last_cast_mode` | str | `smite` / `beam` / `wave` / `trap` |
| `_spells_cast_this_combat` | int | Incremented |

---

**`effect_received`** — fires when a new effect is applied to the player (not on duration refresh). Armor effect procs fire at the same moment but are handled separately — this event is for perk scripts that want to react to any incoming effect.

| Variable | Type | Description |
|---|---|---|
| `_last_effect_received` | str | Effect ID just applied |
| `_last_effect_duration` | int | Duration applied for (`-1` = permanent) |
| `_effects_received_this_combat` | int | Cumulative count this fight, incremented |

---

**`level_up`** — fires once per level gained.

| Variable | Type | Description |
|---|---|---|
| `_new_level` | int | Level just reached |

---

**`combat_end`** — fires when the last enemy is killed and combat concludes.

| Variable | Type | Description |
|---|---|---|
| `_combat_kills` | int | Snapshot of `_kills_this_combat` |
| `_combat_damage_dealt` | float | Snapshot of `_damage_dealt_this_combat` |
| `_combat_damage_taken` | float | Snapshot of `_damage_taken_this_combat` |
| `_combat_spells_cast` | int | Snapshot of `_spells_cast_this_combat` |
| `_combat_dodges` | int | Snapshot of `_dodges_this_combat` |
| `_combat_blocks` | int | Snapshot of `_blocks_this_combat` |
| `_combat_effects_received` | int | Snapshot of `_effects_received_this_combat` |
| `_combat_rounds` | int | Number of rounds the fight lasted |

---

**`flee`** — fires when the player successfully flees combat.

| Variable | Type | Description |
|---|---|---|
| `_flee_enemy_count` | int | Number of enemies alive at time of fleeing |
| `_flee_enemy_ids` | str | Comma-separated instance ids of surviving enemies |

---

### Reading event variables in scripts

All `_`-prefixed event variables are readable directly via the `get_var` helper in `.lua` scripts, the same as any other game variable:

```lua
if get_var("_kills_this_combat") >= 3 then
    add("fervor", 1)
    msg("A battle frenzy takes hold.")
end
```

```lua
if get_var("_last_hit_damage_actual") > 20 then
    msg("A powerful blow!")
    add_effect("player", "stunned", 1)
end
```

```lua
if get_var("_last_kill_faction") == "undead" then
    set_stat("player", "health", "+10")
    msg("Holy light flows through you.")
end
```

---

## Armor Plates (`content/armor_plates/<id>.json`)

| Field | Description |
|---|---|
| `id` | Must match filename |
| `name` / `display_name` | Internal / shown name |
| `zone` | Slot: `"head"` \| `"chest"` \| `"torso"` \| `"arms"` \| `"legs"` |
| `material` | Determines base tier |
| `defense` | Flat defense value |
| `value` | Trade value |
| `procs` | List of proc objects (see below) |

Armor plates have two independent hook systems that can be used together.

### Event hooks

Define `on_<event>` fields directly on the plate JSON — same format as perks, same commands, same variables in scripts. Any engine event works.

```json
{
  "id": "iron_chest",
  "display_name": "Iron Chestplate",
  "zone": "chest",
  "defense": 5,
  "value": 20,
  "on_hit_received": ["add_effect player regen 3"],
  "on_kill": ["set_stat player health +5"]
}
```

See the **Perk Events** section for the full event list and context variables.

### Effect procs

A separate `effect_procs` array specifically for reacting to effects being applied to the wearer. Each entry names the effect and the commands to run — no event name needed, this list is always and only for effect reactions.

```json
"effect_procs": [
  {
    "effect": "bleed",
    "consume": true,
    "commands": ["add_effect player regen 5", "print The plate drinks the wound."]
  },
  {
    "effect": "fire",
    "consume": false,
    "chance": 50,
    "commands": ["add_effect player ember_shell 3"]
  }
]
```

| Field | Type | Description |
|---|---|---|
| `effect` | str | Effect ID that triggers this proc |
| `commands` | list[str] | Commands to run |
| `consume` | bool | If `true`, remove the triggering effect after all procs for it have fired |
| `chance` | int | Optional 0–100 roll gate — omit or set to 100 for guaranteed |

- Fires on **both new application and duration refresh** — any time the effect lands.
- Multiple procs can match the same effect (across multiple plates or multiple entries). All matching procs fire before any consume happens.
- Works on **enemies** too — enemies have no equip slots, so any armor-type item in their inventory is treated as worn.
- The `effect_received` perk event fires at the same moment (player only) — readable via `_last_effect_received` in scripts.

---

## AI Packages (`content/ai_packages/<id>.json`)

Referenced from NPC JSON via `"combat_ai_package": "<id>"`. Defines how an enemy behaves in the spatial combat grid.

```json
{
  "id": "basic_melee",
  "action_tables": [
    { "condition": "self_dist > 1",  "actions": [{"action": "advance", "weight": 1}] },
    { "condition": "self_dist == 1", "actions": [{"action": "attack",  "weight": 1}] },
    { "condition": "fallback",       "actions": [{"action": "advance", "weight": 1}] }
  ]
}
```

Tables are checked top-to-bottom. First match wins. Actions within a matching block are weighted-random. Always end with a `fallback` block.

**No telegraphs.** Enemy movement is not announced to the player — players read the grid and predict based on distance, row, and known speed.

### Condition Syntax

```
<lhs> <op> <rhs>
```
Operators: `<` `<=` `>` `>=` `==` `!=`

AND chain (spaces around `AND` required):
```
self_dist > 1 AND self_health < 50
```

**LHS values:**

| Value | Description |
|---|---|
| `self_dist` | Enemy distance from player (1–9); melee at 1 |
| `self_row` | Enemy row (1–9) |
| `self_health` | Enemy health as % of max (0–100) |
| `self_stamina` | Enemy current stamina |
| `self_focus` | Enemy current focus |
| `player_health` | Player health (raw) |
| `player_stamina` | Player stamina (raw) |
| `player_focus` | Player focus (raw) |
| `enemies_at_dist1` | Count of all enemies currently at distance 1 |
| `var.<name>` | Any game variable (cast to float) |

**Special conditions (no operator):**

| Condition | True when |
|---|---|
| `fallback` | Always — use as the final catch-all |
| `player_has:<effect_id>` | Player currently has the named effect |
| `player_last_action:<action>` | Player's last action was `dodge`, `block`, `cast`, or `attack` |

### Action Types

| Action | Parameters | Description |
|---|---|---|
| `advance` | — | Move toward player by enemy speed |
| `end_turn` | — | Do nothing this round |
| `retreat` | `amount: N` | Move away N cells (default 2) |
| `sidestep` | `row: N` | Move to row N |
| `attack` | `cost: {stamina: N}` | Commit to melee attack (fires at distance 1) |
| `cast` | `cost: {focus: N}` | Commit to a cast attack |

All actions accept `"weight": N` (default 1).

---

## Shops (`content/shops/<id>.json`)

Referenced from NPC dialogue via `"shop": "<id>"`.

```json
{
  "id": "blacksmith",
  "categories": [
    {
      "name": "Weapons",
      "items": [
        {"id": "iron-sword", "price": 3, "currency": "currency"}
      ]
    }
  ]
}
```

`currency` is the item ID accepted as payment.

---

## Economic Events (`content/economic_events/<id>.json`)

Macro-economy events that modify shop buy prices for items matching a tag. Authored in Inkwell and exported by the Menagerie driver.

| Field | Description |
|---|---|
| `id` | Must match filename |
| `tag` | The item tag this event targets (matches against item `tags` lists) |
| `fluctuation` | Price multiplier delta, `-1.0` to `1.0`. Final price = `base × (1 + fluctuation)`, minimum 1 |
| `tick_scope` | How many ticks the event remains active after it is triggered |

Events are activated via the `economic_event` command (see Command API below) and stored in `state.variables["_active_economic_event"]` with `tick_start` stamped at activation. The event is automatically expired once `tick_scope` ticks have elapsed — this check happens lazily when a shop is browsed or a purchase is made.

Only one event can be active at a time. Triggering a new event while one is active is a no-op unless `force` is passed.

---

## Quest Variables

Quests are not tracked by the engine — they are just variables in `state.variables`. A quest is a set of flags that get set as the player progresses through dialogue and scripts.

Variable naming convention: `category-name` (accessible via `get_var("category-name")` in Lua scripts).

Example: `farmer-disposition` → readable as `farmer_disposition` in scripts, `farmer-disposition` in variable_conditions JSON.

Quest definitions in `content/quests/<id>.json` are documentation only — they list the variables a quest uses. Progression is entirely driven by dialogue topics and scripts.

---

## Command API

All effect `tick_commands`, spell `on_hit_commands`, armor proc `commands`, and scripts share the same command surface via `engine/api.nim`.

### Target Selectors

| Selector | Resolves to |
|---|---|
| `player` | The player |
| `enemy.self` | The entity the effect/command is running on |
| `enemy.all` | Every living enemy in current combat |
| `enemy.<id>` | Specific enemy by instance ID or label (case-insensitive) |

### Commands

```
damage          <target> <amount> [stat]
add_effect      <target> <effect_id> <duration>
remove_effect   <target> <effect_id>
set_stat        <target> <stat> <value>        stat: health | stamina | focus | hunger | fatigue
give            <target> <item_id> [amount]
move_npc        <npc_id> <tile>
print           [<target>] <text...>
cast            <mode> <spell_id> <row> [dist]
economic_event  <event_id> [force]
```

**Script files** — any command entry ending in `.lua` is treated as a script filename and run through the Lua engine. Works in every command field (`tick_commands`, `on_apply_commands`, proc commands, event hook commands, etc.):
```
satchel.lua
on_kill_handler.lua
```

**`damage`** — deal damage to health (default), stamina, or focus:
```
damage player 10
damage enemy.self 5 stamina
damage enemy.all 3 focus
```

**`add_effect`** — apply an effect for N ticks:
```
add_effect player burning 3
add_effect enemy.self stunned 2
```

**`set_stat`** — set or adjust any stat, absolute or relative, clamped to `[0, max]`:
```
set_stat player health 50
set_stat player health +20
set_stat player stamina -5
set_stat enemy.self focus +10
```
Shorthands `set_health`, `set_stamina`, `set_focus` also work and are equivalent.

**`give`** — give item(s) to the player:
```
give player satchel
give player gold 5
```

**`move_npc`** — relocate a named NPC to a tile (takes effect on next room entry):
```
move_npc town-villager spawn
```

**`print`** — emit a narration line:
```
print The ground shakes.
```

**`cast`** — fire a spell (from armor proc or script):
```
cast beam death 5
cast smite frost 3 2
cast wave bleed 4
```

**`economic_event`** — activate an economic event by ID. Prices in all shops are adjusted for items whose `tags` include the event's `tag`. The event expires automatically after `tick_scope` ticks. Silently ignored if another event is already active; pass `force` to override:
```
economic_event iron_shortage
economic_event iron_shortage force
```

---

## Scripts

Scripts are `.lua` files in `content/scripts/`. Triggered via `death_script` in NPC JSON or `inline_script` in dialogue topics. Run through the embedded Lua 5.4 engine.

### Flat Command Syntax

Command fields (`tick_commands`, `on_apply_commands`, `inline_script`, etc.) accept a list of command strings. Each string is one command verb + args:

```
damage player 10
add_effect player burning 3
remove_effect player burning
set_stat player health 50
set_stat player health +20
give player satchel
give player satchel 3
move_npc town-villager spawn
msg You find a satchel on the corpse.
take satchel
set quest_done 1
add farmer-disposition 5
sub bounty 1
```

### Lua Logic

Script files are full Lua 5.4. Game functions are available as globals. Use `get_var` / `set_var` to read and write game variables.

```lua
if get_var("farmer_disposition") >= 10 then
    msg("You already know this person well.")
else
    give("player", "gold", 5)
    add_var("farmer-disposition", 5)
    msg("They hand you something.")
end
```

### Available Functions

```lua
damage(selector, amount)
damage(selector, amount, stat)           -- stat: "health" | "stamina" | "focus"
add_effect(selector, effect_id, duration)
remove_effect(selector, effect_id)
set_stat(selector, stat, value)          -- stat: "health" | "stamina" | "focus" | "hunger" | "fatigue"
give(selector, item_id)
give(selector, item_id, amount)
move_npc(npc_id, tile)
msg(text)
take(item_id)
get_var(name)                            -- read a game variable
set_var(name, value)                     -- write a game variable
add_var(name, amount)                    -- add to a numeric variable
sub_var(name, amount)                    -- subtract from a numeric variable
```
