## rooms_tab.nim
## Room preset editor tab — preset list + detail form + sprite canvas overlay.

import sdl2
import sdl2/ttf
import std/[json, tables, os, strutils, strformat, algorithm]
import "../theme"
import plugin_meta
import plugin_io
import room_data
import sprite_canvas

# ── Constants ─────────────────────────────────────────────────────────────────

const
  LIST_FRAC  = 35    ## percent of tab width used by the preset list column
  BORDER_W   = 3     ## category-color left border on list rows
  LABEL_W    = 100   ## form label column width
  DESC_LINES = 4     ## visible lines in the description textarea
  CHIP_PAD   = 6     ## horizontal padding inside enemy chips
  CHIP_H     = ROW_H - 6
  CHIP_GAP   = 4

# ── Types ─────────────────────────────────────────────────────────────────────

type
  RoomPreset = object
    id, name, category, `type`, description, image: string
    enemies:          seq[string]
    sprite_positions: seq[SpritePos]
    deleted:          bool

  RoomsPlugin = object
    meta:    PluginMeta
    presets: Table[string, RoomPreset]
    path:    string
    dirty:   bool

  PresetItem = tuple[id: string; pidx: int]

  EditField = enum
    efNone, efSearch, efName, efDescLine, efEnemyAdd, efImageFilter

  DropTarget = enum dtNone, dtCategory, dtType, dtImage

  RoomsTab* = object
    plugins:      seq[RoomsPlugin]
    selPluginIdx: int
    modpackDir:   string
    contentDir:   string
    imageFiles:   seq[string]   ## basenames scanned from modpackDir plugin asset folders

    filtered:    seq[PresetItem]
    selPresetId: string
    listScrollY: int

    ## Search bar
    searchBuf:    string
    searchCursor: int

    ## New preset inline form
    newMode:   bool
    newBuf:    string
    newCursor: int

    ## Single-field edit state
    editField:     EditField
    editBuf:       string
    editCursorPos: int

    ## Description multi-line edit state
    editDescLines: seq[string]
    editDescLine:  int
    descScrollY:   int

    ## Dropdown
    dropOpen: DropTarget

    ## Image filter text input
    imageFilterBuf:    string
    imageFilterCursor: int
    imageFiltered:     seq[string]  # subset of imageFiles matching imageFilterBuf

    ## Sprite canvas overlay
    sc: SpriteCanvas

    ## Layout cache (set each render pass, read by input handlers)
    listX, listY, listW, listH:   int
    searchBarY, searchBarH:       int
    listRowsY, listRowsH:         int
    formX, formY, formW, formH:   int
    fLabelX, fInputX, fInputW:    int

    ## Form field y-positions (top of each labeled row)
    fIdY, fNameY, fCatY, fTypeY:  int
    fDescY, fDescH:               int
    fImageY, fEnemyY:             int
    fSpriteY, fCopyBtnY:          int

    ## Drop popup bounds (when open)
    dropPopX, dropPopY, dropPopW, dropPopH: int

    ## List button rects
    lbtnNewX, lbtnNewW: int
    lbtnDupX, lbtnDupW: int
    lbtnDelX, lbtnDelW: int
    lbtnY, lbtnH:       int

    ## Enemy chip rects (rebuilt each render pass)
    chipRects:    seq[tuple[x, y, w, h: int]]
    enemyAddBtnX, enemyAddBtnY, enemyAddBtnW: int
    spriteBtnX,   spriteBtnY,   spriteBtnW:   int
    copyBtnX,     copyBtnY,     copyBtnW:     int

    statusMsg*: string
    statusOk*:  bool

# ── JSON helpers ──────────────────────────────────────────────────────────────

proc loadRoomsPlugin(path: string): RoomsPlugin =
  result.path = path
  let raw = loadPluginJson(path)
  if raw.isNil: return
  result.meta = metaFromJson(raw.getOrDefault("meta"))
  let node = raw.getOrDefault("presets")
  if node.isNil or node.kind != JObject: return
  for presetId, pn in node:
    var p: RoomPreset
    p.id          = pn.getOrDefault("id").getStr
    if p.id.len == 0: p.id = presetId
    p.name        = pn.getOrDefault("name").getStr
    p.category    = pn.getOrDefault("category").getStr
    p.`type`      = pn.getOrDefault("type").getStr
    p.description = pn.getOrDefault("description").getStr
    p.image       = pn.getOrDefault("image").getStr
    p.deleted     = pn.getOrDefault("deleted").getBool
    let en = pn.getOrDefault("enemies")
    if not en.isNil and en.kind == JArray:
      for e in en: p.enemies.add e.getStr
    let sp = pn.getOrDefault("sprite_positions")
    if not sp.isNil and sp.kind == JArray:
      for pair in sp:
        if pair.kind == JArray and pair.len >= 2:
          p.sprite_positions.add [pair[0].getFloat.float32,
                                  pair[1].getFloat.float32]
    if p.id.len > 0:
      result.presets[p.id] = p

proc toJson(p: RoomsPlugin): JsonNode =
  result = newJObject()
  result["meta"] = p.meta.toJson()
  var presetsObj = newJObject()
  for id, pr in p.presets:
    if pr.deleted: continue
    var pn = newJObject()
    pn["id"]          = newJString(pr.id)
    pn["name"]        = newJString(pr.name)
    pn["category"]    = newJString(pr.category)
    pn["type"]        = newJString(pr.`type`)
    pn["description"] = newJString(pr.description)
    pn["image"]       = newJString(pr.image)
    var enemies = newJArray()
    for e in pr.enemies: enemies.add newJString(e)
    pn["enemies"] = enemies
    var positions = newJArray()
    for s in pr.sprite_positions:
      var pair = newJArray()
      pair.add newJFloat(s[0])
      pair.add newJFloat(s[1])
      positions.add pair
    pn["sprite_positions"] = positions
    presetsObj[id] = pn
  result["presets"] = presetsObj

proc save(p: var RoomsPlugin) =
  savePluginJson(p.path, p.toJson())
  p.dirty = false

# ── Helpers ────────────────────────────────────────────────────────────────────

proc inR(x, y, rx, ry, rw, rh: int): bool {.inline.} =
  x >= rx and x < rx + rw and y >= ry and y < ry + rh

proc activePlugin(rt: var RoomsTab): ptr RoomsPlugin =
  if rt.selPluginIdx >= 0 and rt.selPluginIdx < rt.plugins.len:
    addr rt.plugins[rt.selPluginIdx]
  else: nil

proc buildImageFiltered(rt: var RoomsTab) =
  let q = rt.imageFilterBuf.toLowerAscii
  if q.len == 0:
    rt.imageFiltered = rt.imageFiles
  else:
    rt.imageFiltered = @[]
    for f in rt.imageFiles:
      if f.toLowerAscii.contains(q):
        rt.imageFiltered.add f

