## world_tab.nim
## World tile-map editor tab — infinite grid, pan/zoom, paint/erase, undo/redo.
## Tile edit form opens on double-click via tile_form.nim overlay.

import sdl2
import sdl2/ttf
import std/[json, tables, strformat, math, os, strutils, algorithm, sets]
import "../theme"
import "../../src/engine/log"
import plugin_meta
import plugin_io
import world_data
import tile_form

# ── Constants ─────────────────────────────────────────────────────────────────

const
  PALETTE_W  = 120
  PAL_ROW_H  = 36
  MAX_UNDO   = 100
  CELL_MIN   = 1.0
  CELL_MAX   = 64.0
  CELL_DEF   = 8.0
  GRID_FADE_LO = 6.0   ## cellSize below which grid is invisible
  GRID_FADE_HI = 12.0  ## cellSize above which grid is full opacity

# ── Types ─────────────────────────────────────────────────────────────────────

type
  WorldPlugin = object
    meta:       PluginMeta
    world_seed: int
    tiles:      Table[(int, int), TileEntry]
    path:       string
    dirty:      bool

  MergedTile = object
    entry:    TileEntry
    isActive: bool

  DragMode = enum dmNone, dmPanning, dmPainting

  WorldTab* = object
    plugins:      seq[WorldPlugin]
    selPluginIdx: int
    modpackDir:   string
    imageFiles:   seq[string]   ## basenames scanned from modpack asset folders

    # Canvas state
    offsetX, offsetY: float
    cellSize:         float
    selTileX, selTileY: int
    hasSel:           bool

    # Drag state
    dragMode:    DragMode
    panStartMx, panStartMy: int
    panStartOx, panStartOy: float
    lastPaintX, lastPaintY: int

    # Palette
    selTileType: int
    palRowRects: array[4, Rect]

    # Undo / redo (per active plugin, cleared on switch)
    undoStack:    seq[Table[(int, int), TileEntry]]
    redoStack:    seq[Table[(int, int), TileEntry]]
    undoPlugin:   int

    # Tile form overlay
    tileForm: TileForm

    # Layout cache (set each render, read by input handlers)
    canvasX, canvasY, canvasW, canvasH: int
    paletteX: int
    needCenter: bool   ## center origin on first render after reload

    statusMsg*: string
    statusOk*:  bool

# ── JSON helpers ──────────────────────────────────────────────────────────────

proc tileToJson(t: TileEntry): JsonNode =
  result = newJObject()
  result["x"]         = newJInt(t.x)
  result["y"]         = newJInt(t.y)
  result["tile"]      = newJString(t.tile)
  result["type"]      = newJString(t.`type`)
  result["image"]     = newJString(t.image)
  result["entry_tag"] = newJString(t.entry_tag)
  var blocksArr = newJArray()
  for b in t.room_blocks:
    var bj = newJObject()
    var tagsArr = newJArray()
    for tag in b.tags: tagsArr.add newJString(tag)
    bj["tags"] = tagsArr
    var entriesArr = newJArray()
    for e in b.entries:
      var ej = newJObject()
      ej["condition"] = newJString(e.condition)
      ej["room"]      = newJString(e.room)
      entriesArr.add ej
    bj["entries"] = entriesArr
    blocksArr.add bj
  result["room_blocks"] = blocksArr
  var linksArr = newJArray()
  for lnk in t.room_links: linksArr.add newJString(lnk)
  result["room_links"] = linksArr
  var npcsArr = newJArray()
  for npc in t.global_npcs: npcsArr.add newJString(npc)
  result["global_npcs"] = npcsArr
  result["encounter_chance"] = newJInt(t.encounter_chance)
  var encTagsArr = newJArray()
  for tag in t.encounter_tags: encTagsArr.add newJString(tag)
  result["encounter_tags"] = encTagsArr

