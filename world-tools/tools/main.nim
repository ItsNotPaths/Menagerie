## main.nim
## World Tools — single SDL2 window with World / Rooms / Vars tabs.
## Entry point: initialises SDL2, loads config, runs event loop.

import sdl2
import sdl2/ttf
import std/[os, json, algorithm]
import "../theme"
import plugin_sidebar
import world_tab
import rooms_tab
import vars_tab

# ── Local layout constants ─────────────────────────────────────────────────────

const
  HEADER_H    = 30    ## modpack selector bar above the tab strip
  DROP_MIN_W  = 200   ## minimum width of the modpack dropdown popup

# ── Config ────────────────────────────────────────────────────────────────────

const CONFIG_FILE = "world_tools_config.json"

type Config = object
  dataDir:    string   ## parent folder containing modpack subfolders
  modpackDir: string   ## last-selected modpack (abs path)
  contentDir: string
  winW, winH: int
  activeTab:  int

proc defaultConfig(): Config =
  Config(winW: 1200, winH: 780, activeTab: 0)

proc configPath(): string =
  getAppDir() / CONFIG_FILE

proc loadConfig(): Config =
  result = defaultConfig()
  try:
    let j = parseFile(configPath())
    result.dataDir    = j.getOrDefault("data_dir").getStr
    result.modpackDir = j.getOrDefault("modpack_dir").getStr
    result.contentDir = j.getOrDefault("content_dir").getStr
    result.winW       = j.getOrDefault("win_w").getInt(1200)
    result.winH       = j.getOrDefault("win_h").getInt(780)
    result.activeTab  = j.getOrDefault("active_tab").getInt(0)
  except: discard

proc saveConfig(cfg: Config) =
  var j = newJObject()
  j["data_dir"]    = newJString(cfg.dataDir)
  j["modpack_dir"] = newJString(cfg.modpackDir)
  j["content_dir"] = newJString(cfg.contentDir)
  j["win_w"]       = newJInt(cfg.winW)
  j["win_h"]       = newJInt(cfg.winH)
  j["active_tab"]  = newJInt(cfg.activeTab)
  try: writeFile(configPath(), j.pretty)
  except: discard

# ── Tab strip ─────────────────────────────────────────────────────────────────

type TabDef = object
  label:  string
  toolId: string

const TABS: array[3, TabDef] = [
  TabDef(label: "World", toolId: "world-tool"),
  TabDef(label: "Rooms", toolId: "room-editor"),
  TabDef(label: "Vars",  toolId: "gameplay-vars"),
]

# ── App ───────────────────────────────────────────────────────────────────────

type
  Btn = object
    rect: Rect
    hot:  bool

  App = object
    win:   WindowPtr
    ren:   RendererPtr
    font:  FontPtr
    fontH: int

    cfg:       Config
    activeTab: int

    # Modpack selector
    modpacks:     seq[string]   ## subfolder names inside cfg.dataDir
    modpackIdx:   int
    dropdownOpen: bool
    btnModpack:   Btn

    sidebar:   Sidebar
    worldTab:  WorldTab
    roomsTab:  RoomsTab
    varsTab:   VarsTab

    mouseX, mouseY: int
    running: bool

# ── Modpack helpers ───────────────────────────────────────────────────────────

proc scanModpacks(dataDir: string): seq[string] =
  ## Return sorted subfolder names inside dataDir.
  if not dirExists(dataDir): return
  for kind, path in walkDir(dataDir):
    if kind == pcDir:
      result.add lastPathPart(path)
  result.sort()

proc currentModpackDir(app: App): string =
  if app.modpacks.len == 0: return ""
  app.cfg.dataDir / app.modpacks[app.modpackIdx]

proc loadModpack(app: var App) =
  ## Reload all tabs and sidebar for the currently selected modpack.
  let dir = app.currentModpackDir()
  if dir.len == 0: return
  app.cfg.modpackDir = dir
  app.sidebar.reload(dir, TABS[app.activeTab].toolId)
  app.worldTab.reload(dir, app.cfg.contentDir)
  app.roomsTab.reload(dir, app.cfg.contentDir)
  app.varsTab.reload(dir)

