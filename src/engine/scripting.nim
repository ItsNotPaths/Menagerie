## Lua scripting bridge.
## Embeds Lua 5.4 via the amalgamation in vendor/lua/src/ — no external dependency.

import strutils, os
import std/[json, tables]
import state, api_types, content

# Compile the full Lua runtime into the binary.
# MAKE_LIB suppresses the lua/luac standalone main() symbols.
# passC -I must be absolute (passed verbatim to gcc); header: paths use one ..
# because Nim adds -I<srcDir> to gcc and that makes ../vendor/... resolve correctly.
const luaSrcDir = currentSourcePath.parentDir / ".." / ".." / "vendor" / "lua" / "src"
{.passC: "-DMAKE_LIB -I\"" & luaSrcDir & "\"".}
{.compile: "../../vendor/lua/src/onelua.c".}

# ─── Lua C API — types ───────────────────────────────────────────────────────
type
  LuaState {.importc: "lua_State", header: "../vendor/lua/src/lua.h".} = object
  LuaStatePtr* = ptr LuaState
  LuaCFunction* = proc(L: LuaStatePtr): cint {.cdecl.}

# ─── Lua C API — constants ───────────────────────────────────────────────────
const
  LUA_OK*       = 0
  LUA_TFUNCTION* = 6
  LUA_MULTRET*  = -1

# ─── Lua C API — proc bindings ───────────────────────────────────────────────
# Only the subset actively used by ScriptEngine is bound here.
# Extend as needed when adding new Nim→Lua or Lua→Nim interfaces.

proc luaL_newstate*(): LuaStatePtr
  {.importc: "luaL_newstate", header: "../vendor/lua/src/lualib.h".}

proc luaL_openlibs*(L: LuaStatePtr)
  {.importc: "luaL_openlibs", header: "../vendor/lua/src/lualib.h".}

proc lua_close*(L: LuaStatePtr)
  {.importc: "lua_close", header: "../vendor/lua/src/lua.h".}

proc luaL_loadfilex*(L: LuaStatePtr; filename, mode: cstring): cint
  {.importc: "luaL_loadfilex", header: "../vendor/lua/src/lauxlib.h".}

proc lua_pcallk*(L: LuaStatePtr; nargs, nresults, msgh, ctx: cint;
                 k: pointer): cint
  {.importc: "lua_pcallk", header: "../vendor/lua/src/lua.h".}

proc lua_tolstring*(L: LuaStatePtr; idx: cint; len: ptr csize_t): cstring
  {.importc: "lua_tolstring", header: "../vendor/lua/src/lua.h".}

proc lua_settop*(L: LuaStatePtr; idx: cint)
  {.importc: "lua_settop", header: "../vendor/lua/src/lua.h".}

proc lua_gettop*(L: LuaStatePtr): cint
  {.importc: "lua_gettop", header: "../vendor/lua/src/lua.h".}

proc lua_pushstring*(L: LuaStatePtr; s: cstring): cstring
  {.importc: "lua_pushstring", header: "../vendor/lua/src/lua.h", discardable.}

proc lua_pushcclosure*(L: LuaStatePtr; fn: LuaCFunction; n: cint)
  {.importc: "lua_pushcclosure", header: "../vendor/lua/src/lua.h".}

proc lua_setglobal*(L: LuaStatePtr; name: cstring)
  {.importc: "lua_setglobal", header: "../vendor/lua/src/lua.h".}

proc lua_getglobal*(L: LuaStatePtr; name: cstring): cint
  {.importc: "lua_getglobal", header: "../vendor/lua/src/lua.h", discardable.}

proc lua_newtable*(L: LuaStatePtr)
  {.importc: "lua_newtable", header: "../vendor/lua/src/lua.h".}

proc lua_setfield*(L: LuaStatePtr; idx: cint; k: cstring)
  {.importc: "lua_setfield", header: "../vendor/lua/src/lua.h".}

proc lua_pushnil*(L: LuaStatePtr)
  {.importc: "lua_pushnil", header: "../vendor/lua/src/lua.h".}

# ─── Nim-friendly wrappers ───────────────────────────────────────────────────
template luaPCall*(L: LuaStatePtr; nargs, nresults, msgh: cint): cint =
  lua_pcallk(L, nargs, nresults, msgh, 0, nil)

template luaLoadFile*(L: LuaStatePtr; path: string): cint =
  luaL_loadfilex(L, path.cstring, nil)

proc luaToString*(L: LuaStatePtr; idx: cint): string =
  let cs = lua_tolstring(L, idx, nil)
  if cs == nil: "" else: $cs

proc luaPopError*(L: LuaStatePtr): string =
  ## Read the error string on top of the stack and pop it.
  result = luaToString(L, -1)
  lua_settop(L, -2)

# ─── ScriptEngine ────────────────────────────────────────────────────────────
type
  PrintCallback* = proc(msg: string)

  ScriptEngine* = object
    L*:       LuaStatePtr
    onPrint*: PrintCallback  ## Routes Lua print() output to the UI

# Single global pointer so cdecl C callbacks can reach the engine.
# Acceptable for a single-engine application.
var gEngine*: ptr ScriptEngine = nil

# ─── Script execution context ────────────────────────────────────────────────
# Set before runScript, cleared after.  Lets cdecl callbacks reach game state.
var gScriptState:   ptr GameState = nil
var gScriptSelfId:  string = ""
var gScriptLines:   seq[string] = @[]