proc buildFiltered(rt: var RoomsTab) =
  ## Merge presets from all enabled plugins (last-write-wins per id),
  ## apply search filter, sort by id.
  var merged: Table[string, PresetItem]
  var order: seq[string]
  for pidx, p in rt.plugins:
    if not p.meta.enabled: continue
    for id, pr in p.presets:
      if pr.deleted: continue
      if not merged.hasKey(id): order.add id
      merged[id] = (id: id, pidx: pidx)
  let q = rt.searchBuf.toLowerAscii
  rt.filtered = @[]
  for id in order:
    if not merged.hasKey(id): continue
    let item = merged[id]
    if q.len > 0:
      let pr = rt.plugins[item.pidx].presets[id]
      if not (id.toLowerAscii.contains(q) or pr.name.toLowerAscii.contains(q)):
        continue
    rt.filtered.add item
  rt.filtered.sort(proc(a, b: PresetItem): int = cmp(a.id, b.id))

# ── Load ──────────────────────────────────────────────────────────────────────

proc scanImageFiles(modpackDir: string): seq[string] =
  ## Collect basenames of image files by scanning plugin folders in modpackDir
  ## for any subfolder named "assets", then recursively finding images inside.
  ## Never reads content/ — works from source data only.
  const IMG_EXTS = [".png", ".jpg", ".jpeg", ".webp"]
  if not dirExists(modpackDir): return
  var seen: Table[string, bool]
  for kind, pluginDir in walkDir(modpackDir):
    if kind != pcDir: continue
    let assetsDir = pluginDir / "assets"
    if not dirExists(assetsDir): continue
    for f in walkDirRec(assetsDir):
      let ext = f.splitFile.ext.toLowerAscii
      if ext in IMG_EXTS:
        let basename = f.splitFile.name & ext
        if not seen.hasKey(basename):
          seen[basename] = true
          result.add basename
  result.sort()

proc reload*(rt: var RoomsTab; modpackDir, contentDir: string) =
  rt.modpackDir   = modpackDir
  rt.contentDir   = contentDir
  rt.imageFiles   = scanImageFiles(modpackDir)
  rt.imageFiltered = rt.imageFiles
  rt.imageFilterBuf = ""
  rt.imageFilterCursor = 0
  rt.plugins      = @[]
  let entries = scanModpack(modpackDir, "room-editor")
  for e in entries:
    rt.plugins.add loadRoomsPlugin(e.path)
  rt.selPluginIdx  = if rt.plugins.len > 0: 0 else: -1
  rt.buildFiltered()
  rt.selPresetId   = ""
  rt.listScrollY   = 0
  rt.editField     = efNone
  rt.editDescLines = @[""]
  rt.newMode       = false
  rt.dropOpen      = dtNone
  if not rt.sc.bgTexture.isNil:
    destroyTexture(rt.sc.bgTexture)
    rt.sc.bgTexture  = nil
    rt.sc.bgFilename = ""
  rt.sc.open   = false
  rt.statusMsg = fmt"{rt.plugins.len} plugin(s) — {rt.filtered.len} preset(s)"
  rt.statusOk  = true

proc reloadForPlugin*(rt: var RoomsTab; activePluginPath: string) =
  for i, p in rt.plugins:
    if p.path == activePluginPath:
      rt.selPluginIdx = i
      return

proc isDirty*(rt: RoomsTab): bool =
  rt.selPluginIdx >= 0 and rt.selPluginIdx < rt.plugins.len and
  rt.plugins[rt.selPluginIdx].dirty

proc saveActive*(rt: var RoomsTab) =
  if rt.selPluginIdx >= 0 and rt.selPluginIdx < rt.plugins.len:
    rt.plugins[rt.selPluginIdx].save()
    rt.statusMsg = "Saved"
    rt.statusOk  = true

# ── Edit helpers ──────────────────────────────────────────────────────────────

proc enterEdit(rt: var RoomsTab; field: EditField; initial: string) =
  rt.editField     = field
  rt.editBuf       = initial
  rt.editCursorPos = initial.len

proc initDescLines(rt: var RoomsTab; description: string) =
  rt.editDescLines = description.split('\n')
  if rt.editDescLines.len == 0: rt.editDescLines = @[""]

proc syncDescLine(rt: var RoomsTab) =
  ## Write editBuf back into editDescLines[editDescLine].
  if rt.editField == efDescLine and rt.editDescLine < rt.editDescLines.len:
    rt.editDescLines[rt.editDescLine] = rt.editBuf

proc enterDescLine(rt: var RoomsTab; lineIdx: int) =
  if rt.editDescLines.len == 0: rt.editDescLines = @[""]
  let idx = lineIdx.clamp(0, rt.editDescLines.len - 1)
  rt.editField     = efDescLine
  rt.editDescLine  = idx
  rt.editBuf       = rt.editDescLines[idx]
  rt.editCursorPos = rt.editBuf.len
  if idx < rt.descScrollY:
    rt.descScrollY = idx
  elif idx >= rt.descScrollY + DESC_LINES:
    rt.descScrollY = idx - DESC_LINES + 1

proc commitEdit(rt: var RoomsTab) =
  let field = rt.editField
  if field == efNone or field == efSearch:
    rt.editField = efNone; return
  if field == efImageFilter:
    rt.editField = efNone
    rt.dropOpen  = dtNone
    return
  let ap = rt.activePlugin()
  if ap.isNil or not ap.presets.hasKey(rt.selPresetId):
    rt.editField = efNone; return
  case field
  of efName:
    ap.presets[rt.selPresetId].name = rt.editBuf
    ap.dirty = true
  of efDescLine:
    rt.syncDescLine()
    ap.presets[rt.selPresetId].description = rt.editDescLines.join("\n")
    ap.dirty = true
  of efEnemyAdd:
    let tag = rt.editBuf.strip()
    if tag.len > 0 and tag notin ap.presets[rt.selPresetId].enemies:
      ap.presets[rt.selPresetId].enemies.add tag
      ap.dirty = true
  else: discard
  rt.editField = efNone
  rt.statusMsg = "Unsaved changes"
  rt.statusOk  = true

# ── Rendering ─────────────────────────────────────────────────────────────────

