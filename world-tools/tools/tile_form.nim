## tile_form.nim
## Floating tile-edit panel — SDL2 overlay on top of the world canvas.
## Defines RoomRef and TileEntry (imported by world_tab).
## Open with openFor(); world_tab checks resultEntry after wasSaved/wasCopied.

import sdl2
import sdl2/ttf
import std/[strutils, sequtils, strformat]
import "../theme"
import world_data

const
  FORM_W    = 480
  FORM_H    = 416   ## +26 for image row
  LABEL_W   = 112
  SWATCH_SZ = 14
  ROOM_ROWS = 4

# ── Types ─────────────────────────────────────────────────────────────────────

type
  RoomRef* = object
    id*:          string
    connections*: seq[string]

  TileEntry* = object
    x*, y*:       int
    tile*:        string
    `type`*:      string
    image*:       string
    entry_room*:  string
    rooms*:       seq[RoomRef]
    global_npcs*: seq[string]
    deleted*:     bool

  TileField = enum tfNone, tfTile, tfEntryRoom, tfRoom, tfNpcAdd, tfImageFilter

  TileForm* = object
    open*:         bool
    isForeign*:    bool
    wasSaved*:     bool
    wasCopied*:    bool
    wasCancelled*: bool
    resultEntry*:  TileEntry   ## filled when wasSaved or wasCopied

    tileX*, tileY*: int

    tileBuf:      string
    tileCursor:   int
    selType:      int
    typeDropOpen: bool
    imgFilterBuf:     string
    imgFilterCursor:  int
    imgFiles:         seq[string]   ## all image basenames (populated on open)
    imgFiltered:      seq[string]   ## filtered subset
    imgDropOpen:      bool
    entryBuf:     string
    entryCursor:  int

    roomLines:   seq[string]   ## "room_id: conn1, conn2" per RoomRef
    selRoom:     int
    editRoom:    int           ## -1 = not editing
    roomBuf:     string
    roomCursor:  int
    roomScrollY: int

    npcTags:    seq[string]
    npcAddMode: bool
    npcBuf:     string
    npcCursor:  int

    activeField: TileField

    # Layout cache (rebuilt each render)
    formX, formY: int
    tileFldR:     Rect
    imgFldR:      Rect
    imgDropR:     Rect
    entryFldR:    Rect
    typeBtnR:     Rect
    typeOptR:     array[4, Rect]
    roomRowR:     seq[Rect]
    btnAddRoom:   Rect
    btnDelRoom:   Rect
    npcChipXR:    seq[Rect]    ## chip × rects, one per tag
    btnAddNpc:    Rect
    btnSave:      Rect
    btnCancel:    Rect
    btnCopy:      Rect

# ── Helpers ───────────────────────────────────────────────────────────────────

proc roomToLine(r: RoomRef): string =
  if r.connections.len == 0: return r.id
  r.id & ": " & r.connections.join(", ")

proc lineToRoom(s: string): RoomRef =
  let i = s.find(':')
  if i < 0:
    result.id = s.strip()
  else:
    result.id = s[0 ..< i].strip()
    for c in s[i + 1 .. ^1].split(","):
      let t = c.strip()
      if t.len > 0: result.connections.add t

proc inRect(r: Rect; x, y: int): bool =
  x >= r.x.int and x < r.x.int + r.w.int and
  y >= r.y.int and y < r.y.int + r.h.int

proc buildImgFiltered(form: var TileForm) =
  let q = form.imgFilterBuf.toLowerAscii
  if q.len == 0:
    form.imgFiltered = form.imgFiles
  else:
    form.imgFiltered = @[]
    for f in form.imgFiles:
      if f.toLowerAscii.contains(q):
        form.imgFiltered.add f

proc packResult(form: TileForm): TileEntry =
  result.x           = form.tileX
  result.y           = form.tileY
  result.tile        = form.tileBuf.strip()
  result.`type`      = TILE_TYPES[form.selType]
  result.image       = form.imgFilterBuf.strip()
  result.entry_room  = form.entryBuf.strip()
  result.rooms       = form.roomLines.filterIt(it.strip().len > 0).mapIt(lineToRoom(it))
  result.global_npcs = form.npcTags

# ── Open / Close ──────────────────────────────────────────────────────────────

