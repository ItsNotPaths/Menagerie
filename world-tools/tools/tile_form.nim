## tile_form.nim
## Floating tile-edit panel — SDL2 overlay on top of the world canvas.
## Defines RoomCondEntry, RoomBlock and TileEntry (imported by world_tab).
## Open with openFor(); world_tab checks resultEntry after wasSaved/wasCopied.
##
## Room block model:
##   Each tile has a list of RoomBlocks.  A block has tags (seq[string]) and
##   a list of RoomCondEntry (condition + room name).  Conditions are
##   game/quest-state expressions of the form "var op value" where op is
##   >/</=/!=.  An entry with no condition loads unconditionally.
##
## Connection syntax (stored as raw strings in room_links, parsed on export):
##   tag1 <> tag2   bidirectional  (>< also accepted)
##   tag1 >  tag2   one-way from tag1 to tag2
##
## Entry tag:
##   The tile's default entry block is identified by a tag string matching
##   one of the block tags.  If multiple blocks share the tag the engine
##   picks the first (undefined / user error).

import sdl2
import sdl2/ttf
import std/[strutils, sequtils, strformat]
import "../theme"
import world_data

const
  FORM_W     = 540
  FORM_H     = 700
  LABEL_W    = 112
  SWATCH_SZ  = 14
  SIDEBAR_W  = 148   ## block sidebar column width (incl. right gap)
  BLOCK_ROWS = 5     ## block rows visible in sidebar
  ENTRY_ROWS = 4     ## entry rows visible in editor panel
  LINK_ROWS  = 2
  DROP_ROWS  = 12    ## max visible rows in image dropdown

# ── Types ─────────────────────────────────────────────────────────────────────

type
  RoomCondEntry* = object
    condition*: string   ## game/quest-state expression; empty = fallback
    room*:      string

  RoomBlock* = object
    tags*:    seq[string]
    entries*: seq[RoomCondEntry]

  TileEntry* = object
    x*, y*:               int
    tile*:                string
    `type`*:              string
    image*:               string
    entry_tag*:           string        ## tag naming the default entry block
    room_blocks*:         seq[RoomBlock]
    room_links*:          seq[string]   ## raw "tag1<>tag2" / "tag1>tag2" strings
    global_npcs*:         seq[string]
    encounter_chance*:    int           ## 0-100
    encounter_tags*:      seq[string]
    deleted*:             bool

  TileField = enum
    tfNone, tfTile, tfEntryTag,
    tfBlockTagAdd, tfEntry, tfLink,
    tfNpcAdd, tfImageFilter,
    tfEncounterChance, tfEncTagAdd

  TileForm* = object
    open*:         bool
    isForeign*:    bool
    wasSaved*:     bool
    wasCopied*:    bool
    wasCancelled*: bool
    resultEntry*:  TileEntry    ## filled when wasSaved or wasCopied
    warnMsgs*:     seq[string]  ## link-tag validation warnings after save

    tileX*, tileY*: int

    tileBuf:      string
    tileCursor:   int
    selType:      int
    typeDropOpen: bool

    imgFilterBuf:     string
    imgFilterCursor:  int
    imgFiles:         seq[string]
    imgFiltered:      seq[string]
    imgDropOpen:      bool
    imgDropScrollY:   int

    entryTagBuf:    string
    entryTagCursor: int

    # Block editing
    blocks:          seq[RoomBlock]
    selBlock:        int          ## -1 = none selected
    blockScrollY:    int
    blockTagAddMode: bool
    blockTagBuf:     string
    blockTagCursor:  int

    # Entry editing within selected block
    selEntry:     int    ## -1 = none
    editEntry:    int    ## -1 = not editing
    entryBuf:     string ## "condition | room" while editing
    entryCursor:  int
    entryScrollY: int

    # Connections
    linkLines:   seq[string]
    selLink:     int
    editLink:    int
    linkBuf:     string
    linkCursor:  int
    linkScrollY: int

    npcTags:    seq[string]
    npcAddMode: bool
    npcBuf:     string
    npcCursor:  int

    encChanceBuf:    string
    encChanceCursor: int
    encTags:         seq[string]
    encTagAddMode:   bool
    encTagBuf:       string
    encTagCursor:    int

    activeField: TileField

    # Layout cache (rebuilt each render)
    formX, formY:    int
    tileFldR:        Rect
    imgFldR:         Rect
    imgDropR:        Rect
    entryTagFldR:    Rect
    typeBtnR:        Rect
    typeOptR:        array[4, Rect]
    blockRowR:       seq[Rect]
    btnAddBlock:     Rect
    btnDelBlock:     Rect
    blockTagChipXR:  seq[Rect]
    btnAddBlockTag:  Rect
    entryRowR:       seq[Rect]
    btnAddEntry:     Rect
    btnDelEntry:     Rect
    linkRowR:        seq[Rect]
    btnAddLink:      Rect
    btnDelLink:      Rect
    npcChipXR:       seq[Rect]
    btnAddNpc:       Rect
    encFldR:         Rect
    encTagChipXR:    seq[Rect]
    btnAddEncTag:    Rect
    btnSave:         Rect
    btnCancel:       Rect
    btnCopy:         Rect