proc renderList(rt: var RoomsTab; ren: RendererPtr; font: FontPtr;
                fontH, mx, my: int) =
  let lx = rt.listX
  let ly = rt.listY
  let lw = rt.listW

  ## Search bar
  rt.searchBarY = ly + PAD
  rt.searchBarH = BTN_H
  let sbX = lx + PAD
  let sbW = lw - PAD * 2
  ren.fillRect(sbX, rt.searchBarY, sbW, rt.searchBarH, BG2)
  ren.drawRect(sbX, rt.searchBarY, sbW, rt.searchBarH,
               if rt.editField == efSearch: FG_ACTIVE else: BG3)
  let sbTextY = rt.searchBarY + (rt.searchBarH - fontH) div 2 - 2
  if rt.editField == efSearch:
    renderText(ren, font, rt.editBuf, sbX + PAD, sbTextY, FG_ACTIVE)
    let showCaret = (getTicks().int div 530) mod 2 == 0
    if showCaret:
      let cx = sbX + PAD + textWidth(font, rt.editBuf[0 ..< rt.editCursorPos])
      ren.drawVLine(cx, rt.searchBarY + 3, rt.searchBarH - 6, FG_ACTIVE)
  elif rt.searchBuf.len > 0:
    renderText(ren, font, rt.searchBuf, sbX + PAD, sbTextY, FG)
  else:
    renderText(ren, font, "Search…", sbX + PAD, sbTextY, FG_DIM)

  ## Row area
  let btnBarH  = BTN_H + PAD * 2
  rt.lbtnY     = ly + rt.listH - btnBarH + PAD
  rt.lbtnH     = BTN_H
  rt.listRowsY = rt.searchBarY + rt.searchBarH + 2
  rt.listRowsH = rt.lbtnY - PAD - rt.listRowsY
  let visRows  = rt.listRowsH div ROW_H

  for i in rt.listScrollY ..< min(rt.listScrollY + visRows, rt.filtered.len):
    let item     = rt.filtered[i]
    let ry       = rt.listRowsY + (i - rt.listScrollY) * ROW_H
    let isSel    = item.id == rt.selPresetId
    let isForeign = item.pidx != rt.selPluginIdx
    if isSel: ren.fillRect(lx, ry, lw, ROW_H, SEL_BG)
    let pr  = rt.plugins[item.pidx].presets[item.id]
    ren.fillRect(lx, ry, BORDER_W, ROW_H, categoryColor(pr.category))
    let label = if pr.name.len > 0: pr.name else: pr.id
    renderText(ren, font, label, lx + BORDER_W + PAD,
               ry + (ROW_H - fontH) div 2 - 2, if isForeign: FG_DIM else: FG)
    if pr.`type`.len > 0:
      let tw = textWidth(font, pr.`type`)
      renderText(ren, font, pr.`type`, lx + lw - tw - PAD,
                 ry + (ROW_H - fontH) div 2 - 2, FG_DIM)
    ren.drawHLine(lx, ry + ROW_H - 1, lw, BG3)

  ## New preset inline form
  if rt.newMode:
    let newRowOff = min(rt.filtered.len - rt.listScrollY, visRows)
    let newY = rt.listRowsY + newRowOff * ROW_H
    if newY < rt.listRowsY + rt.listRowsH:
      ren.fillRect(lx, newY, lw, ROW_H, BG2)
      ren.drawHLine(lx, newY, lw, BG3)
      let prompt = "id: "
      renderText(ren, font, prompt, lx + BORDER_W + PAD,
                 newY + (ROW_H - fontH) div 2 - 2, FG_DIM)
      let idX = lx + BORDER_W + PAD + textWidth(font, prompt)
      renderText(ren, font, rt.newBuf, idX, newY + (ROW_H - fontH) div 2 - 2,
                 FG_ACTIVE)
      let showCaret = (getTicks().int div 530) mod 2 == 0
      if showCaret:
        let cx = idX + textWidth(font, rt.newBuf[0 ..< rt.newCursor])
        ren.drawVLine(cx, newY + 3, ROW_H - 6, FG_ACTIVE)

  ## Buttons: New, Dup, Del
  var bx = lx + PAD
  template lbtn(label: string; rx, rw2: untyped; fg: Color) =
    let bw  = textWidth(font, label) + PAD * 2
    let hot = inR(mx, my, bx, rt.lbtnY, bw, rt.lbtnH)
    ren.fillRect(bx, rt.lbtnY, bw, rt.lbtnH, if hot: BTN_HOV else: BTN_BG)
    let lw2 = textWidth(font, label)
    renderText(ren, font, label, bx + (bw - lw2) div 2,
               rt.lbtnY + (rt.lbtnH - fontH) div 2 - 2, fg)
    rx = bx; rw2 = bw
    bx += bw + 4
  lbtn("New", rt.lbtnNewX, rt.lbtnNewW, FG_OK)
  lbtn("Dup", rt.lbtnDupX, rt.lbtnDupW, FG_ACTIVE)
  lbtn("Del", rt.lbtnDelX, rt.lbtnDelW, FG_DEL)

