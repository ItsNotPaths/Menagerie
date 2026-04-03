## ui/journal.nim
## ──────────────
## Journal overlay — rendering, page management, and input handling.
## Included (not imported) by text_window.nim; operates on App directly
## and has full access to the parent module's types, constants, and helpers.

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
  app.journalPages     = if pages.len > 0: pages else: @[""]
  app.journalOpen      = true
  app.journalSrchFocus = false
  app.journalSearch    = ""
  app.journalSrchCur   = 0
  app.journalPageFocus = false
  app.journalPageInput = ""
  app.journalPageCur   = 0
  app.journalGotoPage(clamp(idx, 0, app.journalPages.high))

proc closeJournalOverlay(app: var App) =
  app.journalSaveCurrentPage()
  toGame.send(GameMsg(kind: gmJournalSave, savedPages: app.journalPages))
  app.journalOpen = false

proc journalResultLines(app: App): seq[Line] =
  ## Build search result lines. Spans are constructed directly so the label
  ## can contain colons without confusing parseLine's [[label:cmd]] split.
  let q = app.journalSearch.toLowerAscii
  result.add @[Span(text: "Results for '" & app.journalSearch & "':")]
  result.add @[Span(text: "")]
  var found = false
  for i, page in app.journalPages:
    let pageLow = page.toLowerAscii
    let matchIdx = pageLow.find(q)
    if matchIdx >= 0:
      let ctx    = 35
      let start  = max(0, matchIdx - ctx)
      let stop   = min(page.high, matchIdx + q.len + ctx - 1)
      let pre    = if start > 0: "..." else: ""
      let suf    = if stop < page.high: "..." else: ""
      let excerpt = pre & page[start .. stop].replace("\n", " ") & suf
      let label  = "Page " & $(i+1) & ": " & excerpt
      result.add @[Span(text: "  "),
                   Span(text: label, isLink: true,
                        cmd: "journal_goto " & $i)]
      found = true
  if not found:
    result.add @[Span(text: "  No results.")]

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

  # ── Page N / M (clickable input) ──────────────────────────────────────────
  let pageText = "Page " & $(app.journalIdx + 1) & " / " & $app.journalPages.len
  let ptX = prevR.x + prevR.w + 6
  let ptY = btnY + (btnH - app.fontH) div 2
  let ptW = textWidth(app.font, pageText)
  let pageR = (x: ptX, y: btnY, w: ptW, h: btnH)
  app.jPageBox = pageR
  if app.journalPageFocus:
    app.ren.setColor(COL_BG)
    app.ren.fillRect(pageR.x, pageR.y, pageR.w, pageR.h)
    app.ren.setColor(COL_FG_LINK)
    var pageBorder = rect(pageR.x.cint, pageR.y.cint, pageR.w.cint, pageR.h.cint)
    discard app.ren.drawRect(pageBorder.addr)
    let pInnerX = pageR.x + 3
    discard app.ren.renderText(app.font, app.journalPageInput, pInnerX, ptY, COL_FG)
    if app.showCursor:
      let curX = pInnerX +
                 textWidth(app.font, app.journalPageInput[0 ..< app.journalPageCur])
      app.ren.setColor(COL_CURSOR)
      app.ren.fillRect(curX, ptY, 2, app.fontH)
  else:
    discard app.ren.renderText(app.font, pageText, ptX, ptY, COL_FG)

  # ── [>] next button ────────────────────────────────────────────────────────
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
    let rlines = journalResultLines(app)
    for li, line in rlines:
      let lineY = bodyY + TEXT_PAD + li * app.lineH
      var cx = TEXT_PAD
      for span in line:
        let sw = textWidth(app.font, span.text)
        let isHovered = span.isLink and
                        mx.int >= cx and mx.int < cx + sw and
                        my.int >= lineY and my.int < lineY + app.lineH
        discard app.ren.renderText(app.font, span.text, cx, lineY,
                                   if span.isLink: COL_FG_LINK else: COL_FG)
        if span.isLink:
          app.ren.setColor(COL_FG_LINK)
          app.ren.fillRect(cx, lineY + app.fontH - 4, sw, 1)
          if isHovered:
            app.ren.setColor((r: 143u8, g: 188u8, b: 187u8, a: 40u8))
            discard app.ren.setDrawBlendMode(BlendMode_Blend)
            app.ren.fillRect(cx, lineY + 4, sw, app.fontH - 4)
            discard app.ren.setDrawBlendMode(BlendMode_None)
        cx += sw
  else:
    for li, line in app.journalLines:
      let lineY = bodyY + TEXT_PAD + li * app.lineH
      if li == app.journalCurL and not app.journalSrchFocus and app.showCursor:
        let curX = TEXT_PAD +
                   textWidth(app.font, line[0 ..< app.journalCurC])
        app.ren.setColor(COL_CURSOR)
        app.ren.fillRect(curX, lineY, 2, app.fontH)
      discard app.ren.renderText(app.font, line, TEXT_PAD, lineY, COL_FG)

  discard app.ren.setClipRect(nil)


