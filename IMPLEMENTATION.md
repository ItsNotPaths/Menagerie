# Menagerie — Nim/SDL2 Frontend: Implementation Guide

A reference for anyone porting the Python/Tkinter Menagerie codebase to this Nim/SDL2 stack. This document covers architectural decisions, technology mappings, patterns, and gotchas.

---

## Technology Stack

| Concern | Python original | Nim port |
|---|---|---|
| GUI framework | Tkinter (ttk) | SDL2 (via `sdl2` nimble package) |
| Image loading | Pillow (PIL) | SDL2_image |
| Font rendering | Tkinter font | SDL2_ttf |
| Scripting | Python (game logic in-process) | Lua 5.4 (embedded via amalgamation) |
| Layout | `ttk.PanedWindow` | Manual sash rect math |
| Text widget | `tk.Text` | Custom span renderer |
| Input | `tk.Entry` | SDL `TextInput` events |

---

## Project Layout

```
menagerie-nim-frontend-proto/
├── src/
│   ├── menagerie.nim       # Main: window, event loop, rendering
│   └── scripting.nim       # Lua bridge (ScriptEngine, bindings)
├── vendor/
│   ├── lua/src/            # Lua 5.4 source (onelua.c + headers)
│   └── sdl/                # Bundled SDL2/SDL2_ttf/SDL2_image .so files
├── data/
│   └── base-game/
│       ├── assets/         # Images (rooms, sprites, tiles)
│       └── scripts/        # Lua scripts
├── SpaceMono-Regular.ttf   # Monospace font (temporary)
├── nim.cfg                 # Compiler flags, library paths, rpath
└── menagerie               # Compiled binary
```

---

## Building

```bash
# debug build (fast compile, slower binary)
nim c -o:menagerie src/menagerie.nim

# release build
nim c -d:release -o:menagerie src/menagerie.nim
```

`nim.cfg` handles SDL2 linker flags and the `$ORIGIN/vendor/sdl` rpath automatically — no extra flags needed.

### Why `$ORIGIN` rpath?

The SDL2 .so files live in `vendor/sdl/`. The binary is built with `DT_RPATH = $ORIGIN/vendor/sdl` (not `RUNPATH`) so that `dlopen()` — which Nim's SDL2 bindings use at runtime — searches that directory first. `RUNPATH` is not searched by `dlopen` on Linux; `RPATH` is. The `--disable-new-dtags` linker flag forces `RPATH` instead of the modern default `RUNPATH`.

### Lua is compiled in

Lua is embedded via `{.compile: "../vendor/lua/src/onelua.c".}` in `scripting.nim`. The `-DMAKE_LIB` flag suppresses the `main()` symbols. No external `liblua.so` is needed.

---

## The Two-Panel Layout

### Tkinter original
`ttk.PanedWindow(orient=HORIZONTAL)` with two children at `weight=3` and `weight=1`. Dragging the sash fires a resize event.

### SDL2 port
There is no widget system. Layout is entirely manual pixel math:

```
┌─────────────────────┬─────┬─────────────────┐
│                     │     │                 │
│   Left panel        │sash │   Right panel   │
│   (image)           │  5px│   (text + input)│
│                     │     │                 │
│   0 .. sashX        │     │sashX+5 .. winW  │
└─────────────────────┴─────┴─────────────────┘
                                        └──32px── input bar
```

`app.sashX` is the only layout variable. Everything is derived from it at render time:
- Left panel width: `sashX`
- Right panel x origin: `sashX + SASH_W`
- Right panel width: `winW - (sashX + SASH_W)`

Sash drag is handled in `MouseMotion` when `app.draggingSash` is true. On window resize, `sashX` is clamped to keep both panels usable, then `recomputeBgRect()` is called.

---

## Image Panel (Left)

### Tkinter original
A `tk.Canvas`. Pillow (`PIL`) loads images, resizes them to fit the canvas height, and pastes sprites on top. The composite is re-rendered to a `PhotoImage` on dirty flag.

### SDL2 port
`SDL2_image.load()` loads PNG/JPG directly to an SDL `Surface`, which is immediately uploaded to a GPU `Texture` via `createTextureFromSurface`. The texture is kept alive and reused every frame — no per-frame CPU image processing.