# ── Helpers ───────────────────────────────────────────────────────────────────

proc entryToLine(e: RoomCondEntry): string =
  if e.condition.len == 0: e.room
  else: e.condition & ": " & e.room

proc lineToEntry(s: string): RoomCondEntry =
  ## "condition: room"  or just  "room"
  let i = s.find(':')
  if i < 0:
    result.room = s.strip()
  else:
    result.condition = s[0 ..< i].strip()
    result.room      = s[i + 1 .. ^1].strip()

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
  form.imgDropScrollY = 0

proc allBlockTags(form: TileForm): seq[string] =
  for b in form.blocks:
    for t in b.tags:
      if t notin result: result.add t

proc validateLinks(form: TileForm): seq[string] =
  ## Returns warning strings for tags used in links that don't match any block tag.
  let known = allBlockTags(form)
  var bad: seq[string]
  for lnk in form.linkLines:
    let s = lnk.strip()
    if s.len == 0: continue
    var a, b: string
    let idx2 = block:
      let i = s.find("<>")
      if i >= 0: i else: s.find("><")
    if idx2 >= 0:
      a = s[0 ..< idx2].strip()
      b = s[idx2 + 2 .. ^1].strip()
    else:
      let i = s.find('>')
      if i >= 0:
        a = s[0 ..< i].strip()
        b = s[i + 1 .. ^1].strip()
    if a.len > 0 and a notin known and fmt"link references unknown tag '{a}'" notin bad:
      bad.add fmt"link references unknown tag '{a}'"
    if b.len > 0 and b notin known and fmt"link references unknown tag '{b}'" notin bad:
      bad.add fmt"link references unknown tag '{b}'"
  result = bad

proc commitEditEntry(form: var TileForm) =
  if form.editEntry >= 0 and form.selBlock >= 0 and
     form.selBlock < form.blocks.len and
     form.editEntry < form.blocks[form.selBlock].entries.len:
    form.blocks[form.selBlock].entries[form.editEntry] = lineToEntry(form.entryBuf)
  form.editEntry = -1

proc commitEditLink(form: var TileForm) =
  if form.editLink >= 0 and form.editLink < form.linkLines.len:
    form.linkLines[form.editLink] = form.linkBuf
  form.editLink = -1

proc packResult(form: TileForm): TileEntry =
  result.x              = form.tileX
  result.y              = form.tileY
  result.tile           = form.tileBuf.strip()
  result.`type`         = TILE_TYPES[form.selType]
  result.image          = form.imgFilterBuf.strip()
  result.entry_tag      = form.entryTagBuf.strip()
  result.room_blocks    = form.blocks
  result.room_links     = form.linkLines.filterIt(it.strip().len > 0)
  result.global_npcs    = form.npcTags
  result.encounter_chance =
    try: min(100, max(0, parseInt(form.encChanceBuf.strip())))
    except ValueError: 0
  result.encounter_tags = form.encTags

# ── Open / Close ──────────────────────────────────────────────────────────────

