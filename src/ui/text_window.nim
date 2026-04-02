import sdl2
import sdl2/ttf
import sdl2/image
import strutils, unicode, math
import ipc

# ─── Palette ────────────────────────────────────────────────────────────────
const
  COL_BG       = (r:  17u8, g:  17u8, b:  17u8, a: 255u8)
  COL_BG_INPUT = (r:  26u8, g:  26u8, b:  26u8, a: 255u8)
  COL_FG       = (r: 212u8, g: 201u8, b: 168u8, a: 255u8)
  COL_FG_DIM   = (r: 122u8, g: 112u8, b:  96u8, a: 255u8)
  COL_FG_LINK  = (r: 143u8, g: 188u8, b: 187u8, a: 255u8)
  COL_SASH     = (r:  45u8, g:  45u8, b:  45u8, a: 255u8)
  COL_SASH_HOT = (r:  80u8, g:  80u8, b:  80u8, a: 255u8)
  COL_SEL      = (r:  60u8, g:  80u8, b:  90u8, a: 255u8)
  COL_CURSOR   = (r: 212u8, g: 201u8, b: 168u8, a: 200u8)

  SASH_W       = 5
  INPUT_H      = 32
  TEXT_PAD     = 8
  FONT_SIZE    = 16
  HUD_MARGIN   = 10
  HUD_PAD      = 6
  HUD_LINE_H   = 18
  HUD_BOX_W    = 220
  TARGET_FPS   = 60
  FRAME_MS     = 1000 div TARGET_FPS
  CURSOR_BLINK   = 530  # ms
  SCROLL_PAD_B   = 20  # px gap between last text line and input bar

# ─── Types ───────────────────────────────────────────────────────────────────
type
  Span = object
    text:   string
    isLink: bool
    cmd:    string  # command fired on click (empty if not a link)

  Line = seq[Span]

  TextBuffer = object
    lines:   seq[Line]
    scrollY: int  # pixel scroll offset from top
    totalH:  int  # total pixel height of all lines

  SelectionAnchor = object
    lineIdx: int
    spanIdx: int
    charIdx: int
    px, py:  int

  App = object
    win:  WindowPtr
    ren:  RendererPtr
    font: FontPtr
    fontH, lineH: int

    # layout
    winW, winH:   int
    sashX:        int
    draggingSash: bool
    sashDragOff:  int

    # left panel
    bgTex:     TexturePtr
    bgRect:    Rect  # centered render rect within left panel
    bgW, bgH:  int   # original image dimensions

    # right panel — scrollback
    buf: TextBuffer

    # text selection
    selecting:    bool
    selStart:     SelectionAnchor
    selEnd:       SelectionAnchor
    hasSelection: bool

    # input bar
    inputText:   string
    inputCursor: int     # byte index into inputText
    inputScroll: int     # pixel scroll offset for long input
    cursorBlink: uint32
    showCursor:  bool

    # command history
    history:    seq[string]
    histIdx:    int      # index into history while browsing; history.len = not browsing
    histDraft:  string   # saved current input when browsing starts

    # journal overlay
    journalOpen:      bool
    journalPages:     seq[string]      ## all pages (one string per page, \n-joined)
    journalIdx:       int              ## current page index
    journalLines:     seq[string]      ## current page split into edit lines
    journalCurL:      int              ## body cursor: line index
    journalCurC:      int              ## body cursor: byte offset
    journalSearch:    string           ## search box text
    journalSrchCur:   int              ## search box cursor byte offset
    journalSrchFocus: bool             ## true = search box has keyboard focus
    # button/region rects set by renderJournal, read by event handler
    jBtnPrev:  tuple[x,y,w,h: int]
    jBtnNext:  tuple[x,y,w,h: int]
    jBtnClose: tuple[x,y,w,h: int]
    jSrchBox:  tuple[x,y,w,h: int]
    jBodyY:    int

    # hover link
    hoverLink: string

    # HUD stats (label, value) pairs — updated via umStats messages
    hudStats: seq[(string, string)]

    # Panel state — tracks where the most recent panel block sits in buf.lines
    # so that umPanelAppend can replace it in-place rather than appending.
    # panelStart = -1 means no panel is currently tracked.
    panelStart: int   ## buf.lines index where panel begins
    panelLen:   int   ## number of lines the panel occupies

    # system cursors (created once, reused every frame)
    curArrow:  CursorPtr
    curHand:   CursorPtr
    curSizeWE: CursorPtr
    curIBeam:  CursorPtr

# ─── SDL helpers ─────────────────────────────────────────────────────────────
template sdlCheck(call: untyped) =
  if not call:
    echo "SDL error: ", getError()
    quit(1)

proc setColor(ren: RendererPtr; c: tuple[r,g,b,a: uint8]) =
  discard ren.setDrawColor(c.r, c.g, c.b, c.a)

proc fillRect(ren: RendererPtr; x, y, w, h: int) =
  var r = rect(x.cint, y.cint, w.cint, h.cint)
  discard ren.fillRect(r)

proc renderText(ren: RendererPtr; font: FontPtr; text: string;
                x, y: int; col: tuple[r,g,b,a: uint8]): int =
  ## Render UTF-8 text. Returns pixel width of rendered text, 0 for empty.
  if text.len == 0: return 0
  let surf = font.renderUtf8Blended(text.cstring, color(col.r, col.g, col.b, col.a))
  if surf.isNil: return 0
  let tex = ren.createTextureFromSurface(surf)
  freeSurface(surf)
  if tex.isNil: return 0
  var tw, th: cint
  discard queryTexture(tex, nil, nil, tw.addr, th.addr)
  var dst = rect(x.cint, y.cint, tw, th)
  discard ren.copy(tex, nil, dst.addr)
  destroyTexture(tex)
  return tw.int

