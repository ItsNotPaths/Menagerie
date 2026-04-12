## lua_runner.nim
## Lua state for the mod manager — injects file I/O helpers and calls
## driver export() functions.  Uses the same onelua.c amalgamation as the
## main game engine.

import std/[json, os, strutils, tables]
import plugin_db
import ../../vendor/lua/lua_bindings

proc luaPopError(L: LuaStatePtr): string =
  result = luaToString(L, -1)
  lua_settop(L, -2)

# ── JSON → Lua table ──────────────────────────────────────────────────────────

proc pushJson(L: LuaStatePtr; node: JsonNode) =
  if node.isNil:
    lua_pushnil(L)
    return
  case node.kind
  of JNull:
    lua_pushnil(L)
  of JBool:
    lua_pushboolean(L, if node.getBool: 1 else: 0)
  of JInt:
    lua_pushinteger(L, node.getInt)
  of JFloat:
    lua_pushnumber(L, node.getFloat)
  of JString:
    discard lua_pushstring(L, node.getStr.cstring)
  of JArray:
    lua_newtable(L)
    for i, item in node.elems:
      pushJson(L, item)
      lua_rawseti(L, -2, (i + 1).cint)
  of JObject:
    lua_newtable(L)
    for k, v in node.fields:
      discard lua_pushstring(L, k.cstring)
      pushJson(L, v)
      lua_settable(L, -3)

# ── Lua table → JSON ──────────────────────────────────────────────────────────

proc luaToJson(L: LuaStatePtr; idx: cint): JsonNode

proc luaTableToJson(L: LuaStatePtr; idx: cint): JsonNode =
  ## Convert a Lua table at absolute stack index idx to JsonNode.
  ## Uses rawlen > 0 as the array heuristic (mirrors how we push from JSON).
  let absIdx = if idx < 0: lua_gettop(L) + idx + 1 else: idx
  let len    = lua_rawlen(L, absIdx.cint).int

  if len > 0:
    # Array-like: iterate 1..len
    result = newJArray()
    for i in 1 .. len:
      discard lua_rawgeti(L, absIdx.cint, i.int64)
      result.add luaToJson(L, -1)
      lua_settop(L, -2)
  else:
    # Object: iterate with lua_next
    result = newJObject()
    lua_pushnil(L)                       # first key
    while lua_next(L, absIdx.cint) != 0:
      # key at -2, value at -1
      let key = luaToString(L, -2)
      let val = luaToJson(L, -1)
      lua_settop(L, -2)                  # pop value, keep key for next iteration
      if key.len > 0:
        result[key] = val

proc luaToJson(L: LuaStatePtr; idx: cint): JsonNode =
  case lua_type(L, idx)
  of LUA_TNIL:     newJNull()
  of LUA_TBOOLEAN: newJBool(lua_toboolean(L, idx) != 0)
  of LUA_TNUMBER:
    if lua_isinteger(L, idx) != 0:
      newJInt(lua_tointegerx(L, idx, nil).int)
    else:
      newJFloat(lua_tonumberx(L, idx, nil).float)
  of LUA_TSTRING:  newJString(luaToString(L, idx))
  of LUA_TTABLE:   luaTableToJson(L, idx)
  else:            newJNull()

# ── Injected helper callbacks ─────────────────────────────────────────────────
# Each proc is a cdecl C callback registered as a Lua global.

proc cbWriteFile(L: LuaStatePtr): cint {.cdecl.} =
  let path    = luaToString(L, 1)
  let content = luaToString(L, 2)
  try:
    createDir(parentDir(path))
    writeFile(path, content)
  except CatchableError as e:
    discard lua_pushstring(L, ("write_file error: " & e.msg).cstring)
    return 1  # return error string (caller can ignore)
  return 0

proc cbReadFile(L: LuaStatePtr): cint {.cdecl.} =
  let path = luaToString(L, 1)
  try:
    discard lua_pushstring(L, readFile(path).cstring)
  except:
    lua_pushnil(L)
  return 1

proc cbMakeDirs(L: LuaStatePtr): cint {.cdecl.} =
  let path = luaToString(L, 1)
  try: createDir(path)
  except: discard
  return 0

proc cbPathJoin(L: LuaStatePtr): cint {.cdecl.} =
  let a = luaToString(L, 1)
  let b = luaToString(L, 2)
  discard lua_pushstring(L, (a / b).cstring)
  return 1

proc cbPathDirname(L: LuaStatePtr): cint {.cdecl.} =
  discard lua_pushstring(L, parentDir(luaToString(L, 1)).cstring)
  return 1

proc cbPathBasename(L: LuaStatePtr): cint {.cdecl.} =
  discard lua_pushstring(L, lastPathPart(luaToString(L, 1)).cstring)
  return 1

proc cbPathExists(L: LuaStatePtr): cint {.cdecl.} =
  lua_pushboolean(L, if fileExists(luaToString(L, 1)) or
                        dirExists(luaToString(L, 1)): 1 else: 0)
  return 1

proc cbIsDir(L: LuaStatePtr): cint {.cdecl.} =
  lua_pushboolean(L, if dirExists(luaToString(L, 1)): 1 else: 0)
  return 1

proc cbIsFile(L: LuaStatePtr): cint {.cdecl.} =
  lua_pushboolean(L, if fileExists(luaToString(L, 1)): 1 else: 0)
  return 1