proc initModpacks(app: var App) =
  ## Scan data dir, restore last-selected modpack index.
  app.modpacks   = scanModpacks(app.cfg.dataDir)
  app.modpackIdx = 0
  for i, name in app.modpacks:
    if app.cfg.dataDir / name == app.cfg.modpackDir:
      app.modpackIdx = i
      break

# ── Layout ────────────────────────────────────────────────────────────────────
## Fixed zones (top to bottom):
##   [0 .. HEADER_H)                      — modpack selector bar
##   [HEADER_H .. HEADER_H+TAB_H)         — tab strip
##   [HEADER_H+TAB_H .. winH-STATUS_H)    — content area, split left/right
##   [winH-STATUS_H .. winH)              — status bar

proc tabStripRect(app: App): tuple[x, y, w, h: int] =
  (0, HEADER_H, app.cfg.winW, TAB_H)

proc contentRect(app: App): tuple[x, y, w, h: int] =
  let y = HEADER_H + TAB_H
  (0, y, app.cfg.winW, app.cfg.winH - y - STATUS_H)

proc sidebarRect(app: App): tuple[x, y, w, h: int] =
  let c = app.contentRect
  (c.x, c.y, SIDEBAR_W, c.h)

proc tabAreaRect(app: App): tuple[x, y, w, h: int] =
  let c = app.contentRect
  (c.x + SIDEBAR_W, c.y, c.w - SIDEBAR_W, c.h)

proc statusRect(app: App): tuple[x, y, w, h: int] =
  (0, app.cfg.winH - STATUS_H, app.cfg.winW, STATUS_H)

proc textCy(containerY, containerH, fontH: int): int =
  containerY + (containerH - fontH) div 2 - 2

# ── Rendering ─────────────────────────────────────────────────────────────────

proc drawBtn(app: var App; btn: var Btn; x, y, w, h: int; label: string;
             fg: Color = FG) =
  btn.rect = (x.cint, y.cint, w.cint, h.cint)
  btn.hot  = app.mouseX >= x and app.mouseX < x + w and
             app.mouseY >= y and app.mouseY < y + h
  app.ren.fillRect(x, y, w, h, if btn.hot: BTN_HOV else: BTN_BG)
  let lw = textWidth(app.font, label)
  renderText(app.ren, app.font, label,
             x + (w - lw) div 2, textCy(y, h, app.fontH), fg)

proc renderHeader(app: var App) =
  ## Modpack selector bar.
  let w = app.cfg.winW
  app.ren.fillRect(0, 0, w, HEADER_H, BG2)

  # "Data:" label
  let labelTxt = "Data:"
  let labelW   = textWidth(app.font, labelTxt)
  renderText(app.ren, app.font, labelTxt,
             PAD, textCy(0, HEADER_H, app.fontH), FG_DIM)

  # Modpack dropdown button
  let mpLabel = if app.modpacks.len > 0: app.modpacks[app.modpackIdx] & "  [v]"
                else: "(no modpacks found)  [v]"
  let mpBtnW = textWidth(app.font, mpLabel) + PAD * 2
  let mpBtnX = PAD + labelW + PAD
  let mpBtnY = (HEADER_H - BTN_H) div 2
  app.drawBtn(app.btnModpack, mpBtnX, mpBtnY, mpBtnW, BTN_H, mpLabel, FG_ACTIVE)

  # Data dir path (dimmed, after the button)
  if app.cfg.dataDir.len > 0:
    let pathX = mpBtnX + mpBtnW + PAD * 2
    renderText(app.ren, app.font, app.cfg.dataDir,
               pathX, textCy(0, HEADER_H, app.fontH), FG_DIM)

  # Bottom divider
  app.ren.drawHLine(0, HEADER_H - 1, w, BG3)