proc tileFromJson(j: JsonNode): TileEntry =
  result.x         = j.getOrDefault("x").getInt
  result.y         = j.getOrDefault("y").getInt
  result.tile      = j.getOrDefault("tile").getStr
  result.`type`    = j.getOrDefault("type").getStr("road")
  result.image     = j.getOrDefault("image").getStr
  result.entry_tag = j.getOrDefault("entry_tag").getStr
  result.deleted   = j.getOrDefault("deleted").getBool(false)
  if j.hasKey("room_blocks") and j["room_blocks"].kind == JArray:
    for bj in j["room_blocks"]:
      var b: RoomBlock
      if bj.hasKey("tags") and bj["tags"].kind == JArray:
        for t in bj["tags"]: b.tags.add t.getStr
      if bj.hasKey("entries") and bj["entries"].kind == JArray:
        for ej in bj["entries"]:
          b.entries.add RoomCondEntry(
            condition: ej.getOrDefault("condition").getStr,
            room:      ej.getOrDefault("room").getStr
          )
      result.room_blocks.add b
  if j.hasKey("room_links") and j["room_links"].kind == JArray:
    for lnk in j["room_links"]: result.room_links.add lnk.getStr
  if j.hasKey("global_npcs") and j["global_npcs"].kind == JArray:
    for n in j["global_npcs"]: result.global_npcs.add n.getStr
  result.encounter_chance = j.getOrDefault("encounter_chance").getInt(0)
  if j.hasKey("encounter_tags") and j["encounter_tags"].kind == JArray:
    for tag in j["encounter_tags"]: result.encounter_tags.add tag.getStr

proc toJson(p: WorldPlugin): JsonNode =
  result = newJObject()
  result["meta"]       = p.meta.toJson()
  result["world_seed"] = newJInt(p.world_seed)
  var tilesArr = newJArray()
  for _, t in p.tiles:
    if not t.deleted: tilesArr.add tileToJson(t)
  result["tiles"] = tilesArr

proc save(p: var WorldPlugin) =
  savePluginJson(p.path, p.toJson())
  p.dirty = false

proc loadWorldPlugin(path: string): WorldPlugin =
  result.path = path
  let raw = loadPluginJson(path)
  if raw.isNil: return
  result.meta       = metaFromJson(raw.getOrDefault("meta"))
  result.world_seed = raw.getOrDefault("world_seed").getInt(0)
  if raw.hasKey("tiles") and raw["tiles"].kind == JArray:
    for tj in raw["tiles"]:
      let t = tileFromJson(tj)
      result.tiles[(t.x, t.y)] = t

# ── Plugin management ─────────────────────────────────────────────────────────

proc scanImageFiles(modpackDir: string): seq[string] =
  const IMG_EXTS = [".png", ".jpg", ".jpeg", ".webp"]
  if not dirExists(modpackDir): return
  var seen: HashSet[string]
  for kind, pluginDir in walkDir(modpackDir):
    if kind != pcDir: continue
    let assetsDir = pluginDir / "assets"
    if not dirExists(assetsDir): continue
    for f in walkDirRec(assetsDir):
      let ext = f.splitFile.ext.toLowerAscii
      if ext in IMG_EXTS:
        let basename = f.splitFile.name & ext
        if basename notin seen:
          seen.incl basename
          result.add basename
  result.sort()

proc reload*(wt: var WorldTab; modpackDir, contentDir: string) =
  wt.modpackDir    = modpackDir
  wt.imageFiles    = scanImageFiles(modpackDir)
  wt.plugins       = @[]
  let entries = scanModpack(modpackDir, "world-tool")
  for e in entries:
    wt.plugins.add loadWorldPlugin(e.path)
  wt.selPluginIdx = if wt.plugins.len > 0: 0 else: -1
  wt.cellSize     = CELL_DEF
  wt.needCenter   = true
  wt.hasSel       = false
  wt.dragMode     = dmNone
  wt.selTileType  = 0
  wt.undoStack    = @[]
  wt.redoStack    = @[]
  wt.undoPlugin   = wt.selPluginIdx
  wt.tileForm.open = false
  wt.statusMsg    = fmt"{wt.plugins.len} world plugin(s)"
  wt.statusOk     = true

