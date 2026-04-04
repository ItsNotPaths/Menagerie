## assets_tab.nim
## Assets ordering tab for the mod manager.
## Sidebar: dedicated "assets" plugins (interactive) + cross-tool plugins that
## have assets/ or scripts/ subdirs (read-only, dimmed).
## VFS is built from all enabled plugins across all tool IDs.

import sdl2
import sdl2/ttf
import std/[strutils, tables, sequtils, algorithm, os]
import plugin_db, asset_vfs
import "../theme"

# ── Layout ────────────────────────────────────────────────────────────────────

const
  SIDE_W       = 200
  TREE_PCT     = 60
  UPDATE_BTN_W = 140

# ── Helpers ───────────────────────────────────────────────────────────────────

proc textCy(containerY, containerH, fontH: int): int =
  containerY + (containerH - fontH) div 2 - 2

# ── Types ─────────────────────────────────────────────────────────────────────

type
  ABtn = object
    rect: Rect
    hot:  bool

  SidebarEntry = object
    plugin: PluginEntry
    isOwn:  bool    ## true = meta.tool = "assets" (fully interactive)
    ownIdx: int     ## index in db.plugins["assets"]; -1 for cross-tool

  TreeRowKind = enum trkSection, trkFile

  TreeRow = object
    kind:         TreeRowKind
    label:        string
    basename:     string
    isWinning:    bool
    overriddenBy: string

  AssetsAction* = enum
    aaNone, aaUpdateVFS, aaExportAll

  AssetsTab* = object
    selPluginIdx*: int        ## index into sidebarEntries; -1 = none
    sideScrollY*:  int
    treeScrollY*:  int
    selBasename*:  string
    vfs*:          AssetVFS
    vfsStale*:     bool

    # hit-test buttons (rebuilt each render)
    btnUp, btnDown, btnToggle, btnUpdateVFS, btnExportAll: ABtn

    # layout cache (rebuilt each render, read in handleClick/handleScroll)
    sideListX, sideListY, sideListW, sideListH: int
    treeX, treeAreaY, treeW, treeAreaH: int
    previewX, previewW: int

    # rebuilt each render, read in handleClick
    sidebarEntries: seq[SidebarEntry]
    treeRowCache:   seq[TreeRow]
    treeFirstRowY:  int

# ── Sidebar entry builder ─────────────────────────────────────────────────────

proc buildSidebarEntries(db: PluginDb): seq[SidebarEntry] =
  ## Dedicated "assets" plugins first (interactive), then cross-tool plugins
  ## that have an assets/ or scripts/ subfolder (dimmed, read-only).
  let ownPlugins = db.plugins.getOrDefault("assets", newSeq[PluginEntry]())
  for i, e in ownPlugins:
    result.add SidebarEntry(plugin: e, isOwn: true, ownIdx: i)

  for tid in TOOL_IDS:
    if tid == "assets": continue
    for e in db.plugins.getOrDefault(tid, newSeq[PluginEntry]()):
      if dirExists(e.folder / "assets") or dirExists(e.folder / "scripts"):
        result.add SidebarEntry(plugin: e, isOwn: false, ownIdx: -1)

# ── VFS helpers ───────────────────────────────────────────────────────────────

proc allEnabled(db: PluginDb): seq[PluginEntry] =
  for tid in TOOL_IDS:
    for e in db.plugins.getOrDefault(tid, newSeq[PluginEntry]()):
      if e.enabled: result.add e

proc initAssetsTab*(): AssetsTab =
  result.selPluginIdx = -1
  result.vfsStale     = true

proc refreshVFS*(tab: var AssetsTab; db: PluginDb) =
  ## Rebuild VFS view from all enabled plugins; does NOT clear vfsStale.
  tab.vfs = buildVFS(allEnabled(db))

proc rebuildVFS*(tab: var AssetsTab; db: PluginDb) =
  ## Rebuild VFS view and mark export as current.
  tab.vfs      = buildVFS(allEnabled(db))
  tab.vfsStale = false

