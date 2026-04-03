## mod_manager.nim
## Menagerie Mod Manager — SDL2 UI for managing plugin load order and
## triggering Lua export drivers.
##
## Layout:
##   <binary dir>/
##     world-tools/drivers/<driver>/<driver>.lua
##     data/<modpack>/
##       load_order.json
##       <PluginFolder>/<plugin>.json
##     content/                ← export target

import sdl2
import sdl2/ttf
import std/[os, strutils, strformat, tables, algorithm]
import plugin_db
import lua_runner

# ── Embedded font (compile-time) ──────────────────────────────────────────────

const FONT_DATA = staticRead("../../vendor/fonts/SpaceMono-Regular.ttf")

# ── Theme ─────────────────────────────────────────────────────────────────────

type Color = tuple[r, g, b, a: uint8]

const
  BG        : Color = (17,  17,  17,  255)
  BG2       : Color = (26,  26,  26,  255)
  BG3       : Color = (46,  46,  46,  255)
  FG        : Color = (204, 204, 204, 255)
  FG_DIM    : Color = (85,  85,  85,  255)
  FG_ACTIVE : Color = (212, 201, 168, 255)  ## parchment — matches game fg
  FG_OK     : Color = (102, 204, 136, 255)
  FG_MASTER : Color = (255, 204, 102, 255)
  SEL_BG    : Color = (55,  55,  55,  255)  ## light grey row selection
  BTN_BG    : Color = (58,  58,  58,  255)
  BTN_HOV   : Color = (74,  74,  74,  255)
  TAB_ACT   : Color = (52,  52,  52,  255)  ## light grey active tab
  DROP_BG   : Color = (36,  36,  36,  255)
  DROP_HOV  : Color = (55,  55,  55,  255)  ## light grey dropdown hover

# ── Layout constants ──────────────────────────────────────────────────────────

const
  WIN_W    = 760
  WIN_H    = 548
  FONT_SIZE = 14
  HEADER_H = 30   ## modpack selector bar
  TAB_H    = 30   ## tab strip
  ROW_H    = 22
  BTN_H    = 26
  STATUS_H = 24
  PAD      = 10

# ── Tab definitions ───────────────────────────────────────────────────────────

type TabDef = object
  label:  string
  toolId: string
  driver: string

const TABS: array[4, TabDef] = [
  TabDef(label: "World",   toolId: "world-tool",   driver: "world"),
  TabDef(label: "Rooms",   toolId: "room-editor",  driver: "rooms"),
  TabDef(label: "Vars",    toolId: "gameplay-vars", driver: "gameplay_vars"),
  TabDef(label: "Inkwell", toolId: "inkwell",       driver: "menagerie"),
]

# ── Button ────────────────────────────────────────────────────────────────────

type Button = object
  rect:  Rect
  hot:   bool

proc contains(r: Rect; x, y: int): bool =
  x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h

# ── App ───────────────────────────────────────────────────────────────────────

type App = object
  win:  WindowPtr
  ren:  RendererPtr
  font: FontPtr
  fontH: int

  # Runtime paths (set from getAppDir() in main)
  rootDir, driversDir, dataDir, contentDir: string

  # Modpack state
  modpacks:     seq[string]  ## sorted list of subfolder names in data/
  modpackIdx:   int          ## index into modpacks
  dropdownOpen: bool

  db: PluginDb

  activeTab: int
  selIdx:    int
  scrollY:   int

  status:   string
  statusOk: bool

  # hit-test rects (rebuilt each render)
  btnModpack:   Button
  btnMoveUp:    Button
  btnMoveDown:  Button
  btnToggle:    Button
  btnExport:    Button
  btnExportAll: Button

  mouseX, mouseY: int
  running: bool

# ── SDL helpers ───────────────────────────────────────────────────────────────

proc setColor(ren: RendererPtr; c: Color) =
  discard ren.setDrawColor(c.r, c.g, c.b, c.a)

proc fillRect(ren: RendererPtr; x, y, w, h: int) =
  var r: Rect = (x.cint, y.cint, w.cint, h.cint)
  discard ren.fillRect(r)

