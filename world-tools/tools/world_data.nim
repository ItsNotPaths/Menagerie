## world_data.nim
## Tile type constants for the world editor.
## Port of world-tools-py/world-editor/world_data.py

import "../theme"

const
  TILE_TYPES* = ["road", "crossroads", "town", "dungeon"]

  ## Display colors per tile type — matches theme.nim tile color constants.
  TILE_COLORS*: array[4, tuple[name: string, color: Color]] = [
    (name: "road",       color: TILE_ROAD),
    (name: "crossroads", color: TILE_CROSSROADS),
    (name: "town",       color: TILE_TOWN),
    (name: "dungeon",    color: TILE_DUNGEON),
  ]

proc tileColor*(tileType: string): Color =
  for t in TILE_COLORS:
    if t.name == tileType: return t.color
  result = TILE_ROAD  ## fallback