proc openFor*(form: var TileForm; entry: TileEntry; isForeign: bool;
              imageFiles: seq[string]) =
  form.open         = true
  form.isForeign    = isForeign
  form.wasSaved     = false
  form.wasCopied    = false
  form.wasCancelled = false
  form.warnMsgs     = @[]
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
  form.entryTagBuf    = entry.entry_tag
  form.entryTagCursor = entry.entry_tag.len
  form.blocks         = entry.room_blocks
  form.selBlock       = -1
  form.blockScrollY   = 0
  form.blockTagAddMode = false
  form.blockTagBuf     = ""
  form.blockTagCursor  = 0
  form.selEntry        = -1
  form.editEntry       = -1
  form.entryBuf        = ""
  form.entryCursor     = 0
  form.entryScrollY    = 0
  form.linkLines       = entry.room_links
  form.selLink         = -1
  form.editLink        = -1
  form.linkBuf         = ""
  form.linkCursor      = 0
  form.linkScrollY     = 0
  form.npcTags         = entry.global_npcs
  form.npcAddMode      = false
  form.npcBuf          = ""
  form.npcCursor       = 0
  form.encChanceBuf    = if entry.encounter_chance > 0: $entry.encounter_chance else: ""
  form.encChanceCursor = form.encChanceBuf.len
  form.encTags         = entry.encounter_tags
  form.encTagAddMode   = false
  form.encTagBuf       = ""
  form.encTagCursor    = 0
  form.activeField     = if isForeign: tfNone else: tfTile
  form.blockRowR       = @[]
  form.blockTagChipXR  = @[]
  form.entryRowR       = @[]
  form.linkRowR        = @[]
  form.npcChipXR       = @[]
  form.encTagChipXR    = @[]

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

  # ── Entry tag ────────────────────────────────────────────────────────────────
  renderText(ren, font, "Entry tag:",
             fx + PAD, curY + (ROW_H - fontH) div 2 - 2, FG_DIM)
  ren.fillRect(fieldX, curY, fieldW, ROW_H, BG)
  ren.drawRect(fieldX, curY, fieldW, ROW_H,
               if form.activeField == tfEntryTag and editable: FG_DIM else: BG3)
  renderText(ren, font, form.entryTagBuf,
             fieldX + 4, curY + (ROW_H - fontH) div 2 - 2,
             if editable: FG else: FG_DIM)
  if form.activeField == tfEntryTag and editable and showCaret:
    let cx = fieldX + 4 + textWidth(font, form.entryTagBuf[0 ..< form.entryTagCursor])
    ren.drawVLine(cx, curY + 3, ROW_H - 6, FG_ACTIVE)
  form.entryTagFldR = (fieldX.cint, curY.cint, fieldW.cint, ROW_H.cint)
  curY += ROW_H + 6

  # ── Room Blocks (sidebar | editor) ───────────────────────────────────────────
  renderText(ren, font, "Room Blocks:", listX, curY, FG_DIM)
  curY += fontH + 4

  let panelTop  = curY
  let sideListW = SIDEBAR_W - PAD     ## block list box width
  let rightX    = listX + SIDEBAR_W   ## left edge of editor panel
  let rightW    = listW - SIDEBAR_W   ## width of editor panel

  var leftY  = panelTop
  var rightY = panelTop

  # ── Left: block list ─────────────────────────────────────────────────────────
  let blkListH = BLOCK_ROWS * ROW_H
  ren.fillRect(listX, leftY, sideListW, blkListH, BG)
  ren.drawRect(listX, leftY, sideListW, blkListH, BG3)

  form.blockRowR.setLen(0)
  for i in form.blockScrollY ..< min(form.blockScrollY + BLOCK_ROWS, form.blocks.len):
    let ry    = leftY + (i - form.blockScrollY) * ROW_H
    let rr: Rect = (listX.cint, ry.cint, sideListW.cint, ROW_H.cint)
    form.blockRowR.add rr
    let isSel = i == form.selBlock
    if isSel: ren.fillRect(listX, ry, sideListW, ROW_H, SEL_BG)
    let b     = form.blocks[i]
    let label = if b.tags.len > 0: b.tags[0] else: "#" & $i
    renderText(ren, font, label, listX + 4, ry + (ROW_H - fontH) div 2 - 2,
               if isSel: FG_ACTIVE else: FG_DIM)

  leftY += blkListH + 4

  if editable:
    let bw = (sideListW - 4) div 2
    form.btnAddBlock = (listX.cint, leftY.cint, bw.cint, BTN_H.cint)
    form.btnDelBlock = ((listX + bw + 4).cint, leftY.cint, bw.cint, BTN_H.cint)
    ren.fillRect(listX, leftY, bw, BTN_H,
                 if form.btnAddBlock.inRect(mx, my): BTN_HOV else: BTN_BG)
    renderText(ren, font, "+",
               listX + (bw - textWidth(font, "+")) div 2,
               leftY + (BTN_H - fontH) div 2 - 2, FG_OK)
    ren.fillRect(listX + bw + 4, leftY, bw, BTN_H,
                 if form.btnDelBlock.inRect(mx, my): BTN_HOV else: BTN_BG)
    renderText(ren, font, "-",
               listX + bw + 4 + (bw - textWidth(font, "-")) div 2,
               leftY + (BTN_H - fontH) div 2 - 2, FG_DEL)
  leftY += BTN_H + 6

  # ── Right: block editor ───────────────────────────────────────────────────────
  let hasBlock = form.selBlock >= 0 and form.selBlock < form.blocks.len
  form.blockTagChipXR.setLen(0)

  if not hasBlock:
    renderText(ren, font, "(select a block)",
               rightX + 4, rightY + (ROW_H - fontH) div 2 - 2, FG_DIM)
    rightY += ROW_H + 6
  else:
    # Tag chips
    let tagLabelW = textWidth(font, "Tags:") + 6
    renderText(ren, font, "Tags:", rightX, rightY + (ROW_H - fontH) div 2 - 2, FG_DIM)
    var chipX = rightX + tagLabelW
    for i, tag in form.blocks[form.selBlock].tags:
      let xBtnW = if editable: ROW_H else: 0
      let tw = textWidth(font, tag) + 8 + xBtnW
      ren.fillRect(chipX, rightY, tw, ROW_H, BG3)
      renderText(ren, font, tag, chipX + 4, rightY + (ROW_H - fontH) div 2 - 2, FG)
      if editable:
        let xr: Rect = ((chipX + tw - ROW_H).cint, rightY.cint, ROW_H.cint, ROW_H.cint)
        form.blockTagChipXR.add xr
        renderText(ren, font, "x",
                   xr.x.int + (ROW_H - textWidth(font, "×")) div 2,
                   rightY + (ROW_H - fontH) div 2 - 2, FG_DEL)
      else:
        form.blockTagChipXR.add (0.cint, 0.cint, 0.cint, 0.cint)
      chipX += tw + 4
      if chipX > listX + listW - 60: break
    if editable:
      if form.blockTagAddMode:
        let addW = max(20, listX + listW - chipX - PAD)
        ren.fillRect(chipX, rightY, addW, ROW_H, BG)
        ren.drawRect(chipX, rightY, addW, ROW_H, BG3)
        renderText(ren, font, form.blockTagBuf,
                   chipX + 4, rightY + (ROW_H - fontH) div 2 - 2, FG)
        if form.activeField == tfBlockTagAdd and showCaret:
          let cx = chipX + 4 + textWidth(font, form.blockTagBuf[0 ..< form.blockTagCursor])
          ren.drawVLine(cx, rightY + 3, ROW_H - 6, FG_ACTIVE)
      else:
        form.btnAddBlockTag = (chipX.cint, rightY.cint, 54.cint, ROW_H.cint)
        let addTagHot = form.btnAddBlockTag.inRect(mx, my)
        ren.fillRect(chipX, rightY, 54, ROW_H, if addTagHot: BTN_HOV else: BTN_BG)
        renderText(ren, font, "+ Tag", chipX + 4, rightY + (ROW_H - fontH) div 2 - 2, FG_OK)
    rightY += ROW_H + 6

    # Entries list
    renderText(ren, font, "Entries:", rightX, rightY, FG_DIM)
    rightY += fontH + 4

    let entryListH = ENTRY_ROWS * ROW_H
    ren.fillRect(rightX, rightY, rightW, entryListH, BG)
    ren.drawRect(rightX, rightY, rightW, entryListH, BG3)

    form.entryRowR.setLen(0)
    let blk = form.blocks[form.selBlock]
    for i in form.entryScrollY ..< min(form.entryScrollY + ENTRY_ROWS, blk.entries.len):
      let ry     = rightY + (i - form.entryScrollY) * ROW_H
      let rr: Rect = (rightX.cint, ry.cint, rightW.cint, ROW_H.cint)
      form.entryRowR.add rr
      let isSel  = i == form.selEntry
      let isEdit = i == form.editEntry and editable
      if isSel: ren.fillRect(rightX, ry, rightW, ROW_H, SEL_BG)
      let lineStr = if isEdit: form.entryBuf else: entryToLine(blk.entries[i])
      let lineFg  = if isEdit: FG_ACTIVE elif isSel: FG else: FG_DIM
      renderText(ren, font, lineStr, rightX + 4, ry + (ROW_H - fontH) div 2 - 2, lineFg)
      if isEdit and showCaret:
        let cx = rightX + 4 + textWidth(font, form.entryBuf[0 ..< form.entryCursor])
        ren.drawVLine(cx, ry + 3, ROW_H - 6, FG_ACTIVE)

    rightY += entryListH + 4

    if editable:
      let bw = 64
      form.btnAddEntry = (rightX.cint, rightY.cint, bw.cint, BTN_H.cint)
      form.btnDelEntry = ((rightX + bw + 4).cint, rightY.cint, bw.cint, BTN_H.cint)
      ren.fillRect(rightX, rightY, bw, BTN_H,
                   if form.btnAddEntry.inRect(mx, my): BTN_HOV else: BTN_BG)
      renderText(ren, font, "+ Entry", rightX + 4, rightY + (BTN_H - fontH) div 2 - 2, FG_OK)
      ren.fillRect(rightX + bw + 4, rightY, bw, BTN_H,
                   if form.btnDelEntry.inRect(mx, my): BTN_HOV else: BTN_BG)
      renderText(ren, font, "- Entry", rightX + bw + 8, rightY + (BTN_H - fontH) div 2 - 2, FG_DEL)
    rightY += BTN_H + 6

  # Separator line between sidebar and editor
  ren.drawVLine(listX + SIDEBAR_W - PAD div 2,
                panelTop, max(leftY, rightY) - panelTop, BG3)

  curY = max(leftY, rightY) + 4

  # ── Connections ───────────────────────────────────────────────────────────────
  renderText(ren, font, "Connections:", listX, curY, FG_DIM)
  curY += fontH + 4

  let linkListH = LINK_ROWS * ROW_H
  ren.fillRect(listX, curY, listW, linkListH, BG)
  ren.drawRect(listX, curY, listW, linkListH, BG3)

  form.linkRowR.setLen(0)
  for i in form.linkScrollY ..< min(form.linkScrollY + LINK_ROWS, form.linkLines.len):
    let ry    = curY + (i - form.linkScrollY) * ROW_H
    let rr: Rect = (listX.cint, ry.cint, listW.cint, ROW_H.cint)
    form.linkRowR.add rr
    let isSel  = i == form.selLink
    let isEdit = i == form.editLink and editable
    if isSel: ren.fillRect(listX, ry, listW, ROW_H, SEL_BG)
    let lineStr = if isEdit: form.linkBuf else: form.linkLines[i]
    let lineFg  = if isEdit: FG_ACTIVE elif isSel: FG else: FG_DIM
    renderText(ren, font, lineStr, listX + 4, ry + (ROW_H - fontH) div 2 - 2, lineFg)
    if isEdit and showCaret:
      let cx = listX + 4 + textWidth(font, form.linkBuf[0 ..< form.linkCursor])
      ren.drawVLine(cx, ry + 3, ROW_H - 6, FG_ACTIVE)

  curY += linkListH + 4

  if editable:
    let bw = 64
    form.btnAddLink = (listX.cint, curY.cint, bw.cint, BTN_H.cint)
    form.btnDelLink = ((listX + bw + 4).cint, curY.cint, bw.cint, BTN_H.cint)
    ren.fillRect(listX, curY, bw, BTN_H,
                 if form.btnAddLink.inRect(mx, my): BTN_HOV else: BTN_BG)
    renderText(ren, font, "+ Row", listX + 4, curY + (BTN_H - fontH) div 2 - 2, FG_OK)
    ren.fillRect(listX + bw + 4, curY, bw, BTN_H,
                 if form.btnDelLink.inRect(mx, my): BTN_HOV else: BTN_BG)
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

  curY += ROW_H + 6

  # ── Encounter chance ──────────────────────────────────────────────────────────
  renderText(ren, font, "Enc. Chance %:",
             fx + PAD, curY + (ROW_H - fontH) div 2 - 2, FG_DIM)
  ren.fillRect(fieldX, curY, fieldW, ROW_H, BG)
  ren.drawRect(fieldX, curY, fieldW, ROW_H,
               if form.activeField == tfEncounterChance and editable: FG_DIM else: BG3)
  renderText(ren, font, form.encChanceBuf,
             fieldX + 4, curY + (ROW_H - fontH) div 2 - 2,
             if editable: FG else: FG_DIM)
  if form.activeField == tfEncounterChance and editable and showCaret:
    let cx = fieldX + 4 + textWidth(font, form.encChanceBuf[0 ..< form.encChanceCursor])
    ren.drawVLine(cx, curY + 3, ROW_H - 6, FG_ACTIVE)
  form.encFldR = (fieldX.cint, curY.cint, fieldW.cint, ROW_H.cint)
  curY += ROW_H + 6

  # ── Encounter tags ────────────────────────────────────────────────────────────
  renderText(ren, font, "Enc. Tags:", fx + PAD, curY, FG_DIM)
  curY += fontH + 4

  form.encTagChipXR.setLen(0)
  var encChipX = listX
  for i, tag in form.encTags:
    let xBtnW = if editable: ROW_H else: 0
    let tw    = textWidth(font, tag) + 8 + xBtnW
    ren.fillRect(encChipX, curY, tw, ROW_H, BG3)
    renderText(ren, font, tag, encChipX + 4, curY + (ROW_H - fontH) div 2 - 2, FG)
    if editable:
      let xr: Rect = ((encChipX + tw - ROW_H).cint, curY.cint, ROW_H.cint, ROW_H.cint)
      form.encTagChipXR.add xr
      renderText(ren, font, "x",
                 xr.x.int + (ROW_H - textWidth(font, "×")) div 2,
                 curY + (ROW_H - fontH) div 2 - 2, FG_DEL)
    else:
      form.encTagChipXR.add (0.cint, 0.cint, 0.cint, 0.cint)
    encChipX += tw + 4
    if encChipX > fx + FORM_W - PAD - 80: break

  if editable:
    if form.encTagAddMode:
      ren.fillRect(encChipX, curY, 120, ROW_H, BG)
      ren.drawRect(encChipX, curY, 120, ROW_H, BG3)
      renderText(ren, font, form.encTagBuf,
                 encChipX + 4, curY + (ROW_H - fontH) div 2 - 2, FG)
      if form.activeField == tfEncTagAdd and showCaret:
        let cx = encChipX + 4 + textWidth(font, form.encTagBuf[0 ..< form.encTagCursor])
        ren.drawVLine(cx, curY + 3, ROW_H - 6, FG_ACTIVE)
    else:
      form.btnAddEncTag = (encChipX.cint, curY.cint, 60.cint, ROW_H.cint)
      let addEncTagHot  = form.btnAddEncTag.inRect(mx, my)
      ren.fillRect(encChipX, curY, 60, ROW_H, if addEncTagHot: BTN_HOV else: BTN_BG)
      renderText(ren, font, "+ Add", encChipX + 4, curY + (ROW_H - fontH) div 2 - 2, FG_OK)

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
    let dx      = form.imgFldR.x.int
    let dy      = form.imgFldR.y.int + ROW_H
    let dw      = form.imgFldR.w.int
    let total   = form.imgFiltered.len
    let visible = min(DROP_ROWS, total)
    let dh      = visible * ROW_H
    form.imgDropR = (dx.cint, dy.cint, dw.cint, dh.cint)
    ren.fillRect(dx, dy, dw, dh, DROP_BG)
    ren.drawRect(dx, dy, dw, dh, BG3)
    let hasScroll = total > visible
    let sbW       = if hasScroll: 7 else: 0
    let rowW      = dw - sbW
    for i in 0 ..< visible:
      let idx = form.imgDropScrollY + i
      if idx >= total: break
      let ry  = dy + i * ROW_H
      let hot = mx >= dx and mx < dx + rowW and my >= ry and my < ry + ROW_H
      if hot: ren.fillRect(dx, ry, rowW, ROW_H, DROP_HOV)
      renderText(ren, font, form.imgFiltered[idx],
                 dx + 4, ry + (ROW_H - fontH) div 2 - 2,
                 if hot: FG_ACTIVE else: FG)
    if hasScroll:
      let sbX    = dx + dw - sbW
      ren.fillRect(sbX, dy, sbW, dh, BG3)
      let thumbH = max(ROW_H, dh * visible div total)
      let thumbY = dy + (dh - thumbH) * form.imgDropScrollY div max(1, total - visible)
      ren.fillRect(sbX + 1, thumbY, sbW - 2, thumbH, FG_DIM)

