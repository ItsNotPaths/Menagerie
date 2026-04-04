## plugin_io.nim
## Scan a modpack directory for plugins belonging to a given tool_id,
## apply saved load order, and provide raw JSON load/save.
##
## Higher-level tab modules (world_tab, rooms_tab, vars_tab) parse the
## returned JsonNode into their own typed structures.

import std/[json, os, tables, sequtils, strutils]
import plugin_meta
import load_order

type
  PluginEntry* = object
    path*:     string    ## absolute path to the plugin JSON file
    meta*:     PluginMeta

# ── Scan ──────────────────────────────────────────────────────────────────────

proc scanModpack*(modpackDir, toolId: string): seq[PluginEntry] =
  ## Walk modpackDir (one level deep), collect all plugin JSONs whose
  ## meta.tool == toolId, then reorder according to load_order.json.
  ## Any files not in the saved order are appended at the end.
  var found: Table[string, PluginEntry]
  try:
    for kind, folder in walkDir(modpackDir):
      if kind != pcDir: continue
      for kind2, fpath in walkDir(folder):
        if kind2 != pcFile: continue
        if not fpath.endsWith(".json"): continue
        try:
          let raw  = parseFile(fpath)
          let meta = metaFromJson(raw.getOrDefault("meta"))
          if meta.tool != toolId: continue
          found[fpath] = PluginEntry(path: fpath, meta: meta)
        except: discard
  except: discard

  # Apply saved order, then append newly discovered
  let order = loadOrder(modpackDir, toolId)
  var seen: Table[string, bool]
  for p in order:
    if found.hasKey(p):
      result.add found[p]
      seen[p] = true
  for p, e in found:
    if not seen.hasKey(p): result.add e

# ── Load / Save ───────────────────────────────────────────────────────────────

proc loadPluginJson*(path: string): JsonNode =
  ## Parse a plugin file; returns nil on error.
  try: result = parseFile(path)
  except: result = nil

proc savePluginJson*(path: string; j: JsonNode) =
  ## Write plugin JSON to path (creates parent dirs as needed).
  createDir(parentDir(path))
  writeFile(path, j.pretty)

# ── Meta mutation helpers ──────────────────────────────────────────────────────

proc patchEnabled*(path: string; enabled: bool) =
  ## Toggle enabled flag in a plugin file without a full round-trip.
  try:
    var j = parseFile(path)
    if j.hasKey("meta") and j["meta"].kind == JObject:
      j["meta"]["enabled"] = newJBool(enabled)
    writeFile(path, j.pretty)
  except: discard

proc deletePlugin*(modpackDir, toolId, path: string;
                  entries: var seq[PluginEntry]) =
  ## Remove plugin from the entry list, delete the file and its parent folder
  ## (if the folder is now empty), then update load order.
  entries.keepItIf(it.path != path)
  let folder = parentDir(path)
  try: removeFile(path)
  except: discard
  try:
    var empty = true
    for _, _ in walkDir(folder): empty = false; break
    if empty: removeDir(folder)
  except: discard
  saveOrder(modpackDir, toolId, entries.mapIt(it.path))

proc persistOrder*(modpackDir, toolId: string; entries: seq[PluginEntry]) =
  saveOrder(modpackDir, toolId, entries.mapIt(it.path))
