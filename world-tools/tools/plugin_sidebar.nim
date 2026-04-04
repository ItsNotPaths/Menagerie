## plugin_sidebar.nim
## Shared left sidebar: scrollable plugin list filtered to the active tab's
## tool_id. New, Rename, Toggle, Delete, Move Up/Down buttons.
## Active plugin is highlighted — all edits from tab modules go to it.

import sdl2
import sdl2/ttf
import std/[strformat, strutils, sequtils, json, os]
import "../theme"
import plugin_meta
import plugin_io
import load_order

# ── Types ─────────────────────────────────────────────────────────────────────

type
  SidebarBtn = object
    rect: Rect
    hot:  bool

  Sidebar* = object
    entries:          seq[PluginEntry]
    selIdx:           int
    scrollY:          int
    activePluginPath*: string

    statusMsg*: string
    statusOk*:  bool

    pluginsChanged*:  bool    ## set after create/delete; cleared by main.nim
    lastCreatedPath*: string  ## path of most-recently created plugin (or "")
    saveRequested*:   bool    ## set when Save button clicked; cleared by main.nim
    dirty*:           bool    ## set by main.nim before render to highlight Save btn

    modpackDir: string
    toolId:     string

    # New-plugin inline form
    newPluginMode*: bool
    newNameBuf:     string
    newNameCursor:  int

    # buttons (rebuilt each render)
    btnNew:    SidebarBtn
    btnSetAct: SidebarBtn
    btnToggle: SidebarBtn
    btnUp:     SidebarBtn
    btnDown:   SidebarBtn
    btnDel:    SidebarBtn
    btnSave:   SidebarBtn
    btnCreate: SidebarBtn
    btnCancel: SidebarBtn

    # layout cache
    listY, listH, listW: int

# ── Load / refresh ────────────────────────────────────────────────────────────

proc reload*(sb: var Sidebar; modpackDir, toolId: string) =
  sb.modpackDir    = modpackDir
  sb.toolId        = toolId
  sb.entries       = scanModpack(modpackDir, toolId)
  sb.selIdx        = if sb.entries.len > 0: 0 else: -1
  sb.scrollY       = 0
  sb.newPluginMode = false
  if sb.entries.len > 0:
    sb.activePluginPath = sb.entries[0].path
  else:
    sb.activePluginPath = ""
  sb.statusMsg = fmt"{sb.entries.len} plugin(s) loaded"
  sb.statusOk  = true

# ── New-plugin helpers ────────────────────────────────────────────────────────

proc toSlug(name: string): string =
  ## Derive a valid plugin id slug from a display name.
  var buf = newStringOfCap(name.len)
  for c in name.toLowerAscii():
    if c.isAlphaNumeric: buf.add c
    elif c in {' ', '_', '-'} and buf.len > 0 and buf[^1] != '-': buf.add '-'
  while buf.len > 0 and not buf[0].isAlphaAscii: buf = buf[1 .. ^1]
  result = buf

proc emptyPluginBody(toolId: string): JsonNode =
  ## Minimal data section for a freshly-created plugin of a given tool type.
  result = newJObject()
  case toolId
  of "world-tool":
    result["world_seed"] = newJInt(0)
    result["tiles"]      = newJArray()
  of "room-editor":
    result["presets"] = newJObject()
  of "gameplay-vars":
    result["vars"] = newJObject()
  else: discard

proc createPlugin(sb: var Sidebar) =
  let name = sb.newNameBuf.strip()
  if name.len == 0:
    sb.statusMsg = "Name cannot be empty"
    sb.statusOk  = false
    return

  let slug = toSlug(name)
  if slug.len == 0:
    sb.statusMsg = "Could not derive a valid id from that name"
    sb.statusOk  = false
    return

  # Folder: <modpackDir>/<slug>/   file: <slug>.json
  let folder = sb.modpackDir / slug
  let path   = folder / (slug & ".json")

  if fileExists(path):
    sb.statusMsg = fmt"Plugin '{slug}' already exists"
    sb.statusOk  = false
    return

  var meta    = defaultMeta()
  meta.id     = slug
  meta.name   = name
  meta.tool   = sb.toolId
  meta.tags   = @[slug]
  meta.enabled = true

  var j = newJObject()
  j["meta"] = meta.toJson()
  for k, v in emptyPluginBody(sb.toolId): j[k] = v

  try:
    createDir(folder)
    savePluginJson(path, j)
  except:
    sb.statusMsg = "Failed to write plugin file"
    sb.statusOk  = false
    return

  # Reload and select the new entry
  sb.newPluginMode = false
  sb.reload(sb.modpackDir, sb.toolId)
  for i, e in sb.entries:
    if e.path == path:
      sb.selIdx           = i
      sb.activePluginPath = path
      break

  saveOrder(sb.modpackDir, sb.toolId, sb.entries.mapIt(it.path))
  sb.pluginsChanged  = true
  sb.lastCreatedPath = path
  sb.statusMsg = fmt"Created '{name}'"
  sb.statusOk  = true