proc renderText(app: App; text: string; x, y: int; c: Color): int =
  if text.len == 0: return 0
  var col: sdl2.Color = (c.r, c.g, c.b, c.a)
  let surf = app.font.renderUtf8Solid(text.cstring, col)
  if surf == nil: return 0
  let tex = app.ren.createTextureFromSurface(surf)
  freeSurface(surf)
  if tex == nil: return 0
  var w2, h2: cint
  discard tex.queryTexture(nil, nil, addr w2, addr h2)
  var dst: Rect = (x.cint, y.cint, w2, h2)
  discard app.ren.copy(tex, nil, addr dst)
  destroyTexture(tex)
  return w2.int

proc textWidth(app: App; text: string): int =
  var w, h: cint
  discard app.font.sizeUtf8(text.cstring, addr w, addr h)
  return w.int

proc textCy(containerY, containerH, fontH: int): int =
  ## Vertical centre of text inside a container — nudged up 2px to
  ## compensate for the descent region SDL_ttf includes in surface height.
  containerY + (containerH - fontH) div 2 - 2

# ── Layout ────────────────────────────────────────────────────────────────────

proc contentTop(): int = HEADER_H + TAB_H

proc listArea(): tuple[x, y, w, h: int] =
  let y = contentTop() + PAD
  let h = WIN_H - contentTop() - PAD - BTN_H - PAD - STATUS_H - PAD
  (PAD, y, WIN_W - PAD * 2, h)

proc visibleRows(): int =
  max(0, listArea().h div ROW_H - 1)  ## -1 for the header row

# ── Render helpers ────────────────────────────────────────────────────────────

proc drawBtn(app: var App; btn: var Button; x, y, w, h: int; label: string;
             fg: Color = FG) =
  btn.rect = (x.cint, y.cint, w.cint, h.cint)
  btn.hot  = contains(btn.rect, app.mouseX, app.mouseY)
  app.ren.setColor(if btn.hot: BTN_HOV else: BTN_BG)
  app.ren.fillRect(x, y, w, h)
  let tw = app.textWidth(label)
  discard app.renderText(label, x + (w - tw) div 2,
                         textCy(y, h, app.fontH), fg)