proc renderForm(rt: var RoomsTab; ren: RendererPtr; font: FontPtr;
                fontH, mx, my: int) =
  ren.fillRect(rt.formX, rt.formY, rt.formW, rt.formH, BG)

  if rt.selPresetId.len == 0:
    renderText(ren, font, "Select a preset to edit",
               rt.formX + PAD, rt.formY + PAD, FG_DIM)
    return

  var dispPidx = -1
  for item in rt.filtered:
    if item.id == rt.selPresetId: dispPidx = item.pidx; break
  if dispPidx < 0 or not rt.plugins[dispPidx].presets.hasKey(rt.selPresetId):
    renderText(ren, font, "Preset not found", rt.formX + PAD, rt.formY + PAD, FG_DIM)
    return

  let pr        = rt.plugins[dispPidx].presets[rt.selPresetId]
  let isForeign = dispPidx != rt.selPluginIdx
  let showCaret = (getTicks().int div 530) mod 2 == 0 and not isForeign

  let lx = rt.formX + PAD
  let ix = lx + LABEL_W
  let iw = rt.formW - LABEL_W - PAD * 2
  rt.fLabelX = lx
  rt.fInputX = ix
  rt.fInputW = iw

  var cy = rt.formY + PAD

  ## id (always read-only)
  rt.fIdY = cy
  renderText(ren, font, "id", lx, cy + (ROW_H - fontH) div 2 - 2, FG_DIM)
  ren.fillRect(ix, cy, iw, ROW_H, BG2)
  ren.drawRect(ix, cy, iw, ROW_H, BG3)
  renderText(ren, font, pr.id, ix + PAD, cy + (ROW_H - fontH) div 2 - 2, FG_DIM)
  cy += ROW_H + PAD

  ## name
  rt.fNameY = cy
  let nameEdit = rt.editField == efName
  renderText(ren, font, "name", lx, cy + (ROW_H - fontH) div 2 - 2, FG_DIM)
  ren.fillRect(ix, cy, iw, ROW_H, BG2)
  ren.drawRect(ix, cy, iw, ROW_H, if nameEdit: FG_ACTIVE else: BG3)
  let nameStr = if nameEdit: rt.editBuf else: pr.name
  renderText(ren, font, nameStr, ix + PAD, cy + (ROW_H - fontH) div 2 - 2,
             if isForeign: FG_DIM else: FG)
  if nameEdit and showCaret:
    let cx = ix + PAD + textWidth(font, rt.editBuf[0 ..< rt.editCursorPos])
    ren.drawVLine(cx, cy + 3, ROW_H - 6, FG_ACTIVE)
  cy += ROW_H + PAD

  ## category (in-panel dropdown)
  rt.fCatY = cy
  let catOpen = rt.dropOpen == dtCategory
  let catHot  = not isForeign and inR(mx, my, ix, cy, iw, ROW_H)
  renderText(ren, font, "category", lx, cy + (ROW_H - fontH) div 2 - 2, FG_DIM)
  ren.fillRect(ix, cy, iw, ROW_H, if catOpen: SEL_BG elif catHot: BTN_HOV else: BG2)
  ren.drawRect(ix, cy, iw, ROW_H, BG3)
  ren.fillRect(ix + PAD, cy + (ROW_H - 8) div 2, 8, 8, categoryColor(pr.category))
  renderText(ren, font, pr.category & "  [v]", ix + PAD + 12,
             cy + (ROW_H - fontH) div 2 - 2, if isForeign: FG_DIM else: FG)
  cy += ROW_H + PAD

  ## type (in-panel dropdown)
  rt.fTypeY = cy
  let typeOpen = rt.dropOpen == dtType
  let typeHot  = not isForeign and inR(mx, my, ix, cy, iw, ROW_H)
  renderText(ren, font, "type", lx, cy + (ROW_H - fontH) div 2 - 2, FG_DIM)
  ren.fillRect(ix, cy, iw, ROW_H, if typeOpen: SEL_BG elif typeHot: BTN_HOV else: BG2)
  ren.drawRect(ix, cy, iw, ROW_H, BG3)
  renderText(ren, font, pr.`type` & "  [v]", ix + PAD,
             cy + (ROW_H - fontH) div 2 - 2, if isForeign: FG_DIM else: FG)
  cy += ROW_H + PAD

  ## description (multi-line)
  rt.fDescY = cy
  rt.fDescH = DESC_LINES * ROW_H
  renderText(ren, font, "description", lx, cy + (ROW_H - fontH) div 2 - 2, FG_DIM)
  ren.fillRect(ix, cy, iw, rt.fDescH, BG2)
  ren.drawRect(ix, cy, iw, rt.fDescH, BG3)
  let descLines = if rt.editField == efDescLine: rt.editDescLines
                  else: pr.description.split('\n')
  for li in 0 ..< DESC_LINES:
    let lineIdx = li + rt.descScrollY
    let ldy     = cy + li * ROW_H
    let lty     = ldy + (ROW_H - fontH) div 2 - 2
    if lineIdx < descLines.len:
      let isEditLine = rt.editField == efDescLine and lineIdx == rt.editDescLine
      let lineStr    = if isEditLine: rt.editBuf else: descLines[lineIdx]
      renderText(ren, font, lineStr, ix + PAD, lty,
                 if isForeign: FG_DIM else: FG)
      if isEditLine and showCaret:
        let cx = ix + PAD + textWidth(font, rt.editBuf[0 ..< rt.editCursorPos])
        ren.drawVLine(cx, ldy + 3, ROW_H - 6, FG_ACTIVE)
    if li < DESC_LINES - 1:
      ren.drawHLine(ix, ldy + ROW_H - 1, iw, BG3)
  cy += rt.fDescH + PAD

  ## image (filter input + dropdown)
  rt.fImageY = cy
  let imgFilterActive = rt.editField == efImageFilter
  let imgOpen = rt.dropOpen == dtImage
  renderText(ren, font, "image", lx, cy + (ROW_H - fontH) div 2 - 2, FG_DIM)
  ren.fillRect(ix, cy, iw, ROW_H, BG2)
  ren.drawRect(ix, cy, iw, ROW_H,
               if imgFilterActive: FG_ACTIVE elif imgOpen: BG3 else: BG3)
  ## show filter text when active, otherwise show current value
  let imgDisplayText =
    if imgFilterActive: rt.imageFilterBuf
    elif pr.image.len > 0: pr.image
    else: "(none)"
  let imgTextCol =
    if isForeign: FG_DIM
    elif imgFilterActive: FG_ACTIVE
    elif pr.image.len > 0: FG
    else: FG_DIM
  renderText(ren, font, imgDisplayText, ix + PAD,
             cy + (ROW_H - fontH) div 2 - 2, imgTextCol)
  if imgFilterActive:
    let showC = (getTicks().int div 530) mod 2 == 0
    if showC:
      let cx2 = ix + PAD + textWidth(font, rt.imageFilterBuf[0 ..< rt.imageFilterCursor])
      ren.drawVLine(cx2, cy + 3, ROW_H - 6, FG_ACTIVE)
  cy += ROW_H + PAD

  ## enemies
  rt.fEnemyY = cy
  renderText(ren, font, "enemies", lx, cy + (ROW_H - fontH) div 2 - 2, FG_DIM)
  rt.chipRects.setLen(0)
  var chipX    = ix
  var chipRowY = cy

  for i, e in pr.enemies:
    let xMark = if isForeign: 0 else: ROW_H div 2 + 2
    let cw    = textWidth(font, e) + CHIP_PAD * 2 + xMark
    if chipX + cw > ix + iw and chipX > ix:
      chipX    = ix
      chipRowY += ROW_H
    ren.fillRect(chipX, chipRowY + 3, cw, CHIP_H, BG3)
    renderText(ren, font, e, chipX + CHIP_PAD,
               chipRowY + 3 + (CHIP_H - fontH) div 2 - 2,
               if isForeign: FG_DIM else: FG)
    if not isForeign:
      renderText(ren, font, "×", chipX + cw - xMark,
                 chipRowY + 3 + (CHIP_H - fontH) div 2 - 2, FG_DEL)
    rt.chipRects.add (chipX, chipRowY + 3, cw, CHIP_H)
    chipX += cw + CHIP_GAP

  if not isForeign:
    if rt.editField == efEnemyAdd:
      let addW = iw div 2
      ren.fillRect(chipX, chipRowY, addW, ROW_H, BG2)
      ren.drawRect(chipX, chipRowY, addW, ROW_H, FG_ACTIVE)
      renderText(ren, font, rt.editBuf, chipX + PAD,
                 chipRowY + (ROW_H - fontH) div 2 - 2, FG_ACTIVE)
      let showC = (getTicks().int div 530) mod 2 == 0
      if showC:
        let cx = chipX + PAD + textWidth(font, rt.editBuf[0 ..< rt.editCursorPos])
        ren.drawVLine(cx, chipRowY + 3, ROW_H - 6, FG_ACTIVE)
      rt.enemyAddBtnX = chipX
      rt.enemyAddBtnY = chipRowY
      rt.enemyAddBtnW = addW
    else:
      let addBtnW = textWidth(font, "+ Add") + PAD * 2
      let addHot  = inR(mx, my, chipX, chipRowY + 3, addBtnW, CHIP_H)
      ren.fillRect(chipX, chipRowY + 3, addBtnW, CHIP_H,
                   if addHot: BTN_HOV else: BTN_BG)
      renderText(ren, font, "+ Add", chipX + PAD,
                 chipRowY + 3 + (CHIP_H - fontH) div 2 - 2, FG_OK)
      rt.enemyAddBtnX = chipX
      rt.enemyAddBtnY = chipRowY + 3
      rt.enemyAddBtnW = addBtnW

  cy = chipRowY + ROW_H + PAD

  ## sprite_positions
  rt.fSpriteY = cy
  renderText(ren, font, "sprites", lx, cy + (ROW_H - fontH) div 2 - 2, FG_DIM)
  let countStr  = fmt"{pr.sprite_positions.len} marker(s)"
  renderText(ren, font, countStr, ix + PAD, cy + (ROW_H - fontH) div 2 - 2, FG)
  let editLbl   = "[Edit Positions]"
  let editBtnW  = textWidth(font, editLbl) + PAD * 2
  let editBtnX  = ix + PAD + textWidth(font, countStr) + PAD * 2
  let editBtnHot = inR(mx, my, editBtnX, cy, editBtnW, ROW_H)
  ren.fillRect(editBtnX, cy, editBtnW, ROW_H, if editBtnHot: BTN_HOV else: BTN_BG)
  renderText(ren, font, editLbl, editBtnX + PAD,
             cy + (ROW_H - fontH) div 2 - 2, FG_ACTIVE)
  rt.spriteBtnX = editBtnX
  rt.spriteBtnY = cy
  rt.spriteBtnW = editBtnW
  cy += ROW_H + PAD

  ## Copy to Active Plugin (foreign presets only)
  if isForeign:
    rt.fCopyBtnY = cy
    let copyLbl = "Copy to Active Plugin"
    let copyW   = textWidth(font, copyLbl) + PAD * 2
    let copyHot = inR(mx, my, ix, cy, copyW, BTN_H)
    ren.fillRect(ix, cy, copyW, BTN_H, if copyHot: BTN_HOV else: BTN_BG)
    let lw2 = textWidth(font, copyLbl)
    renderText(ren, font, copyLbl, ix + (copyW - lw2) div 2,
               cy + (BTN_H - fontH) div 2 - 2, FG_ACTIVE)
    rt.copyBtnX = ix
    rt.copyBtnY = cy
    rt.copyBtnW = copyW