proc openFor*(form: var TileForm; entry: TileEntry; isForeign: bool;
              imageFiles: seq[string]) =
  form.open         = true
  form.isForeign    = isForeign
  form.wasSaved     = false
  form.wasCopied    = false
  form.wasCancelled = false
  form.tileX        = entry.x
  form.tileY        = entry.y
  form.tileBuf      = entry.tile
  form.tileCursor   = entry.tile.len
  form.selType      = 0
  for i, t in TILE_TYPES:
    if t == entry.`type`: form.selType = i; break
  form.typeDropOpen    = false
  form.imgFiles        = imageFiles
  form.imgFilterBuf    = entry.image
  form.imgFilterCursor = entry.image.len
  form.imgDropOpen     = false
  form.buildImgFiltered()
  form.entryBuf     = entry.entry_room
  form.entryCursor  = entry.entry_room.len
  form.roomLines    = entry.rooms.mapIt(roomToLine(it))
  form.selRoom      = -1
  form.editRoom     = -1
  form.roomScrollY  = 0
  form.npcTags      = entry.global_npcs
  form.npcAddMode   = false
  form.npcBuf       = ""
  form.npcCursor    = 0
  form.activeField  = if isForeign: tfNone else: tfTile
  form.roomRowR     = @[]
  form.npcChipXR    = @[]

proc doClose*(form: var TileForm) =
  form.open         = false
  form.typeDropOpen = false

# ── Render ────────────────────────────────────────────────────────────────────