proc textWidth(font: FontPtr; text: string): int =
  if text.len == 0: return 0
  var w, h: cint
  discard sizeUtf8(font, text.cstring, w.addr, h.addr)
  return w.int

# ─── Link parsing ────────────────────────────────────────────────────────────
proc parseLine(raw: string): Line =
  ## Parse a raw string into spans, recognising [[label:cmd]] / [[cmd]] links.
  var pos = 0
  while pos < raw.len:
    let linkStart = raw.find("[[", pos)
    if linkStart < 0:
      result.add Span(text: raw[pos..^1])
      break
    if linkStart > pos:
      result.add Span(text: raw[pos ..< linkStart])
    let linkEnd = raw.find("]]", linkStart + 2)
    if linkEnd < 0:
      result.add Span(text: raw[linkStart..^1])
      break
    let inner = raw[linkStart + 2 ..< linkEnd]
    let colon = inner.find(':')
    if colon >= 0:
      result.add Span(text: inner[0 ..< colon], isLink: true,
                      cmd: inner[colon + 1 .. ^1])
    else:
      result.add Span(text: inner, isLink: true, cmd: inner)
    pos = linkEnd + 2

# ─── TextBuffer ──────────────────────────────────────────────────────────────
proc addLine(buf: var TextBuffer; raw: string) =
  buf.lines.add parseLine(raw)

proc recomputeHeight(buf: var TextBuffer; lineH: int) =
  buf.totalH = buf.lines.len * lineH

proc scrollToBottom(buf: var TextBuffer; viewH: int) =
  buf.scrollY = max(0, buf.totalH - viewH)

# ─── Selection helpers ───────────────────────────────────────────────────────
proc anchorFromMouse(app: App; mx, my: int): SelectionAnchor =
  let ry = my + app.buf.scrollY
  let lineIdx = clamp(ry div app.lineH, 0, app.buf.lines.high)
  let line = app.buf.lines[lineIdx]
  var cx = TEXT_PAD
  var spanIdx, charIdx = 0
  block outer:
    for si, span in line:
      let sw = textWidth(app.font, span.text)
      if mx < cx + sw or si == line.high:
        spanIdx = si
        for ci in 0 .. span.text.high:
          if cx + textWidth(app.font, span.text[0 ..< ci]) >= mx:
            charIdx = ci
            break outer
          charIdx = ci + 1
        break outer
      cx += sw
      spanIdx = si
  result = SelectionAnchor(lineIdx: lineIdx, spanIdx: spanIdx,
                            charIdx: charIdx, px: mx, py: my)

proc selectionText(app: App): string =
  if not app.hasSelection: return ""
  var a = app.selStart
  var b = app.selEnd
  if a.lineIdx > b.lineIdx or
     (a.lineIdx == b.lineIdx and a.spanIdx > b.spanIdx) or
     (a.lineIdx == b.lineIdx and a.spanIdx == b.spanIdx and a.charIdx > b.charIdx):
    swap(a, b)
  for li in a.lineIdx .. b.lineIdx:
    if li >= app.buf.lines.len: break
    let line = app.buf.lines[li]
    for si, span in line:
      if li == a.lineIdx and si < a.spanIdx: continue
      if li == b.lineIdx and si > b.spanIdx: continue
      var s = span.text
      if li == b.lineIdx and si == b.spanIdx:
        s = s[0 ..< min(b.charIdx, s.len)]
      if li == a.lineIdx and si == a.spanIdx:
        s = s[min(a.charIdx, s.len) .. ^1]
      result.add s
    if li < b.lineIdx: result.add "\n"

# ─── Journal helpers ─────────────────────────────────────────────────────────
const JOURNAL_MAX_LINES = 24

func inRect(x, y: int; r: tuple[x,y,w,h: int]): bool =
  x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h

proc journalSaveCurrentPage(app: var App) =
  if app.journalIdx >= 0 and app.journalIdx < app.journalPages.len:
    app.journalPages[app.journalIdx] = app.journalLines.join("\n")

proc journalGotoPage(app: var App; idx: int) =
  app.journalSaveCurrentPage()
  app.journalIdx   = clamp(idx, 0, app.journalPages.high)
  app.journalLines = app.journalPages[app.journalIdx].splitLines()
  if app.journalLines.len == 0: app.journalLines = @[""]
  app.journalCurL  = app.journalLines.high
  app.journalCurC  = app.journalLines[app.journalCurL].len
  app.journalSearch   = ""
  app.journalSrchCur  = 0

proc openJournalOverlay(app: var App; pages: seq[string]; idx: int) =
  app.journalPages    = if pages.len > 0: pages else: @[""]
  app.journalOpen     = true
  app.journalSrchFocus = false
  app.journalSearch   = ""
  app.journalSrchCur  = 0
  app.journalGotoPage(clamp(idx, 0, app.journalPages.high))

proc closeJournalOverlay(app: var App) =
  app.journalSaveCurrentPage()
  toGame.send(GameMsg(kind: gmJournalSave, savedPages: app.journalPages))
  app.journalOpen = false

proc journalResultLines(app: App): seq[Line] =
  ## Build search result lines as parsed Line objects so links work.
  let q = app.journalSearch.toLowerAscii
  result.add parseLine("Results for '" & app.journalSearch & "':")
  result.add parseLine("")
  var found = false
  for i, page in app.journalPages:
    if q in page.toLowerAscii:
      let fl = page.splitLines()
      let label = if fl.len > 0 and fl[0].strip.len > 0: fl[0].strip
                  else: "(empty page)"
      result.add parseLine("  [[Page " & $(i+1) & ": " & label &
                            ":journal_goto " & $i & "]]")
      found = true
  if not found:
    result.add parseLine("  No results.")