proc renderDropdown(rt: var RoomsTab; ren: RendererPtr; font: FontPtr;
                    fontH, mx, my: int) =
  if rt.dropOpen == dtNone: return
  let fieldY = case rt.dropOpen
    of dtCategory: rt.fCatY
    of dtType:     rt.fTypeY
    of dtImage:    rt.fImageY
    else: return
  let items: seq[string] = case rt.dropOpen
    of dtCategory: @CATEGORIES
    of dtType:     @ROOM_TYPES
    of dtImage:    rt.imageFiltered
    else: @[]
  if items.len == 0:
    rt.dropOpen = dtNone; return
  rt.dropPopX = rt.fInputX
  rt.dropPopY = fieldY + ROW_H
  rt.dropPopW = rt.fInputW
  ## Cap height so the popup doesn't run off the bottom of the form
  let maxRows = max(1, (rt.formH - (rt.dropPopY - rt.formY)) div ROW_H)
  rt.dropPopH = min(items.len, maxRows) * ROW_H + 4
  ren.fillRect(rt.dropPopX, rt.dropPopY, rt.dropPopW, rt.dropPopH, DROP_BG)
  ren.drawRect(rt.dropPopX, rt.dropPopY, rt.dropPopW, rt.dropPopH, BG3)
  let visItems = (rt.dropPopH - 4) div ROW_H
  for i in 0 ..< min(visItems, items.len):
    let iy  = rt.dropPopY + 2 + i * ROW_H
    let hot = inR(mx, my, rt.dropPopX, iy, rt.dropPopW, ROW_H)
    if hot: ren.fillRect(rt.dropPopX, iy, rt.dropPopW, ROW_H, DROP_HOV)
    renderText(ren, font, items[i], rt.dropPopX + PAD,
               iy + (ROW_H - fontH) div 2 - 2, if hot: FG_ACTIVE else: FG)

proc render*(rt: var RoomsTab; ren: RendererPtr; font: FontPtr; fontH,
             x, y, w, h, mx, my: int) =
  ## Sprite canvas overlay takes over the full tab area.
  if rt.sc.open:
    let bgPath = block:
      var p = ""
      if rt.selPresetId.len > 0:
        for item in rt.filtered:
          if item.id == rt.selPresetId:
            let pr = rt.plugins[item.pidx].presets[item.id]
            if pr.image.len > 0:
              p = rt.contentDir / "images" / "rooms" / pr.image
            break
      p
    rt.sc.loadBg(ren, bgPath)
    rt.sc.render(ren, font, fontH, x, y, w, h, mx, my)
    return

  rt.listX = x;  rt.listY = y
  rt.listW = w * LIST_FRAC div 100
  rt.listH = h
  rt.formX = x + rt.listW + 1
  rt.formY = y;  rt.formW = w - rt.listW - 1;  rt.formH = h

  ren.fillRect(x, y, w, h, BG)
  ren.drawVLine(rt.formX - 1, y, h, BG3)

  rt.renderList(ren, font, fontH, mx, my)
  rt.renderForm(ren, font, fontH, mx, my)

  if rt.dropOpen != dtNone:
    rt.renderDropdown(ren, font, fontH, mx, my)

# ── Input ─────────────────────────────────────────────────────────────────────

