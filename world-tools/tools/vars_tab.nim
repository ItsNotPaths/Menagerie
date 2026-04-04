## vars_tab.nim
## Gameplay Vars tab — key/value editor for the vars plugin dict.

import sdl2
import sdl2/ttf
import std/[json, strformat, tables]
import "../theme"
import plugin_meta
import plugin_io

# ── Types ─────────────────────────────────────────────────────────────────────

type
  VarRow = object
    key:   string
    value: string  ## stored as raw JSON string representation

  VarsPlugin = object
    meta: PluginMeta
    vars: seq[VarRow]
    path: string

  EditMode = enum emNone, emKey, emValue

  VarsTab* = object
    plugins:      seq[VarsPlugin]
    selPluginIdx: int
    selRowIdx:    int
    scrollY:      int

    editMode:      EditMode
    editBuf:       string
    editRowIdx:    int
    editCursorPos: int   ## byte offset into editBuf

    modpackDir: string
    statusMsg*: string
    statusOk*:  bool

    # layout cache (set each render, read by input handlers)
    listX, listY, listW, listH: int
    keyColW: int

# ── JSON helpers ──────────────────────────────────────────────────────────────

proc loadVarsPlugin(path: string): VarsPlugin =
  result.path = path
  let raw = loadPluginJson(path)
  if raw.isNil: return
  result.meta = metaFromJson(raw.getOrDefault("meta"))
  let varsNode = raw.getOrDefault("vars")
  if not varsNode.isNil and varsNode.kind == JObject:
    for k, v in varsNode:
      result.vars.add VarRow(key: k, value: $v)

proc toJson(p: VarsPlugin): JsonNode =
  result = newJObject()
  result["meta"] = p.meta.toJson()
  var varsNode = newJObject()
  for r in p.vars:
    try:    varsNode[r.key] = parseJson(r.value)
    except: varsNode[r.key] = newJString(r.value)
  result["vars"] = varsNode

proc save(p: VarsPlugin) =
  savePluginJson(p.path, p.toJson())

proc activePlugin(vt: var VarsTab): ptr VarsPlugin =
  if vt.selPluginIdx >= 0 and vt.selPluginIdx < vt.plugins.len:
    addr vt.plugins[vt.selPluginIdx]
  else: nil

# ── Load ──────────────────────────────────────────────────────────────────────

proc reload*(vt: var VarsTab; modpackDir: string; seedPath: string = "") =
  vt.modpackDir = modpackDir
  vt.plugins    = @[]
  let entries = scanModpack(modpackDir, "gameplay-vars")
  for e in entries:
    vt.plugins.add loadVarsPlugin(e.path)
  vt.selPluginIdx = if vt.plugins.len > 0: 0 else: -1
  vt.selRowIdx    = -1
  vt.scrollY      = 0
  vt.editMode     = emNone
  vt.statusMsg    = fmt"{vt.plugins.len} vars plugin(s)"
  vt.statusOk     = true

  # Pre-populate a freshly created plugin with merged vars from all other
  # enabled plugins, so the user sees every known key as an override candidate.
  if seedPath.len > 0:
    var seedIdx = -1
    for i, p in vt.plugins:
      if p.path == seedPath: seedIdx = i; break
    if seedIdx >= 0 and vt.plugins[seedIdx].vars.len == 0:
      var merged: OrderedTable[string, string]
      for i, p in vt.plugins:
        if i != seedIdx and p.meta.enabled:
          for row in p.vars:
            if not merged.hasKey(row.key):
              merged[row.key] = row.value
      if merged.len > 0:
        for k, v in merged:
          vt.plugins[seedIdx].vars.add VarRow(key: k, value: v)
        vt.plugins[seedIdx].save()
    vt.selPluginIdx = seedIdx

proc reloadForPlugin*(vt: var VarsTab; activePluginPath: string) =
  for i, p in vt.plugins:
    if p.path == activePluginPath:
      vt.selPluginIdx = i
      return

# ── Edit helpers ──────────────────────────────────────────────────────────────