proc renderJournalBtn(app: var App; r: tuple[x,y,w,h: int];
                      label: string; hot: bool) =
  app.ren.setColor(if hot: COL_SASH_HOT else: COL_SASH)
  app.ren.fillRect(r.x, r.y, r.w, r.h)
  let tx = r.x + (r.w - textWidth(app.font, label)) div 2
  let ty = r.y + (r.h - app.fontH) div 2
  discard app.ren.renderText(app.font, label, tx, ty, COL_FG)

proc renderJournal(app: var App) =
  let panelW = app.sashX
  let toolH  = app.lineH + TEXT_PAD * 2
  let btnH   = app.lineH
  let btnY   = TEXT_PAD

  var mx, my: cint
  discard getMouseState(mx.addr, my.addr)

  # ── Background ─────────────────────────────────────────────────────────────
  app.ren.setColor(COL_BG)
  app.ren.fillRect(0, 0, panelW, app.winH)
  app.ren.setColor(COL_BG_INPUT)
  app.ren.fillRect(0, 0, panelW, toolH)
  app.ren.setColor(COL_SASH)
  app.ren.fillRect(0, toolH, panelW, 1)

  # ── [<] prev button ────────────────────────────────────────────────────────
  let btnW  = textWidth(app.font, "<") + 8
  let prevR = (x: TEXT_PAD, y: btnY, w: btnW, h: btnH)
  app.jBtnPrev = prevR
  app.renderJournalBtn(prevR, "<", inRect(mx.int, my.int, prevR))

  # ── Page N / M ─────────────────────────────────────────────────────────────
  let pageText = "Page " & $(app.journalIdx + 1) & " / " & $app.journalPages.len
  let ptX = prevR.x + prevR.w + 6
  let ptY = btnY + (btnH - app.fontH) div 2
  discard app.ren.renderText(app.font, pageText, ptX, ptY, COL_FG)

  # ── [>] next button ────────────────────────────────────────────────────────
  let ptW   = textWidth(app.font, pageText)
  let nextR = (x: ptX + ptW + 6, y: btnY, w: btnW, h: btnH)
  app.jBtnNext = nextR
  app.renderJournalBtn(nextR, ">", inRect(mx.int, my.int, nextR))

  # ── [X] close button ───────────────────────────────────────────────────────
  let closeBtnW = textWidth(app.font, "X") + 8
  let closeR    = (x: panelW - TEXT_PAD - closeBtnW, y: btnY,
                   w: closeBtnW, h: btnH)
  app.jBtnClose = closeR
  app.renderJournalBtn(closeR, "X", inRect(mx.int, my.int, closeR))

  # ── Search box ─────────────────────────────────────────────────────────────
  let srchLabelW = textWidth(app.font, "search:")
  let srchBoxW   = 140
  let srchBoxX   = closeR.x - TEXT_PAD - srchBoxW
  let srchLabelX = srchBoxX - 4 - srchLabelW
  let srchR      = (x: srchBoxX, y: btnY, w: srchBoxW, h: btnH)
  app.jSrchBox = srchR
  discard app.ren.renderText(app.font, "search:", srchLabelX, ptY, COL_FG_DIM)
  app.ren.setColor(COL_BG)
  app.ren.fillRect(srchR.x, srchR.y, srchR.w, srchR.h)
  app.ren.setColor(if app.journalSrchFocus: COL_FG_LINK else: COL_SASH)
  var srchBorder = rect(srchR.x.cint, srchR.y.cint, srchR.w.cint, srchR.h.cint)
  discard app.ren.drawRect(srchBorder.addr)
  let srchInnerX = srchR.x + 3
  let srchInnerW = srchR.w - 6
  var srchClip = rect(srchInnerX.cint, srchR.y.cint,
                      srchInnerW.cint, srchR.h.cint)
  discard app.ren.setClipRect(srchClip.addr)
  discard app.ren.renderText(app.font, app.journalSearch, srchInnerX, ptY, COL_FG)
  if app.journalSrchFocus and app.showCursor:
    let curX = srchInnerX +
               textWidth(app.font, app.journalSearch[0 ..< app.journalSrchCur])
    app.ren.setColor(COL_CURSOR)
    app.ren.fillRect(curX, ptY, 2, app.fontH)
  discard app.ren.setClipRect(nil)

  # ── Body ───────────────────────────────────────────────────────────────────
  let bodyY = toolH + 1
  app.jBodyY = bodyY
  var bodyClip = rect(TEXT_PAD.cint, bodyY.cint,
                      (panelW - TEXT_PAD).cint, (app.winH - bodyY).cint)
  discard app.ren.setClipRect(bodyClip.addr)

  if app.journalSearch.len > 0:
    # Search results — render using same Line/Span loop as scrollback
    let rlines = journalResultLines(app)
    for li, line in rlines:
      let lineY = bodyY + TEXT_PAD + li * app.lineH
      var cx = TEXT_PAD
      for span in line:
        let col = if span.isLink: COL_FG_LINK else: COL_FG
        cx += app.ren.renderText(app.font, span.text, cx, lineY, col)
  else:
    # Edit mode — plain lines with blinking cursor
    for li, line in app.journalLines:
      let lineY = bodyY + TEXT_PAD + li * app.lineH
      if li == app.journalCurL and not app.journalSrchFocus and app.showCursor:
        let curX = TEXT_PAD +
                   textWidth(app.font, line[0 ..< app.journalCurC])
        app.ren.setColor(COL_CURSOR)
        app.ren.fillRect(curX, lineY, 2, app.fontH)
      discard app.ren.renderText(app.font, line, TEXT_PAD, lineY, COL_FG)

  discard app.ren.setClipRect(nil)