proc handleMouseDown*(rt: var RoomsTab; x, y, btn: int; activePluginPath: string) =
  rt.reloadForPlugin(activePluginPath)

  ## Sprite canvas intercepts when open
  if rt.sc.open:
    if btn == 1:
      if inR(x, y, rt.sc.okRect.x, rt.sc.okRect.y,
             rt.sc.okRect.w, rt.sc.okRect.h):
        let ap = rt.activePlugin()
        if not ap.isNil and ap.presets.hasKey(rt.selPresetId):
          ap.presets[rt.selPresetId].sprite_positions = rt.sc.positions
          ap.dirty = true
          rt.statusMsg = "Unsaved changes"; rt.statusOk = true
        rt.sc.open = false; return
      if inR(x, y, rt.sc.cancelRect.x, rt.sc.cancelRect.y,
             rt.sc.cancelRect.w, rt.sc.cancelRect.h):
        rt.sc.open = false; return
      if inR(x, y, rt.sc.clearAllRect.x, rt.sc.clearAllRect.y,
             rt.sc.clearAllRect.w, rt.sc.clearAllRect.h):
        rt.sc.positions = @[]; return
    rt.sc.handleMouseDown(x, y, btn)
    return

  ## Dropdown intercepts when open
  if rt.dropOpen != dtNone:
    if inR(x, y, rt.dropPopX, rt.dropPopY, rt.dropPopW, rt.dropPopH):
      let row = (y - rt.dropPopY - 2) div ROW_H
      let ap  = rt.activePlugin()
      if not ap.isNil and ap.presets.hasKey(rt.selPresetId):
        case rt.dropOpen
        of dtCategory:
          if row >= 0 and row < CATEGORIES.len:
            ap.presets[rt.selPresetId].category = CATEGORIES[row]
            ap.dirty = true; rt.statusMsg = "Unsaved changes"; rt.statusOk = true
        of dtType:
          if row >= 0 and row < ROOM_TYPES.len:
            ap.presets[rt.selPresetId].`type` = ROOM_TYPES[row]
            ap.dirty = true; rt.statusMsg = "Unsaved changes"; rt.statusOk = true
        of dtImage:
          if row >= 0 and row < rt.imageFiltered.len:
            ap.presets[rt.selPresetId].image = rt.imageFiltered[row]
            ap.dirty = true; rt.statusMsg = "Unsaved changes"; rt.statusOk = true
            rt.imageFilterBuf    = rt.imageFiltered[row]
            rt.imageFilterCursor = rt.imageFilterBuf.len
            rt.editField = efNone
        else: discard
    rt.dropOpen = dtNone; return

  if rt.newMode and not inR(x, y, rt.listX, rt.listY, rt.listW, rt.listH):
    rt.newMode = false

  ## List column
  if inR(x, y, rt.listX, rt.listY, rt.listW, rt.listH):
    ## Search bar
    if inR(x, y, rt.listX + PAD, rt.searchBarY, rt.listW - PAD * 2, rt.searchBarH):
      if rt.editField != efSearch:
        if rt.editField == efDescLine: rt.syncDescLine()
        rt.commitEdit()
        rt.enterEdit(efSearch, rt.searchBuf)
      return
    ## Preset rows
    if inR(x, y, rt.listX, rt.listRowsY, rt.listW, rt.listRowsH) and btn == 1:
      let row = rt.listScrollY + (y - rt.listRowsY) div ROW_H
      if row >= 0 and row < rt.filtered.len:
        let newId = rt.filtered[row].id
        if newId != rt.selPresetId:
          if rt.editField == efDescLine: rt.syncDescLine()
          rt.commitEdit()
          rt.selPresetId = newId
          rt.descScrollY = 0
          for item in rt.filtered:
            if item.id == newId:
              rt.initDescLines(rt.plugins[item.pidx].presets[newId].description)
              break
      return
    ## New button
    if inR(x, y, rt.lbtnNewX, rt.lbtnY, rt.lbtnNewW, rt.lbtnH):
      let ap = rt.activePlugin()
      if not ap.isNil:
        if rt.editField == efDescLine: rt.syncDescLine()
        rt.commitEdit()
        rt.newBuf = ""; rt.newCursor = 0; rt.newMode = true
      return
    ## Dup button
    if inR(x, y, rt.lbtnDupX, rt.lbtnY, rt.lbtnDupW, rt.lbtnH):
      let ap = rt.activePlugin()
      if not ap.isNil and rt.selPresetId.len > 0:
        var srcPr: RoomPreset
        var found = false
        for item in rt.filtered:
          if item.id == rt.selPresetId:
            srcPr = rt.plugins[item.pidx].presets[item.id]
            found = true; break
        if found:
          var newId = rt.selPresetId & "-copy"
          var n = 2
          while ap.presets.hasKey(newId):
            newId = rt.selPresetId & "-copy" & $n; inc n
          srcPr.id = newId
          ap.presets[newId] = srcPr
          ap.dirty = true
          rt.buildFiltered()
          rt.selPresetId = newId
          rt.initDescLines(srcPr.description)
          rt.statusMsg = "Duplicated as " & newId; rt.statusOk = true
      return
    ## Del button
    if inR(x, y, rt.lbtnDelX, rt.lbtnY, rt.lbtnDelW, rt.lbtnH):
      let ap = rt.activePlugin()
      if not ap.isNil and ap.presets.hasKey(rt.selPresetId):
        ap.presets[rt.selPresetId].deleted = true
        ap.dirty = true
        let delId = rt.selPresetId
        rt.buildFiltered()
        rt.selPresetId = ""
        rt.statusMsg = "Deleted " & delId; rt.statusOk = true
      return
    return

  ## Form column
  if not inR(x, y, rt.formX, rt.formY, rt.formW, rt.formH): return
  if rt.selPresetId.len == 0: return
  var dispPidx = -1
  for item in rt.filtered:
    if item.id == rt.selPresetId: dispPidx = item.pidx; break
  if dispPidx < 0: return
  let isForeign = dispPidx != rt.selPluginIdx
  let ap = rt.activePlugin()

  ## name
  if inR(x, y, rt.fInputX, rt.fNameY, rt.fInputW, ROW_H) and not isForeign:
    if rt.editField == efDescLine: rt.syncDescLine()
    rt.commitEdit()
    rt.enterEdit(efName, rt.plugins[dispPidx].presets[rt.selPresetId].name)
    return

  ## category dropdown toggle
  if inR(x, y, rt.fInputX, rt.fCatY, rt.fInputW, ROW_H) and not isForeign:
    rt.commitEdit()
    rt.dropOpen = if rt.dropOpen == dtCategory: dtNone else: dtCategory
    return

  ## type dropdown toggle
  if inR(x, y, rt.fInputX, rt.fTypeY, rt.fInputW, ROW_H) and not isForeign:
    rt.commitEdit()
    rt.dropOpen = if rt.dropOpen == dtType: dtNone else: dtType
    return

  ## description lines
  if inR(x, y, rt.fInputX, rt.fDescY, rt.fInputW, rt.fDescH) and not isForeign:
    let lineInBox = (y - rt.fDescY) div ROW_H
    let lineIdx   = rt.descScrollY + lineInBox
    if rt.editField != efDescLine:
      rt.initDescLines(rt.plugins[dispPidx].presets[rt.selPresetId].description)
    else:
      rt.syncDescLine()
    rt.enterDescLine(lineIdx)
    return

  ## image filter input — click opens it for typing and shows dropdown
  if inR(x, y, rt.fInputX, rt.fImageY, rt.fInputW, ROW_H) and not isForeign:
    if rt.editField == efDescLine: rt.syncDescLine()
    rt.commitEdit()
    ## Pre-fill with current image value so user can refine it
    let curImage = rt.plugins[dispPidx].presets[rt.selPresetId].image
    if rt.editField != efImageFilter:
      rt.imageFilterBuf = curImage
    rt.editField         = efImageFilter
    rt.imageFilterCursor = rt.imageFilterBuf.len
    rt.buildImageFiltered()
    rt.dropOpen = dtImage
    return

  ## enemy chip × buttons
  for i, cr in rt.chipRects:
    if isForeign: break
    let xBtn = cr.x + cr.w - ROW_H div 2 - 2
    if inR(x, y, xBtn, cr.y, ROW_H div 2 + 4, cr.h):
      if not ap.isNil and ap.presets.hasKey(rt.selPresetId):
        ap.presets[rt.selPresetId].enemies.delete(i)
        ap.dirty = true; rt.statusMsg = "Unsaved changes"; rt.statusOk = true
      return

  ## + Add button
  if rt.editField != efEnemyAdd and
     inR(x, y, rt.enemyAddBtnX, rt.enemyAddBtnY, rt.enemyAddBtnW, CHIP_H) and
     not isForeign:
    if rt.editField == efDescLine: rt.syncDescLine()
    rt.commitEdit()
    rt.enterEdit(efEnemyAdd, "")
    return

  ## [Edit Positions] button
  if inR(x, y, rt.spriteBtnX, rt.spriteBtnY, rt.spriteBtnW, ROW_H):
    let pr = rt.plugins[dispPidx].presets[rt.selPresetId]
    rt.sc.openCanvas(pr.sprite_positions)
    return

  ## Copy to Active Plugin (foreign)
  if isForeign and inR(x, y, rt.copyBtnX, rt.copyBtnY, rt.copyBtnW, BTN_H):
    if not ap.isNil:
      let pr = rt.plugins[dispPidx].presets[rt.selPresetId]
      ap.presets[rt.selPresetId] = pr
      ap.dirty = true
      rt.buildFiltered()
      rt.initDescLines(pr.description)
      rt.statusMsg = "Copied to active plugin"; rt.statusOk = true
    return

  ## Click elsewhere in form — commit
  if rt.editField == efDescLine: rt.syncDescLine()
  rt.commitEdit()

