## engine/skills.nim
## ─────────────────
## Skill system: flat integer values 0–SKILL_CAP stored in PlayerState.skills.
##
## Level-up flow
## ─────────────
##   Content calls:    give_xp player <amount>   (via api.runCommand)
##   When xp >= XP_PER_LEVEL: level++, xp wraps, pending picks awarded.
##   Player resolves:  levelup_skill <name>  /  levelup_stat <stat>
##                     (cmd_universal.nim — Phase 10)
##
## Skill → mechanic hooks (all via skillPct → 0.0–1.0)
## ─────────────────────────────────────────────────────
##   longblade/shortblade/longblunt/shortblunt  melee damage multiplier (combat)
##   archery          ranged damage (future)
##   block            block_reduction derivation (combat)
##   heavy_armor      armor defense scaling (future)
##   light_armor      armor defense scaling (future)
##   destruction      spell damage multiplier (combat)
##   alteration       aux spell params (future)
##   restoration      healing magnitude (future)
##   sneak            detection roll (sneak)
##   pickpocket       pickpocket roll (sneak)
##   mercantile       buy/sell price spread (economy)
##   speech           rep gain magnitude (future)

import std/[random, strformat, strutils, tables]
import state
import modifiers as mods

# ── Constants ─────────────────────────────────────────────────────────────────

const
  SKILL_CAP*    = 100
  XP_PER_LEVEL* = 1000
  SKILL_BUMP*   = 1      ## awarded skill increases per level-up skill pick
  STAT_BUMP*    = 10.0   ## max resource increase per stat pick

const SKILL_NAMES*: seq[string] = @[
  "longblade", "shortblade", "longblunt", "shortblunt", "archery",
  "block", "heavy_armor", "light_armor",
  "destruction", "alteration", "restoration",
  "sneak", "pickpocket", "mercantile", "speech",
]

const STAT_OPTIONS* = ["health", "stamina", "focus"]


# ── Internal helpers ──────────────────────────────────────────────────────────

func toTitleCase*(s: string): string =
  for word in s.split('_'):
    if result.len > 0: result.add ' '
    if word.len > 0:
      result.add toUpperAscii(word[0])
      result.add word[1..^1]


# ── Accessors ─────────────────────────────────────────────────────────────────

proc skillVal*(state: GameState; name: string): int =
  ## Current skill value (0–SKILL_CAP).
  state.player.skills.getOrDefault(name, 0)

proc skillPct*(state: GameState; name: string): float =
  ## Skill as a 0.0–1.0 fraction of SKILL_CAP.
  skillVal(state, name).float / SKILL_CAP.float


# ── Mutation ──────────────────────────────────────────────────────────────────

proc trainSkill*(state: var GameState; name: string; amount: int) =
  ## Directly increment a skill by amount, clamped to SKILL_CAP.
  ## Called by trainer dialogue and book on_use_commands.
  if name notin SKILL_NAMES: return
  let current = state.player.skills.getOrDefault(name, 0)
  state.player.skills[name] = min(SKILL_CAP, current + max(0, amount))


# ── Level-up prompts ──────────────────────────────────────────────────────────

proc skillPickPrompt*(state: GameState): seq[string] =
  result.add "  Choose a skill to improve:"
  for s in SKILL_NAMES:
    result.add &"    [[{toTitleCase(s)} ({skillVal(state, s)}):levelup_skill {s}]]"

proc statPickPrompt*(state: GameState): seq[string] =
  let p = state.player
  result.add "  Choose a stat to improve:"
  for s in STAT_OPTIONS:
    let (cur, mx) = case s
      of "health":  (int(p.health),  int(p.maxHealth))
      of "stamina": (int(p.stamina), int(p.maxStamina))
      else:         (int(p.focus),   int(p.maxFocus))
    result.add &"    [[{toTitleCase(s)} ({cur}/{mx}):levelup_stat {s}]]"

proc perkPickPrompt*(): seq[string] =
  result.add "  A perk pick is available. Use [[perks]] to view active perks."
  result.add "  Grant a perk:  levelup_perk <perk_id>"


# ── XP / level-up ─────────────────────────────────────────────────────────────

proc skillRoll*(state: GameState; names: varargs[string]): bool =
  ## Roll success against one or more skills. Returns true = success.
  ## threshold = sum(skills) / (SKILL_CAP × count)
  ## Missing skills default to 0. Requires randomize() at game start.
  var total = 0
  for n in names:
    total += skillVal(state, n)
  let denom = SKILL_CAP * max(1, names.len)
  rand(1.0) < (total.float / denom.float)


proc giveXp*(state: var GameState; amount: float): seq[string] =
  ## Award XP. Triggers one or more level-ups if threshold crossed.
  ## Returns narration lines including pick prompts.
  ## modifier "xp_gain_pct": positive value = more XP per award (e.g. 0.2 → +20%)
  state.player.xp += amount * mods.modifierGet(state, "xp_gain_pct")
  while state.player.xp >= XP_PER_LEVEL.float:
    state.player.xp         -= XP_PER_LEVEL.float
    state.player.level      += 1
    state.player.pendingSkillPicks += 1
    state.player.pendingStatPicks  += 1
    state.player.pendingPerkPicks  += 1
    result.add &"  Level {state.player.level}!"
    result &= mods.fireEvent(state, "level_up", "player")
  if state.player.pendingSkillPicks > 0:
    result.add "  Skill pick available — open [[skills]] to choose."
  if state.player.pendingPerkPicks > 0:
    result.add ""
    result &= perkPickPrompt()