# ─── Journal input handlers ───────────────────────────────────────────────────

proc handleJournalMouseMotion(app: var App; mx, my: int) =
  let overSrch = inRect(mx, my, app.jSrchBox)
  let overPage = inRect(mx, my, app.jPageBox)
  let overBtn  = inRect(mx, my, app.jBtnPrev) or
                 inRect(mx, my, app.jBtnNext) or
                 inRect(mx, my, app.jBtnClose)
  var overResultLink = false
  if app.journalSearch.len > 0 and my >= app.jBodyY:
    let li = (my - app.jBodyY - TEXT_PAD) div app.lineH
    let rlines = journalResultLines(app)
    if li >= 0 and li < rlines.len:
      var cx = TEXT_PAD
      for span in rlines[li]:
        let sw = textWidth(app.font, span.text)
        if span.isLink and mx >= cx and mx < cx + sw:
          overResultLink = true
          break
        cx += sw
  setCursor:
    if overSrch or overPage: app.curIBeam
    elif overBtn or overResultLink: app.curHand
    else: app.curArrow

proc handleJournalMouseUp(app: var App; mx, my: int) =
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
    app.journalPageFocus = false
  elif inRect(mx, my, app.jPageBox):
    app.journalPageFocus = true
    app.journalSrchFocus = false
    app.journalPageInput = $(app.journalIdx + 1)
    app.journalPageCur   = app.journalPageInput.len
  elif my >= app.jBodyY and app.journalSearch.len > 0:
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
    app.journalPageFocus = false

proc handleJournalTextInput(app: var App; s: string) =
  if app.journalPageFocus:
    if s.len == 1 and s[0] in '0' .. '9':
      app.journalPageInput.insert(s, app.journalPageCur)
      app.journalPageCur += s.len
  elif app.journalSrchFocus:
    app.journalSearch.insert(s, app.journalSrchCur)
    app.journalSrchCur += s.len
  else:
    var l = app.journalLines[app.journalCurL]
    l.insert(s, app.journalCurC)
    app.journalLines[app.journalCurL] = l
    app.journalCurC += s.len

proc handleJournalKey(app: var App; ks: KeySym; nowTick: uint32) =
  app.showCursor  = true
  app.cursorBlink = nowTick
  case ks.sym
  of K_ESCAPE:
    if app.journalPageFocus:
      app.journalPageFocus = false
    else:
      app.closeJournalOverlay()
  of K_TAB:
    app.journalSrchFocus = not app.journalSrchFocus
    app.journalPageFocus = false
  of K_RETURN, K_KP_ENTER:
    if app.journalPageFocus:
      try:
        let n = parseInt(app.journalPageInput) - 1
        app.journalPageFocus = false
        while n > app.journalPages.high:
          app.journalPages.add ""
        app.journalGotoPage(n)
      except ValueError:
        app.journalPageFocus = false
    elif app.journalSrchFocus:
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
    if app.journalPageFocus:
      if app.journalPageCur > 0:
        app.journalPageInput.delete(app.journalPageCur - 1 .. app.journalPageCur - 1)
        dec app.journalPageCur
    elif app.journalSrchFocus:
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
    if app.journalPageFocus:
      if app.journalPageCur < app.journalPageInput.len:
        app.journalPageInput.delete(app.journalPageCur .. app.journalPageCur)
    elif not app.journalSrchFocus:
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
    if app.journalPageFocus:
      if app.journalPageCur > 0: dec app.journalPageCur
    elif app.journalSrchFocus:
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
    if app.journalPageFocus:
      if app.journalPageCur < app.journalPageInput.len: inc app.journalPageCur
    elif app.journalSrchFocus:
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
    if app.journalPageFocus: app.journalPageCur = 0
    elif app.journalSrchFocus: app.journalSrchCur = 0
    else: app.journalCurC = 0
  of K_END:
    if app.journalPageFocus:
      app.journalPageCur = app.journalPageInput.len
    elif app.journalSrchFocus:
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