# ── Button helpers ────────────────────────────────────────────────────────────

proc btnContains(b: ABtn; x, y: int): bool =
  x >= b.rect.x.int and x < b.rect.x.int + b.rect.w.int and
  y >= b.rect.y.int and y < b.rect.y.int + b.rect.h.int

proc drawABtn(ren: RendererPtr; font: FontPtr; fontH: int;
              btn: var ABtn; x, y, w, h: int; label: string;
              mx, my: int; fg: Color = FG) =
  btn.rect = (x.cint, y.cint, w.cint, h.cint)
  btn.hot  = mx >= x and mx < x + w and my >= y and my < y + h
  ren.fillRect(x, y, w, h, if btn.hot: BTN_HOV else: BTN_BG)
  let tw = font.textWidth(label)
  ren.renderText(font, label, x + (w - tw) div 2, textCy(y, h, fontH), fg)

# ── Tree row builder ──────────────────────────────────────────────────────────

type SectionDef = tuple[kind: AssetKind; label: string]

const SECTIONS: array[4, SectionDef] = [
  (akImage,  "Images"),
  (akSound,  "Sounds"),
  (akScript, "Scripts"),
  (akOther,  "Other"),
]

proc buildTreeRows(tab: AssetsTab): seq[TreeRow] =
  if tab.selPluginIdx < 0 or tab.selPluginIdx >= tab.sidebarEntries.len:
    return @[]
  let folder = tab.sidebarEntries[tab.selPluginIdx].plugin.folder

  for s in SECTIONS:
    let bns = pluginBasenames(tab.vfs, folder, s.kind)
    if bns.len == 0: continue
    result.add TreeRow(kind: trkSection, label: s.label)
    for bn in bns:
      let entry   = tab.vfs.entries.getOrDefault(bn)
      let winning = entry.winning.pluginFolder == folder
      result.add TreeRow(
        kind:         trkFile,
        label:        bn,
        basename:     bn,
        isWinning:    winning,
        overriddenBy: if winning: "" else: entry.winning.pluginName)

# ── Render ────────────────────────────────────────────────────────────────────