# ─── Rendering ───────────────────────────────────────────────────────────────
proc renderScrollbar(app: var App) =
  let viewH = app.winH - INPUT_H
  if app.buf.totalH <= viewH: return
  let sbW    = 6
  let sbX    = app.sashX - sbW - 2
  let trackH = viewH - 4
  let thumbH = max(20, trackH * viewH div app.buf.totalH)
  let thumbY = 2 + (trackH - thumbH) * app.buf.scrollY div
               max(1, app.buf.totalH - viewH)
  app.ren.setColor(COL_BG_INPUT)
  app.ren.fillRect(sbX, 2, sbW, trackH)
  app.ren.setColor(COL_SASH)
  app.ren.fillRect(sbX, thumbY, sbW, thumbH)

proc renderLeftPanel(app: var App) =
  ## Left panel: text scrollback + input bar.
  let panelW    = app.sashX
  let viewH     = app.winH - INPUT_H
  let textViewH = viewH - SCROLL_PAD_B

  app.ren.setColor(COL_BG)
  app.ren.fillRect(0, 0, panelW, viewH)

  var clip = rect(0, 0, panelW.cint, textViewH.cint)
  discard app.ren.setClipRect(clip.addr)

  let startLine = max(0, app.buf.scrollY div app.lineH)
  let endLine   = min(app.buf.lines.high,
                      (app.buf.scrollY + textViewH) div app.lineH + 1)

  for li in startLine .. endLine:
    if li >= app.buf.lines.len: break
    let lineY = li * app.lineH - app.buf.scrollY
    var cx = TEXT_PAD

    for si, span in app.buf.lines[li]:
      let sw = textWidth(app.font, span.text)

      if app.hasSelection:
        var sa = app.selStart
        var sb = app.selEnd
        if sa.lineIdx > sb.lineIdx or
           (sa.lineIdx == sb.lineIdx and sa.spanIdx > sb.spanIdx) or
           (sa.lineIdx == sb.lineIdx and sa.spanIdx == sb.spanIdx and
            sa.charIdx > sb.charIdx):
          swap(sa, sb)
        let inSel =
          (li > sa.lineIdx or (li == sa.lineIdx and si >= sa.spanIdx)) and
          (li < sb.lineIdx or (li == sb.lineIdx and si <= sb.spanIdx))
        if inSel:
          let isSaSpan = li == sa.lineIdx and si == sa.spanIdx
          let isSbSpan = li == sb.lineIdx and si == sb.spanIdx
          let hx = if isSaSpan:
            cx + textWidth(app.font, span.text[0 ..< min(sa.charIdx, span.text.len)])
          else: cx
          let hend = if isSbSpan:
            cx + textWidth(app.font, span.text[0 ..< min(sb.charIdx, span.text.len)])
          else: cx + sw
          if hend > hx:
            app.ren.setColor(COL_SEL)
            app.ren.fillRect(hx, lineY, hend - hx, app.lineH)

      discard app.ren.renderText(app.font, span.text, cx, lineY,
                                  if span.isLink: COL_FG_LINK else: COL_FG)

      if span.isLink:
        app.ren.setColor(COL_FG_LINK)
        app.ren.fillRect(cx, lineY + app.fontH - 4, sw, 1)
        if span.cmd == app.hoverLink:
          app.ren.setColor((r: 143u8, g: 188u8, b: 187u8, a: 40u8))
          discard app.ren.setDrawBlendMode(BlendMode_Blend)
          app.ren.fillRect(cx, lineY + 4, sw, app.fontH - 4)
          discard app.ren.setDrawBlendMode(BlendMode_None)

      cx += sw

  discard app.ren.setClipRect(nil)
  app.renderScrollbar()

  # input bar
  let iy = viewH
  app.ren.setColor(COL_BG_INPUT)
  app.ren.fillRect(0, iy, panelW, INPUT_H)
  app.ren.setColor(COL_SASH)
  app.ren.fillRect(0, iy, panelW, 1)

  let promptW = app.ren.renderText(app.font, ">", TEXT_PAD, iy + 7, COL_FG_DIM)
  let inputX  = TEXT_PAD + promptW + 6
  let inputW  = panelW - TEXT_PAD * 2 - promptW - 6 - 36

  var iclip = rect(inputX.cint, (iy + 1).cint, inputW.cint, (INPUT_H - 2).cint)
  discard app.ren.setClipRect(iclip.addr)
  discard app.ren.renderText(app.font, app.inputText,
                              inputX - app.inputScroll, iy + 7, COL_FG)
  discard app.ren.setClipRect(nil)

  if app.showCursor:
    let curX = inputX + textWidth(app.font, app.inputText[0 ..< app.inputCursor]) -
               app.inputScroll
    if curX >= inputX and curX < inputX + inputW:
      app.ren.setColor(COL_CURSOR)
      app.ren.fillRect(curX, iy + 5, 2, app.fontH)

  discard app.ren.renderText(app.font, "<help>", panelW - 70, iy + 7, COL_FG_DIM)