**Centering:** `recomputeBgRect()` computes a destination `Rect` that fits the image to panel height while preserving aspect ratio, centered horizontally:

```nim
let aspect = bgW.float / bgH.float
var dw = (panelH.float * aspect).int
var dh = panelH
if dw > panelW:          # image wider than panel: fit to width instead
  dw = panelW
  dh = (panelW.float / aspect).int
let dx = (panelW - dw) div 2
let dy = (panelH - dh) div 2
```

This only runs on window resize or sash drag — not every frame.

**Sprite overlays** are not yet implemented. The pattern will be: load sprite textures once, store `(tex, nx, ny, scale)` tuples, and blit in `renderLeftPanel` after the background using the same normalised-coordinate math as the Python version.

---

## Text Panel (Right) — The TUI

This is the most complex part because Tkinter's `Text` widget gives you rich text, scrolling, clickable tags, and selection for free. In SDL2 you build all of it yourself.

### Data model: `TextBuffer` and `Line`

```
TextBuffer
  lines: seq[Line]         ← seq of logical lines
  scrollY: int             ← pixel scroll offset from top
  totalH: int              ← total pixel height of all lines

Line = seq[Span]           ← one screen line, split into styled runs

Span
  text:   string           ← display text
  isLink: bool             ← renders teal + underline, clickable
  cmd:    string           ← command string fired on click
```

Lines are never reflowed. Each `Line` is exactly one row of output. Word wrapping (if needed later) would be done at insertion time, splitting a logical paragraph into multiple `Line` entries.

### Inline link syntax

Links use the same `[[label:command]]` / `[[command]]` syntax as the Python version, parsed in `parseLine()`:

```lua
-- In Lua scripts, emit links like this:
print("You see a [[rusty sword:examine sword]] on the ground.")
print("Exits: [[north:go north]], [[south:go south]]")
```

`parseLine` splits the raw string on `[[...]]` and returns a `seq[Span]` with `isLink` set on link spans.

### Rendering

Each frame, only visible lines are rendered (viewport culling):

```nim
let startLine = max(0, scrollY div lineH)
let endLine   = min(lines.high, (scrollY + viewH) div lineH + 1)
for li in startLine .. endLine:
  # render each span left-to-right, accumulating x position
```

`renderText()` calls SDL2_ttf's `renderUtf8Blended()` per span, creates a temporary texture, blits it, then destroys it. This is simple but not optimal for large buffers — a future glyph atlas/texture cache would batch this.

Links get an underline drawn as a 1px filled rect below the span, and a semi-transparent hover highlight when `hoverLink` matches.

### Scrollbar

A minimal 6px scrollbar on the right edge of the text panel. Thumb height and position are computed proportionally:

```nim
thumbH = max(20, trackH * viewH div totalH)
thumbY = 2 + (trackH - thumbH) * scrollY div max(1, totalH - viewH)
```

### Input bar

Always rendered at the bottom of the right panel (`winH - INPUT_H` to `winH`). Contains:
- A `>` prompt label
- The input text, clipped to available width with pixel-scroll for long strings
- A blinking text cursor (toggled every `CURSOR_BLINK` ms)
- An `⏎` button label on the right

**UTF-8 cursor movement:** Backspace and arrow keys walk backwards/forwards over continuation bytes (`0xC0` mask) to find character boundaries — SDL gives you raw UTF-8 bytes.

---

## Mouse Handling

### Sash drag

```
MouseButtonDown → sashX ≤ mx < sashX+SASH_W → draggingSash = true
MouseMotion     → if draggingSash: sashX = clamp(mx - dragOffset, 200, winW-250)
MouseButtonUp   → draggingSash = false
```

### Link click vs text selection

Both start on `MouseButtonDown`. On `MouseButtonUp`:
- If the mouse moved < 4px: treat as a click → `hitTestLink()` → `handleLinkClick()`
- If the mouse moved ≥ 4px: finalise selection

`hitTestLink()` does the same span-walk as rendering to find which span the mouse is over, returning its `cmd` string.

### Cursor changes