proc renderTabStrip(app: var App) =
  let (_, ty, tw, th) = app.tabStripRect
  app.ren.fillRect(0, ty, tw, th, BG2)

  let tabW = tw div TABS.len
  for i, t in TABS:
    let x     = i * tabW
    let isAct = i == app.activeTab
    app.ren.fillRect(x, ty, tabW, th, if isAct: TAB_ACT else: BG2)
    let lw = textWidth(app.font, t.label)
    renderText(app.ren, app.font, t.label,
               x + (tabW - lw) div 2,
               textCy(ty, th, app.fontH),
               if isAct: FG_ACTIVE else: FG)
    if isAct:
      app.ren.drawHLine(x, ty + th - 1, tabW, FG_ACTIVE)

  app.ren.drawHLine(0, ty + th - 1, tw, BG3)

proc renderStatusBar(app: App; sidebarMsg: string; sidebarOk: bool;
                     tabMsg: string; tabOk: bool) =
  let (sx, sy, sw, sh) = app.statusRect
  app.ren.fillRect(sx, sy, sw, sh, BG)
  app.ren.drawHLine(sx, sy, sw, BG3)
  renderText(app.ren, app.font, sidebarMsg,
             sx + PAD, textCy(sy, sh, app.fontH),
             if sidebarOk: FG_DIM else: FG_DEL)
  if tabMsg.len > 0:
    let tw = textWidth(app.font, tabMsg)
    renderText(app.ren, app.font, tabMsg,
               sx + sw - tw - PAD, textCy(sy, sh, app.fontH),
               if tabOk: FG_ACTIVE else: FG_DEL)

proc renderDropdown(app: var App) =
  ## Modpack dropdown popup — drawn last so it overlays everything.
  if not app.dropdownOpen or app.modpacks.len == 0: return
  let popX = app.btnModpack.rect.x.int
  let popY = HEADER_H
  let popW = max(app.btnModpack.rect.w.int, DROP_MIN_W)
  let popH = app.modpacks.len * ROW_H + 4

  app.ren.fillRect(popX, popY, popW, popH, DROP_BG)
  app.ren.drawRect(popX, popY, popW, popH, BG3)

  for i, name in app.modpacks:
    let ry  = popY + 2 + i * ROW_H
    let hot = app.mouseX >= popX and app.mouseX < popX + popW and
              app.mouseY >= ry  and app.mouseY < ry + ROW_H
    if hot or i == app.modpackIdx:
      app.ren.fillRect(popX, ry, popW, ROW_H,
                       if hot: DROP_HOV else: SEL_BG)
    let fg = if i == app.modpackIdx: FG_ACTIVE else: FG
    renderText(app.ren, app.font, name,
               popX + PAD, textCy(ry, ROW_H, app.fontH), fg)

proc render(app: var App) =
  app.ren.setColor(BG)
  discard app.ren.clear()

  app.renderHeader()
  app.renderTabStrip()

  let (sx, sy, sw, sh) = app.sidebarRect
  let (ax, ay, aw, ah) = app.tabAreaRect

  app.sidebar.render(app.ren, app.font, app.fontH, sx, sy, sw, sh,
                     TABS[app.activeTab].toolId, app.mouseX, app.mouseY)
  app.ren.drawVLine(sx + sw, sy, sh, BG3)

  case app.activeTab
  of 0: app.worldTab.render(app.ren, app.font, app.fontH, ax, ay, aw, ah,
                             app.mouseX, app.mouseY)
  of 1: app.roomsTab.render(app.ren, app.font, app.fontH, ax, ay, aw, ah,
                             app.mouseX, app.mouseY)
  of 2: app.varsTab.render(app.ren, app.font, app.fontH, ax, ay, aw, ah,
                            app.mouseX, app.mouseY)
  else: discard

  let (tabMsg, tabOk) = case app.activeTab
    of 0: (app.worldTab.statusMsg, app.worldTab.statusOk)
    of 1: (app.roomsTab.statusMsg, app.roomsTab.statusOk)
    of 2: (app.varsTab.statusMsg,  app.varsTab.statusOk)
    else: ("", true)
  app.renderStatusBar(app.sidebar.statusMsg, app.sidebar.statusOk, tabMsg, tabOk)

  # Dropdown drawn on top of everything else
  app.renderDropdown()

  app.ren.present()

# ── Input ─────────────────────────────────────────────────────────────────────

proc contains(r: Rect; x, y: int): bool =
  x >= r.x.int and x < r.x.int + r.w.int and
  y >= r.y.int and y < r.y.int + r.h.int