# ── Input ─────────────────────────────────────────────────────────────────────

proc handleMouseDown*(form: var TileForm; x, y, btn: int) =
  if not form.open: return
  let editable = not form.isForeign

  # Image dropdown intercepts when open
  if form.imgDropOpen and editable:
    if form.imgDropR.inRect(x, y):
      let total   = form.imgFiltered.len
      let visible = min(DROP_ROWS, total)
      let sbW     = if total > visible: 7 else: 0
      if x < form.imgDropR.x.int + form.imgDropR.w.int - sbW:
        let row = (y - form.imgDropR.y.int) div ROW_H + form.imgDropScrollY
        if row >= 0 and row < total:
          form.imgFilterBuf    = form.imgFiltered[row]
          form.imgFilterCursor = form.imgFilterBuf.len
          form.buildImgFiltered()
    form.imgDropOpen = false
    return

  # Type dropdown intercepts when open
  if form.typeDropOpen and editable:
    for i in 0 ..< 4:
      if form.typeOptR[i].inRect(x, y):
        form.selType      = i
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

  # Entry tag field
  if form.entryTagFldR.inRect(x, y) and editable:
    form.activeField = tfEntryTag
    return

  # Block list rows
  for i, rr in form.blockRowR:
    if rr.inRect(x, y):
      let realIdx = form.blockScrollY + i
      form.commitEditEntry()
      form.selBlock        = realIdx
      form.selEntry        = -1
      form.entryScrollY    = 0
      form.blockTagAddMode = false
      form.activeField     = tfNone
      return

  # Add/Del block buttons
  if editable:
    if form.btnAddBlock.inRect(x, y):
      form.commitEditEntry()
      form.blocks.add RoomBlock()
      let ni = form.blocks.high
      form.selBlock        = ni
      form.selEntry        = -1
      form.entryScrollY    = 0
      form.blockTagAddMode = false
      form.activeField     = tfNone
      if ni >= form.blockScrollY + BLOCK_ROWS:
        form.blockScrollY = ni - BLOCK_ROWS + 1
      return
    if form.btnDelBlock.inRect(x, y) and form.selBlock >= 0 and
       form.selBlock < form.blocks.len:
      form.blocks.delete(form.selBlock)
      form.editEntry    = -1
      form.selEntry     = -1
      form.selBlock     = min(form.selBlock, form.blocks.high)
      form.entryScrollY = 0
      return

  # Block tag chip × buttons
  if editable and form.selBlock >= 0 and form.selBlock < form.blocks.len:
    for i, xr in form.blockTagChipXR:
      if xr.w > 0 and xr.inRect(x, y) and i < form.blocks[form.selBlock].tags.len:
        form.blocks[form.selBlock].tags.delete(i)
        form.blockTagChipXR.setLen(0)
        return
    if not form.blockTagAddMode and form.btnAddBlockTag.inRect(x, y):
      form.blockTagAddMode = true
      form.blockTagBuf     = ""
      form.blockTagCursor  = 0
      form.activeField     = tfBlockTagAdd
      return

  # Entry rows within selected block
  if form.selBlock >= 0 and form.selBlock < form.blocks.len:
    for i, rr in form.entryRowR:
      if rr.inRect(x, y):
        let realIdx = form.entryScrollY + i
        if form.selEntry == realIdx and editable and form.editEntry != realIdx:
          # Second click → enter edit
          form.commitEditEntry()
          form.editEntry   = realIdx
          form.entryBuf    = entryToLine(form.blocks[form.selBlock].entries[realIdx])
          form.entryCursor = form.entryBuf.len
          form.activeField = tfEntry
        elif form.editEntry >= 0:
          form.commitEditEntry()
          form.selEntry    = realIdx
          form.activeField = tfNone
        else:
          form.selEntry    = realIdx
          form.activeField = tfNone
        return

  # Add/Del entry buttons
  if editable and form.selBlock >= 0 and form.selBlock < form.blocks.len:
    if form.btnAddEntry.inRect(x, y):
      form.commitEditEntry()
      form.blocks[form.selBlock].entries.add RoomCondEntry()
      let ni = form.blocks[form.selBlock].entries.high
      form.selEntry    = ni
      form.editEntry   = ni
      form.entryBuf    = ""
      form.entryCursor = 0
      form.activeField = tfEntry
      if ni >= form.entryScrollY + ENTRY_ROWS:
        form.entryScrollY = ni - ENTRY_ROWS + 1
      return
    if form.btnDelEntry.inRect(x, y) and form.selEntry >= 0 and
       form.selEntry < form.blocks[form.selBlock].entries.len:
      form.blocks[form.selBlock].entries.delete(form.selEntry)
      form.editEntry = -1
      form.selEntry  = min(form.selEntry, form.blocks[form.selBlock].entries.high)
      return

  # Link rows
  for i, rr in form.linkRowR:
    if rr.inRect(x, y):
      let realIdx = form.linkScrollY + i
      if form.selLink == realIdx and editable and form.editLink != realIdx:
        form.commitEditLink()
        form.editLink   = realIdx
        form.linkBuf    = form.linkLines[realIdx]
        form.linkCursor = form.linkBuf.len
        form.activeField = tfLink
      elif form.editLink >= 0:
        form.commitEditLink()
        form.selLink     = realIdx
        form.activeField = tfNone
      else:
        form.selLink     = realIdx
        form.activeField = tfNone
      return

  # Add/Del link buttons
  if editable:
    if form.btnAddLink.inRect(x, y):
      form.commitEditLink()
      form.linkLines.add ""
      let ni = form.linkLines.high
      form.selLink    = ni
      form.editLink   = ni
      form.linkBuf    = ""
      form.linkCursor = 0
      form.activeField = tfLink
      if ni >= form.linkScrollY + LINK_ROWS:
        form.linkScrollY = ni - LINK_ROWS + 1
      return
    if form.btnDelLink.inRect(x, y) and form.selLink >= 0 and
       form.selLink < form.linkLines.len:
      form.linkLines.delete(form.selLink)
      form.editLink = -1
      form.selLink  = min(form.selLink, form.linkLines.high)
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

  # Encounter chance field
  if form.encFldR.inRect(x, y) and editable:
    form.activeField = tfEncounterChance
    return

  # Enc tag chip × buttons
  if editable:
    for i, xr in form.encTagChipXR:
      if xr.w > 0 and xr.inRect(x, y) and i < form.encTags.len:
        form.encTags.delete(i)
        form.encTagChipXR.setLen(0)
        return
    if not form.encTagAddMode and form.btnAddEncTag.inRect(x, y):
      form.encTagAddMode  = true
      form.encTagBuf      = ""
      form.encTagCursor   = 0
      form.activeField    = tfEncTagAdd
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
      form.commitEditEntry()
      form.commitEditLink()
      form.resultEntry = packResult(form)
      form.warnMsgs    = validateLinks(form)
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
  of tfEntryTag:
    form.entryTagBuf.insert(text, form.entryTagCursor)
    form.entryTagCursor += text.len
  of tfBlockTagAdd:
    form.blockTagBuf.insert(text, form.blockTagCursor)
    form.blockTagCursor += text.len
  of tfEntry:
    form.entryBuf.insert(text, form.entryCursor)
    form.entryCursor += text.len
  of tfLink:
    form.linkBuf.insert(text, form.linkCursor)
    form.linkCursor += text.len
  of tfNpcAdd:
    form.npcBuf.insert(text, form.npcCursor)
    form.npcCursor += text.len
  of tfEncounterChance:
    for ch in text:
      if ch in {'0'..'9'}:
        form.encChanceBuf.insert($ch, form.encChanceCursor)
        inc form.encChanceCursor
    if form.encChanceBuf.len > 3:
      form.encChanceBuf    = form.encChanceBuf[0 ..< 3]
      form.encChanceCursor = min(form.encChanceCursor, 3)
  of tfEncTagAdd:
    form.encTagBuf.insert(text, form.encTagCursor)
    form.encTagCursor += text.len
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
      return
    if form.editEntry >= 0:
      form.editEntry   = -1
      form.activeField = tfNone
      return
    if form.blockTagAddMode:
      form.blockTagAddMode = false
      form.activeField     = tfNone
      return
    if form.editLink >= 0:
      form.editLink    = -1
      form.activeField = tfNone
      return
    if form.npcAddMode:
      form.npcAddMode  = false
      form.activeField = tfNone
      return
    if form.encTagAddMode:
      form.encTagAddMode = false
      form.activeField   = tfNone
      return
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
      form.activeField = tfEntryTag
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
  of tfEntryTag:
    case sym
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      form.activeField = tfNone
    else:
      navField(form.entryTagBuf, form.entryTagCursor)
  of tfBlockTagAdd:
    case sym
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      let tag = form.blockTagBuf.strip()
      if tag.len > 0 and form.selBlock >= 0 and form.selBlock < form.blocks.len:
        form.blocks[form.selBlock].tags.add tag
      form.blockTagAddMode = false
      form.blockTagBuf     = ""
      form.activeField     = tfNone
    else:
      navField(form.blockTagBuf, form.blockTagCursor)
  of tfEntry:
    case sym
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      form.commitEditEntry()
      form.activeField = tfNone
    else:
      navField(form.entryBuf, form.entryCursor)
  of tfLink:
    case sym
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      form.commitEditLink()
      form.activeField = tfNone
    else:
      navField(form.linkBuf, form.linkCursor)
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
  of tfEncounterChance:
    case sym
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      form.activeField = tfNone
    else:
      navField(form.encChanceBuf, form.encChanceCursor)
  of tfEncTagAdd:
    case sym
    of SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
      let tag = form.encTagBuf.strip()
      if tag.len > 0: form.encTags.add tag
      form.encTagAddMode = false
      form.encTagBuf     = ""
      form.activeField   = tfNone
    else:
      navField(form.encTagBuf, form.encTagCursor)
  of tfNone: discard

proc handleWheel*(form: var TileForm; dy, mx, my: int) =
  if not form.open: return
  if form.imgDropOpen and form.imgDropR.inRect(mx, my):
    let total   = form.imgFiltered.len
    let visible = min(DROP_ROWS, total)
    form.imgDropScrollY = clamp(form.imgDropScrollY - dy, 0, max(0, total - visible))
