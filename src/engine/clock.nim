## engine/clock.nim
## ─────────────────
## Tick system. passTicks(state, n) is called after every command and drives
## all time-dependent systems: effect tick-down, hunger/stamina regen,
## schedule boundary checks.
##
## 240 ticks = 1 day. 1 tick = 6 minutes.

import std/[sequtils, strformat]
import engine/state
import engine/gameplay_vars

const
  ticksPerDay*  = 240
  ticksPerHour* = 10    ## 1 tick = 6 min → 10 ticks = 1 hour
  scheduleSlot* = 10    ## NPC schedules re-evaluated every N ticks

const
  fatigueMin = -100.0
  hungerMax  =  100.0


proc dayTick*(state: GameState): int =
  ## Current tick within the day (0–239).
  state.player.tick mod ticksPerDay


proc timeOfDay*(state: GameState): string =
  ## Human-readable 12-hour time, e.g. "2:30 PM".
  let dt     = dayTick(state)
  let hour   = dt div ticksPerHour
  let minute = (dt mod ticksPerHour) * 6
  let suffix = if hour < 12: "AM" else: "PM"
  let h12    = if hour mod 12 == 0: 12 else: hour mod 12
  &"{h12}:{minute:02d} {suffix}"


proc fatiguePenalty*(state: GameState): float =
  ## 0.0–1.0 cap penalty from fatigue; 0.0 when fatigue >= 0.
  max(0.0, -state.player.fatigue / 100.0)


proc hungerPenalty*(state: GameState): float =
  ## 0.0–1.0 cap penalty from hunger; 0.0 when hunger is above threshold.
  let threshold = gvFloat("hunger_penalty_threshold", 25.0)
  let h = state.player.hunger
  if h >= threshold: return 0.0
  1.0 - (h / threshold)


proc effectiveStatCap*(state: GameState; baseCap: float): float =
  ## Apply fatigue and hunger penalties to a stat's maximum.
  let fatRed = gvFloat("fatigue_stat_cap_reduction", 0.5)
  let hunRed = gvFloat("hunger_stat_cap_reduction", 0.25)
  let penalty = fatiguePenalty(state) * fatRed + hungerPenalty(state) * hunRed
  baseCap * (1.0 - min(1.0, penalty))


proc passTicks*(state: var GameState; n: int) =
  ## Advance time by n ticks and run all time-dependent subsystems.
  let prev = state.player.tick
  state.player.tick += n

  # Tick down temporary effects (ticksRemaining < 0 = permanent — kept forever).
  for e in state.player.effects.mitems:
    if e.ticksRemaining > 0:
      e.ticksRemaining = max(0, e.ticksRemaining - n)
  state.player.effects.keepIf(proc(e: ActiveEffect): bool = e.ticksRemaining != 0)

  # Hunger drain
  let hungerRate = gvFloat("hunger_drain_per_tick", hungerMax / float(ticksPerDay))
  state.player.hunger = max(0.0, state.player.hunger - hungerRate * float(n))

  # Stamina regen
  let stamRate = gvFloat("player_regen_stamina", 20.0)
  let stamCap  = effectiveStatCap(state, state.player.maxStamina)
  state.player.stamina = min(stamCap, state.player.stamina + stamRate * float(n))

  # Fatigue drain
  let fatRate = gvFloat("fatigue_drain_per_tick", 100.0 / float(ticksPerDay))
  state.player.fatigue = max(fatigueMin, state.player.fatigue - fatRate * float(n))

  # Clamp all stats to effective caps
  state.player.health  = min(state.player.health,  effectiveStatCap(state, state.player.maxHealth))
  state.player.stamina = min(state.player.stamina, effectiveStatCap(state, state.player.maxStamina))
  state.player.focus   = min(state.player.focus,   effectiveStatCap(state, state.player.maxFocus))

  # NPC schedule reload if a slot boundary was crossed
  if (prev div scheduleSlot) != (state.player.tick div scheduleSlot):
    discard  # TODO Phase 7: re-evaluate NPC schedules