proc render*(tab: var AssetsTab; ren: RendererPtr; font: FontPtr; fontH: int;
             mx, my, winW, winH, contentY: int; db: PluginDb) =
  let contentH  = winH - contentY - STATUS_H
  let toolbarH  = BTN_H + PAD * 2
  let btnY      = winH - STATUS_H - PAD - BTN_H
  let rightX    = SIDE_W
  let rightW    = winW - SIDE_W
  let sideListY = contentY + ROW_H + PAD
  let sideListH = btnY - sideListY - PAD
  let sideListW = SIDE_W - PAD
  let treeAreaY = contentY + toolbarH
  let treeAreaH = winH - STATUS_H - treeAreaY
  let treeW     = rightW * TREE_PCT div 100
  let previewX  = rightX + treeW
  let previewW  = rightW - treeW

  # Cache for hit-testing
  tab.sideListX  = PAD
  tab.sideListY  = sideListY
  tab.sideListW  = sideListW
  tab.sideListH  = sideListH
  tab.treeX      = rightX
  tab.treeAreaY  = treeAreaY
  tab.treeW      = treeW
  tab.treeAreaH  = treeAreaH
  tab.previewX   = previewX
  tab.previewW   = previewW

  # Build sidebar entries (used in render + handleClick)
  tab.sidebarEntries = buildSidebarEntries(db)
  let entries = tab.sidebarEntries

  # ── Sidebar background ──────────────────────────────────────────────────────
  ren.fillRect(0, contentY, SIDE_W, contentH, BG2)
  ren.fillRect(0, contentY, SIDE_W, ROW_H, BG3)
  ren.renderText(font, "Assets Plugins", PAD,
                 textCy(contentY, ROW_H, fontH), FG_DIM)

  # ── Sidebar plugin list ─────────────────────────────────────────────────────
  let vis = max(0, sideListH div ROW_H)
  let maxSideScroll = max(0, entries.len - vis)
  if tab.sideScrollY > maxSideScroll: tab.sideScrollY = maxSideScroll

  var prevIsOwn = true
  for row in 0 ..< vis:
    let pidx = row + tab.sideScrollY
    if pidx >= entries.len: break
    let s   = entries[pidx]
    let ry  = sideListY + row * ROW_H
    let sel = pidx == tab.selPluginIdx

    # Thin separator before the first cross-tool entry
    if prevIsOwn and not s.isOwn:
      ren.fillRect(0, ry, SIDE_W, 1, BG3)
      prevIsOwn = false

    if sel:
      ren.fillRect(0, ry, SIDE_W, ROW_H, SEL_BG)
    elif row mod 2 == 1:
      ren.fillRect(0, ry, SIDE_W, ROW_H,
                   (r: 30u8, g: 30u8, b: 30u8, a: 255u8))

    let cy = textCy(ry, ROW_H, fontH)
    let dimmed = not s.plugin.enabled or not s.isOwn
    ren.renderText(font, if s.plugin.enabled: "+" else: "-", PAD, cy,
                   if s.plugin.enabled: FG_OK else: FG_DIM)
    ren.renderText(font, s.plugin.name, PAD + 16, cy,
                   if dimmed: FG_DIM else: FG)

  if entries.len == 0:
    ren.renderText(font, "(none)", PAD, sideListY + PAD, FG_DIM)

  # ── Sidebar buttons ─────────────────────────────────────────────────────────
  let bw = (SIDE_W - PAD * 2 - 4) div 3
  var bx = PAD
  let selIsOwn = tab.selPluginIdx >= 0 and
                 tab.selPluginIdx < entries.len and
                 entries[tab.selPluginIdx].isOwn
  let upFg   = if selIsOwn: FG else: FG_DIM
  let downFg = if selIsOwn: FG else: FG_DIM
  let togFg  = if selIsOwn: FG else: FG_DIM
  drawABtn(ren, font, fontH, tab.btnUp,     bx, btnY, bw, BTN_H, "^ Up",   mx, my, upFg);   bx += bw + 2
  drawABtn(ren, font, fontH, tab.btnDown,   bx, btnY, bw, BTN_H, "v Down", mx, my, downFg); bx += bw + 2
  drawABtn(ren, font, fontH, tab.btnToggle, bx, btnY, bw, BTN_H, "Toggle", mx, my, togFg)

  # ── Sidebar / content divider ────────────────────────────────────────────────
  ren.fillRect(SIDE_W, contentY, 1, contentH, BG3)

  # ── Toolbar ─────────────────────────────────────────────────────────────────
  ren.fillRect(rightX, contentY, rightW, toolbarH, BG2)
  ren.fillRect(rightX, contentY + toolbarH - 1, rightW, 1, BG3)

  let updateLabel = if tab.vfsStale: "Update VFS *" else: "Update VFS"
  let updateFg    = if tab.vfsStale: FG_DEL else: FG_ACTIVE
  drawABtn(ren, font, fontH, tab.btnUpdateVFS,
           rightX + PAD, contentY + PAD, UPDATE_BTN_W, BTN_H,
           updateLabel, mx, my, updateFg)

  let exportAllBtnX = rightX + PAD + UPDATE_BTN_W + PAD
  drawABtn(ren, font, fontH, tab.btnExportAll,
           exportAllBtnX, contentY + PAD, UPDATE_BTN_W, BTN_H,
           "Export All", mx, my)

  if tab.vfsStale:
    ren.renderText(font, "VFS out of date",
                   exportAllBtnX + UPDATE_BTN_W + PAD,
                   textCy(contentY, toolbarH, fontH), FG_DIM)

  # ── Build tree rows ─────────────────────────────────────────────────────────
  tab.treeRowCache = buildTreeRows(tab)
  let maxTreeScroll = max(0, tab.treeRowCache.len - treeAreaH div ROW_H)
  if tab.treeScrollY > maxTreeScroll: tab.treeScrollY = maxTreeScroll

  # ── Tree ─────────────────────────────────────────────────────────────────────
  ren.fillRect(rightX, treeAreaY, treeW, treeAreaH, BG)

  let treeFirstY = treeAreaY - tab.treeScrollY * ROW_H
  tab.treeFirstRowY = treeFirstY

  if tab.treeRowCache.len == 0:
    let hint = if tab.selPluginIdx < 0:
                 "Select a plugin to view its assets"
               else:
                 "No assets or scripts found in this plugin"
    ren.renderText(font, hint, rightX + PAD, treeAreaY + PAD, FG_DIM)
  else:
    for i, row in tab.treeRowCache:
      let ry = treeFirstY + i * ROW_H
      if ry + ROW_H <= treeAreaY: continue
      if ry >= treeAreaY + treeAreaH: break

      if row.kind == trkSection:
        ren.fillRect(rightX, ry, treeW, ROW_H, BG3)
        ren.renderText(font, "== " & row.label & " ==",
                       rightX + PAD, textCy(ry, ROW_H, fontH), FG_DIM)
      else:
        if row.basename == tab.selBasename:
          ren.fillRect(rightX, ry, treeW, ROW_H, SEL_BG)

        let nameColor   = if row.isWinning: FG_ACTIVE else: FG_DIM
        let statusStr   = if row.isWinning: " ^"
                          else: " -> " & row.overriddenBy
        let statusColor = if row.isWinning: FG_OK else: FG_DEL
        let nameW       = font.textWidth(row.label)

        ren.renderText(font, row.label,
                       rightX + PAD, textCy(ry, ROW_H, fontH), nameColor)
        ren.renderText(font, statusStr,
                       rightX + PAD + nameW + 4,
                       textCy(ry, ROW_H, fontH), statusColor)

  # ── Tree / preview divider ───────────────────────────────────────────────────
  ren.fillRect(previewX, treeAreaY, 1, treeAreaH, BG3)

  # ── Preview ──────────────────────────────────────────────────────────────────
  ren.fillRect(previewX + 1, treeAreaY, previewW - 1, treeAreaH, BG2)

  let px = previewX + PAD
  var py = treeAreaY + PAD

  if tab.selBasename.len > 0 and tab.vfs.entries.hasKey(tab.selBasename):
    let entry = tab.vfs.entries[tab.selBasename]

    ren.renderText(font, tab.selBasename, px, py, FG_ACTIVE)
    py += fontH + 6

    let kindStr = case entry.kind
      of akImage:  "[image]"
      of akSound:  "[sound]"
      of akScript: "[script]"
      of akOther:  "[file]"
    ren.renderText(font, kindStr, px, py, FG_DIM)
    py += fontH + 12

    let selFolder =
      if tab.selPluginIdx >= 0 and tab.selPluginIdx < entries.len:
        entries[tab.selPluginIdx].plugin.folder
      else: ""

    if selFolder.len > 0:
      if entry.winning.pluginFolder == selFolder:
        ren.renderText(font, "Winning ^", px, py, FG_OK)
      else:
        ren.renderText(font, "Overridden by:", px, py, FG_DIM)
        py += fontH + 4
        ren.renderText(font, entry.winning.pluginName, px + PAD, py, FG_DEL)
    else:
      let statusText =
        if entry.allProviders.len > 1: "Winner: " & entry.winning.pluginName
        else: "Unique"
      ren.renderText(font, statusText, px, py, FG_DIM)

    py += fontH + 12
    ren.renderText(font, "Path:", px, py, FG_DIM)
    py += fontH + 4
    var fp = entry.winning.fullPath
    let maxW = previewW - PAD * 2
    while fp.len > 4 and font.textWidth(fp) > maxW:
      fp = "..." & fp[fp.len div 3 .. ^1]
    ren.renderText(font, fp, px, py, FG_DIM)
  else:
    let hint = if tab.selPluginIdx < 0: "Select a plugin"
               else: "Select a file"
    ren.renderText(font, hint, px, py, FG_DIM)