proc reloadForPlugin*(wt: var WorldTab; activePluginPath: string) =
  for i, p in wt.plugins:
    if p.path == activePluginPath:
      if i != wt.selPluginIdx:
        wt.selPluginIdx = i
        wt.undoStack    = @[]
        wt.redoStack    = @[]
        wt.undoPlugin   = i
      return

proc isDirty*(wt: WorldTab): bool =
  wt.selPluginIdx >= 0 and wt.selPluginIdx < wt.plugins.len and
  wt.plugins[wt.selPluginIdx].dirty

proc saveActive*(wt: var WorldTab) =
  if wt.selPluginIdx >= 0 and wt.selPluginIdx < wt.plugins.len:
    wt.plugins[wt.selPluginIdx].save()
    wt.statusMsg = "Saved"
    wt.statusOk  = true

# ── Canvas helpers ────────────────────────────────────────────────────────────

proc buildMerged(wt: WorldTab): Table[(int, int), MergedTile] =
  for i, p in wt.plugins:
    if not p.meta.enabled: continue
    for coord, t in p.tiles:
      if t.deleted: continue
      result[coord] = MergedTile(entry: t, isActive: i == wt.selPluginIdx)

proc tileCoord(wt: WorldTab; sx, sy: int): (int, int) =
  ## Screen position → tile coordinate (canvas-relative).
  (floor((sx.float - wt.canvasX.float - wt.offsetX) / wt.cellSize).int,
   floor((sy.float - wt.canvasY.float - wt.offsetY) / wt.cellSize).int)

# ── Undo / redo ───────────────────────────────────────────────────────────────

proc pushUndo(wt: var WorldTab) =
  if wt.selPluginIdx < 0 or wt.selPluginIdx >= wt.plugins.len: return
  wt.redoStack = @[]
  wt.undoStack.add wt.plugins[wt.selPluginIdx].tiles
  if wt.undoStack.len > MAX_UNDO: wt.undoStack.delete(0)

proc doUndo*(wt: var WorldTab) =
  if wt.undoStack.len == 0 or wt.selPluginIdx < 0: return
  let p = addr wt.plugins[wt.selPluginIdx]
  wt.redoStack.add p.tiles
  if wt.redoStack.len > MAX_UNDO: wt.redoStack.delete(0)
  p.tiles = wt.undoStack.pop()
  p.dirty = true
  wt.statusMsg = "Undo"
  wt.statusOk  = true

proc doRedo*(wt: var WorldTab) =
  if wt.redoStack.len == 0 or wt.selPluginIdx < 0: return
  let p = addr wt.plugins[wt.selPluginIdx]
  wt.undoStack.add p.tiles
  if wt.undoStack.len > MAX_UNDO: wt.undoStack.delete(0)
  p.tiles = wt.redoStack.pop()
  p.dirty = true
  wt.statusMsg = "Redo"
  wt.statusOk  = true

# ── Tile mutations ────────────────────────────────────────────────────────────

proc paintTile(wt: var WorldTab; tx, ty: int) =
  if wt.selPluginIdx < 0: return
  let merged = buildMerged(wt)
  if merged.hasKey((tx, ty)): return
  pushUndo(wt)
  wt.plugins[wt.selPluginIdx].tiles[(tx, ty)] = TileEntry(
    x: tx, y: ty,
    tile: fmt"tile_{tx}_{ty}",
    `type`: TILE_TYPES[wt.selTileType]
  )
  wt.plugins[wt.selPluginIdx].dirty = true

proc eraseTile(wt: var WorldTab; tx, ty: int) =
  if wt.selPluginIdx < 0: return
  if not wt.plugins[wt.selPluginIdx].tiles.hasKey((tx, ty)): return
  pushUndo(wt)
  wt.plugins[wt.selPluginIdx].tiles.del((tx, ty))
  wt.plugins[wt.selPluginIdx].dirty = true
  wt.hasSel = false

# ── Rendering ─────────────────────────────────────────────────────────────────

