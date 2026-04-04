## sprite_canvas.nim
## SDL2 overlay for editing sprite_positions in room presets.
## Rendered as a full tab-area overlay (not a separate OS window).
## State lives in rooms_tab as a SpriteCanvas sub-object.

import sdl2
import sdl2/image as sdlImg
import sdl2/ttf
import "../theme"

type
  SpritePos* = array[2, float32]

  SpriteCanvas* = object
    open*:       bool
    positions*:  seq[SpritePos]
    dragIdx*:    int            ## -1 = none
    bgTexture*:  TexturePtr
    bgFilename*: string
    ## Set each render pass; read by input handlers
    canvasX*, canvasY*, canvasW*, canvasH*: int
    okRect*:       tuple[x, y, w, h: int]
    cancelRect*:   tuple[x, y, w, h: int]
    clearAllRect*: tuple[x, y, w, h: int]

const
  MARKER_R* = 10
  HIT_R*    = 15

proc openCanvas*(sc: var SpriteCanvas; positions: seq[SpritePos]) =
  sc.open      = true
  sc.positions = positions
  sc.dragIdx   = -1

proc loadBg*(sc: var SpriteCanvas; ren: RendererPtr; path: string) =
  ## Load background image if path changed. No-op when filename is unchanged.
  if path == sc.bgFilename: return
  if not sc.bgTexture.isNil:
    destroyTexture(sc.bgTexture)
    sc.bgTexture = nil
  sc.bgFilename = path
  if path.len > 0:
    let surf = sdlImg.load(path.cstring)
    if not surf.isNil:
      sc.bgTexture = ren.createTextureFromSurface(surf)
      freeSurface(surf)

proc markerScreen(sc: SpriteCanvas; i: int): tuple[x, y: int] =
  let p = sc.positions[i]
  (x: sc.canvasX + int(p[0] * sc.canvasW.float32),
   y: sc.canvasY + int(p[1] * sc.canvasH.float32))

proc hitTest*(sc: SpriteCanvas; mx, my: int): int =
  ## Return index of nearest marker within HIT_R, or -1.
  result = -1
  var best = HIT_R * HIT_R + 1
  for i in 0 ..< sc.positions.len:
    let s  = sc.markerScreen(i)
    let d2 = (mx - s.x) * (mx - s.x) + (my - s.y) * (my - s.y)
    if d2 < best:
      best   = d2
      result = i

proc render*(sc: var SpriteCanvas; ren: RendererPtr; font: FontPtr; fontH,
             tabX, tabY, tabW, tabH, mx, my: int) =
  if not sc.open: return

  ren.fillRect(tabX, tabY, tabW, tabH, BG)

  ## Toolbar
  let toolY = tabY + PAD
  var bx    = tabX + PAD

  template scBtn(label: string; rect: untyped; fg: Color) =
    let bw  = textWidth(font, label) + PAD * 2
    let hot = mx >= bx and mx < bx + bw and my >= toolY and my < toolY + BTN_H
    ren.fillRect(bx, toolY, bw, BTN_H, if hot: BTN_HOV else: BTN_BG)
    renderText(ren, font, label, bx + PAD, toolY + (BTN_H - fontH) div 2 - 2, fg)
    rect = (bx, toolY, bw, BTN_H)
    bx  += bw + 4

  scBtn("OK",        sc.okRect,       FG_OK)
  scBtn("Cancel",    sc.cancelRect,   FG)
  scBtn("Clear All", sc.clearAllRect, FG_DEL)
  renderText(ren, font,
    "  left-click: add  |  drag: move  |  right-click: remove",
    bx, toolY + (BTN_H - fontH) div 2 - 2, FG_DIM)

  ## Canvas area
  sc.canvasX = tabX + PAD
  sc.canvasY = toolY + BTN_H + PAD
  sc.canvasW = tabW - PAD * 2
  sc.canvasH = tabH - (sc.canvasY - tabY) - PAD

  if not sc.bgTexture.isNil:
    var dst = sdl2.rect(sc.canvasX.cint, sc.canvasY.cint,
                        sc.canvasW.cint, sc.canvasH.cint)
    discard ren.copy(sc.bgTexture, nil, dst.addr)
  else:
    ren.fillRect(sc.canvasX, sc.canvasY, sc.canvasW, sc.canvasH,
                 (r: 10'u8, g: 10'u8, b: 10'u8, a: 255'u8))
    let msg = if sc.bgFilename.len > 0: "Image not found: " & sc.bgFilename
              else: "(no image assigned — set one in the image field)"
    renderText(ren, font, msg, sc.canvasX + PAD, sc.canvasY + PAD, FG_DIM)

  ren.drawRect(sc.canvasX, sc.canvasY, sc.canvasW, sc.canvasH, BG3)

  ## Markers
  for i in 0 ..< sc.positions.len:
    let s   = sc.markerScreen(i)
    let col = if i == sc.dragIdx: MARKER_DRAG else: MARKER_IDLE
    ren.fillRect(s.x - MARKER_R, s.y - MARKER_R, MARKER_R * 2, MARKER_R * 2, col)
    ren.drawRect(s.x - MARKER_R, s.y - MARKER_R, MARKER_R * 2, MARKER_R * 2, BG)
    let label = $(i + 1)
    let lw    = textWidth(font, label)
    renderText(ren, font, label, s.x - lw div 2, s.y - fontH div 2 - 2, BG)

proc handleMouseDown*(sc: var SpriteCanvas; mx, my, btn: int) =
  if not sc.open: return
  if my < sc.canvasY or my >= sc.canvasY + sc.canvasH: return
  if mx < sc.canvasX or mx >= sc.canvasX + sc.canvasW: return
  if btn == 3:
    let hit = sc.hitTest(mx, my)
    if hit >= 0: sc.positions.delete(hit)
  elif btn == 1:
    let hit = sc.hitTest(mx, my)
    if hit >= 0:
      sc.dragIdx = hit
    else:
      let nx = (mx - sc.canvasX).float32 / sc.canvasW.float32
      let ny = (my - sc.canvasY).float32 / sc.canvasH.float32
      sc.positions.add [nx.clamp(0'f32, 1'f32), ny.clamp(0'f32, 1'f32)]
      sc.dragIdx = sc.positions.len - 1

proc handleMouseUp*(sc: var SpriteCanvas) =
  sc.dragIdx = -1

proc handleMouseMotion*(sc: var SpriteCanvas; mx, my: int) =
  if not sc.open or sc.dragIdx < 0: return
  if sc.dragIdx >= sc.positions.len: sc.dragIdx = -1; return
  let nx = (mx - sc.canvasX).float32 / sc.canvasW.float32
  let ny = (my - sc.canvasY).float32 / sc.canvasH.float32
  sc.positions[sc.dragIdx] = [nx.clamp(0'f32, 1'f32), ny.clamp(0'f32, 1'f32)]