proc handleMouseUp*(rt: var RoomsTab; x, y, btn: int) =
  if rt.sc.open: rt.sc.handleMouseUp()

proc handleMouseMotion*(rt: var RoomsTab; x, y: int) =
  if rt.sc.open: rt.sc.handleMouseMotion(x, y)

proc handleWheel*(rt: var RoomsTab; dy: int) =
  if rt.sc.open: return
  let visRows   = if rt.listRowsH > 0: rt.listRowsH div ROW_H else: 10
  let maxScroll = max(0, rt.filtered.len - visRows)
  rt.listScrollY = (rt.listScrollY - dy).clamp(0, maxScroll)

proc handleTextInput*(rt: var RoomsTab; text: string) =
  if rt.newMode:
    rt.newBuf.insert(text, rt.newCursor)
    rt.newCursor += text.len
    return
  case rt.editField
  of efSearch:
    rt.editBuf.insert(text, rt.editCursorPos)
    rt.editCursorPos += text.len
    rt.searchBuf = rt.editBuf
    rt.buildFiltered()
  of efName, efEnemyAdd, efDescLine:
    rt.editBuf.insert(text, rt.editCursorPos)
    rt.editCursorPos += text.len
  of efImageFilter:
    rt.imageFilterBuf.insert(text, rt.imageFilterCursor)
    rt.imageFilterCursor += text.len
    rt.buildImageFiltered()
    rt.dropOpen = dtImage
  else: discard

