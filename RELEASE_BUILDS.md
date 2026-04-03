# Menagerie — Release Build Strategy

How to produce distributable binaries for Linux and Windows.

---

## The core problem

Two things prevent a fully static, fully portable binary on Linux:

1. **glibc** — the C runtime. Every Linux binary links against it. It can't be fully
   statically linked portably because it dlopen's its own internals (NSS, DNS), and
   its symbol versions are stamped at compile time. A binary built against glibc 2.38
   won't run on a system with glibc 2.17.

2. **SDL2's backend loading** — SDL2 calls dlopen() at runtime to load X11, Wayland,
   ALSA, PulseAudio, etc., regardless of how you link libSDL2 itself. You cannot link
   your way around this. SDL2 is dynamic by design so one binary supports multiple
   display/audio systems. These backends (display server, audio daemon, GPU drivers)
   are system infrastructure — present on any desktop Linux, never something the user
   installs separately.

Everything else — libSDL2 itself, SDL2_ttf, SDL2_image, freetype, harfbuzz, libpng,
libjpeg, all of your own code — can be fully statically linked.

SDL2 is zlib licensed. Static linking is fine with no redistribution requirements.

---

## Platform strategies

### Linux

**What gets statically linked:**
- SDL2 (built from source in Docker — see below)
- SDL2_ttf, SDL2_image
- freetype, harfbuzz, glib, brotli
- libpng, libjpeg, libwebp, libtiff and their deps (Lerc, jbig, deflate, zstd, lzma)
- All Nim runtime code

**What stays dynamic (unavoidable):**
- `libc.so.6` (glibc) — always present, every Linux system
- `libm.so.6` — always present
- X11/Wayland libs, ALSA/PulseAudio — SDL2's runtime backend loading, always present
  on any desktop Linux; SDL2 dlopen's these itself regardless of how libSDL2 is linked

**Glibc compatibility floor:**
Build inside Docker on Ubuntu 20.04 (glibc 2.31). The container's glibc version
stamps the minimum required version. Modern glibc is backwards compatible, so the
binary runs on anything with glibc >= 2.31 — effectively all Linux installs since 2020.
Ubuntu 18.04 (glibc 2.27) is an option for a lower floor but its toolchain is older.

```
your binary
  ├── SDL2.a          ← compiled in (built from source)
  ├── SDL2_ttf.a      ← compiled in
  ├── SDL2_image.a    ← compiled in
  ├── freetype.a      ← compiled in
  ├── harfbuzz.a      ← compiled in
  ├── libpng.a        ← compiled in
  ├── libjpeg.a       ← compiled in
  ├── libwebp.a       ← compiled in
  └── libc / glibc    ← dynamic (system, always present)
```

**No bundled `.so` files. No user install requirements.**

---

### Windows

Windows has no glibc, no dlopen backend loading issue. SDL2 on Windows uses
DirectX/WinAPI directly via normal static linkage. A fully static `.exe` is
straightforward.

**What gets statically linked: everything.**
- SDL2, SDL2_ttf, SDL2_image (from MinGW static libs)
- freetype, harfbuzz, libpng, libjpeg, libwebp
- All Nim runtime code
- The Windows CRT (via MinGW)

**Runtime dependencies: none.** Single `.exe`, no `.dll`s needed.

The SDL project ships official pre-built MinGW static libraries at:
`https://github.com/libsdl-org/SDL/releases` (SDL2-devel-X.X.X-mingw.tar.gz)
Same for SDL2_ttf and SDL2_image. No need to compile from source.

---

## What needs to be built

### Linux — one-time setup

**1. Fetch vendored source deps**

SDL2, SDL2_ttf, SDL2_image, and Lua source tarballs are downloaded once into
`vendor/` and are not committed. Run this before first build and whenever
versions change:

```bash
./download-deps.sh
```

This also fetches `vendor/fonts/SpaceMono-Regular.ttf` (embedded at compile time
via `staticRead`).