proc render(app: var App) =
  app.ren.setColor(BG)
  discard app.ren.clear()

  # ── Header — modpack selector ───────────────────────────────────────────────
  app.ren.setColor(BG2)
  app.ren.fillRect(0, 0, WIN_W, HEADER_H)

  discard app.renderText("Modpack:", PAD, textCy(0, HEADER_H, app.fontH), FG_DIM)

  let mpLabel = if app.modpacks.len > 0: app.modpacks[app.modpackIdx] & "  [v]"
                else: "(none found)  [v]"
  let mpBtnW  = app.textWidth(mpLabel) + PAD * 2
  let mpBtnX  = PAD + app.textWidth("Modpack:") + PAD
  app.drawBtn(app.btnModpack, mpBtnX, (HEADER_H - BTN_H) div 2,
              mpBtnW, BTN_H, mpLabel, FG_ACTIVE)

  app.ren.setColor(BG3)
  app.ren.fillRect(0, HEADER_H - 1, WIN_W, 1)

  # ── Tab strip ───────────────────────────────────────────────────────────────
  let tabW = WIN_W div TABS.len
  for i, t in TABS:
    let tx = i * tabW
    app.ren.setColor(if i == app.activeTab: TAB_ACT else: BG2)
    app.ren.fillRect(tx, HEADER_H, tabW, TAB_H)
    let col = if i == app.activeTab: FG_ACTIVE else: FG
    let tw  = app.textWidth(t.label)
    discard app.renderText(t.label,
                           tx + (tabW - tw) div 2,
                           textCy(HEADER_H, TAB_H, app.fontH), col)

  app.ren.setColor(BG3)
  app.ren.fillRect(0, HEADER_H + TAB_H - 1, WIN_W, 1)

  # ── Plugin list ─────────────────────────────────────────────────────────────
  let (lx, ly, lw, lh) = listArea()
  app.ren.setColor(BG2)
  app.ren.fillRect(lx, ly, lw, lh)

  let tid      = TABS[app.activeTab].toolId
  let plugins  = app.db.plugins.getOrDefault(tid)
  let vis      = visibleRows()
  let maxScroll = max(0, plugins.len - vis)
  if app.scrollY > maxScroll: app.scrollY = maxScroll

  let colNum = 28
  let colMst = 16
  let colEn  = 20
  let colRec = 72

  # List header row
  app.ren.setColor(BG3)
  app.ren.fillRect(lx, ly, lw, ROW_H)
  let hcy = textCy(ly, ROW_H, app.fontH)
  var hx = lx + PAD
  discard app.renderText("#",       hx, hcy, FG_DIM)
  discard app.renderText("M",  hx + colNum, hcy, FG_DIM)
  discard app.renderText("+", hx + colNum + colMst, hcy, FG_DIM)
  discard app.renderText("Name",    hx + colNum + colMst + colEn, hcy, FG_DIM)
  discard app.renderText("Records", lx + lw - colRec - PAD, hcy, FG_DIM)

  # Data rows
  for row in 0 ..< vis:
    let pidx = row + app.scrollY
    if pidx >= plugins.len: break
    let e  = plugins[pidx]
    let ry = ly + ROW_H + row * ROW_H
    let sel = pidx == app.selIdx

    if sel:
      app.ren.setColor(SEL_BG)
      app.ren.fillRect(lx, ry, lw, ROW_H)
    elif row mod 2 == 1:
      app.ren.setColor((r: 30u8, g: 30u8, b: 30u8, a: 255u8))
      app.ren.fillRect(lx, ry, lw, ROW_H)

    let cy = textCy(ry, ROW_H, app.fontH)
    var cx = lx + PAD

    discard app.renderText($(pidx + 1), cx, cy, FG_DIM);  cx += colNum
    if e.isMaster:
      discard app.renderText("*", cx, cy, FG_MASTER)
    cx += colMst
    discard app.renderText(if e.enabled: "+" else: "-", cx, cy,
                           if e.enabled: FG_OK else: FG_DIM)
    cx += colEn
    discard app.renderText(e.name, cx, cy, if e.enabled: FG else: FG_DIM)

    let recStr = $e.recordCount & " rec"
    discard app.renderText(recStr, lx + lw - app.textWidth(recStr) - PAD, cy, FG_DIM)

  # ── Action buttons ──────────────────────────────────────────────────────────
  let btnY = ly + lh + PAD
  let bw   = 106
  let gap  = 6
  var bx   = PAD

  app.drawBtn(app.btnMoveUp,    bx, btnY, bw, BTN_H, "^ Up");       bx += bw + gap
  app.drawBtn(app.btnMoveDown,  bx, btnY, bw, BTN_H, "v Down");     bx += bw + gap
  app.drawBtn(app.btnToggle,    bx, btnY, bw, BTN_H, "Toggle");      bx += bw + gap
  app.drawBtn(app.btnExport,    bx, btnY, bw + 24, BTN_H, "Export Tab"); bx += bw + 24 + gap
  app.drawBtn(app.btnExportAll, bx, btnY, bw + 24, BTN_H, "Export All")

  # ── Status bar ──────────────────────────────────────────────────────────────
  let sty = WIN_H - STATUS_H
  app.ren.setColor(BG)
  app.ren.fillRect(0, sty, WIN_W, STATUS_H)
  app.ren.setColor(BG3)
  app.ren.fillRect(0, sty, WIN_W, 1)
  discard app.renderText(app.status, PAD,
                         textCy(sty, STATUS_H, app.fontH),
                         if app.statusOk: FG_OK else: FG_DIM)

  # ── Modpack dropdown popup (drawn last / on top) ────────────────────────────
  if app.dropdownOpen and app.modpacks.len > 0:
    let popX = app.btnModpack.rect.x.int
    let popY = HEADER_H  ## open downward from the header bottom
    let popW = max(app.btnModpack.rect.w.int, 200)
    let popH = app.modpacks.len * ROW_H + 4

    app.ren.setColor(DROP_BG)
    app.ren.fillRect(popX, popY, popW, popH)
    app.ren.setColor(BG3)
    # border
    var border: Rect = (popX.cint, popY.cint, popW.cint, popH.cint)
    discard app.ren.drawRect(border)

    for i, mp in app.modpacks:
      let iy  = popY + 2 + i * ROW_H
      let hot = app.mouseX >= popX and app.mouseX < popX + popW and
                app.mouseY >= iy   and app.mouseY < iy + ROW_H
      if hot or i == app.modpackIdx:
        app.ren.setColor(DROP_HOV)
        app.ren.fillRect(popX + 1, iy, popW - 2, ROW_H)
      let col = if i == app.modpackIdx: FG_ACTIVE else: FG
      discard app.renderText(mp, popX + PAD, textCy(iy, ROW_H, app.fontH), col)

  app.ren.present()