proc renderCanvas(wt: var WorldTab; ren: RendererPtr; font: FontPtr; fontH: int;
                  mx, my: int) =
  let cx = wt.canvasX
  let cy = wt.canvasY
  let cw = wt.canvasW
  let ch = wt.canvasH

  # Clip to canvas rect
  var clip = sdl2.rect(cx.cint, cy.cint, cw.cint, ch.cint)
  discard ren.setClipRect(addr clip)

  ren.fillRect(cx, cy, cw, ch, BG)

  if wt.plugins.len == 0:
    renderText(ren, font, "No world plugin — create one in the sidebar.",
               cx + PAD, cy + PAD, FG_DIM)
    discard ren.setClipRect(nil)
    return

  # Visible tile range
  let x0 = floor(-wt.offsetX / wt.cellSize).int - 1
  let y0 = floor(-wt.offsetY / wt.cellSize).int - 1
  let x1 = x0 + ceil(cw.float / wt.cellSize).int + 2
  let y1 = y0 + ceil(ch.float / wt.cellSize).int + 2

  let merged = buildMerged(wt)

  # Draw tile fills
  for coord, mt in merged:
    let (tx, ty) = coord
    if tx < x0 or tx > x1 or ty < y0 or ty > y1: continue
    let sx = (tx.float * wt.cellSize + wt.offsetX).int + cx
    let sy = (ty.float * wt.cellSize + wt.offsetY).int + cy
    let sz = max(1, wt.cellSize.int)
    var c = tileColor(mt.entry.`type`)
    if not mt.isActive:
      c.r = (c.r.int * 45 div 100).uint8
      c.g = (c.g.int * 45 div 100).uint8
      c.b = (c.b.int * 45 div 100).uint8
    ren.fillRect(sx, sy, sz, sz, c)

  # Draw grid lines (fade in between GRID_FADE_LO and GRID_FADE_HI)
  if wt.cellSize >= GRID_FADE_LO:
    let t = clamp((wt.cellSize - GRID_FADE_LO) / (GRID_FADE_HI - GRID_FADE_LO), 0.0, 1.0)
    let alpha = (t * 160.0 + 0.5).uint8
    discard ren.setDrawBlendMode(BlendMode_Blend)
    discard ren.setDrawColor(BG3.r, BG3.g, BG3.b, alpha)
    for tx in x0 .. x1:
      let sx = (tx.float * wt.cellSize + wt.offsetX).int + cx
      if sx < cx or sx >= cx + cw: continue
      discard ren.drawLine(sx.cint, cy.cint, sx.cint, (cy + ch).cint)
    for ty in y0 .. y1:
      let sy = (ty.float * wt.cellSize + wt.offsetY).int + cy
      if sy < cy or sy >= cy + ch: continue
      discard ren.drawLine(cx.cint, sy.cint, (cx + cw).cint, sy.cint)
    discard ren.setDrawBlendMode(BlendMode_None)

  # Selected tile outline
  if wt.hasSel:
    let sx = (wt.selTileX.float * wt.cellSize + wt.offsetX).int + cx
    let sy = (wt.selTileY.float * wt.cellSize + wt.offsetY).int + cy
    let sz = max(1, wt.cellSize.int)
    ren.drawRect(sx, sy, sz, sz, (r: 255'u8, g: 255'u8, b: 255'u8, a: 255'u8))

  discard ren.setClipRect(nil)

  # Coordinate overlay (outside clip so it's always readable)
  let (tx, ty) = wt.tileCoord(mx, my)
  renderText(ren, font, fmt"({tx}, {ty})", cx + PAD, cy + PAD, FG_DIM)