proc renderRightPanel(app: var App) =
  ## Right panel: background image + HUD stats.
  let panelX = app.sashX + SASH_W
  let panelW = app.winW - panelX

  app.ren.setColor(COL_BG)
  app.ren.fillRect(panelX, 0, panelW, app.winH)

  if app.bgTex != nil:
    var clip = rect(panelX.cint, 0.cint, panelW.cint, app.winH.cint)
    discard app.ren.setClipRect(clip.addr)
    var dst = app.bgRect
    discard app.ren.copy(app.bgTex, nil, dst.addr)
    discard app.ren.setClipRect(nil)

  if app.hudStats.len > 0:
    let hx   = panelX + HUD_MARGIN
    let boxH = HUD_PAD * 2 + app.hudStats.len * HUD_LINE_H
    app.ren.setColor((r: 17u8, g: 17u8, b: 17u8, a: 220u8))
    discard app.ren.setDrawBlendMode(BlendMode_Blend)
    app.ren.fillRect(hx, HUD_MARGIN, HUD_BOX_W, boxH)
    discard app.ren.setDrawBlendMode(BlendMode_None)
    app.ren.setColor(COL_SASH)
    var box = rect(hx.cint, HUD_MARGIN.cint, HUD_BOX_W.cint, boxH.cint)
    discard app.ren.drawRect(box.addr)
    for i, (label, val) in app.hudStats:
      let ty = HUD_MARGIN + HUD_PAD + i * HUD_LINE_H
      let lw = app.ren.renderText(app.font, label & ": ",
                                  hx + HUD_PAD, ty, COL_FG_DIM)
      discard app.ren.renderText(app.font, val,
                                  hx + HUD_PAD + lw, ty, COL_FG)

proc renderSash(app: var App; hot: bool) =
  app.ren.setColor(if hot: COL_SASH_HOT else: COL_SASH)
  app.ren.fillRect(app.sashX, 0, SASH_W, app.winH)

proc render(app: var App) =
  app.ren.setColor(COL_BG)
  discard app.ren.clear()
  if app.journalOpen:
    app.renderJournal()
  else:
    app.renderLeftPanel()
  app.renderRightPanel()
  var mx, my: cint
  discard getMouseState(mx.addr, my.addr)
  app.renderSash(app.draggingSash or
                  (mx.int >= app.sashX and mx.int < app.sashX + SASH_W))
  app.ren.present()

# ─── Image loading ───────────────────────────────────────────────────────────
proc loadBgImage(app: var App; path: string) =
  if app.bgTex != nil:
    destroyTexture(app.bgTex)
    app.bgTex = nil
  let surf = image.load(path.cstring)
  if surf.isNil:
    echo "Image load failed: ", path, " — ", getError()
    return
  app.bgW = surf.w.int
  app.bgH = surf.h.int
  app.bgTex = app.ren.createTextureFromSurface(surf)
  freeSurface(surf)

proc recomputeBgRect(app: var App) =
  ## Scale image to window height (aspect preserved), centre within right panel.
  ## Overflow left/right is cropped by the clip rect in renderRightPanel.
  if app.bgTex == nil: return
  let panelX = app.sashX + SASH_W
  let panelW = app.winW - panelX
  let dh     = app.winH
  let dw     = (app.bgW.float * app.winH.float / app.bgH.float).int
  app.bgRect = rect((panelX + (panelW - dw) div 2).cint, 0.cint,
                    dw.cint, dh.cint)

# ─── Input handling ──────────────────────────────────────────────────────────
proc clampInputScroll(app: var App; inputX, inputW: int) =
  let tw       = textWidth(app.font, app.inputText)
  let cursorPx = textWidth(app.font, app.inputText[0 ..< app.inputCursor])
  if cursorPx - app.inputScroll > inputW:
    app.inputScroll = cursorPx - inputW + 4
  elif cursorPx - app.inputScroll < 0:
    app.inputScroll = max(0, cursorPx - 4)
  app.inputScroll = clamp(app.inputScroll, 0, max(0, tw - inputW))

proc submitInput(app: var App) =
  if app.inputText.len == 0: return
  let cmd = app.inputText.strip()
  app.buf.addLine("> " & cmd)
  app.buf.recomputeHeight(app.lineH)
  app.buf.scrollToBottom(app.winH - INPUT_H - SCROLL_PAD_B)
  toGame.send(GameMsg(kind: gmInput, raw: cmd))
  if cmd.len > 0:
    app.history.add cmd
    app.histIdx  = app.history.len
    app.histDraft = ""
  app.inputText   = ""
  app.inputCursor = 0
  app.inputScroll = 0

proc handleLinkClick(app: var App; cmd: string) =
  app.inputText   = cmd
  app.inputCursor = cmd.len
  app.inputScroll = 0
  app.submitInput()