proc render*(form: var TileForm; ren: RendererPtr; font: FontPtr; fontH: int;
             canvasX, canvasY, canvasW, canvasH: int; mx, my: int) =
  if not form.open: return

  let fx = canvasX + (canvasW - FORM_W) div 2
  let fy = canvasY + (canvasH - FORM_H) div 2
  form.formX = fx
  form.formY = fy

  # Panel background
  ren.fillRect(fx, fy, FORM_W, FORM_H, BG2)
  ren.drawRect(fx, fy, FORM_W, FORM_H, BG3)

  # Title bar
  ren.fillRect(fx, fy, FORM_W, 28, BG3)
  let titleStr = fmt"Tile ({form.tileX}, {form.tileY})" &
                 (if form.isForeign: "  [foreign - read only]" else: "")
  renderText(ren, font, titleStr, fx + PAD, fy + (28 - fontH) div 2 - 2,
             if form.isForeign: FG_DIM else: FG_ACTIVE)

  let editable  = not form.isForeign
  let showCaret = (getTicks().int div 530) mod 2 == 0
  let fieldX    = fx + LABEL_W
  let fieldW    = FORM_W - LABEL_W - PAD * 2
  let listX     = fx + PAD
  let listW     = FORM_W - PAD * 2

  var curY = fy + 28 + PAD

  # ── Tile name ────────────────────────────────────────────────────────────────
  renderText(ren, font, "Tile:",
             fx + PAD, curY + (ROW_H - fontH) div 2 - 2, FG_DIM)
  ren.fillRect(fieldX, curY, fieldW, ROW_H, BG)
  ren.drawRect(fieldX, curY, fieldW, ROW_H,
               if form.activeField == tfTile and editable: FG_DIM else: BG3)
  renderText(ren, font, form.tileBuf,
             fieldX + 4, curY + (ROW_H - fontH) div 2 - 2,
             if editable: FG else: FG_DIM)
  if form.activeField == tfTile and editable and showCaret:
    let cx = fieldX + 4 + textWidth(font, form.tileBuf[0 ..< form.tileCursor])
    ren.drawVLine(cx, curY + 3, ROW_H - 6, FG_ACTIVE)
  form.tileFldR = (fieldX.cint, curY.cint, fieldW.cint, ROW_H.cint)
  curY += ROW_H + 6

  # ── Tile type ────────────────────────────────────────────────────────────────
  renderText(ren, font, "Type:",
             fx + PAD, curY + (ROW_H - fontH) div 2 - 2, FG_DIM)
  let swatchY = curY + (ROW_H - SWATCH_SZ) div 2
  ren.fillRect(fieldX, swatchY, SWATCH_SZ, SWATCH_SZ, TILE_COLORS[form.selType].color)
  let tbx = fieldX + SWATCH_SZ + 6
  let tbw = fieldW - SWATCH_SZ - 6
  form.typeBtnR = (tbx.cint, curY.cint, tbw.cint, ROW_H.cint)
  let typeHot = editable and not form.typeDropOpen and
                mx >= tbx and mx < tbx + tbw and my >= curY and my < curY + ROW_H
  ren.fillRect(tbx, curY, tbw, ROW_H,
               if typeHot: BTN_HOV elif editable: BTN_BG else: BG)
  renderText(ren, font, TILE_TYPES[form.selType] & (if editable: "  v" else: ""),
             tbx + 4, curY + (ROW_H - fontH) div 2 - 2,
             if editable: FG else: FG_DIM)
  curY += ROW_H + 6

  # ── Image ─────────────────────────────────────────────────────────────────────
  renderText(ren, font, "Image:",
             fx + PAD, curY + (ROW_H - fontH) div 2 - 2, FG_DIM)
  let imgActive = form.activeField == tfImageFilter and editable
  ren.fillRect(fieldX, curY, fieldW, ROW_H, BG)
  ren.drawRect(fieldX, curY, fieldW, ROW_H,
               if imgActive: FG_ACTIVE else: BG3)
  let imgDisplayText =
    if imgActive: form.imgFilterBuf
    elif form.imgFilterBuf.len > 0: form.imgFilterBuf
    else: "(none)"
  renderText(ren, font, imgDisplayText,
             fieldX + 4, curY + (ROW_H - fontH) div 2 - 2,
             if not editable: FG_DIM elif imgActive: FG_ACTIVE
             elif form.imgFilterBuf.len > 0: FG else: FG_DIM)
  if imgActive and showCaret:
    let cx = fieldX + 4 + textWidth(font, form.imgFilterBuf[0 ..< form.imgFilterCursor])
    ren.drawVLine(cx, curY + 3, ROW_H - 6, FG_ACTIVE)
  form.imgFldR = (fieldX.cint, curY.cint, fieldW.cint, ROW_H.cint)
  curY += ROW_H + 6

  # ── Entry room ───────────────────────────────────────────────────────────────
  renderText(ren, font, "Entry room:",
             fx + PAD, curY + (ROW_H - fontH) div 2 - 2, FG_DIM)
  ren.fillRect(fieldX, curY, fieldW, ROW_H, BG)
  ren.drawRect(fieldX, curY, fieldW, ROW_H,
               if form.activeField == tfEntryRoom and editable: FG_DIM else: BG3)
  renderText(ren, font, form.entryBuf,
             fieldX + 4, curY + (ROW_H - fontH) div 2 - 2,
             if editable: FG else: FG_DIM)
  if form.activeField == tfEntryRoom and editable and showCaret:
    let cx = fieldX + 4 + textWidth(font, form.entryBuf[0 ..< form.entryCursor])
    ren.drawVLine(cx, curY + 3, ROW_H - 6, FG_ACTIVE)
  form.entryFldR = (fieldX.cint, curY.cint, fieldW.cint, ROW_H.cint)
  curY += ROW_H + 6

  # ── Rooms line-list ───────────────────────────────────────────────────────────
  renderText(ren, font, "Rooms:", fx + PAD, curY, FG_DIM)
  curY += fontH + 4

  let roomListH = ROOM_ROWS * ROW_H
  ren.fillRect(listX, curY, listW, roomListH, BG)
  ren.drawRect(listX, curY, listW, roomListH, BG3)

  form.roomRowR.setLen(0)
  for i in form.roomScrollY ..< min(form.roomScrollY + ROOM_ROWS, form.roomLines.len):
    let ry = curY + (i - form.roomScrollY) * ROW_H
    let rr: Rect = (listX.cint, ry.cint, listW.cint, ROW_H.cint)
    form.roomRowR.add rr
    let isSel  = i == form.selRoom
    let isEdit = i == form.editRoom and editable
    if isSel: ren.fillRect(listX, ry, listW, ROW_H, SEL_BG)
    let lineStr = if isEdit: form.roomBuf else: form.roomLines[i]
    let lineFg  = if isEdit: FG_ACTIVE elif isSel: FG else: FG_DIM
    renderText(ren, font, lineStr, listX + 4, ry + (ROW_H - fontH) div 2 - 2, lineFg)
    if isEdit and showCaret:
      let cx = listX + 4 + textWidth(font, form.roomBuf[0 ..< form.roomCursor])
      ren.drawVLine(cx, ry + 3, ROW_H - 6, FG_ACTIVE)

  curY += roomListH + 4

  if editable:
    let bw = 64
    form.btnAddRoom = (listX.cint, curY.cint, bw.cint, BTN_H.cint)
    form.btnDelRoom = ((listX + bw + 4).cint, curY.cint, bw.cint, BTN_H.cint)
    let addRowHot = form.btnAddRoom.inRect(mx, my)
    let delRowHot = form.btnDelRoom.inRect(mx, my)
    ren.fillRect(listX, curY, bw, BTN_H, if addRowHot: BTN_HOV else: BTN_BG)
    renderText(ren, font, "+ Row", listX + 4, curY + (BTN_H - fontH) div 2 - 2, FG_OK)
    ren.fillRect(listX + bw + 4, curY, bw, BTN_H, if delRowHot: BTN_HOV else: BTN_BG)
    renderText(ren, font, "- Row", listX + bw + 8, curY + (BTN_H - fontH) div 2 - 2, FG_DEL)
  curY += BTN_H + 6

  # ── global_npcs tag chips ─────────────────────────────────────────────────────
  renderText(ren, font, "NPCs:", fx + PAD, curY, FG_DIM)
  curY += fontH + 4

  form.npcChipXR.setLen(0)
  var chipX = listX
  for i, tag in form.npcTags:
    let xBtnW = if editable: ROW_H else: 0
    let tw = textWidth(font, tag) + 8 + xBtnW
    ren.fillRect(chipX, curY, tw, ROW_H, BG3)
    renderText(ren, font, tag, chipX + 4, curY + (ROW_H - fontH) div 2 - 2, FG)
    if editable:
      let xr: Rect = ((chipX + tw - ROW_H).cint, curY.cint, ROW_H.cint, ROW_H.cint)
      form.npcChipXR.add xr
      renderText(ren, font, "x",
                 xr.x.int + (ROW_H - textWidth(font, "×")) div 2,
                 curY + (ROW_H - fontH) div 2 - 2, FG_DEL)
    else:
      form.npcChipXR.add (0.cint, 0.cint, 0.cint, 0.cint)
    chipX += tw + 4
    if chipX > fx + FORM_W - PAD - 80: break

  if editable:
    if form.npcAddMode:
      ren.fillRect(chipX, curY, 120, ROW_H, BG)
      ren.drawRect(chipX, curY, 120, ROW_H, BG3)
      renderText(ren, font, form.npcBuf, chipX + 4, curY + (ROW_H - fontH) div 2 - 2, FG)
      if form.activeField == tfNpcAdd and showCaret:
        let cx = chipX + 4 + textWidth(font, form.npcBuf[0 ..< form.npcCursor])
        ren.drawVLine(cx, curY + 3, ROW_H - 6, FG_ACTIVE)
    else:
      form.btnAddNpc = (chipX.cint, curY.cint, 60.cint, ROW_H.cint)
      let addNpcHot = form.btnAddNpc.inRect(mx, my)
      ren.fillRect(chipX, curY, 60, ROW_H, if addNpcHot: BTN_HOV else: BTN_BG)
      renderText(ren, font, "+ Add", chipX + 4, curY + (ROW_H - fontH) div 2 - 2, FG_OK)

  # ── Footer buttons ────────────────────────────────────────────────────────────
  let footY = fy + FORM_H - BTN_H - PAD
  if form.isForeign:
    form.btnCopy   = ((fx + PAD).cint, footY.cint, 184.cint, BTN_H.cint)
    form.btnCancel = ((fx + PAD + 188).cint, footY.cint, 80.cint, BTN_H.cint)
    ren.fillRect(fx + PAD, footY, 184, BTN_H,
                 if form.btnCopy.inRect(mx, my): BTN_HOV else: BTN_BG)
    renderText(ren, font, "Copy to Active Plugin",
               fx + PAD + 4, footY + (BTN_H - fontH) div 2 - 2, FG_ACTIVE)
    ren.fillRect(fx + PAD + 188, footY, 80, BTN_H,
                 if form.btnCancel.inRect(mx, my): BTN_HOV else: BTN_BG)
    renderText(ren, font, "Cancel",
               fx + PAD + 188 + 4, footY + (BTN_H - fontH) div 2 - 2, FG_RED)
  else:
    let bw = 80
    let bx = fx + FORM_W - PAD - bw * 2 - 4
    form.btnSave   = (bx.cint, footY.cint, bw.cint, BTN_H.cint)
    form.btnCancel = ((bx + bw + 4).cint, footY.cint, bw.cint, BTN_H.cint)
    ren.fillRect(bx, footY, bw, BTN_H,
                 if form.btnSave.inRect(mx, my): BTN_HOV else: BTN_BG)
    renderText(ren, font, "Save",
               bx + (bw - textWidth(font, "Save")) div 2,
               footY + (BTN_H - fontH) div 2 - 2, FG_OK)
    ren.fillRect(bx + bw + 4, footY, bw, BTN_H,
                 if form.btnCancel.inRect(mx, my): BTN_HOV else: BTN_BG)
    renderText(ren, font, "Cancel",
               bx + bw + 4 + (bw - textWidth(font, "Cancel")) div 2,
               footY + (BTN_H - fontH) div 2 - 2, FG_RED)

  # ── Type dropdown (drawn on top of everything) ────────────────────────────────
  if form.typeDropOpen and editable:
    let dx = form.typeBtnR.x.int
    let dy = form.typeBtnR.y.int + ROW_H
    let dw = form.typeBtnR.w.int
    ren.fillRect(dx, dy, dw, 4 * ROW_H, DROP_BG)
    ren.drawRect(dx, dy, dw, 4 * ROW_H, BG3)
    for i in 0 ..< 4:
      let ry = dy + i * ROW_H
      form.typeOptR[i] = (dx.cint, ry.cint, dw.cint, ROW_H.cint)
      if i == form.selType: ren.fillRect(dx, ry, dw, ROW_H, SEL_BG)
      ren.fillRect(dx + 2, ry + (ROW_H - SWATCH_SZ) div 2, SWATCH_SZ, SWATCH_SZ,
                   TILE_COLORS[i].color)
      renderText(ren, font, TILE_TYPES[i],
                 dx + SWATCH_SZ + 8, ry + (ROW_H - fontH) div 2 - 2, FG)

  # ── Image dropdown (drawn on top of everything) ───────────────────────────────
  if form.imgDropOpen and editable and form.imgFiltered.len > 0:
    let dx = form.imgFldR.x.int
    let dy = form.imgFldR.y.int + ROW_H
    let dw = form.imgFldR.w.int
    let maxRows = min(6, form.imgFiltered.len)
    let dh = maxRows * ROW_H
    form.imgDropR = (dx.cint, dy.cint, dw.cint, dh.cint)
    ren.fillRect(dx, dy, dw, dh, DROP_BG)
    ren.drawRect(dx, dy, dw, dh, BG3)
    for i in 0 ..< maxRows:
      let ry  = dy + i * ROW_H
      let hot = mx >= dx and mx < dx + dw and my >= ry and my < ry + ROW_H
      if hot: ren.fillRect(dx, ry, dw, ROW_H, DROP_HOV)
      renderText(ren, font, form.imgFiltered[i],
                 dx + 4, ry + (ROW_H - fontH) div 2 - 2,
                 if hot: FG_ACTIVE else: FG)