`createSystemCursor` is called once at startup for `ARROW`, `HAND`, and `SIZEWE`. `setCursor()` is called in `MouseMotion` based on what's under the pointer. SDL2 cursor pointers must be created with `createSystemCursor`, not `setSystemCursor` (which does not exist in this binding version).

---

## Lua Scripting (`scripting.nim`)

### Architecture

```
ScriptEngine
  L: LuaStatePtr     ← single persistent Lua state
  onPrint: proc      ← called when Lua print()s — routes to TextBuffer

gEngine: ptr ScriptEngine   ← global so C callbacks can reach it
```

`onelua.c` compiles the entire Lua runtime into the binary. No `liblua.so` needed.

### Nim → Lua call

```nim
# Call a global Lua function by name
app.scriptEng.callGlobal("on_command", [cmd])
```

### Lua → Nim call (callbacks)

Nim functions exposed to Lua must be `cdecl` and match `LuaCFunction = proc(L: LuaStatePtr): cint`:

```nim
proc myCallback(L: LuaStatePtr): cint {.cdecl.} =
  let arg = luaToString(L, 1)   # get first argument
  # ... do something ...
  lua_pushstring(L, "result")   # push return value
  return 1                      # number of return values

# Register it
eng.pushFunction(myCallback, "my_func")
```

### Script conventions

- Scripts are loaded in order at startup; they share a single Lua state.
- `on_command(cmd: string) → bool` — called for every player input. Return `false` to fall through to Nim's built-in handlers.
- `print()` is overridden to route output to the scrollback via `onPrint`.
- The `engine` table exposes additional Nim-side functions (`engine.print()` etc.).

### Adding new Nim functions to Lua

1. Write a `{.cdecl.}` proc taking `LuaStatePtr`, returning `cint`
2. Use `gEngine.onPrint` or other state via the `gEngine` global pointer
3. Register it in `initScriptEngine` with `eng.pushFunction(myProc, "name")` or as a field on the `engine` table via `lua_pushcclosure` + `lua_setfield`

---

## Colour Palette

All colours defined as `(r, g, b, a: uint8)` tuples:

| Name | Hex | Usage |
|---|---|---|
| `COL_BG` | `#111111` | Panel backgrounds |
| `COL_BG_INPUT` | `#1a1a1a` | Input bar, scrollbar track |
| `COL_FG` | `#d4c9a8` | Body text |
| `COL_FG_DIM` | `#7a7060` | Prompt `>`, labels |
| `COL_FG_LINK` | `#8fbcbb` | Link text + underline |
| `COL_SASH` | `#2d2d2d` | Sash, divider lines |
| `COL_SASH_HOT` | `#505050` | Sash on hover |
| `COL_SEL` | `#3c505a` | Text selection highlight |
| `COL_CURSOR` | `#d4c9a8 @ 200α` | Input cursor |

---

## HUD (Stats overlay)

Rendered in `renderLeftPanel` in the top-left corner of the image area. It's a semi-transparent filled rect drawn with `BlendMode_Blend`, then text drawn on top. Stats are a `seq[(string, string)]` (label, value) stored in `app.hudStats`. Update them from Lua or game logic and they'll render next frame.

---

## IPC / Threading model

The Python version uses a daemon thread for game logic posting to a Tkinter-polled queue. The Nim port is currently single-threaded — the game logic (Lua) runs synchronously in the event handler on the main thread. For the full port:

- Keep the SDL event loop on the main thread (SDL requires this on most platforms)
- Run long game-logic operations in a Nim thread or via async
- Communicate back via a simple channel (`Channel[string]` or a ring buffer) polled each frame before rendering

The `scripting.nim` `gEngine` global will need a mutex guard if Lua is ever called from a second thread.

---

## Known Limitations (proto scope)

- **Text selection** selects whole lines, not individual characters within a line (character-level span hit-testing is scaffolded but not fully wired)
- **No text reflow** — lines wider than the panel overflow rather than wrap
- **No sprite rendering** — image panel shows background only
- **Render text is not cached** — `renderUtf8Blended` + texture create/destroy per span per frame; fine for short buffers, needs a glyph atlas for large scrollbacks
- **Single Lua state** — no sandboxing between scripts
