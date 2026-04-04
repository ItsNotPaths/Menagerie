# Menagerie

A text RPG engine. Spatial grid combat, Morrowind-style topic dialogue, a persistent open world, and a content pipeline for authoring everything from NPCs to spell interaction chains.

The engine is a pure interpreter — all game content lives in `content/` as compiled JSON. The game itself is separate from the engine and not included here.

**Nim / SDL2. Statically linked — no install requirements.**

```
./menagerie
```

---

## Engine Features

**Combat** — Turn-based spatial grid. Enemies occupy rows and distances. You see their positions and react. Resources (health, stamina, focus) form a trifecta: spending one recovers the others. Spells have cast modes (smite, beam, wave, trap) and chain into interaction combos via the effect system.

**World** — Tile grid with deterministic procedural generation. Named locations (towns, dungeons, crossroads) hand-placed via editor. Road travel auto-pathfinds along the network. Wilderness is manual tile-by-tile exploration.

**Dialogue** — Topic-based keyword dialogue (Morrowind-style). Condition-gated topics, variable changes on selection, inline scripting, shop triggers. Built in Inkwell.

**Effects** — Status effects with tick commands, on-apply/on-expire hooks, and interaction chains. Two effects meeting on the same target can combine into a third.

**Saves** — Working directory always current, written on the fly. Full save is a ZIP on sleep. Dirty cache for per-tile persistence. Crash-safe.

---

## Toolchain

Content is authored in separate tools and compiled to `content/` via Lua export drivers. The engine never sees plugin files.

- **Inkwell** (https://github.com/ItsNotPaths/Inkwell) — NPC, dialogue, items, effects, armor plates, AI packages, quests
- **Mod Manager** (`mod_manager`) — SDL2 binary; plugin load order per tool, enable/disable, one-click Export All; calls Lua drivers statically linked into the binary
- **World / Room / Vars / Spell editors** — planned Nim/SDL2 applets (see `plans/nim_world_tools.md`)

Export drivers live in `world-tools/drivers/` as Lua 5.4 scripts. The mod manager links Lua 5.4 statically (via `onelua.c`) and calls each driver's `export()` function.

---

## Structure

```
src/                        engine + UI source (Nim)
  menagerie.nim             entry point
  engine/                   game logic (state, combat, world, saves, ...)
  commands/                 player-input handlers split by context
  ui/                       SDL2 window, IPC channels
content/                    compiled runtime content (JSON) — written by drivers
data/                       plugin source files (authored content)
  <modpack>/
    <PluginFolder>/
      <plugin>.json
world-tools/
  drivers/                  Lua 5.4 export drivers (world, rooms, gameplay_vars, menagerie, assets)
  mod_manager/              mod manager source (Nim/SDL2)
vendor/                     SDL2, SDL2_ttf, Lua source — downloaded by download-deps.sh
docker-build/               release build scripts and Dockerfile
plans/                      design documentation
saves/                      save files
```