# ── Input ─────────────────────────────────────────────────────────────────────

proc handleMouseDown*(form: var TileForm; x, y, btn: int) =
  if not form.open: return
  let editable = not form.isForeign

  # Image dropdown intercepts when open
  if form.imgDropOpen and editable:
    if form.imgDropR.inRect(x, y):
      let row = (y - form.imgDropR.y.int) div ROW_H
      if row >= 0 and row < form.imgFiltered.len:
        form.imgFilterBuf    = form.imgFiltered[row]
        form.imgFilterCursor = form.imgFilterBuf.len
        form.buildImgFiltered()
    form.imgDropOpen = false
    return

  # Type dropdown intercepts first when open
  if form.typeDropOpen and editable:
    for i in 0 ..< 4:
      if form.typeOptR[i].inRect(x, y):
        form.selType     = i
        form.typeDropOpen = false
        return
    form.typeDropOpen = false
    return

  # Type button
  if form.typeBtnR.inRect(x, y) and editable:
    form.typeDropOpen = not form.typeDropOpen
    return

  # Tile name field
  if form.tileFldR.inRect(x, y) and editable:
    form.activeField = tfTile
    return

  # Image filter field
  if form.imgFldR.inRect(x, y) and editable:
    form.activeField     = tfImageFilter
    form.imgFilterCursor = form.imgFilterBuf.len
    form.buildImgFiltered()
    form.imgDropOpen = true
    return

  # Entry room field
  if form.entryFldR.inRect(x, y) and editable:
    form.activeField = tfEntryRoom
    return

  # Room rows
  for i, rr in form.roomRowR:
    if rr.inRect(x, y):
      let realIdx = form.roomScrollY + i
      if form.selRoom == realIdx and editable and form.editRoom != realIdx:
        # Second click → enter edit
        if form.editRoom >= 0 and form.editRoom < form.roomLines.len:
          form.roomLines[form.editRoom] = form.roomBuf
        form.editRoom   = realIdx
        form.roomBuf    = form.roomLines[realIdx]
        form.roomCursor = form.roomBuf.len
        form.activeField = tfRoom
      elif form.editRoom >= 0 and form.editRoom < form.roomLines.len:
        form.roomLines[form.editRoom] = form.roomBuf
        form.editRoom = -1
        form.selRoom  = realIdx
        form.activeField = tfNone
      else:
        form.selRoom  = realIdx
        form.activeField = tfNone
      return

  # Add/Del row buttons
  if editable:
    if form.btnAddRoom.inRect(x, y):
      if form.editRoom >= 0 and form.editRoom < form.roomLines.len:
        form.roomLines[form.editRoom] = form.roomBuf
      form.roomLines.add ""
      let ni = form.roomLines.high
      form.selRoom    = ni
      form.editRoom   = ni
      form.roomBuf    = ""
      form.roomCursor = 0
      form.activeField = tfRoom
      # Scroll to show new row
      if ni >= form.roomScrollY + ROOM_ROWS:
        form.roomScrollY = ni - ROOM_ROWS + 1
      return
    if form.btnDelRoom.inRect(x, y) and form.selRoom >= 0 and
       form.selRoom < form.roomLines.len:
      form.roomLines.delete(form.selRoom)
      form.editRoom = -1
      form.selRoom  = min(form.selRoom, form.roomLines.high)
      return

  # NPC chip × buttons
  if editable:
    for i, xr in form.npcChipXR:
      if xr.w > 0 and xr.inRect(x, y) and i < form.npcTags.len:
        form.npcTags.delete(i)
        form.npcChipXR.setLen(0)
        return
    if not form.npcAddMode and form.btnAddNpc.inRect(x, y):
      form.npcAddMode  = true
      form.npcBuf      = ""
      form.npcCursor   = 0
      form.activeField = tfNpcAdd
      return

  # Footer
  if form.isForeign:
    if form.btnCopy.inRect(x, y):
      form.resultEntry = packResult(form)
      form.wasCopied   = true
      form.doClose()
      return
  else:
    if form.btnSave.inRect(x, y):
      if form.editRoom >= 0 and form.editRoom < form.roomLines.len:
        form.roomLines[form.editRoom] = form.roomBuf
      form.resultEntry = packResult(form)
      form.wasSaved    = true
      form.doClose()
      return
  if form.btnCancel.inRect(x, y):
    form.wasCancelled = true
    form.doClose()
    return

  # Click outside form → cancel
  if x < form.formX or x >= form.formX + FORM_W or
     y < form.formY or y >= form.formY + FORM_H:
    form.wasCancelled = true
    form.doClose()