# ── Modpack loading ───────────────────────────────────────────────────────────

proc loadModpack(app: var App) =
  if app.modpacks.len == 0:
    app.status   = "No modpacks found in " & app.dataDir
    app.statusOk = false
    return
  let mp = app.modpacks[app.modpackIdx]
  app.db = scan(app.dataDir / mp)
  app.selIdx  = -1
  app.scrollY = 0
  app.status   = "Loaded: " & mp
  app.statusOk = true

# ── Export ────────────────────────────────────────────────────────────────────

proc exportTab(app: var App; tabIdx: int) =
  let t       = TABS[tabIdx]
  let luaPath = app.driversDir / t.driver / (t.driver & ".lua")
  if not fileExists(luaPath):
    app.status = "Driver not found: " & luaPath; app.statusOk = false; return

  var ds: DriverState
  ds.init()
  defer: ds.close()
  if not ds.loadDriver(luaPath):
    app.status = "Failed to load driver: " & t.driver; app.statusOk = false; return

  createDir(app.contentDir)
  let n = ds.runExport(app.db.enabledPlugins(t.toolId), app.contentDir)
  if n < 0: app.status = fmt"[{t.label}] export failed";          app.statusOk = false
  else:     app.status = fmt"[{t.label}] exported {n} file(s)";   app.statusOk = true

proc exportAssets(app: var App) =
  let luaPath = app.driversDir / "assets" / "assets.lua"
  if not fileExists(luaPath):
    app.status = "Assets driver not found"; app.statusOk = false; return

  var ds: DriverState
  ds.init()
  defer: ds.close()
  if not ds.loadDriver(luaPath):
    app.status = "Failed to load assets driver"; app.statusOk = false; return

  var folders: seq[string]
  for tid in TOOL_IDS:
    for e in app.db.enabledPlugins(tid):
      if e.folder notin folders: folders.add e.folder

  createDir(app.contentDir)
  let n = ds.runAssetExport(folders, app.contentDir)
  if n < 0: app.status = "Assets export failed";            app.statusOk = false
  else:     app.status = fmt"Assets: mapped {n} file(s)";   app.statusOk = true

proc exportAll(app: var App) =
  var total = 0
  var failed = false
  for i in 0 ..< TABS.len:
    let luaPath = app.driversDir / TABS[i].driver / (TABS[i].driver & ".lua")
    if not fileExists(luaPath): continue
    var ds: DriverState
    ds.init()
    if not ds.loadDriver(luaPath): ds.close(); failed = true; continue
    createDir(app.contentDir)
    let n = ds.runExport(app.db.enabledPlugins(TABS[i].toolId), app.contentDir)
    ds.close()
    if n >= 0: total += n else: failed = true
  app.exportAssets()
  if failed: app.status = fmt"Done with errors — {total} file(s)"; app.statusOk = false
  else:      app.status = fmt"Export complete — {total} file(s)";  app.statusOk = true

# ── Event handling ────────────────────────────────────────────────────────────