**2. Build the Docker image**

The Dockerfile (`docker-build/Dockerfile`) COPYs the pre-downloaded `vendor/`
source tarballs and builds them all inside the container. Docker layer caching
means subsequent builds only recompile what changed.

```bash
# Run from project root — build context is the project root so COPY can reach vendor/
docker build -f docker-build/Dockerfile -t menagerie-linux-build .
```

**3. Release nim.cfg**

`docker-build/nim.cfg` is mounted read-only into the container at `/src/nim.cfg`.
`dynlibOverride` tells Nim's codegen to use `importc` instead of `dlopen` for the
SDL2 libs, so the static `.a` files are linked at compile time.

```nim
# docker-build/nim.cfg (actual file — abridged)
dynlibOverride = "SDL2"
dynlibOverride = "SDL2_ttf"
dynlibOverride = "SDL2_image"

passL = "-static-libstdc++"   # harfbuzz is C++; bundles GCC runtime
passL = "-Wl,-Bstatic"
passL = "-lSDL2_ttf -lharfbuzz -lfreetype"
passL = "-lSDL2_image -lSDL2"
passL = "-lpng16 -ljpeg -lwebp -lwebpdemux"
passL = "-lz"
passL = "-Wl,-Bdynamic"
passL = "-ldl -lpthread -lrt -lm"
```

**4. Compile**

`docker-build/build.sh` runs the container, compiles, strips, fixes ownership,
verifies no SDL2 dynamic dep, and copies the result to `../menagerie-release/`.

Flags:
- `--game` — build the main game binary (`menagerie`)
- `--manager` — build the mod manager binary (`mod_manager`)
- `--tools` — reserved for the future world/room editor tools applet

```bash
./docker-build/build.sh --game
./docker-build/build.sh --manager
./docker-build/build.sh --game --manager   # both at once
```

**5. Verify the result**

```bash
ldd menagerie
# Expected output — no SDL2:
#   linux-vdso.so.1
#   libm.so.6
#   libc.so.6
#   ld-linux-x86-64.so.2

# Confirm minimum glibc version required
objdump -p menagerie | grep GLIBC | sort -V | tail -1
# Should show GLIBC_2.31 or lower
```

---

### Windows — planned (not yet implemented)

Windows has no glibc and no dlopen backend issue, so a fully static `.exe` is
straightforward. The approach will be MinGW cross-compilation from Linux.

Planned steps:
1. Install `mingw-w64` cross-compiler
2. Download SDL2/ttf/image official MinGW static libs from the SDL releases page
   (`SDL2-devel-X.X.X-mingw.tar.gz` etc.) — no need to compile from source
3. Write `docker-build/nim-windows.cfg` with MinGW target + static link flags
4. Add a Windows build step to `docker-build/build.sh`

Expected nim.cfg sketch:
```nim
cpu      = "amd64"
os       = "windows"
gcc.exe       = "x86_64-w64-mingw32-gcc"
gcc.linkerexe = "x86_64-w64-mingw32-gcc"
dynlibOverride = "SDL2"
dynlibOverride = "SDL2_ttf"
dynlibOverride = "SDL2_image"
passL = "-static"
passL = "-lSDL2 -lSDL2_ttf -lSDL2_image"
passL = "-lfreetype -lharfbuzz -lpng -ljpeg -lwebp -lz -lm"
passL = "-ldinput8 -ldxguid -luser32 -lgdi32 -lwinmm -limm32"
passL = "-lole32 -loleaut32 -lshell32 -lsetupapi -lversion -luuid"
passL = "-mwindows"
```

---

## Repository structure