# ── Hit helpers ───────────────────────────────────────────────────────────────

proc contains(r: Rect; x, y: int): bool =
  x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h

# ── Rendering ─────────────────────────────────────────────────────────────────

const
  BTN_ROW_H = BTN_H + 4
  BTN_PAD   = 2

proc drawBtn(ren: RendererPtr; font: FontPtr; fontH: int;
             btn: var SidebarBtn; x, y, w, h: int; label: string;
             fg: Color; mx, my: int) =
  btn.rect = (x.cint, y.cint, w.cint, h.cint)
  btn.hot  = btn.rect.contains(mx, my)
  ren.fillRect(x, y, w, h, if btn.hot: BTN_HOV else: BTN_BG)
  let lw = textWidth(font, label)
  renderText(ren, font, label,
             x + (w - lw) div 2,
             y + (h - fontH) div 2 - 2,
             fg)

proc renderNewPluginForm(sb: var Sidebar; ren: RendererPtr; font: FontPtr;
                         fontH: int; x, y, w, h: int; mx, my: int) =
  ## Inline new-plugin form drawn in the lower portion of the sidebar.
  ren.fillRect(x, y, w, h, BG3)
  ren.drawHLine(x, y, w, BG2)

  let pad  = PAD
  var curY = y + pad

  renderText(ren, font, "New Plugin", x + pad, curY, FG_ACTIVE)
  curY += fontH + pad

  # Name label
  renderText(ren, font, "Name:", x + pad, curY, FG_DIM)
  curY += fontH + 2

  # Name input field
  let fieldX = x + pad
  let fieldW = w - pad * 2
  let fieldH = ROW_H
  ren.fillRect(fieldX, curY, fieldW, fieldH, BG)
  ren.drawRect(fieldX, curY, fieldW, fieldH, BG2)

  let nameDisplay = sb.newNameBuf
  renderText(ren, font, nameDisplay,
             fieldX + 4, curY + (fieldH - fontH) div 2 - 2, FG)

  # Cursor in name field
  if (getTicks().int div 530) mod 2 == 0:
    let caretX = fieldX + 4 + textWidth(font, sb.newNameBuf[0 ..< sb.newNameCursor])
    ren.drawVLine(caretX, curY + 3, fieldH - 6, FG_ACTIVE)

  curY += fieldH + pad

  # Auto-derived slug preview
  let slug = toSlug(sb.newNameBuf)
  renderText(ren, font, "id: " & (if slug.len > 0: slug else: "-"),
             x + pad, curY, FG_DIM)
  curY += fontH + pad

  # Create / Cancel buttons
  let bw = (fieldW - BTN_PAD) div 2
  drawBtn(ren, font, fontH, sb.btnCreate,
          fieldX, curY, bw, BTN_H, "Create", FG_OK, mx, my)
  drawBtn(ren, font, fontH, sb.btnCancel,
          fieldX + bw + BTN_PAD, curY, bw, BTN_H, "Cancel", FG_RED, mx, my)