proc hitTab(app: App; x, y: int): int =
  let (_, ty, tw, th) = app.tabStripRect
  if y < ty or y >= ty + th: return -1
  let tabW = tw div TABS.len
  let i = x div tabW
  if i >= 0 and i < TABS.len: i else: -1

proc handleDropdownClick(app: var App; x, y: int): bool =
  ## Handle a click while the dropdown is open. Returns true if consumed.
  if not app.dropdownOpen: return false
  let popX = app.btnModpack.rect.x.int
  let popY = HEADER_H
  let popW = max(app.btnModpack.rect.w.int, DROP_MIN_W)
  let popH = app.modpacks.len * ROW_H + 4

  if x >= popX and x < popX + popW and y >= popY and y < popY + popH:
    let row = (y - popY - 2) div ROW_H
    if row >= 0 and row < app.modpacks.len:
      app.modpackIdx   = row
      app.cfg.modpackDir = app.currentModpackDir()
      app.loadModpack()
    app.dropdownOpen = false
    return true

  # Click outside — close without selecting
  app.dropdownOpen = false
  return true

proc handleMouseDown(app: var App; x, y, btn, clicks: int) =
  # Dropdown intercepts everything when open
  if app.handleDropdownClick(x, y): return

  # Header — modpack button
  if y < HEADER_H:
    if app.btnModpack.rect.contains(x, y):
      app.dropdownOpen = not app.dropdownOpen
    return

  # Tab strip
  let tab = app.hitTab(x, y)
  if tab >= 0:
    if tab != app.activeTab:
      app.activeTab     = tab
      app.cfg.activeTab = tab
      app.sidebar.reload(app.cfg.modpackDir, TABS[tab].toolId)
    return

  # Sidebar
  let (sx, _, sw, _) = app.sidebarRect
  if x >= sx and x < sx + sw:
    app.sidebar.handleMouseDown(x, y, btn,
                                app.cfg.modpackDir, TABS[app.activeTab].toolId)
    if app.sidebar.pluginsChanged:
      let created = app.sidebar.lastCreatedPath
      app.sidebar.pluginsChanged  = false
      app.sidebar.lastCreatedPath = ""
      case app.activeTab
      of 0: app.worldTab.reload(app.cfg.modpackDir, app.cfg.contentDir)
      of 1: app.roomsTab.reload(app.cfg.modpackDir, app.cfg.contentDir)
      of 2: app.varsTab.reload(app.cfg.modpackDir, created)
      else: discard
    # Sync active plugin selection for every sidebar action (Actv, Up, Down, etc.)
    case app.activeTab
    of 0: app.worldTab.reloadForPlugin(app.sidebar.activePluginPath)
    of 1: app.roomsTab.reloadForPlugin(app.sidebar.activePluginPath)
    of 2: app.varsTab.reloadForPlugin(app.sidebar.activePluginPath)
    else: discard
    return

  # Tab area
  case app.activeTab
  of 0: app.worldTab.handleMouseDown(x, y, btn, clicks, app.sidebar.activePluginPath)
  of 1: app.roomsTab.handleMouseDown(x, y, btn, app.sidebar.activePluginPath)
  of 2: app.varsTab.handleMouseDown(x, y, btn, app.sidebar.activePluginPath)
  else: discard

proc handleMouseUp(app: var App; x, y, btn: int) =
  case app.activeTab
  of 0: app.worldTab.handleMouseUp(x, y, btn)
  of 1: app.roomsTab.handleMouseUp(x, y, btn)
  of 2: app.varsTab.handleMouseUp(x, y, btn)
  else: discard

proc handleMouseMotion(app: var App; x, y: int) =
  app.mouseX = x
  app.mouseY = y
  case app.activeTab
  of 0: app.worldTab.handleMouseMotion(x, y)
  of 1: app.roomsTab.handleMouseMotion(x, y)
  of 2: app.varsTab.handleMouseMotion(x, y)
  else: discard