proc renderPalette(wt: var WorldTab; ren: RendererPtr; font: FontPtr; fontH: int;
                   mx, my: int) =
  let px = wt.paletteX
  let py = wt.canvasY
  let pw = PALETTE_W
  let ph = wt.canvasH

  ren.fillRect(px, py, pw, ph, BG2)
  ren.drawVLine(px, py, ph, BG3)
  renderText(ren, font, "Type", px + PAD, py + PAD, FG_DIM)

  let startY = py + PAD + fontH + PAD
  for i, tc in TILE_COLORS:
    let ry  = startY + i * PAL_ROW_H
    let isSel = i == wt.selTileType
    wt.palRowRects[i] = (px.cint, ry.cint, pw.cint, PAL_ROW_H.cint)
    let isHot = not isSel and mx >= px and mx < px + pw and
                my >= ry and my < ry + PAL_ROW_H
    ren.fillRect(px, ry, pw, PAL_ROW_H,
                 if isSel: SEL_BG elif isHot: BTN_HOV else: BG2)
    ren.fillRect(px + PAD, ry + (PAL_ROW_H - 14) div 2, 14, 14, tc.color)
    renderText(ren, font, tc.name,
               px + PAD + 18, ry + (PAL_ROW_H - fontH) div 2 - 2,
               if isSel: FG_ACTIVE else: FG)
    if isSel:
      renderText(ren, font, "*",
                 px + pw - PAD - textWidth(font, "*"),
                 ry + (PAL_ROW_H - fontH) div 2 - 2, FG_ACTIVE)

proc render*(wt: var WorldTab; ren: RendererPtr; font: FontPtr; fontH: int;
             x, y, w, h: int; mx, my: int) =
  wt.canvasX  = x
  wt.canvasY  = y
  wt.canvasW  = w - PALETTE_W
  wt.canvasH  = h
  wt.paletteX = x + w - PALETTE_W

  if wt.needCenter:
    wt.offsetX  = wt.canvasW.float / 2.0
    wt.offsetY  = wt.canvasH.float / 2.0
    wt.needCenter = false

  wt.renderCanvas(ren, font, fontH, mx, my)
  wt.renderPalette(ren, font, fontH, mx, my)

  # Tile form overlay (drawn last — on top of everything)
  wt.tileForm.render(ren, font, fontH,
                     wt.canvasX, wt.canvasY, wt.canvasW, wt.canvasH, mx, my)

# ── Form result handling ──────────────────────────────────────────────────────

proc processFormResults(wt: var WorldTab) =
  if wt.tileForm.wasSaved:
    wt.tileForm.wasSaved = false
    if wt.selPluginIdx >= 0:
      let entry = wt.tileForm.resultEntry
      pushUndo(wt)
      wt.plugins[wt.selPluginIdx].tiles[(entry.x, entry.y)] = entry
      wt.plugins[wt.selPluginIdx].dirty = true
      wt.hasSel   = true
      wt.selTileX = entry.x
      wt.selTileY = entry.y
      if wt.tileForm.warnMsgs.len > 0:
        let warns = wt.tileForm.warnMsgs.join("; ")
        wt.statusMsg = fmt"Unsaved — link warnings: {warns}"
        wt.statusOk  = false
        log(Tools, Warn, fmt"world tile ({entry.x},{entry.y}): {warns}")
      else:
        wt.statusMsg = "Unsaved changes"
        wt.statusOk  = true
  elif wt.tileForm.wasCopied:
    wt.tileForm.wasCopied = false
    if wt.selPluginIdx >= 0:
      let entry = wt.tileForm.resultEntry
      pushUndo(wt)
      wt.plugins[wt.selPluginIdx].tiles[(entry.x, entry.y)] = entry
      wt.plugins[wt.selPluginIdx].dirty = true
      wt.hasSel   = true
      wt.selTileX = entry.x
      wt.selTileY = entry.y
      wt.statusMsg = fmt"Copied to {wt.plugins[wt.selPluginIdx].meta.name}"
      wt.statusOk  = true
  elif wt.tileForm.wasCancelled:
    wt.tileForm.wasCancelled = false

# ── Input ─────────────────────────────────────────────────────────────────────

proc inCanvas(wt: WorldTab; x, y: int): bool =
  x >= wt.canvasX and x < wt.canvasX + wt.canvasW and
  y >= wt.canvasY and y < wt.canvasY + wt.canvasH

proc inPalette(wt: WorldTab; x, y: int): bool =
  x >= wt.paletteX and x < wt.paletteX + PALETTE_W and
  y >= wt.canvasY  and y < wt.canvasY + wt.canvasH