proc render*(sb: var Sidebar; ren: RendererPtr; font: FontPtr; fontH: int;
             x, y, w, h: int; toolId: string; mx, my: int) =
  ren.fillRect(x, y, w, h, BG2)

  # ── Bottom button row (hidden when form is open) ─────────────────────────
  let btnRowY  = y + h - BTN_ROW_H - PAD
  let formH    = fontH * 2 + ROW_H + BTN_H + PAD * 5 + 2  ## form panel height
  let newBtnY  = btnRowY - BTN_H - BTN_PAD    ## Save Plugin button
  let dividerY = newBtnY - BTN_H - BTN_PAD * 2 - PAD div 2  ## above New Plugin + Save

  if not sb.newPluginMode:
    let bw = (w - PAD * 2 - BTN_PAD * 4) div 5
    var bx = x + PAD

    template btn(field, lbl, fg: untyped) =
      drawBtn(ren, font, fontH, sb.field, bx, btnRowY, bw, BTN_H, lbl, fg, mx, my)
      bx += bw + BTN_PAD

    btn(btnSetAct, "Actv", FG_ACTIVE)
    btn(btnToggle, "+/-",  FG)
    btn(btnUp,     "^",    FG)
    btn(btnDown,   "v",    FG)
    btn(btnDel,    "Del",  FG_DEL)

    let saveFg  = if sb.dirty: FG_OK else: FG_DIM
    let newBtnY2 = newBtnY - BTN_H - BTN_PAD
    drawBtn(ren, font, fontH, sb.btnNew,
            x + PAD, newBtnY2, w - PAD * 2, BTN_H, "+ New Plugin", FG_OK, mx, my)
    drawBtn(ren, font, fontH, sb.btnSave,
            x + PAD, newBtnY, w - PAD * 2, BTN_H,
            if sb.dirty: "* Save Plugin" else: "Save Plugin",
            saveFg, mx, my)
    ren.drawHLine(x, dividerY, w, BG3)

  # ── New-plugin inline form ───────────────────────────────────────────────
  if sb.newPluginMode:
    let formY = y + h - formH - PAD
    renderNewPluginForm(sb, ren, font, fontH, x, formY, w, formH, mx, my)

  # ── Plugin list ──────────────────────────────────────────────────────────
  let listBottom = if sb.newPluginMode: y + h - formH - PAD
                   else:                dividerY + PAD div 2
  sb.listY = y + PAD
  sb.listH = listBottom - sb.listY
  sb.listW = w
  let visRows = sb.listH div ROW_H

  ren.fillRect(x, sb.listY, w, sb.listH, BG2)

  # Header row
  ren.fillRect(x, sb.listY, w, ROW_H, BG3)
  renderText(ren, font, "  # Name                  M",
             x + PAD, sb.listY + (ROW_H - fontH) div 2 - 2, FG_DIM)

  let startIdx = sb.scrollY
  let endIdx   = min(startIdx + visRows - 1, sb.entries.high)

  for i in startIdx .. endIdx:
    if i < 0 or i > sb.entries.high: continue
    let e   = sb.entries[i]
    let row = i - startIdx + 1
    let ry  = sb.listY + row * ROW_H

    let isActive = e.path == sb.activePluginPath
    let isSel    = i == sb.selIdx

    if isSel:     ren.fillRect(x, ry, w, ROW_H, SEL_BG)
    elif isActive: ren.fillRect(x, ry, w, ROW_H, (r: 38'u8, g: 42'u8, b: 50'u8, a: 255'u8))

    let actMark  = if isActive:        ">" else: " "
    let mastMark = if e.meta.isMaster: "*" else: " "
    let enMark   = if e.meta.enabled: "" else: " off"
    let nameStr  = (e.meta.name & enMark)[0 .. min(18, (e.meta.name & enMark).high)]
    let rowText  = fmt" {actMark} {i+1:<2} {nameStr:<19} {mastMark}"

    let fg =
      if not e.meta.enabled: FG_DIM
      elif isActive:         FG_ACTIVE
      elif e.meta.isMaster:  FG_MASTER
      else:                  FG

    renderText(ren, font, rowText, x + PAD div 2,
               ry + (ROW_H - fontH) div 2 - 2, fg)

  if sb.entries.len > visRows - 1 and visRows > 1:
    let total = sb.entries.len
    let barH  = max(ROW_H, sb.listH * (visRows - 1) div max(1, total))
    let barY  = sb.listY + ROW_H +
                (sb.listH - ROW_H - barH) * sb.scrollY div max(1, total - visRows + 1)
    ren.fillRect(x + w - 3, barY, 3, barH, BG3)

# ── Input ─────────────────────────────────────────────────────────────────────

proc clampScroll(sb: var Sidebar; visRows: int) =
  sb.scrollY = sb.scrollY.clamp(0, max(0, sb.entries.len - visRows + 1))

proc handleWheel*(sb: var Sidebar; dy: int) =
  if sb.newPluginMode: return
  sb.scrollY = max(0, sb.scrollY - dy)
  let visRows = if sb.listH > 0: sb.listH div ROW_H else: 1
  sb.clampScroll(visRows)