proc handleWheel(app: var App; dy: int) =
  if app.dropdownOpen: return
  let (sx, _, sw, _) = app.sidebarRect
  if app.mouseX >= sx and app.mouseX < sx + sw:
    app.sidebar.handleWheel(dy)
  else:
    case app.activeTab
    of 0: app.worldTab.handleWheel(dy, app.mouseX, app.mouseY)
    of 1: app.roomsTab.handleWheel(dy)
    of 2: app.varsTab.handleWheel(dy)
    else: discard

proc handleTextInput(app: var App; text: string) =
  if app.sidebar.newPluginMode:
    app.sidebar.handleTextInput(text)
    return
  case app.activeTab
  of 0: app.worldTab.handleTextInput(text)
  of 1: app.roomsTab.handleTextInput(text)
  of 2: app.varsTab.handleTextInput(text)
  else: discard

proc handleKeyDown(app: var App; sym: Scancode; ctrl, shift: bool) =
  if sym == SDL_SCANCODE_ESCAPE and app.dropdownOpen:
    app.dropdownOpen = false
    return
  if app.sidebar.newPluginMode:
    app.sidebar.handleKeyDown(sym)
    return
  case app.activeTab
  of 0: app.worldTab.handleKeyDown(sym, ctrl, shift)
  of 1: app.roomsTab.handleKeyDown(sym, ctrl, shift)
  of 2: app.varsTab.handleKeyDown(sym, ctrl, shift)
  else: discard

# ── Main ──────────────────────────────────────────────────────────────────────

proc main() =
  discard sdl2.init(INIT_VIDEO or INIT_EVENTS)
  defer: sdl2.quit()
  discard ttfInit()
  defer: ttfQuit()

  var app: App
  app.cfg       = loadConfig()
  app.activeTab = app.cfg.activeTab.clamp(0, TABS.len - 1)

  # Default data dir: <binary>/../data/
  if app.cfg.dataDir.len == 0:
    app.cfg.dataDir = normalizedPath(getAppDir() / ".." / "data")

  # Default content dir: <binary>/../content/
  if app.cfg.contentDir.len == 0:
    app.cfg.contentDir = normalizedPath(getAppDir() / ".." / "content")

  app.win = createWindow(
    "World Tools",
    SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
    app.cfg.winW.cint, app.cfg.winH.cint,
    SDL_WINDOW_SHOWN or SDL_WINDOW_RESIZABLE)
  app.ren = createRenderer(app.win, -1,
                           Renderer_Accelerated or Renderer_PresentVsync)

  app.font  = openFontMem(FONT_SIZE)
  var fw, fh: cint
  discard app.font.sizeUtf8("Ag", fw.addr, fh.addr)
  app.fontH = fh.int

  # Scan and select modpack
  app.initModpacks()
  if app.modpacks.len > 0:
    app.loadModpack()

  startTextInput()   ## enable SDL2 text input events for typing into fields

  app.running = true
  var ev = defaultEvent

  while app.running:
    while pollEvent(ev):
      case ev.kind
      of QuitEvent:
        app.running = false

      of WindowEvent:
        if ev.window.event == WindowEvent_Resized:
          app.cfg.winW = ev.window.data1.int
          app.cfg.winH = ev.window.data2.int

      of MouseMotion:
        app.handleMouseMotion(ev.motion.x.int, ev.motion.y.int)

      of MouseButtonDown:
        app.handleMouseDown(ev.button.x.int, ev.button.y.int,
                            ev.button.button.int, ev.button.clicks.int)

      of MouseButtonUp:
        app.handleMouseUp(ev.button.x.int, ev.button.y.int, ev.button.button.int)

      of MouseWheel:
        app.handleWheel(ev.wheel.y.int)

      of TextInput:
        app.handleTextInput($cast[cstring](unsafeAddr ev.text.text[0]))

      of KeyDown:
        let ctrl  = (ev.key.keysym.modstate.int and KMOD_CTRL.int)  != 0
        let shift = (ev.key.keysym.modstate.int and KMOD_SHIFT.int) != 0
        app.handleKeyDown(ev.key.keysym.scancode, ctrl, shift)

      else: discard

    app.render()

  saveConfig(app.cfg)
  destroyRenderer(app.ren)
  destroyWindow(app.win)
  close(app.font)

main()