proc handleMouseDown*(wt: var WorldTab; x, y, btn, clicks: int;
                      activePluginPath: string) =
  wt.reloadForPlugin(activePluginPath)

  # Route to tile form when open
  if wt.tileForm.open:
    wt.tileForm.handleMouseDown(x, y, btn)
    wt.processFormResults()
    return

  # Palette
  if wt.inPalette(x, y):
    for i in 0 ..< 4:
      if y >= wt.palRowRects[i].y.int and
         y < wt.palRowRects[i].y.int + wt.palRowRects[i].h.int:
        wt.selTileType = i
    return

  if not wt.inCanvas(x, y): return

  let (tx, ty) = wt.tileCoord(x, y)

  # Middle-click → start panning
  if btn == 2:
    wt.dragMode   = dmPanning
    wt.panStartMx = x
    wt.panStartMy = y
    wt.panStartOx = wt.offsetX
    wt.panStartOy = wt.offsetY
    return

  # Right-click → erase from active plugin
  if btn == 3:
    wt.eraseTile(tx, ty)
    return

  # Left-click
  if btn == 1:
    let merged = buildMerged(wt)
    if clicks >= 2 and merged.hasKey((tx, ty)):
      # Double-click → open tile form
      let mt = merged[(tx, ty)]
      wt.tileForm.openFor(mt.entry, not mt.isActive, wt.imageFiles)
      wt.hasSel   = true
      wt.selTileX = tx
      wt.selTileY = ty
      return
    if merged.hasKey((tx, ty)):
      # Single click on existing tile → select
      wt.hasSel   = true
      wt.selTileX = tx
      wt.selTileY = ty
    else:
      # Empty cell → start painting
      wt.hasSel = false
      if wt.selPluginIdx >= 0:
        wt.dragMode    = dmPainting
        wt.lastPaintX  = tx - 1  ## force first paint
        wt.lastPaintY  = ty
        wt.paintTile(tx, ty)
        wt.lastPaintX = tx
        wt.lastPaintY = ty

proc handleMouseUp*(wt: var WorldTab; x, y, btn: int) =
  if btn == 1 or btn == 2:
    wt.dragMode = dmNone

proc handleMouseMotion*(wt: var WorldTab; x, y: int) =
  if wt.tileForm.open: return
  case wt.dragMode
  of dmPanning:
    wt.offsetX = wt.panStartOx + (x - wt.panStartMx).float
    wt.offsetY = wt.panStartOy + (y - wt.panStartMy).float
  of dmPainting:
    if wt.inCanvas(x, y):
      let (tx, ty) = wt.tileCoord(x, y)
      if (tx, ty) != (wt.lastPaintX, wt.lastPaintY):
        wt.paintTile(tx, ty)
        wt.lastPaintX = tx
        wt.lastPaintY = ty
  of dmNone: discard

proc handleWheel*(wt: var WorldTab; dy, mx, my: int) =
  if wt.tileForm.open:
    wt.tileForm.handleWheel(dy, mx, my)
    return
  if not wt.inCanvas(mx, my): return
  let factor    = if dy > 0: 1.15 else: 1.0 / 1.15
  let newSize   = clamp(wt.cellSize * factor, CELL_MIN, CELL_MAX)
  let tx = (mx.float - wt.canvasX.float - wt.offsetX) / wt.cellSize
  let ty = (my.float - wt.canvasY.float - wt.offsetY) / wt.cellSize
  wt.cellSize = newSize
  wt.offsetX  = mx.float - wt.canvasX.float - tx * wt.cellSize
  wt.offsetY  = my.float - wt.canvasY.float - ty * wt.cellSize

proc handleTextInput*(wt: var WorldTab; text: string) =
  if wt.tileForm.open:
    wt.tileForm.handleTextInput(text)

proc handleKeyDown*(wt: var WorldTab; sym: Scancode; ctrl, shift: bool) =
  if wt.tileForm.open:
    wt.tileForm.handleKeyDown(sym, ctrl, shift)
    wt.processFormResults()
    return
  if ctrl:
    case sym
    of SDL_SCANCODE_Z: wt.doUndo()
    of SDL_SCANCODE_Y: wt.doRedo()
    else: discard