proc handleTextInput*(sb: var Sidebar; text: string) =
  if sb.newPluginMode:
    sb.newNameBuf.insert(text, sb.newNameCursor)
    sb.newNameCursor += text.len

proc handleKeyDown*(sb: var Sidebar; sym: Scancode) =
  if not sb.newPluginMode: return
  case sym
  of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
    sb.createPlugin()
  of SDL_SCANCODE_ESCAPE:
    sb.newPluginMode = false
  of SDL_SCANCODE_BACKSPACE:
    if sb.newNameCursor > 0:
      let i = sb.newNameCursor - 1
      sb.newNameBuf = sb.newNameBuf[0 ..< i] & sb.newNameBuf[i + 1 .. ^1]
      dec sb.newNameCursor
  of SDL_SCANCODE_DELETE:
    if sb.newNameCursor < sb.newNameBuf.len:
      let i = sb.newNameCursor
      sb.newNameBuf = sb.newNameBuf[0 ..< i] & sb.newNameBuf[i + 1 .. ^1]
  of SDL_SCANCODE_LEFT:
    if sb.newNameCursor > 0: dec sb.newNameCursor
  of SDL_SCANCODE_RIGHT:
    if sb.newNameCursor < sb.newNameBuf.len: inc sb.newNameCursor
  of SDL_SCANCODE_HOME:
    sb.newNameCursor = 0
  of SDL_SCANCODE_END:
    sb.newNameCursor = sb.newNameBuf.len
  else: discard

proc rowAtY(sb: Sidebar; my: int): int =
  if my < sb.listY + ROW_H: return -1
  let row = (my - sb.listY) div ROW_H - 1 + sb.scrollY
  if row >= 0 and row < sb.entries.len: row else: -1

proc handleMouseDown*(sb: var Sidebar; x, y, btn: int;
                      modpackDir, toolId: string) =
  # Form buttons take priority
  if sb.newPluginMode:
    if sb.btnCreate.rect.contains(x, y): sb.createPlugin(); return
    if sb.btnCancel.rect.contains(x, y): sb.newPluginMode = false; return
    return  ## eat all other clicks while form is open

  let idx = sb.rowAtY(y)
  if idx >= 0: sb.selIdx = idx

  if sb.btnSetAct.rect.contains(x, y) and sb.selIdx >= 0:
    sb.activePluginPath = sb.entries[sb.selIdx].path
    sb.statusMsg = fmt"Active: {sb.entries[sb.selIdx].meta.name}"
    sb.statusOk  = true
    return

  if sb.btnToggle.rect.contains(x, y) and sb.selIdx >= 0:
    patchEnabled(sb.entries[sb.selIdx].path,
                 not sb.entries[sb.selIdx].meta.enabled)
    sb.entries[sb.selIdx].meta.enabled = not sb.entries[sb.selIdx].meta.enabled
    sb.pluginsChanged  = true
    sb.lastCreatedPath = ""
    sb.statusMsg = "Toggled"; sb.statusOk = true
    return

  if sb.btnUp.rect.contains(x, y) and sb.selIdx > 0:
    swap(sb.entries[sb.selIdx], sb.entries[sb.selIdx - 1])
    dec sb.selIdx
    persistOrder(modpackDir, toolId, sb.entries)
    return

  if sb.btnDown.rect.contains(x, y) and sb.selIdx >= 0 and sb.selIdx < sb.entries.high:
    swap(sb.entries[sb.selIdx], sb.entries[sb.selIdx + 1])
    inc sb.selIdx
    persistOrder(modpackDir, toolId, sb.entries)
    return

  if sb.btnDel.rect.contains(x, y) and sb.selIdx >= 0:
    let path = sb.entries[sb.selIdx].path
    if path == sb.activePluginPath:
      sb.statusMsg = "Cannot delete active plugin"; sb.statusOk = false; return
    deletePlugin(modpackDir, toolId, path, sb.entries)
    sb.selIdx          = sb.selIdx.clamp(0, sb.entries.high)
    sb.pluginsChanged  = true
    sb.lastCreatedPath = ""
    sb.statusMsg = "Plugin deleted"; sb.statusOk = true
    return

  if sb.btnSave.rect.contains(x, y):
    sb.saveRequested = true
    return

  if sb.btnNew.rect.contains(x, y):
    sb.newPluginMode = true
    sb.newNameBuf    = ""
    sb.newNameCursor = 0
    return