proc handleClick(app: var App; x, y: int) =
  # Close dropdown on any click outside it
  if app.dropdownOpen:
    let popX = app.btnModpack.rect.x.int
    let popY = HEADER_H
    let popW = max(app.btnModpack.rect.w.int, 200)
    let popH = app.modpacks.len * ROW_H + 4
    if x >= popX and x < popX + popW and y >= popY and y < popY + popH:
      # Click inside popup — select modpack
      let row = (y - popY - 2) div ROW_H
      if row >= 0 and row < app.modpacks.len:
        app.modpackIdx = row
        app.loadModpack()
      app.dropdownOpen = false
      return
    app.dropdownOpen = false
    return

  # Modpack dropdown button
  if contains(app.btnModpack.rect, x, y):
    app.dropdownOpen = not app.dropdownOpen
    return

  # Tab strip
  if y >= HEADER_H and y < HEADER_H + TAB_H:
    let ti = x div (WIN_W div TABS.len)
    if ti >= 0 and ti < TABS.len:
      app.activeTab = ti
      app.selIdx    = -1
      app.scrollY   = 0
    return

  # Plugin list rows (skip header row)
  let (lx, ly, lw, lh) = listArea()
  if x >= lx and x < lx + lw and y >= ly + ROW_H and y < ly + lh:
    let pidx = (y - ly - ROW_H) div ROW_H + app.scrollY
    let L    = app.db.plugins.getOrDefault(TABS[app.activeTab].toolId).len
    if pidx >= 0 and pidx < L: app.selIdx = pidx
    return

  # Action buttons
  let tid = TABS[app.activeTab].toolId
  if contains(app.btnMoveUp.rect, x, y) and app.selIdx >= 0:
    app.db.moveUp(tid, app.selIdx)
    if app.selIdx > 0: dec app.selIdx
  elif contains(app.btnMoveDown.rect, x, y) and app.selIdx >= 0:
    app.db.moveDown(tid, app.selIdx)
    if app.selIdx < app.db.plugins.getOrDefault(tid).len - 1: inc app.selIdx
  elif contains(app.btnToggle.rect, x, y) and app.selIdx >= 0:
    app.db.toggleEnabled(tid, app.selIdx)
  elif contains(app.btnExport.rect, x, y):
    app.exportTab(app.activeTab)
  elif contains(app.btnExportAll.rect, x, y):
    app.exportAll()

proc handleScroll(app: var App; dy: int) =
  if app.dropdownOpen: return
  let maxS = max(0, app.db.plugins.getOrDefault(TABS[app.activeTab].toolId).len - visibleRows())
  app.scrollY = clamp(app.scrollY + dy, 0, maxS)

# ── Main ──────────────────────────────────────────────────────────────────────

proc main() =
  discard sdl2.init(INIT_VIDEO or INIT_EVENTS)
  defer: sdl2.quit()
  discard ttfInit()
  defer: ttfQuit()

  var app: App
  app.rootDir    = getAppDir()
  app.driversDir = app.rootDir / "world-tools" / "drivers"
  app.dataDir    = app.rootDir / "data"
  app.contentDir = app.rootDir / "content"

  app.win = createWindow("Menagerie Mod Manager",
                         SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                         WIN_W, WIN_H,
                         SDL_WINDOW_SHOWN)
  app.ren  = createRenderer(app.win, -1, Renderer_Accelerated or Renderer_PresentVsync)
  let fontRw = rwFromMem(FONT_DATA.cstring, FONT_DATA.len.cint)
  app.font = openFontRW(fontRw, 1, FONT_SIZE.cint)
  var fW, fH: cint
  discard app.font.sizeUtf8("Ag", addr fW, addr fH)
  app.fontH = fH.int

  app.running  = true
  app.status   = "Ready"
  app.statusOk = true
  app.selIdx   = -1

  # Discover modpacks
  for kind, path in walkDir(app.dataDir):
    if kind == pcDir: app.modpacks.add lastPathPart(path)
  algorithm.sort(app.modpacks)
  app.loadModpack()

  var ev = defaultEvent
  while app.running:
    while pollEvent(ev):
      case ev.kind
      of QuitEvent:
        app.running = false
      of MouseMotion:
        app.mouseX = ev.motion.x.int
        app.mouseY = ev.motion.y.int
      of MouseButtonDown:
        if ev.button.button == BUTTON_LEFT:
          handleClick(app, ev.button.x.int, ev.button.y.int)
      of MouseWheel:
        handleScroll(app, -ev.wheel.y.int)
      of KeyDown:
        case ev.key.keysym.sym
        of K_ESCAPE:
          if app.dropdownOpen: app.dropdownOpen = false
          else: app.running = false
        of K_UP:
          if app.selIdx > 0: dec app.selIdx
          if app.selIdx < app.scrollY: app.scrollY = app.selIdx
        of K_DOWN:
          let L = app.db.plugins.getOrDefault(TABS[app.activeTab].toolId).len
          if app.selIdx < L - 1: inc app.selIdx
          if app.selIdx >= app.scrollY + visibleRows():
            app.scrollY = app.selIdx - visibleRows() + 1
        else: discard
      else: discard

    render(app)

  close(app.font)
  destroy(app.ren)
  destroy(app.win)

main()
