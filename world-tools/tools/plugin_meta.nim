## plugin_meta.nim
## Shared PluginMeta type and topological auto-sort for all tool_ids.
## Port of the PluginMeta dataclass + auto_sort() from the Python plugin managers.

import std/[json, tables, sets, deques, sequtils]

type
  PluginMeta* = object
    id*:          string
    name*:        string
    tool*:        string
    author*:      string
    version*:     string
    isMaster*:    bool
    tags*:        seq[string]
    loadAfter*:   seq[string]
    loadBefore*:  seq[string]
    notes*:       string
    enabled*:     bool

proc defaultMeta*(): PluginMeta =
  result.version = "1.0"
  result.enabled = true

# ── JSON round-trip ───────────────────────────────────────────────────────────

proc toJson*(m: PluginMeta): JsonNode =
  result = newJObject()
  result["id"]          = newJString(m.id)
  result["name"]        = newJString(m.name)
  result["tool"]        = newJString(m.tool)
  result["author"]      = newJString(m.author)
  result["version"]     = newJString(m.version)
  result["is_master"]   = newJBool(m.isMaster)
  var tags = newJArray()
  for t in m.tags: tags.add newJString(t)
  result["tags"] = tags
  var la = newJArray()
  for t in m.loadAfter: la.add newJString(t)
  result["load_after"] = la
  var lb = newJArray()
  for t in m.loadBefore: lb.add newJString(t)
  result["load_before"] = lb
  result["enabled"] = newJBool(m.enabled)
  if m.notes.len > 0:
    result["notes"] = newJString(m.notes)

proc metaFromJson*(j: JsonNode): PluginMeta =
  result = defaultMeta()
  if j.isNil or j.kind != JObject: return
  result.id         = j.getOrDefault("id").getStr
  result.name       = j.getOrDefault("name").getStr
  result.tool       = j.getOrDefault("tool").getStr
  result.author     = j.getOrDefault("author").getStr
  result.version    = j.getOrDefault("version").getStr("1.0")
  result.isMaster   = j.getOrDefault("is_master").getBool(false)
  result.notes      = j.getOrDefault("notes").getStr
  result.enabled    = j.getOrDefault("enabled").getBool(true)
  if j.hasKey("tags") and j["tags"].kind == JArray:
    for t in j["tags"]: result.tags.add t.getStr
  if j.hasKey("load_after") and j["load_after"].kind == JArray:
    for t in j["load_after"]: result.loadAfter.add t.getStr
  if j.hasKey("load_before") and j["load_before"].kind == JArray:
    for t in j["load_before"]: result.loadBefore.add t.getStr

# ── Auto-sort ─────────────────────────────────────────────────────────────────
## Kahn's topological sort. Masters always first. load_after/load_before use
## tags. Circular deps fall back to original order.
## Port of auto_sort() from world-editor/plugin_manager.py.

proc autoSort*[T](plugins: var seq[T]; getMeta: proc(p: T): PluginMeta) =
  ## Sort `plugins` in-place. T must expose a PluginMeta via `getMeta`.
  var masters:    seq[T]
  var nonMasters: seq[T]
  for p in plugins:
    if getMeta(p).isMaster: masters.add p
    else:                   nonMasters.add p

  let n = nonMasters.len
  if n <= 1:
    plugins = masters & nonMasters
    return

  # Build tag → index map
  var tagToIdx: Table[string, seq[int]]
  for i, p in nonMasters:
    for t in getMeta(p).tags:
      tagToIdx.mgetOrPut(t, @[]).add i

  var inDegree:  seq[int]    = newSeq[int](n)
  var successors: seq[HashSet[int]] = newSeq[HashSet[int]](n)

  proc addEdge(before, after: int) =
    if before != after and after notin successors[before]:
      successors[before].incl after
      inc inDegree[after]

  for j, p in nonMasters:
    let m = getMeta(p)
    for tag in m.loadAfter:
      for i in tagToIdx.getOrDefault(tag): addEdge(i, j)
    for tag in m.loadBefore:
      for k in tagToIdx.getOrDefault(tag): addEdge(j, k)

  var queue: Deque[int]
  for i in 0 ..< n:
    if inDegree[i] == 0: queue.addLast i

  var result: seq[T]
  while queue.len > 0:
    let i = queue.popFirst
    result.add nonMasters[i]
    var newlyFree: seq[int]
    for j in successors[i]:
      dec inDegree[j]
      if inDegree[j] == 0: newlyFree.add j
    newlyFree.sort()
    for j in newlyFree: queue.addLast j

  # Cycle fallback — append remainder in original order
  if result.len < n:
    let placed = result.mapIt(getMeta(it).id).toHashSet
    for p in nonMasters:
      if getMeta(p).id notin placed: result.add p

  plugins = masters & result