proc enterEdit(vt: var VarsTab; mode: EditMode; row: int; initial: string) =
  vt.editMode      = mode
  vt.editBuf       = initial
  vt.editRowIdx    = row
  vt.editCursorPos = initial.len   ## cursor starts at end

proc commitEdit(vt: var VarsTab) =
  if vt.editMode == emNone: return
  let p = vt.activePlugin()
  if p.isNil or vt.editRowIdx >= p.vars.len: return
  case vt.editMode
  of emKey:   p.vars[vt.editRowIdx].key   = vt.editBuf
  of emValue: p.vars[vt.editRowIdx].value = vt.editBuf
  else: discard
  p[].save()
  vt.editMode  = emNone
  vt.statusMsg = "Saved"
  vt.statusOk  = true

# ── Rendering ─────────────────────────────────────────────────────────────────

proc render*(vt: var VarsTab; ren: RendererPtr; font: FontPtr; fontH: int;
             x, y, w, h: int; mx, my: int) =
  ren.fillRect(x, y, w, h, BG)

  let p = if vt.selPluginIdx >= 0 and vt.selPluginIdx < vt.plugins.len:
            addr vt.plugins[vt.selPluginIdx]
          else: nil

  # ── Toolbar ────────────────────────────────────────────────────────────────
  let toolY = y + PAD
  renderText(ren, font, "Gameplay Vars", x + PAD, toolY, FG_ACTIVE)
  if not p.isNil:
    renderText(ren, font, fmt"  [{p.meta.name}]  {p.vars.len} var(s)",
               x + PAD + textWidth(font, "Gameplay Vars"), toolY, FG_DIM)

  # ── Column headers ─────────────────────────────────────────────────────────
  let headerY = toolY + fontH + PAD
  vt.keyColW  = w div 3
  let valColX = x + vt.keyColW

  ren.fillRect(x, headerY, w, ROW_H, BG3)
  renderText(ren, font, "  Key",   x + PAD,      headerY + (ROW_H - fontH) div 2 - 2, FG_DIM)
  renderText(ren, font, "  Value", valColX + PAD, headerY + (ROW_H - fontH) div 2 - 2, FG_DIM)
  ren.drawVLine(valColX, headerY, ROW_H, BG2)

  # ── Row list ───────────────────────────────────────────────────────────────
  vt.listX = x
  vt.listY = headerY + ROW_H
  vt.listW = w
  vt.listH = h - (vt.listY - y) - BTN_H - PAD * 2

  if p.isNil:
    renderText(ren, font, "No vars plugin loaded — select one in the sidebar.",
               x + PAD, vt.listY + PAD, FG_DIM)
    return

  let visRows = vt.listH div ROW_H
  let rows    = p.vars
  let showCaret = vt.editMode != emNone and
                  (getTicks().int div 530) mod 2 == 0

  for i in vt.scrollY ..< min(vt.scrollY + visRows, rows.len):
    let ry    = vt.listY + (i - vt.scrollY) * ROW_H
    let isSel = i == vt.selRowIdx
    let textY = ry + (ROW_H - fontH) div 2 - 2

    if isSel: ren.fillRect(x, ry, w, ROW_H, SEL_BG)

    # ── Key cell ─────────────────────────────────────────────────────────────
    let editingKey = isSel and vt.editMode == emKey
    let keyStr     = if editingKey: vt.editBuf else: rows[i].key
    let keyFg      = if editingKey: FG_ACTIVE else: FG
    let keyTextX   = x + PAD
    renderText(ren, font, "  " & keyStr, keyTextX, textY, keyFg)

    if editingKey and showCaret:
      let caretX = keyTextX + textWidth(font, "  " & vt.editBuf[0 ..< vt.editCursorPos])
      ren.drawVLine(caretX, ry + 3, ROW_H - 6, FG_ACTIVE)

    # ── Divider ───────────────────────────────────────────────────────────────
    ren.drawVLine(valColX, ry, ROW_H, BG3)

    # ── Value cell ───────────────────────────────────────────────────────────
    let editingVal = isSel and vt.editMode == emValue
    let valStr     = if editingVal: vt.editBuf else: rows[i].value
    let valFg      = if editingVal: FG_ACTIVE else: FG_DIM
    let valTextX   = valColX + PAD
    renderText(ren, font, "  " & valStr, valTextX, textY, valFg)

    if editingVal and showCaret:
      let caretX = valTextX + textWidth(font, "  " & vt.editBuf[0 ..< vt.editCursorPos])
      ren.drawVLine(caretX, ry + 3, ROW_H - 6, FG_ACTIVE)

    ren.drawHLine(x, ry + ROW_H - 1, w, BG3)

  # ── Footer buttons ─────────────────────────────────────────────────────────
  let btnY = y + h - BTN_H - PAD
  var bx   = x + PAD
  let bw   = 60

  template fbtn(lbl, fg: untyped) =
    let hot = mx >= bx and mx < bx + bw and my >= btnY and my < btnY + BTN_H
    ren.fillRect(bx, btnY, bw, BTN_H, if hot: BTN_HOV else: BTN_BG)
    let lw = textWidth(font, lbl)
    renderText(ren, font, lbl, bx + (bw - lw) div 2,
               btnY + (BTN_H - fontH) div 2 - 2, fg)
    bx += bw + 4

  fbtn("+ Add",  FG_OK)
  fbtn("Delete", FG_DEL)
  fbtn("Save",   FG_ACTIVE)

