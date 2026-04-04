## theme.nim
## Shared visual constants for world-tools binaries (mod_manager, tools applet).
## Import as:  import "../theme"  from any subdirectory under world-tools/.
##
## Color is sdl2's named tuple (r, g, b, a: uint8), re-exported here so
## callers don't need a separate sdl2 import just for the type.

import sdl2
import sdl2/ttf
export Color   ## re-export sdl2.Color so importers of theme have it in scope

# ── Palette ───────────────────────────────────────────────────────────────────

const
  BG*        : Color = (r: 17'u8,  g: 17'u8,  b: 17'u8,  a: 255'u8)
  BG2*       : Color = (r: 26'u8,  g: 26'u8,  b: 26'u8,  a: 255'u8)
  BG3*       : Color = (r: 46'u8,  g: 46'u8,  b: 46'u8,  a: 255'u8)
  FG*        : Color = (r: 204'u8, g: 204'u8, b: 204'u8, a: 255'u8)
  FG_DIM*    : Color = (r: 85'u8,  g: 85'u8,  b: 85'u8,  a: 255'u8)
  FG_ACTIVE* : Color = (r: 212'u8, g: 201'u8, b: 168'u8, a: 255'u8)
  FG_GREEN*  : Color = (r: 102'u8, g: 204'u8, b: 136'u8, a: 255'u8)
  FG_RED*    : Color = (r: 204'u8, g: 102'u8, b: 102'u8, a: 255'u8)
  FG_OK*     : Color = FG_GREEN   ## positive actions (save, create, add)
  FG_DEL*    : Color = FG_RED     ## destructive actions (delete, remove)
  FG_MASTER* : Color = (r: 255'u8, g: 204'u8, b: 102'u8, a: 255'u8)
  SEL_BG*    : Color = (r: 55'u8,  g: 55'u8,  b: 55'u8,  a: 255'u8)
  BTN_BG*    : Color = (r: 58'u8,  g: 58'u8,  b: 58'u8,  a: 255'u8)
  BTN_HOV*   : Color = (r: 74'u8,  g: 74'u8,  b: 74'u8,  a: 255'u8)
  TAB_ACT*   : Color = (r: 52'u8,  g: 52'u8,  b: 52'u8,  a: 255'u8)
  DROP_BG*   : Color = (r: 36'u8,  g: 36'u8,  b: 36'u8,  a: 255'u8)
  DROP_HOV*  : Color = (r: 55'u8,  g: 55'u8,  b: 55'u8,  a: 255'u8)

  ## Tile type colours (world editor)
  TILE_ROAD*       : Color = (r: 176'u8, g: 160'u8, b: 128'u8, a: 255'u8)
  TILE_CROSSROADS* : Color = (r: 212'u8, g: 188'u8, b: 130'u8, a: 255'u8)
  TILE_TOWN*       : Color = (r: 48'u8,  g: 96'u8,  b: 176'u8, a: 255'u8)
  TILE_DUNGEON*    : Color = (r: 96'u8,  g: 48'u8,  b: 160'u8, a: 255'u8)

  ## Category colours (room editor)
  CAT_RUINS*    : Color = (r: 176'u8, g: 120'u8, b: 48'u8,  a: 255'u8)
  CAT_DUNGEONS* : Color = (r: 112'u8, g: 48'u8,  b: 160'u8, a: 255'u8)
  CAT_TOWNS*    : Color = (r: 48'u8,  g: 96'u8,  b: 176'u8, a: 255'u8)

  ## Sprite canvas marker colours
  MARKER_IDLE* : Color = (r: 68'u8,  g: 170'u8, b: 255'u8, a: 255'u8)
  MARKER_DRAG* : Color = (r: 255'u8, g: 204'u8, b: 68'u8,  a: 255'u8)

# ── Layout ────────────────────────────────────────────────────────────────────

const
  FONT_SIZE* = 14
  ROW_H*     = 22
  BTN_H*     = 26
  PAD*       = 10
  STATUS_H*  = 24
  TAB_H*     = 30
  SIDEBAR_W* = 200

# ── Font data ─────────────────────────────────────────────────────────────────

const FONT_DATA* = staticRead("../vendor/fonts/SpaceMono-Regular.ttf")

# ── SDL2 helpers ──────────────────────────────────────────────────────────────

proc setColor*(renderer: RendererPtr; c: Color) =
  discard renderer.setDrawColor(c.r, c.g, c.b, c.a)

proc fillRect*(renderer: RendererPtr; x, y, w, h: int; c: Color) =
  renderer.setColor(c)
  var r = sdl2.rect(x.cint, y.cint, w.cint, h.cint)
  discard renderer.fillRect(r)

proc drawRect*(renderer: RendererPtr; x, y, w, h: int; c: Color) =
  renderer.setColor(c)
  var r = sdl2.rect(x.cint, y.cint, w.cint, h.cint)
  discard renderer.drawRect(r)

proc drawHLine*(renderer: RendererPtr; x, y, w: int; c: Color) =
  renderer.setColor(c)
  discard renderer.drawLine(x.cint, y.cint, (x + w).cint, y.cint)

proc drawVLine*(renderer: RendererPtr; x, y, h: int; c: Color) =
  renderer.setColor(c)
  discard renderer.drawLine(x.cint, y.cint, x.cint, (y + h).cint)

proc renderText*(renderer: RendererPtr; font: FontPtr; text: string;
                 x, y: int; c: Color) =
  if text.len == 0: return
  let surf = font.renderUtf8Blended(text.cstring, c)
  if surf.isNil: return
  let tex = renderer.createTextureFromSurface(surf)
  freeSurface(surf)
  if tex.isNil: return
  var tw, th: cint
  queryTexture(tex, nil, nil, tw.addr, th.addr)
  var dst = sdl2.rect(x.cint, y.cint, tw, th)
  discard renderer.copy(tex, nil, dst.addr)
  destroyTexture(tex)

proc textWidth*(font: FontPtr; text: string): int =
  var w, h: cint
  discard font.sizeUtf8(text.cstring, w.addr, h.addr)
  result = w.int

proc openFontMem*(size: int = FONT_SIZE): FontPtr =
  ## Open the embedded SpaceMono font at the given point size.
  let rw = rwFromConstMem(FONT_DATA.cstring, FONT_DATA.len.cint)
  result = openFontRW(rw, 1, size.cint)