proc luaPrintImpl(L: LuaStatePtr): cint {.cdecl.} =
  ## C callback registered as Lua's print() and engine.print().
  ## Routes to gScriptLines during script execution, onPrint otherwise.
  let n = lua_gettop(L)
  var parts: seq[string]
  for i in 1 .. n:
    parts.add luaToString(L, i.cint)
  let msg = parts.join("\t")
  if gScriptState != nil:
    gScriptLines.add msg
  elif gEngine != nil and gEngine.onPrint != nil:
    gEngine.onPrint(msg)
  else:
    echo "[lua] ", msg
  return 0

proc luaEngineCmdImpl(L: LuaStatePtr): cint {.cdecl.} =
  ## engine.cmd(str) — dispatch a content command string from Lua.
  ## Output lines are appended to gScriptLines.
  let cmd = luaToString(L, 1)
  if gScriptState != nil and apiRunCommand != nil:
    gScriptLines &= apiRunCommand(gScriptState[], cmd, gScriptSelfId)
  return 0

proc luaGetVarImpl(L: LuaStatePtr): cint {.cdecl.} =
  ## engine.get_var(key) — read a GameState variable. Returns string or nil.
  let key = luaToString(L, 1)
  if gScriptState != nil and key.len > 0 and key in gScriptState.variables:
    let val = gScriptState.variables[key]
    let s = if val.kind == JString:          val.getStr
            elif val.kind in {JFloat, JInt}: $(val.getFloat(0))
            elif val.kind == JBool:          (if val.getBool: "true" else: "false")
            else:                            ""
    discard lua_pushstring(L, s.cstring)
    return 1
  lua_pushnil(L)
  return 1

proc luaSetVarImpl(L: LuaStatePtr): cint {.cdecl.} =
  ## engine.set_var(key, value) — write a GameState variable.
  ## Numeric strings are stored as JFloat; everything else as JString.
  let key = luaToString(L, 1)
  let raw = luaToString(L, 2)
  if gScriptState != nil and key.len > 0:
    try:    gScriptState.variables[key] = newJFloat(parseFloat(raw))
    except: gScriptState.variables[key] = newJString(raw)
  return 0

proc initScriptEngine*(eng: var ScriptEngine; onPrint: PrintCallback) =
  eng.L       = luaL_newstate()
  eng.onPrint = onPrint
  gEngine     = eng.addr
  luaL_openlibs(eng.L)

  # Override print() to route output through the UI callback
  lua_pushcclosure(eng.L, luaPrintImpl, 0)
  lua_setglobal(eng.L, "print")

  # engine table — extensible namespace for Nim-side functions exposed to Lua
  lua_newtable(eng.L)
  lua_pushcclosure(eng.L, luaPrintImpl, 0)
  lua_setfield(eng.L, -2, "print")
  lua_pushcclosure(eng.L, luaEngineCmdImpl, 0)
  lua_setfield(eng.L, -2, "cmd")
  lua_pushcclosure(eng.L, luaGetVarImpl, 0)
  lua_setfield(eng.L, -2, "get_var")
  lua_pushcclosure(eng.L, luaSetVarImpl, 0)
  lua_setfield(eng.L, -2, "set_var")
  lua_setglobal(eng.L, "engine")

proc closeScriptEngine*(eng: var ScriptEngine) =
  if eng.L != nil:
    lua_close(eng.L)
    eng.L = nil
  gEngine = nil

proc runFile*(eng: var ScriptEngine; path: string): bool =
  ## Load and execute a Lua source file. Errors are routed through onPrint.
  if luaLoadFile(eng.L, path) != LUA_OK:
    eng.onPrint("[lua error] " & luaPopError(eng.L))
    return false
  if luaPCall(eng.L, 0, LUA_MULTRET, 0) != LUA_OK:
    eng.onPrint("[lua error] " & luaPopError(eng.L))
    return false
  return true

proc callGlobal*(eng: var ScriptEngine; name: string;
                 args: openArray[string] = []): bool =
  ## Call a global Lua function by name, passing optional string arguments.
  ## Returns false if the function does not exist or returns false itself.
  let t = lua_getglobal(eng.L, name.cstring)
  if t != LUA_TFUNCTION:
    lua_settop(eng.L, -2)
    return false
  for a in args:
    lua_pushstring(eng.L, a.cstring)
  if luaPCall(eng.L, args.len.cint, 1, 0) != LUA_OK:
    eng.onPrint("[lua error] " & luaPopError(eng.L))
    return false
  # treat a Lua `return false` as "not handled"
  let ret = luaToString(eng.L, -1)
  lua_settop(eng.L, -2)
  return ret != "false"

proc runScript*(state: var GameState; scriptName, selfId: string): seq[string] =
  ## Resolve scriptName via the asset index, execute it, and return any
  ## output lines produced via engine.cmd / engine.print / print inside Lua.
  ## selfId resolves "enemy.self" selectors within engine.cmd calls.
  if gEngine == nil: return
  let path = content.assetIndex.scripts.getOrDefault(scriptName, "")
  if not fileExists(path):
    if gEngine.onPrint != nil:
      gEngine.onPrint("[lua] script not found: " & path)
    return
  gScriptState  = state.addr
  gScriptSelfId = selfId
  gScriptLines  = @[]
  discard gEngine[].runFile(path)
  gScriptState = nil
  result       = gScriptLines
  gScriptLines = @[]