```
docker-build/
├── Dockerfile          ← Ubuntu 20.04; COPYs vendor/ and builds SDL2/ttf/image/Lua
├── nim.cfg             ← release link flags (dynlibOverride + -Wl,-Bstatic)
└── build.sh            ← --game / --manager / --tools flags; compiles, strips, copies to release dir

vendor/                 ← downloaded by download-deps.sh; not committed
├── sdl2 tarball/
├── sdl2.ttf tarball/
├── sdl2.image tarball/
├── lua/src/            ← Lua 5.4 amalgamation (compiled into both binaries via onelua.c)
└── fonts/
    └── SpaceMono-Regular.ttf   ← embedded at compile time via staticRead

data/
└── base-game/          ← one folder per plugin, keyed by tool_id
    └── <PluginFolder>/
        └── <plugin>.json

src/
├── menagerie.nim       ← entry point
├── engine/             ← game logic (state, combat, world, saves, dialogue, ...)
├── commands/           ← player-input handlers split by context (cmd_combat, cmd_town, ...)
└── ui/
    ├── text_window.nim ← SDL2 window, rendering, input, panel system
    └── ipc.nim         ← typed Channel[UiMsg] / Channel[GameMsg]

world-tools/
├── drivers/            ← Lua 5.4 export drivers (copied to release, not compiled in)
│   ├── world/world.lua
│   ├── rooms/rooms.lua
│   ├── gameplay_vars/gameplay_vars.lua
│   ├── menagerie/menagerie.lua
│   └── assets/assets.lua
└── mod_manager/        ← mod manager source (compiled to separate binary)
    ├── mod_manager.nim
    ├── plugin_db.nim
    └── lua_runner.nim

nim.cfg                 ← development build only (distrobox, dynamic SDL2)
menagerie.nimble        ← bin = @["menagerie"]; srcDir = "src"
download-deps.sh        ← fetches vendor/ contents
```

### Path resolution note for Lua bindings

Nim uses different resolution rules for different pragma types:

| Pragma | Resolved by | Path used |
|---|---|---|
| `{.compile: "...".}` | Nim, relative to source file | `../../vendor/lua/src/onelua.c` |
| `{.passC: "-I...".}` | gcc verbatim — must be absolute | computed via `currentSourcePath` |
| `header: "..."` | gcc, relative to `-I<srcDir>` flag | `lua.h` (resolved via `-I` flag) |

Both `src/engine/scripting.nim` and `world-tools/mod_manager/lua_runner.nim` are exactly
two directory levels from the project root, so `../../vendor/lua/src/onelua.c` resolves
correctly from both locations.

---

## Release archives

**Linux** (`menagerie-linux-x64.tar.gz`):
```
menagerie/
├── menagerie           ← game binary, ~20-30 MB stripped (SDL2 compiled in)
├── mod_manager         ← mod manager binary, same static link profile
├── world-tools/
│   └── drivers/        ← Lua 5.4 export driver scripts
└── data/
```
No install requirements. Run `./menagerie` to play, `./mod_manager` to export content.

**Windows** (`menagerie-windows-x64.zip`):
```
menagerie/
├── menagerie.exe       ← fully self-contained, no DLLs needed
├── mod_manager.exe
├── world-tools/
│   └── drivers/
└── data/
```
No install requirements.

---

## nim.cfg for development (unchanged)

The root `nim.cfg` stays as-is for development inside the distrobox — dynamic
linking against the distrobox SDL2 install. The release build scripts use their
own configs under `build-env/` and don't touch the dev config.

---

## Summary

| | Linux release | Windows release | Dev (distrobox) |
|---|---|---|---|
| SDL2 | static (built from source in Docker) | static (planned) | dynamic (distrobox) |
| SDL2_ttf/image | static | static (planned) | dynamic (distrobox) |
| freetype etc. | static | static (planned) | dynamic (distrobox) |
| glibc | dynamic (system) | N/A | dynamic |
| User install required | none | none | SDL2 in distrobox |
| Build environment | Docker Ubuntu 20.04 | MinGW cross-compiler (planned) | distrobox |
| Bundled .so/.dll | none | none | — |
| Binary size (est.) | ~20-30 MB stripped | ~15-20 MB (est.) | — |