proc handleInputKey(app: var App; ks: KeySym; ctrl: bool; nowTick: uint32) =
  case ks.sym
  of K_RETURN, K_KP_ENTER:
    app.submitInput()
    app.showCursor  = true
    app.cursorBlink = nowTick
  of K_BACKSPACE:
    if app.inputCursor > 0:
      var i = app.inputCursor - 1
      while i > 0 and (app.inputText[i].ord and 0xC0) == 0x80: dec i
      app.inputText.delete(i .. app.inputCursor - 1)
      app.inputCursor = i
      app.showCursor  = true
      app.cursorBlink = nowTick
  of K_DELETE:
    if app.inputCursor < app.inputText.len:
      var i = app.inputCursor + 1
      while i < app.inputText.len and
            (app.inputText[i].ord and 0xC0) == 0x80: inc i
      app.inputText.delete(app.inputCursor .. i - 1)
      app.showCursor  = true
      app.cursorBlink = nowTick
  of K_LEFT:
    if app.inputCursor > 0:
      dec app.inputCursor
      while app.inputCursor > 0 and
            (app.inputText[app.inputCursor].ord and 0xC0) == 0x80:
        dec app.inputCursor
  of K_RIGHT:
    if app.inputCursor < app.inputText.len:
      inc app.inputCursor
      while app.inputCursor < app.inputText.len and
            (app.inputText[app.inputCursor].ord and 0xC0) == 0x80:
        inc app.inputCursor
  of K_UP:
    if app.history.len > 0:
      if app.histIdx == app.history.len:
        app.histDraft = app.inputText
      app.histIdx = max(0, app.histIdx - 1)
      app.inputText   = app.history[app.histIdx]
      app.inputCursor = app.inputText.len
      app.inputScroll = 0
  of K_DOWN:
    if app.histIdx < app.history.len:
      app.histIdx += 1
      app.inputText = if app.histIdx == app.history.len: app.histDraft
                      else: app.history[app.histIdx]
      app.inputCursor = app.inputText.len
      app.inputScroll = 0
  of K_HOME: app.inputCursor = 0
  of K_END:  app.inputCursor = app.inputText.len
  of K_PAGEUP:
    app.buf.scrollY = max(0, app.buf.scrollY -
                           (app.winH - INPUT_H - SCROLL_PAD_B))
  of K_PAGEDOWN:
    app.buf.scrollY = min(max(0, app.buf.totalH -
                               (app.winH - INPUT_H - SCROLL_PAD_B)),
                          app.buf.scrollY + (app.winH - INPUT_H - SCROLL_PAD_B))
  of K_c:
    if ctrl and app.hasSelection:
      discard setClipboardText(app.selectionText().cstring)
  of K_a:
    if ctrl:
      app.inputText   = ""
      app.inputCursor = 0
  else: discard

proc hitTestLink(app: App; mx, my: int): string =
  ## Return the command of any link span under (mx, my), or "".
  if mx >= app.sashX or my >= app.winH - INPUT_H: return ""
  let li = (my + app.buf.scrollY) div app.lineH
  if li < 0 or li >= app.buf.lines.len: return ""
  var cx = TEXT_PAD
  for span in app.buf.lines[li]:
    let sw = textWidth(app.font, span.text)
    if mx >= cx and mx < cx + sw:
      return if span.isLink: span.cmd else: ""
    cx += sw
  return ""