template navField(buf, cur: untyped) =
  case sym
  of SDL_SCANCODE_BACKSPACE:
    if cur > 0:
      let bi = cur - 1
      buf = buf[0 ..< bi] & buf[bi + 1 .. ^1]
      dec cur
  of SDL_SCANCODE_DELETE:
    if cur < buf.len:
      let bi = cur
      buf = buf[0 ..< bi] & buf[bi + 1 .. ^1]
  of SDL_SCANCODE_LEFT:
    if cur > 0: dec cur
  of SDL_SCANCODE_RIGHT:
    if cur < buf.len: inc cur
  of SDL_SCANCODE_HOME: cur = 0
  of SDL_SCANCODE_END:  cur = buf.len
  else: discard

proc handleTextInput*(form: var TileForm; text: string) =
  if not form.open: return
  case form.activeField
  of tfTile:
    form.tileBuf.insert(text, form.tileCursor)
    form.tileCursor += text.len
  of tfImageFilter:
    form.imgFilterBuf.insert(text, form.imgFilterCursor)
    form.imgFilterCursor += text.len
    form.buildImgFiltered()
    form.imgDropOpen = true
  of tfEntryRoom:
    form.entryBuf.insert(text, form.entryCursor)
    form.entryCursor += text.len
  of tfRoom:
    form.roomBuf.insert(text, form.roomCursor)
    form.roomCursor += text.len
  of tfNpcAdd:
    form.npcBuf.insert(text, form.npcCursor)
    form.npcCursor += text.len
  of tfNone: discard

