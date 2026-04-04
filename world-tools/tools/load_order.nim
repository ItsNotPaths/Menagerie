## load_order.nim
## Read/write the shared load_order.json in a modpack directory.
##
## Format (same as plugin_db.nim in mod_manager):
##   { "world-tool": ["/abs/path/...json"], "room-editor": [...], ... }
##
## Each tool_id entry is an independent ordered list of absolute plugin paths.
## Operations on one tool_id preserve all other entries in the file.

import std/[json, os]

const LOAD_ORDER_FILE* = "load_order.json"

proc orderFilePath*(modpackDir: string): string =
  modpackDir / LOAD_ORDER_FILE

proc loadOrder*(modpackDir, toolId: string): seq[string] =
  ## Return the ordered list of plugin paths for toolId, or empty if missing.
  let path = orderFilePath(modpackDir)
  try:
    let j = parseFile(path)
    if j.hasKey(toolId) and j[toolId].kind == JArray:
      for e in j[toolId]: result.add e.getStr
  except: discard

proc saveOrder*(modpackDir, toolId: string; paths: seq[string]) =
  ## Write the path list for toolId, preserving all other tool_ids in the file.
  let path = orderFilePath(modpackDir)
  var j: JsonNode
  try:   j = parseFile(path)
  except: j = newJObject()
  # Drop legacy flat format
  if j.hasKey("load_order") and j.len == 1: j = newJObject()
  var arr = newJArray()
  for p in paths: arr.add newJString(p)
  j[toolId] = arr
  createDir(modpackDir)
  writeFile(path, j.pretty)
