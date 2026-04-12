## src/engine/lua_bindings.nim
## ───────────────────────────
## Shared Nim bindings for the Lua 5.4 C API.
## Compiles the onelua.c amalgamation once per binary and exposes the superset
## of proc/type/constant bindings used by both engine/scripting.nim and
## world-tools/mod_manager/lua_runner.nim.
##
## Import this module instead of declaring your own bindings. Both consumer
## files must continue to set up their own passC -I if they add extra headers,
## but the Lua include path and compile step are handled here.

import std/os

const luaSrcDir* =
  currentSourcePath.parentDir.parentDir.parentDir / "vendor" / "lua" / "src"

# Compile the full Lua runtime into the binary.
# MAKE_LIB suppresses the lua/luac standalone main() symbols.
{.passC: "-DMAKE_LIB -I\"" & luaSrcDir & "\"".}
{.compile: luaSrcDir / "onelua.c".}

# ── Types ─────────────────────────────────────────────────────────────────────

type
  LuaState*   {.importc: "lua_State",   header: "lua.h".}   = object
  LuaStatePtr* = ptr LuaState
  LuaCFunction* = proc(L: LuaStatePtr): cint {.cdecl.}

# ── Constants ─────────────────────────────────────────────────────────────────

const
  LUA_OK*            = 0
  LUA_TNIL*          = 0
  LUA_TBOOLEAN*      = 1
  LUA_TNUMBER*       = 3
  LUA_TSTRING*       = 4
  LUA_TTABLE*        = 5
  LUA_TFUNCTION*     = 6
  LUA_MULTRET*       = -1
  LUA_REGISTRYINDEX* = -1001000

# ── State management ──────────────────────────────────────────────────────────

proc luaL_newstate*(): LuaStatePtr
  {.importc: "luaL_newstate", header: "lualib.h".}

proc luaL_openlibs*(L: LuaStatePtr)
  {.importc: "luaL_openlibs", header: "lualib.h".}

proc lua_close*(L: LuaStatePtr)
  {.importc: "lua_close", header: "lua.h".}

# ── Load and call ─────────────────────────────────────────────────────────────

proc luaL_loadfilex*(L: LuaStatePtr; filename, mode: cstring): cint
  {.importc: "luaL_loadfilex", header: "lauxlib.h".}

proc lua_pcallk*(L: LuaStatePtr; nargs, nresults, msgh, ctx: cint;
                 k: pointer): cint
  {.importc: "lua_pcallk", header: "lua.h".}

# ── Stack inspection ──────────────────────────────────────────────────────────

proc lua_gettop*(L: LuaStatePtr): cint
  {.importc: "lua_gettop", header: "lua.h".}

proc lua_settop*(L: LuaStatePtr; idx: cint)
  {.importc: "lua_settop", header: "lua.h".}

proc lua_type*(L: LuaStatePtr; idx: cint): cint
  {.importc: "lua_type", header: "lua.h".}

# ── Push values ───────────────────────────────────────────────────────────────

proc lua_pushnil*(L: LuaStatePtr)
  {.importc: "lua_pushnil", header: "lua.h".}

proc lua_pushboolean*(L: LuaStatePtr; b: cint)
  {.importc: "lua_pushboolean", header: "lua.h".}

proc lua_pushnumber*(L: LuaStatePtr; n: cdouble)
  {.importc: "lua_pushnumber", header: "lua.h".}

proc lua_pushinteger*(L: LuaStatePtr; n: int64)
  {.importc: "lua_pushinteger", header: "lua.h".}

proc lua_pushstring*(L: LuaStatePtr; s: cstring): cstring
  {.importc: "lua_pushstring", header: "lua.h", discardable.}

proc lua_pushvalue*(L: LuaStatePtr; idx: cint)
  {.importc: "lua_pushvalue", header: "lua.h".}

proc lua_pushcclosure*(L: LuaStatePtr; fn: LuaCFunction; n: cint)
  {.importc: "lua_pushcclosure", header: "lua.h".}

# ── Read values ───────────────────────────────────────────────────────────────

proc lua_toboolean*(L: LuaStatePtr; idx: cint): cint
  {.importc: "lua_toboolean", header: "lua.h".}

proc lua_tonumberx*(L: LuaStatePtr; idx: cint; isnum: ptr cint): cdouble
  {.importc: "lua_tonumberx", header: "lua.h".}

proc lua_tointegerx*(L: LuaStatePtr; idx: cint; isnum: ptr cint): int64
  {.importc: "lua_tointegerx", header: "lua.h".}

proc lua_tolstring*(L: LuaStatePtr; idx: cint; len: ptr csize_t): cstring
  {.importc: "lua_tolstring", header: "lua.h".}

proc lua_isinteger*(L: LuaStatePtr; idx: cint): cint
  {.importc: "lua_isinteger", header: "lua.h".}

proc lua_rawlen*(L: LuaStatePtr; idx: cint): csize_t
  {.importc: "lua_rawlen", header: "lua.h".}

# ── Globals ───────────────────────────────────────────────────────────────────

proc lua_setglobal*(L: LuaStatePtr; name: cstring)
  {.importc: "lua_setglobal", header: "lua.h".}

proc lua_getglobal*(L: LuaStatePtr; name: cstring): cint
  {.importc: "lua_getglobal", header: "lua.h", discardable.}

# ── Tables ────────────────────────────────────────────────────────────────────

proc lua_newtable*(L: LuaStatePtr)
  {.importc: "lua_newtable", header: "lua.h".}

proc lua_settable*(L: LuaStatePtr; idx: cint)
  {.importc: "lua_settable", header: "lua.h".}

proc lua_setfield*(L: LuaStatePtr; idx: cint; k: cstring)
  {.importc: "lua_setfield", header: "lua.h".}

proc lua_getfield*(L: LuaStatePtr; idx: cint; k: cstring): cint
  {.importc: "lua_getfield", header: "lua.h", discardable.}

proc lua_rawgeti*(L: LuaStatePtr; idx: cint; n: int64): cint
  {.importc: "lua_rawgeti", header: "lua.h", discardable.}

proc lua_rawseti*(L: LuaStatePtr; idx, n: cint)
  {.importc: "lua_rawseti", header: "lua.h".}

proc lua_next*(L: LuaStatePtr; idx: cint): cint
  {.importc: "lua_next", header: "lua.h".}

# ── Nim-friendly wrappers ─────────────────────────────────────────────────────

template luaPCall*(L: LuaStatePtr; nargs, nresults, msgh: cint): cint =
  lua_pcallk(L, nargs, nresults, msgh, 0, nil)

template luaLoadFile*(L: LuaStatePtr; path: string): cint =
  luaL_loadfilex(L, path.cstring, nil)

proc luaToString*(L: LuaStatePtr; idx: cint): string =
  let cs = lua_tolstring(L, idx, nil)
  if cs == nil: "" else: $cs