# ─── Main ────────────────────────────────────────────────────────────────────
proc main*() =
  sdlCheck sdl2.init(INIT_VIDEO or INIT_EVENTS)
  discard ttf.ttfInit()
  discard image.init(IMG_INIT_PNG or IMG_INIT_JPG)

  let win = createWindow("Menagerie",
    SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
    1280, 768, SDL_WINDOW_SHOWN or SDL_WINDOW_RESIZABLE)
  if win.isNil: quit("createWindow: " & $getError(), 1)

  let ren = createRenderer(win, -1, Renderer_Accelerated or Renderer_PresentVsync)
  if ren.isNil: quit("createRenderer: " & $getError(), 1)
  discard ren.setDrawBlendMode(BlendMode_None)

  # Font — embedded at compile time via staticRead.
  # Run download-deps.sh to fetch SpaceMono-Regular.ttf before building.
  const fontData = staticRead("../../vendor/fonts/SpaceMono-Regular.ttf")
  let rw = rwFromMem(fontData.cstring, fontData.len.cint)
  let font = openFontRW(rw, 1, FONT_SIZE.cint)
  if font.isNil: quit("openFontRW: " & $getError(), 1)

  var fh: cint
  block:
    var fw: cint
    discard sizeUtf8(font, "M".cstring, fw.addr, fh.addr)

  var app = App(
    win:        win,
    ren:        ren,
    font:       font,
    fontH:      fh.int,
    lineH:      fh.int + 6,
    winW:       1280,
    winH:       768,
    sashX:      420,
    showCursor: true,
    panelStart: -1,
  )

  app.curArrow  = createSystemCursor(SDL_SYSTEM_CURSOR_ARROW)
  app.curHand   = createSystemCursor(SDL_SYSTEM_CURSOR_HAND)
  app.curSizeWE = createSystemCursor(SDL_SYSTEM_CURSOR_SIZEWE)
  app.curIBeam  = createSystemCursor(SDL_SYSTEM_CURSOR_IBEAM)

  # Content loading and welcome messages are handled by the game thread.

  var
    running = true
    ev:      Event

  while running:
    let nowTick = getTicks()

    if nowTick - app.cursorBlink >= CURSOR_BLINK.uint32:
      app.showCursor  = not app.showCursor
      app.cursorBlink = nowTick

    # ── Poll messages from the game thread ───────────────────────────────────
    var dirtyBuf = false
    while true:
      let (avail, msg) = toUi.tryRecv()
      if not avail: break
      case msg.kind
      of umPrint:
        app.buf.addLine(msg.line)
        dirtyBuf = true
      of umLoadLocation:
        app.loadBgImage(msg.imgPath)
        app.recomputeBgRect()
      of umStats:
        app.hudStats = @[]
        for s in msg.statLines:
          let i = s.find(": ")
          if i >= 0: app.hudStats.add (s[0 ..< i], s[i + 2 .. ^1])
          else:      app.hudStats.add (s, "")
      of umPanelReplace:
        # Establish a new panel anchor at the current end of the buffer.
        app.panelStart = app.buf.lines.len
        for line in msg.replaceLines: app.buf.addLine(line)
        app.panelLen = msg.replaceLines.len
        dirtyBuf = true
      of umPanelAppend:
        # Replace the tracked panel in-place with fresh content.
        # Lines that were appended after the panel (e.g. feedback lines from
        # earlier commands) stay in position — only the panel block is spliced.
        let ps = app.panelStart
        let pl = app.panelLen
        if ps >= 0 and pl >= 0 and ps + pl <= app.buf.lines.len:
          for _ in 0 ..< pl:
            app.buf.lines.delete(ps)
          for i in 0 ..< msg.appendLines.len:
            app.buf.lines.insert(parseLine(msg.appendLines[i]), ps + i)
          app.panelLen = msg.appendLines.len
          app.hasSelection = false   # line indices may have shifted
        else:
          for line in msg.appendLines: app.buf.addLine(line)
        dirtyBuf = true
      of umRenderSprites: discard
      of umJournalOpen:
        app.openJournalOverlay(msg.jPages, msg.jIdx)
      of umQuit:
        running = false
    if dirtyBuf:
      app.buf.recomputeHeight(app.lineH)
      app.buf.scrollToBottom(app.winH - INPUT_H - SCROLL_PAD_B)

    while pollEvent(ev):
      case ev.kind

      of QuitEvent:
        running = false

      of WindowEvent:
        let we = ev.window
        if we.event == WindowEvent_Resized:
          app.winW  = we.data1.int
          app.winH  = we.data2.int
          app.sashX = clamp(app.sashX, 200, app.winW - 200)
          app.recomputeBgRect()
          app.buf.recomputeHeight(app.lineH)
          app.buf.scrollToBottom(app.winH - INPUT_H - SCROLL_PAD_B)

      of MouseMotion:
        let mx = ev.motion.x.int
        let my = ev.motion.y.int
        if app.draggingSash:
          app.sashX = clamp(mx - app.sashDragOff, 200, app.winW - 250)
          app.recomputeBgRect()
        else:
          app.hoverLink = app.hitTestLink(mx, my)
          setCursor:
            if my >= app.winH - INPUT_H and mx >= app.sashX - 74 and mx < app.sashX: app.curHand
            elif app.hoverLink.len > 0: app.curHand
            elif mx >= app.sashX and mx < app.sashX + SASH_W: app.curSizeWE
            elif mx < app.sashX and my >= app.winH - INPUT_H: app.curIBeam
            else: app.curArrow
          if app.selecting:
            app.selEnd       = app.anchorFromMouse(mx, my)
            app.hasSelection = true

      of MouseButtonDown:
        let mx = ev.button.x.int
        let my = ev.button.y.int
        if ev.button.button == BUTTON_LEFT:
          if mx >= app.sashX and mx < app.sashX + SASH_W:
            app.draggingSash = true
            app.sashDragOff  = mx - app.sashX
          else:
            app.selecting    = true
            app.hasSelection = false
            app.selStart     = app.anchorFromMouse(mx, my)
            app.selEnd       = app.selStart

      of MouseButtonUp:
        let mx = ev.button.x.int
        let my = ev.button.y.int
        if app.journalOpen:
          if ev.button.button == BUTTON_LEFT:
            if inRect(mx, my, app.jBtnClose):
              app.closeJournalOverlay()
            elif inRect(mx, my, app.jBtnPrev):
              if app.journalIdx > 0: app.journalGotoPage(app.journalIdx - 1)
            elif inRect(mx, my, app.jBtnNext):
              if app.journalIdx < app.journalPages.high:
                app.journalGotoPage(app.journalIdx + 1)
              else:
                app.journalSaveCurrentPage()
                app.journalPages.add ""
                app.journalGotoPage(app.journalPages.high)
            elif inRect(mx, my, app.jSrchBox):
              app.journalSrchFocus = true
            elif my >= app.jBodyY and app.journalSearch.len > 0:
              # hit-test search result links
              let li = (my - app.jBodyY - TEXT_PAD) div app.lineH
              let rlines = journalResultLines(app)
              if li >= 0 and li < rlines.len:
                var cx = TEXT_PAD
                for span in rlines[li]:
                  let sw = textWidth(app.font, span.text)
                  if span.isLink and mx >= cx and mx < cx + sw:
                    let parts = strutils.splitWhitespace(span.cmd)
                    if parts.len >= 2 and parts[0] == "journal_goto":
                      try: app.journalGotoPage(parseInt(parts[1]))
                      except ValueError: discard
                    break
                  cx += sw
            else:
              app.journalSrchFocus = false
        elif ev.button.button == BUTTON_LEFT:
          if app.draggingSash:
            app.draggingSash = false
          elif my >= app.winH - INPUT_H and mx >= app.sashX - 74 and mx < app.sashX:
            app.selecting    = false
            app.hasSelection = false
            toGame.send(GameMsg(kind: gmInput, raw: "help"))
          elif app.selecting:
            app.selecting = false
            let moved = abs(app.selEnd.px - app.selStart.px) +
                        abs(app.selEnd.py - app.selStart.py)
            if moved < 4:
              app.hasSelection = false
              let link = app.hitTestLink(mx, my)
              if link.len > 0: app.handleLinkClick(link)

      of MouseWheel:
        let delta = ev.wheel.y.int * app.lineH * 3
        app.buf.scrollY = clamp(app.buf.scrollY - delta,
                                0, max(0, app.buf.totalH - (app.winH - INPUT_H - SCROLL_PAD_B)))

      of TextInput:
        let s = $cast[cstring](ev.text.text[0].unsafeAddr)
        if app.journalOpen:
          if app.journalSrchFocus:
            app.journalSearch.insert(s, app.journalSrchCur)
            app.journalSrchCur += s.len
          else:
            var l = app.journalLines[app.journalCurL]
            l.insert(s, app.journalCurC)
            app.journalLines[app.journalCurL] = l
            app.journalCurC += s.len
        else:
          app.inputText.insert(s, app.inputCursor)
          app.inputCursor += s.len
          let promptW2 = textWidth(app.font, ">")
          let inputX   = TEXT_PAD + promptW2 + 6
          let inputW2  = app.sashX - TEXT_PAD * 2 - promptW2 - 6 - 36
          app.clampInputScroll(inputX, inputW2)
        app.showCursor  = true
        app.cursorBlink = nowTick

      of KeyDown:
        let ks   = ev.key.keysym
        let ctrl = (ks.modstate and KMOD_CTRL) != 0
        if app.journalOpen:
          app.showCursor  = true
          app.cursorBlink = nowTick
          case ks.sym
          of K_ESCAPE:
            app.closeJournalOverlay()
          of K_TAB:
            app.journalSrchFocus = not app.journalSrchFocus
          of K_RETURN, K_KP_ENTER:
            if app.journalSrchFocus:
              app.journalSrchFocus = false
            elif app.journalLines.len < JOURNAL_MAX_LINES:
              let l      = app.journalLines[app.journalCurL]
              let before = l[0 ..< app.journalCurC]
              let after  = l[app.journalCurC .. ^1]
              app.journalLines[app.journalCurL] = before
              app.journalLines.insert(after, app.journalCurL + 1)
              inc app.journalCurL
              app.journalCurC = 0
          of K_BACKSPACE:
            if app.journalSrchFocus:
              if app.journalSrchCur > 0:
                var i = app.journalSrchCur - 1
                while i > 0 and
                      (app.journalSearch[i].ord and 0xC0) == 0x80: dec i
                app.journalSearch.delete(i .. app.journalSrchCur - 1)
                app.journalSrchCur = i
            else:
              if app.journalCurC > 0:
                var l = app.journalLines[app.journalCurL]
                var i = app.journalCurC - 1
                while i > 0 and (l[i].ord and 0xC0) == 0x80: dec i
                l.delete(i .. app.journalCurC - 1)
                app.journalLines[app.journalCurL] = l
                app.journalCurC = i
              elif app.journalCurL > 0:
                let prev = app.journalLines[app.journalCurL - 1]
                app.journalCurC = prev.len
                app.journalLines[app.journalCurL - 1] =
                  prev & app.journalLines[app.journalCurL]
                app.journalLines.delete(app.journalCurL)
                dec app.journalCurL
          of K_DELETE:
            if not app.journalSrchFocus:
              let l = app.journalLines[app.journalCurL]
              if app.journalCurC < l.len:
                var i = app.journalCurC + 1
                while i < l.len and (l[i].ord and 0xC0) == 0x80: inc i
                var ml = l
                ml.delete(app.journalCurC .. i - 1)
                app.journalLines[app.journalCurL] = ml
              elif app.journalCurL < app.journalLines.high:
                app.journalLines[app.journalCurL] &=
                  app.journalLines[app.journalCurL + 1]
                app.journalLines.delete(app.journalCurL + 1)
          of K_LEFT:
            if app.journalSrchFocus:
              if app.journalSrchCur > 0: dec app.journalSrchCur
            else:
              if app.journalCurC > 0:
                dec app.journalCurC
                while app.journalCurC > 0 and
                      (app.journalLines[app.journalCurL][app.journalCurC].ord and 0xC0) == 0x80:
                  dec app.journalCurC
              elif app.journalCurL > 0:
                dec app.journalCurL
                app.journalCurC = app.journalLines[app.journalCurL].len
          of K_RIGHT:
            if app.journalSrchFocus:
              if app.journalSrchCur < app.journalSearch.len:
                inc app.journalSrchCur
            else:
              let l = app.journalLines[app.journalCurL]
              if app.journalCurC < l.len:
                inc app.journalCurC
                while app.journalCurC < l.len and
                      (l[app.journalCurC].ord and 0xC0) == 0x80:
                  inc app.journalCurC
              elif app.journalCurL < app.journalLines.high:
                inc app.journalCurL
                app.journalCurC = 0
          of K_UP:
            if not app.journalSrchFocus and app.journalCurL > 0:
              dec app.journalCurL
              app.journalCurC =
                min(app.journalCurC, app.journalLines[app.journalCurL].len)
          of K_DOWN:
            if not app.journalSrchFocus and
               app.journalCurL < app.journalLines.high:
              inc app.journalCurL
              app.journalCurC =
                min(app.journalCurC, app.journalLines[app.journalCurL].len)
          of K_HOME:
            if app.journalSrchFocus: app.journalSrchCur = 0
            else: app.journalCurC = 0
          of K_END:
            if app.journalSrchFocus:
              app.journalSrchCur = app.journalSearch.len
            else:
              app.journalCurC = app.journalLines[app.journalCurL].len
          of K_PAGEUP:
            if app.journalIdx > 0:
              app.journalGotoPage(app.journalIdx - 1)
          of K_PAGEDOWN:
            if app.journalIdx < app.journalPages.high:
              app.journalGotoPage(app.journalIdx + 1)
            else:
              app.journalSaveCurrentPage()
              app.journalPages.add ""
              app.journalGotoPage(app.journalPages.high)
          else: discard
        else:
          app.handleInputKey(ks, ctrl, nowTick)

      else: discard

    render(app)

    let elapsed = getTicks() - nowTick
    if elapsed < FRAME_MS.uint32:
      delay(FRAME_MS.uint32 - elapsed)

  if app.bgTex != nil: destroyTexture(app.bgTex)
  font.close()
  ttf.ttfQuit()
  image.quit()
  destroyRenderer(ren)
  destroyWindow(win)
  sdl2.quit()

