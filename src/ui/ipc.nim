## ui/ipc.nim
## ──────────
## Typed inter-thread channels between the game logic thread and the SDL2 UI.
## Requires --mm:orc (channels pass heap types between threads).
##
## Open both channels before starting the game thread.
## UI thread polls toUi.tryRecv each frame.
## Game thread blocks on toGame.recv.

type
  UiMsgKind* = enum
    umPrint,         ## append one line to the scrollback
    umLoadLocation,  ## load a new background image into the left panel
    umRenderSprites, ## render overlay sprites on the left panel
    umStats,         ## replace HUD stats ("Label: value" strings)
    umPanelReplace,  ## replace scrollback with fixed panel lines
    umPanelAppend    ## append lines to the scrollback panel

  SpriteEntry* = object
    path*:    string
    nx*, ny*: float   ## normalised position [0,1] within the left panel

  UiMsg* = object
    case kind*: UiMsgKind
    of umPrint:
      line*: string
      tag*:  string         ## reserved for colour tags (unused in Phase 3)
    of umLoadLocation:
      imgPath*: string
    of umRenderSprites:
      sprites*: seq[SpriteEntry]
    of umStats:
      statLines*: seq[string]   ## "Label: value" — one per HUD row
    of umPanelReplace:
      replaceLines*: seq[string]
    of umPanelAppend:
      appendLines*: seq[string]

  GameMsgKind* = enum gmInput
  GameMsg* = object
    case kind*: GameMsgKind
    of gmInput:
      raw*: string

var
  toUi*:   Channel[UiMsg]
  toGame*: Channel[GameMsg]