proc handleKeyDown*(form: var TileForm; sym: Scancode; ctrl, shift: bool) =
  if not form.open: return

  if sym == SDL_SCANCODE_ESCAPE:
    if form.imgDropOpen:
      form.imgDropOpen = false
      form.activeField = tfNone
      return
    if form.typeDropOpen:
      form.typeDropOpen = false
    elif form.editRoom >= 0:
      form.editRoom    = -1
      form.activeField = tfNone
    elif form.npcAddMode:
      form.npcAddMode  = false
      form.activeField = tfNone
    else:
      form.wasCancelled = true
      form.doClose()
    return

  case form.activeField
  of tfTile:
    case sym
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      form.activeField = tfImageFilter
      form.imgDropOpen = true
    else:
      navField(form.tileBuf, form.tileCursor)
  of tfImageFilter:
    case sym
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      if form.imgFiltered.len > 0:
        form.imgFilterBuf    = form.imgFiltered[0]
        form.imgFilterCursor = form.imgFilterBuf.len
        form.buildImgFiltered()
      form.imgDropOpen = false
      form.activeField = tfEntryRoom
    of SDL_SCANCODE_BACKSPACE:
      if form.imgFilterCursor > 0:
        let i = form.imgFilterCursor - 1
        form.imgFilterBuf = form.imgFilterBuf[0 ..< i] & form.imgFilterBuf[i + 1 .. ^1]
        dec form.imgFilterCursor
        form.buildImgFiltered()
    of SDL_SCANCODE_DELETE:
      if form.imgFilterCursor < form.imgFilterBuf.len:
        let i = form.imgFilterCursor
        form.imgFilterBuf = form.imgFilterBuf[0 ..< i] & form.imgFilterBuf[i + 1 .. ^1]
        form.buildImgFiltered()
    of SDL_SCANCODE_LEFT:
      if form.imgFilterCursor > 0: dec form.imgFilterCursor
    of SDL_SCANCODE_RIGHT:
      if form.imgFilterCursor < form.imgFilterBuf.len: inc form.imgFilterCursor
    of SDL_SCANCODE_HOME: form.imgFilterCursor = 0
    of SDL_SCANCODE_END:  form.imgFilterCursor = form.imgFilterBuf.len
    else: discard
  of tfEntryRoom:
    case sym
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      form.activeField = tfNone
    else:
      navField(form.entryBuf, form.entryCursor)
  of tfRoom:
    case sym
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      if form.editRoom >= 0 and form.editRoom < form.roomLines.len:
        form.roomLines[form.editRoom] = form.roomBuf
      form.editRoom    = -1
      form.activeField = tfNone
    else:
      navField(form.roomBuf, form.roomCursor)
  of tfNpcAdd:
    case sym
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      let tag = form.npcBuf.strip()
      if tag.len > 0: form.npcTags.add tag
      form.npcAddMode  = false
      form.npcBuf      = ""
      form.activeField = tfNone
    else:
      navField(form.npcBuf, form.npcCursor)
  of tfNone: discard
