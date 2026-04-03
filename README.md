# Menagerie

A text RPG engine. Spatial grid combat, Morrowind-style topic dialogue, a persistent open world, and a content pipeline for authoring everything from NPCs to spell interaction chains.

The engine is a pure interpreter - all game content lives in `/content/` as compiled JSON. The game itself is separate from the engine and not included here.

**Python 3.11+ / Tkinter - no external dependencies.**

```
python menagerie.py
```

---

## Engine Features

**Combat** - Turn-based spatial grid. Enemies occupy rows and distances. You see their positions and react. Resources (health, stamina, focus) form a trifecta: spending one recovers the others. Spells have cast modes (smite, beam, wave, trap) and chain into interaction combos via the effect system.

**World** - Tile grid with deterministic procedural generation. Named locations (towns, dungeons, crossroads) hand-placed via editor. Road travel auto-pathfinds along the network. Wilderness is manual tile-by-tile exploration.

**Dialogue** - Topic-based keyword dialogue (Morrowind-style). Condition-gated topics, variable changes on selection, inline scripting, shop triggers. Built in Inkwell.

**Effects** - Status effects with tick commands, on-apply/on-expire hooks, and interaction chains. Two effects meeting on the same target can combine into a third.

**Saves** - Working directory always current, written on the fly. Full save is a ZIP on sleep. Dirty cache for per-tile persistence. Crash-safe.

---

## Toolchain

Content is authored in separate tools and compiled to `/content/` via export drivers. The engine never sees plugin files.

- **Inkwell** (https://github.com/ItsNotPaths/Inkwell) - NPC, dialogue, items, effects, armor plates, AI packages, quests
- **Spell Editor** - Node graph editor for spell authoring and relation weighting
- **World Editor / Room Editor** - Tile map, road network, room presets
- **Mod Manager** (`mod_manager.py`) - Plugin load order, enable/disable, one-click Export All

---

## Structure

```
engine/       core game logic
ui/           Tkinter frontend
content/      compiled runtime content (JSON)
world-tools/  editors and export drivers
saves/        save files
plans/        design documentation
```

`plans/STATUS.md` is the live implementation status and todo list.
