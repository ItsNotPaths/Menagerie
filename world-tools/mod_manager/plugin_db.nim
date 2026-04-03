## plugin_db.nim
## Scan a modpack directory for plugins, manage load order per tool_id.
##
## Layout expected on disk:
##   data/<modpack>/
##     load_order.json          ← keyed by tool_id, stores abs paths to plugin JSONs
##     <PluginFolder>/
##       <plugin>.json          ← must contain meta.tool matching a known tool_id

import std/[json, os, strutils, tables, sequtils]

# ── Known tool tabs (order = tab display order) ───────────────────────────────

const TOOL_IDS* = ["world-tool", "room-editor", "gameplay-vars", "inkwell"]

# ── Types ─────────────────────────────────────────────────────────────────────

type
  PluginEntry* = object
    path*:      string   ## abs path to the plugin JSON
    folder*:    string   ## abs path to the plugin's containing folder
    toolId*:    string
    name*:      string
    isMaster*:  bool
    enabled*:   bool
    recordCount*: int    ## rough count of top-level data keys (for display)

  PluginDb* = object
    modpackDir*: string
    plugins*:    Table[string, seq[PluginEntry]]  ## tool_id → ordered list

# ── Helpers ───────────────────────────────────────────────────────────────────

proc orderFile(modpackDir: string): string =
  modpackDir / "load_order.json"

proc loadOrderFor(modpackDir, toolId: string): seq[string] =
  let path = orderFile(modpackDir)
  try:
    let j = parseFile(path)
    if j.hasKey(toolId) and j[toolId].kind == JArray:
      return j[toolId].elems.mapIt(it.getStr)
  except: discard
  return @[]

proc saveOrderFor*(modpackDir, toolId: string; paths: seq[string]) =
  let path = orderFile(modpackDir)
  var j: JsonNode
  try:   j = parseFile(path)
  except: j = newJObject()
  # drop legacy flat format
  if j.hasKey("load_order") and j.len == 1: j = newJObject()
  var arr = newJArray()
  for p in paths: arr.add newJString(p)
  j[toolId] = arr
  writeFile(path, j.pretty)

proc countRecords(raw: JsonNode): int =
  ## Rough record count — sum the lengths of the main data tables.
  const DATA_KEYS = ["tiles","presets","vars","npcs","shops","quests",
                     "effects","items","armor_plates","ai_packages","spells","mobs"]
  for k in DATA_KEYS:
    if raw.hasKey(k):
      let v = raw[k]
      case v.kind
      of JObject: result += v.len
      of JArray:  result += v.len
      else: discard

# ── Scan ──────────────────────────────────────────────────────────────────────

proc scan*(modpackDir: string): PluginDb =
  ## Walk modpackDir, discover all plugin JSONs, apply saved load order.
  result.modpackDir = modpackDir
  for tid in TOOL_IDS:
    result.plugins[tid] = @[]

  # Discover all plugins, keyed by abs path
  var found: Table[string, PluginEntry]
  for kind, folder in walkDir(modpackDir):
    if kind != pcDir: continue
    for kind2, fpath in walkDir(folder):
      if kind2 != pcFile: continue
      if not fpath.endsWith(".json"): continue
      try:
        let raw  = parseFile(fpath)
        let meta = raw.getOrDefault("meta")
        if meta.isNil or meta.kind != JObject: continue
        let tid = meta.getOrDefault("tool").getStr
        if tid notin TOOL_IDS: continue
        var e: PluginEntry
        e.path        = fpath
        e.folder      = folder
        e.toolId      = tid
        e.name        = meta.getOrDefault("name").getStr(lastPathPart(folder))
        e.isMaster    = meta.getOrDefault("is_master").getBool(false)
        e.enabled     = meta.getOrDefault("enabled").getBool(true)
        e.recordCount = countRecords(raw)
        found[fpath]  = e
      except: discard

  # Apply saved load order; append any newly discovered plugins at the end
  for tid in TOOL_IDS:
    let order = loadOrderFor(modpackDir, tid)
    var seen: Table[string, bool]
    for p in order:
      if found.hasKey(p) and found[p].toolId == tid:
        result.plugins[tid].add found[p]
        seen[p] = true
    for p, e in found:
      if e.toolId == tid and not seen.hasKey(p):
        result.plugins[tid].add e

proc save*(db: PluginDb) =
  ## Persist the current load order for all tool_ids.
  for tid in TOOL_IDS:
    let paths = db.plugins[tid].mapIt(it.path)
    saveOrderFor(db.modpackDir, tid, paths)

# ── Mutation helpers ──────────────────────────────────────────────────────────

proc moveUp*(db: var PluginDb; tid: string; idx: int) =
  if idx > 0 and idx < db.plugins[tid].len:
    swap(db.plugins[tid][idx], db.plugins[tid][idx - 1])
    db.save()

proc moveDown*(db: var PluginDb; tid: string; idx: int) =
  let L = db.plugins[tid].len
  if idx >= 0 and idx < L - 1:
    swap(db.plugins[tid][idx], db.plugins[tid][idx + 1])
    db.save()

proc toggleEnabled*(db: var PluginDb; tid: string; idx: int) =
  ## Toggle enabled flag and write back to the plugin JSON.
  if idx < 0 or idx >= db.plugins[tid].len: return
  let e = addr db.plugins[tid][idx]
  e.enabled = not e.enabled
  try:
    var raw = parseFile(e.path)
    if raw.hasKey("meta") and raw["meta"].kind == JObject:
      raw["meta"]["enabled"] = newJBool(e.enabled)
    writeFile(e.path, raw.pretty)
  except: discard

proc enabledPlugins*(db: PluginDb; tid: string): seq[PluginEntry] =
  db.plugins[tid].filterIt(it.enabled)
