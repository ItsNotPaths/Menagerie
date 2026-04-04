## room_data.nim
## Room preset constants for the room editor.
## Port of world-tools-py/room-editor/room_data.py

import "../theme"

const
  ROOM_TYPES* = [
    "dungeon_entrance", "combat", "rest", "town", "road", "wilderness"
  ]

  CATEGORIES* = ["ruins", "dungeons", "towns"]

  CATEGORY_COLORS*: array[3, tuple[name: string, color: Color]] = [
    (name: "ruins",    color: CAT_RUINS),
    (name: "dungeons", color: CAT_DUNGEONS),
    (name: "towns",    color: CAT_TOWNS),
  ]

proc categoryColor*(category: string): Color =
  for c in CATEGORY_COLORS:
    if c.name == category: return c.color
  result = FG_DIM  ## fallback