proc handleKeyDown*(rt: var RoomsTab; sym: Scancode; ctrl, shift: bool) =
  ## New preset inline form
  if rt.newMode:
    case sym
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      let id = rt.newBuf.strip()
      if id.len > 0:
        let ap = rt.activePlugin()
        if not ap.isNil and not ap.presets.hasKey(id):
          ap.presets[id] = RoomPreset(id: id, name: id,
                                      category: CATEGORIES[0],
                                      `type`:   ROOM_TYPES[0])
          ap.dirty = true
          rt.buildFiltered()
          rt.selPresetId = id
          rt.initDescLines("")
          rt.statusMsg = "Created " & id; rt.statusOk = true
        else:
          rt.statusMsg = if ap.isNil: "No active plugin" else: "ID already exists"
          rt.statusOk  = false
      rt.newMode = false
    of SDL_SCANCODE_ESCAPE:
      rt.newMode = false
    of SDL_SCANCODE_BACKSPACE:
      if rt.newCursor > 0:
        let i = rt.newCursor - 1
        rt.newBuf = rt.newBuf[0 ..< i] & rt.newBuf[i + 1 .. ^1]
        dec rt.newCursor
    of SDL_SCANCODE_DELETE:
      if rt.newCursor < rt.newBuf.len:
        let i = rt.newCursor
        rt.newBuf = rt.newBuf[0 ..< i] & rt.newBuf[i + 1 .. ^1]
    of SDL_SCANCODE_LEFT:
      if rt.newCursor > 0: dec rt.newCursor
    of SDL_SCANCODE_RIGHT:
      if rt.newCursor < rt.newBuf.len: inc rt.newCursor
    of SDL_SCANCODE_HOME: rt.newCursor = 0
    of SDL_SCANCODE_END:  rt.newCursor = rt.newBuf.len
    else: discard
    return

  ## Dropdown (non-image): eat all keys except Escape
  if rt.dropOpen != dtNone and rt.editField != efImageFilter:
    if sym == SDL_SCANCODE_ESCAPE: rt.dropOpen = dtNone
    return

  ## No active edit field
  if rt.editField == efNone: return

  ## Search bar
  if rt.editField == efSearch:
    case sym
    of SDL_SCANCODE_ESCAPE:
      rt.searchBuf = ""; rt.editField = efNone; rt.buildFiltered()
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      rt.searchBuf = rt.editBuf; rt.editField = efNone
    of SDL_SCANCODE_BACKSPACE:
      if rt.editCursorPos > 0:
        let i = rt.editCursorPos - 1
        rt.editBuf = rt.editBuf[0 ..< i] & rt.editBuf[i + 1 .. ^1]
        dec rt.editCursorPos
        rt.searchBuf = rt.editBuf; rt.buildFiltered()
    of SDL_SCANCODE_DELETE:
      if rt.editCursorPos < rt.editBuf.len:
        let i = rt.editCursorPos
        rt.editBuf = rt.editBuf[0 ..< i] & rt.editBuf[i + 1 .. ^1]
        rt.searchBuf = rt.editBuf; rt.buildFiltered()
    of SDL_SCANCODE_LEFT:
      if rt.editCursorPos > 0: dec rt.editCursorPos
    of SDL_SCANCODE_RIGHT:
      if rt.editCursorPos < rt.editBuf.len: inc rt.editCursorPos
    of SDL_SCANCODE_HOME: rt.editCursorPos = 0
    of SDL_SCANCODE_END:  rt.editCursorPos = rt.editBuf.len
    else: discard
    return

  ## Description multi-line editor
  if rt.editField == efDescLine:
    case sym
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      let before = rt.editBuf[0 ..< rt.editCursorPos]
      let after  = rt.editBuf[rt.editCursorPos .. ^1]
      rt.editDescLines[rt.editDescLine] = before
      rt.editDescLines.insert(after, rt.editDescLine + 1)
      rt.enterDescLine(rt.editDescLine + 1)
      rt.editCursorPos = 0
    of SDL_SCANCODE_ESCAPE:
      rt.syncDescLine()
      let ap = rt.activePlugin()
      if not ap.isNil and ap.presets.hasKey(rt.selPresetId):
        ap.presets[rt.selPresetId].description = rt.editDescLines.join("\n")
        ap.dirty = true
      rt.editField = efNone
    of SDL_SCANCODE_BACKSPACE:
      if rt.editCursorPos > 0:
        let i = rt.editCursorPos - 1
        rt.editBuf = rt.editBuf[0 ..< i] & rt.editBuf[i + 1 .. ^1]
        dec rt.editCursorPos
      elif rt.editDescLine > 0:
        rt.syncDescLine()
        let prevIdx  = rt.editDescLine - 1
        let prevLine = rt.editDescLines[prevIdx]
        let curLine  = rt.editDescLines[rt.editDescLine]
        rt.editDescLines.delete(rt.editDescLine)
        rt.editDescLines[prevIdx] = prevLine & curLine
        rt.editDescLine  = prevIdx
        rt.editBuf       = rt.editDescLines[prevIdx]
        rt.editCursorPos = prevLine.len
    of SDL_SCANCODE_DELETE:
      if rt.editCursorPos < rt.editBuf.len:
        let i = rt.editCursorPos
        rt.editBuf = rt.editBuf[0 ..< i] & rt.editBuf[i + 1 .. ^1]
      elif rt.editDescLine < rt.editDescLines.len - 1:
        rt.syncDescLine()
        let curLine  = rt.editDescLines[rt.editDescLine]
        let nextLine = rt.editDescLines[rt.editDescLine + 1]
        rt.editDescLines[rt.editDescLine] = curLine & nextLine
        rt.editDescLines.delete(rt.editDescLine + 1)
        rt.editBuf       = rt.editDescLines[rt.editDescLine]
        rt.editCursorPos = curLine.len
    of SDL_SCANCODE_UP:
      if rt.editDescLine > 0:
        rt.syncDescLine()
        let col     = rt.editCursorPos
        let newLine = rt.editDescLine - 1
        rt.editDescLine  = newLine
        rt.editBuf       = rt.editDescLines[newLine]
        rt.editCursorPos = min(col, rt.editBuf.len)
        if newLine < rt.descScrollY: rt.descScrollY = newLine
    of SDL_SCANCODE_DOWN:
      if rt.editDescLine < rt.editDescLines.len - 1:
        rt.syncDescLine()
        let col     = rt.editCursorPos
        let newLine = rt.editDescLine + 1
        rt.editDescLine  = newLine
        rt.editBuf       = rt.editDescLines[newLine]
        rt.editCursorPos = min(col, rt.editBuf.len)
        if newLine >= rt.descScrollY + DESC_LINES:
          rt.descScrollY = newLine - DESC_LINES + 1
    of SDL_SCANCODE_LEFT:
      if rt.editCursorPos > 0:
        dec rt.editCursorPos
      elif rt.editDescLine > 0:
        rt.syncDescLine()
        let newLine = rt.editDescLine - 1
        rt.editDescLine  = newLine
        rt.editBuf       = rt.editDescLines[newLine]
        rt.editCursorPos = rt.editBuf.len
        if newLine < rt.descScrollY: rt.descScrollY = newLine
    of SDL_SCANCODE_RIGHT:
      if rt.editCursorPos < rt.editBuf.len:
        inc rt.editCursorPos
      elif rt.editDescLine < rt.editDescLines.len - 1:
        rt.syncDescLine()
        let newLine = rt.editDescLine + 1
        rt.editDescLine  = newLine
        rt.editBuf       = rt.editDescLines[newLine]
        rt.editCursorPos = 0
        if newLine >= rt.descScrollY + DESC_LINES:
          rt.descScrollY = newLine - DESC_LINES + 1
    of SDL_SCANCODE_HOME: rt.editCursorPos = 0
    of SDL_SCANCODE_END:  rt.editCursorPos = rt.editBuf.len
    else: discard
    return

  ## Image filter input
  if rt.editField == efImageFilter:
    case sym
    of SDL_SCANCODE_ESCAPE:
      rt.editField = efNone
      rt.dropOpen  = dtNone
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      ## Pick first filtered result if any
      if rt.imageFiltered.len > 0:
        let chosen = rt.imageFiltered[0]
        let ap = rt.activePlugin()
        if not ap.isNil and ap.presets.hasKey(rt.selPresetId):
          ap.presets[rt.selPresetId].image = chosen
          ap.dirty = true; rt.statusMsg = "Unsaved changes"; rt.statusOk = true
        rt.imageFilterBuf    = chosen
        rt.imageFilterCursor = chosen.len
      rt.editField = efNone
      rt.dropOpen  = dtNone
    of SDL_SCANCODE_BACKSPACE:
      if rt.imageFilterCursor > 0:
        let i = rt.imageFilterCursor - 1
        rt.imageFilterBuf = rt.imageFilterBuf[0 ..< i] & rt.imageFilterBuf[i + 1 .. ^1]
        dec rt.imageFilterCursor
        rt.buildImageFiltered()
    of SDL_SCANCODE_DELETE:
      if rt.imageFilterCursor < rt.imageFilterBuf.len:
        let i = rt.imageFilterCursor
        rt.imageFilterBuf = rt.imageFilterBuf[0 ..< i] & rt.imageFilterBuf[i + 1 .. ^1]
        rt.buildImageFiltered()
    of SDL_SCANCODE_LEFT:
      if rt.imageFilterCursor > 0: dec rt.imageFilterCursor
    of SDL_SCANCODE_RIGHT:
      if rt.imageFilterCursor < rt.imageFilterBuf.len: inc rt.imageFilterCursor
    of SDL_SCANCODE_HOME: rt.imageFilterCursor = 0
    of SDL_SCANCODE_END:  rt.imageFilterCursor = rt.imageFilterBuf.len
    else: discard
    return

  ## Single-line fields: efName, efEnemyAdd
  case sym
  of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
    rt.commitEdit()
  of SDL_SCANCODE_ESCAPE:
    rt.editField = efNone
  of SDL_SCANCODE_BACKSPACE:
    if rt.editCursorPos > 0:
      let i = rt.editCursorPos - 1
      rt.editBuf = rt.editBuf[0 ..< i] & rt.editBuf[i + 1 .. ^1]
      dec rt.editCursorPos
  of SDL_SCANCODE_DELETE:
    if rt.editCursorPos < rt.editBuf.len:
      let i = rt.editCursorPos
      rt.editBuf = rt.editBuf[0 ..< i] & rt.editBuf[i + 1 .. ^1]
  of SDL_SCANCODE_LEFT:
    if rt.editCursorPos > 0: dec rt.editCursorPos
  of SDL_SCANCODE_RIGHT:
    if rt.editCursorPos < rt.editBuf.len: inc rt.editCursorPos
  of SDL_SCANCODE_HOME: rt.editCursorPos = 0
  of SDL_SCANCODE_END:  rt.editCursorPos = rt.editBuf.len
  else: discard