# ── Event handling ────────────────────────────────────────────────────────────

proc handleClick*(tab: var AssetsTab; x, y: int; db: var PluginDb;
                  outStatus: var string; outOk: var bool): AssetsAction =
  ## outStatus/outOk are set for mutations that don't trigger a full export.
  ## The caller should display them via the window status bar.
  let entries = tab.sidebarEntries

  # Sidebar plugin list
  if x >= tab.sideListX and x < tab.sideListX + tab.sideListW and
     y >= tab.sideListY and y < tab.sideListY + tab.sideListH:
    let row = (y - tab.sideListY) div ROW_H + tab.sideScrollY
    if row >= 0 and row < entries.len:
      tab.selPluginIdx = row
      tab.selBasename  = ""
    return aaNone

  # Sidebar buttons — only act for own (interactive) plugins
  let selIsOwn = tab.selPluginIdx >= 0 and
                 tab.selPluginIdx < entries.len and
                 entries[tab.selPluginIdx].isOwn

  if btnContains(tab.btnUp, x, y) and selIsOwn:
    let oi = entries[tab.selPluginIdx].ownIdx
    if oi > 0:
      db.moveUp("assets", oi)
      dec tab.selPluginIdx
      tab.refreshVFS(db)
      tab.vfsStale = true
      outStatus = "Load order saved  —  VFS out of date, click Update VFS"
      outOk = true
    return aaNone

  if btnContains(tab.btnDown, x, y) and selIsOwn:
    let oi    = entries[tab.selPluginIdx].ownIdx
    let ownCt = db.plugins.getOrDefault("assets", newSeq[PluginEntry]()).len
    if oi < ownCt - 1:
      db.moveDown("assets", oi)
      inc tab.selPluginIdx
      tab.refreshVFS(db)
      tab.vfsStale = true
      outStatus = "Load order saved  —  VFS out of date, click Update VFS"
      outOk = true
    return aaNone

  if btnContains(tab.btnToggle, x, y) and selIsOwn:
    let oi = entries[tab.selPluginIdx].ownIdx
    db.toggleEnabled("assets", oi)
    tab.refreshVFS(db)
    tab.vfsStale = true
    let name  = entries[tab.selPluginIdx].plugin.name
    # db was mutated, so read the new state from db rather than stale entries
    let nowOn = db.plugins.getOrDefault("assets", newSeq[PluginEntry]())[oi].enabled
    let state = if nowOn: "enabled" else: "disabled"
    outStatus = name & " " & state & "  —  VFS out of date, click Update VFS"
    outOk = true
    return aaNone

  if btnContains(tab.btnUpdateVFS, x, y): return aaUpdateVFS
  if btnContains(tab.btnExportAll, x, y): return aaExportAll

  # Tree file rows
  if x >= tab.treeX and x < tab.treeX + tab.treeW and
     y >= tab.treeAreaY and y < tab.treeAreaY + tab.treeAreaH:
    let rowIdx = (y - tab.treeFirstRowY) div ROW_H
    if rowIdx >= 0 and rowIdx < tab.treeRowCache.len:
      let row = tab.treeRowCache[rowIdx]
      if row.kind == trkFile:
        tab.selBasename = row.basename

  return aaNone

proc handleScroll*(tab: var AssetsTab; x, y, dy: int) =
  if x < SIDE_W:
    tab.sideScrollY = max(0, tab.sideScrollY + dy)
  else:
    tab.treeScrollY = max(0, tab.treeScrollY + dy)