# ── Input ─────────────────────────────────────────────────────────────────────

proc handleWheel*(vt: var VarsTab; dy: int) =
  vt.scrollY = max(0, vt.scrollY - dy)

proc handleMouseDown*(vt: var VarsTab; x, y, btn: int; activePluginPath: string) =
  vt.reloadForPlugin(activePluginPath)
  if y < vt.listY or y >= vt.listY + vt.listH: return
  let row = vt.scrollY + (y - vt.listY) div ROW_H
  let p = if vt.selPluginIdx >= 0: addr vt.plugins[vt.selPluginIdx] else: nil
  if p.isNil or row >= p.vars.len: return
  if row == vt.selRowIdx:
    if x < vt.listX + vt.keyColW:
      vt.enterEdit(emKey,   row, p.vars[row].key)
    else:
      vt.enterEdit(emValue, row, p.vars[row].value)
  else:
    vt.selRowIdx = row
    vt.editMode  = emNone

proc handleMouseUp*(vt: var VarsTab; x, y, btn: int) = discard
proc handleMouseMotion*(vt: var VarsTab; x, y: int) = discard

proc handleTextInput*(vt: var VarsTab; text: string) =
  if vt.editMode == emNone: return
  vt.editBuf.insert(text, vt.editCursorPos)
  vt.editCursorPos += text.len

proc handleKeyDown*(vt: var VarsTab; sym: Scancode; ctrl, shift: bool) =
  if vt.editMode == emNone: return
  case sym
  of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
    vt.commitEdit()
  of SDL_SCANCODE_ESCAPE:
    vt.editMode = emNone
  of SDL_SCANCODE_BACKSPACE:
    if vt.editCursorPos > 0:
      let i = vt.editCursorPos - 1
      vt.editBuf = vt.editBuf[0 ..< i] & vt.editBuf[i + 1 .. ^1]
      dec vt.editCursorPos
  of SDL_SCANCODE_DELETE:
    if vt.editCursorPos < vt.editBuf.len:
      let i = vt.editCursorPos
      vt.editBuf = vt.editBuf[0 ..< i] & vt.editBuf[i + 1 .. ^1]
  of SDL_SCANCODE_LEFT:
    if vt.editCursorPos > 0: dec vt.editCursorPos
  of SDL_SCANCODE_RIGHT:
    if vt.editCursorPos < vt.editBuf.len: inc vt.editCursorPos
  of SDL_SCANCODE_HOME:
    vt.editCursorPos = 0
  of SDL_SCANCODE_END:
    vt.editCursorPos = vt.editBuf.len
  else: discard