proc cbListDir(L: LuaStatePtr): cint {.cdecl.} =
  let path = luaToString(L, 1)
  lua_newtable(L)
  var i = 1
  try:
    for kind, fpath in walkDir(path, relative = true):
      discard lua_pushstring(L, fpath.cstring)
      lua_rawseti(L, -2, i.cint)
      inc i
  except: discard
  return 1

proc cbCopyFile(L: LuaStatePtr): cint {.cdecl.} =
  let src = luaToString(L, 1)
  let dst = luaToString(L, 2)
  try:
    createDir(parentDir(dst))
    copyFile(src, dst)
  except: discard
  return 0

proc cbRemoveFile(L: LuaStatePtr): cint {.cdecl.} =
  try: removeFile(luaToString(L, 1))
  except: discard
  return 0

proc cbRemoveDir(L: LuaStatePtr): cint {.cdecl.} =
  try: removeDir(luaToString(L, 1))
  except: discard
  return 0

proc cbJsonEncode(L: LuaStatePtr): cint {.cdecl.} =
  ## json_encode(table) → JSON string. Accepts any Lua value.
  let node = luaToJson(L, 1)
  discard lua_pushstring(L, node.pretty.cstring)
  return 1

proc cbPrint(L: LuaStatePtr): cint {.cdecl.} =
  let n = lua_gettop(L)
  var parts: seq[string]
  for i in 1 .. n: parts.add luaToString(L, i.cint)
  echo parts.join("\t")
  return 0

# ── DriverState ───────────────────────────────────────────────────────────────

type
  DriverState* = object
    L*: LuaStatePtr

proc init*(ds: var DriverState) =
  ds.L = luaL_newstate()
  luaL_openlibs(ds.L)

  template reg(name: string; fn: LuaCFunction) =
    lua_pushcclosure(ds.L, fn, 0)
    lua_setglobal(ds.L, name.cstring)

  reg("write_file",    cbWriteFile)
  reg("read_file",     cbReadFile)
  reg("make_dirs",     cbMakeDirs)
  reg("path_join",     cbPathJoin)
  reg("path_dirname",  cbPathDirname)
  reg("path_basename", cbPathBasename)
  reg("path_exists",   cbPathExists)
  reg("is_dir",        cbIsDir)
  reg("is_file",       cbIsFile)
  reg("list_dir",      cbListDir)
  reg("copy_file",     cbCopyFile)
  reg("remove_file",   cbRemoveFile)
  reg("remove_dir",    cbRemoveDir)
  reg("json_encode",   cbJsonEncode)
  reg("print",         cbPrint)

proc close*(ds: var DriverState) =
  if ds.L != nil:
    lua_close(ds.L)
    ds.L = nil

proc loadDriver*(ds: var DriverState; luaPath: string): bool =
  ## Load and execute a driver .lua file, defining its export() global.
  if luaLoadFile(ds.L, luaPath) != LUA_OK:
    echo "[lua_runner] load error: ", luaPopError(ds.L)
    return false
  if luaPCall(ds.L, 0, 0, 0) != LUA_OK:
    echo "[lua_runner] exec error: ", luaPopError(ds.L)
    return false
  return true

# ── Call export() ─────────────────────────────────────────────────────────────

proc runExport*(ds: var DriverState;
                plugins: seq[PluginEntry];
                outputDir: string): int =
  ## Push the ordered plugin JSON data as a Lua table and call export().
  ## Returns the file count reported by the driver, or -1 on error.

  # Re-push function
  if lua_getglobal(ds.L, "export") != LUA_TFUNCTION:
    lua_settop(ds.L, 0)
    return -1

  # plugins table
  lua_newtable(ds.L)
  var i = 1
  for e in plugins:
    try:
      var raw = parseFile(e.path)
      if raw.kind == JObject:
        raw["_folder"] = newJString(e.folder)
      pushJson(ds.L, raw)
    except:
      lua_pushnil(ds.L)
    lua_rawseti(ds.L, -2, i.cint)
    inc i

  discard lua_pushstring(ds.L, "".cstring)          # scripts_dir
  discard lua_pushstring(ds.L, outputDir.cstring)   # output_dir
  lua_newtable(ds.L)                                 # kwargs

  if luaPCall(ds.L, 4, 1, 0) != LUA_OK:
    echo "[lua_runner] export() error: ", luaPopError(ds.L)
    lua_settop(ds.L, 0)
    return -1

  var isNum: cint = 0
  let n = lua_tointegerx(ds.L, -1, addr isNum).int
  lua_settop(ds.L, 0)
  return if isNum != 0: n else: 0

proc runAssetExport*(ds: var DriverState;
                     folderPaths: seq[string];
                     contentDir: string): int =
  ## Call the assets driver's export(folder_paths, content_dir).
  if lua_getglobal(ds.L, "export") != LUA_TFUNCTION:
    lua_settop(ds.L, 0)
    return -1

  lua_newtable(ds.L)
  for i, p in folderPaths:
    discard lua_pushstring(ds.L, p.cstring)
    lua_rawseti(ds.L, -2, (i + 1).cint)

  discard lua_pushstring(ds.L, contentDir.cstring)

  if luaPCall(ds.L, 2, 1, 0) != LUA_OK:
    echo "[lua_runner] assets export() error: ", luaPopError(ds.L)
    lua_settop(ds.L, 0)
    return -1

  var isNum: cint = 0
  let n = lua_tointegerx(ds.L, -1, addr isNum).int
  lua_settop(ds.L, 0)
  return if isNum != 0: n else: 0
