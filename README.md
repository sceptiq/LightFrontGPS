<div align="center">

<img src="docs/logo.png" alt="Field GPS for Lightyear Frontier" width="300">

# Field GPS for Lightyear Frontier

**Automatic lane guidance for the harvester mech — press one key and work the field.**

[![Latest release](https://img.shields.io/github/v/release/sceptiq/LightFrontGPS?label=download)](https://github.com/sceptiq/LightFrontGPS/releases/latest)
[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)

[Quick start](#quick-start) · [Usage](#usage) · [How it works](#how-it-works) · [Configuration](#configuration) · [Troubleshooting](#troubleshooting)

</div>

---

Working a field in tractor mode means holding a straight line by eye, and every degree of drift
compounds over the length of a row. This mod does it for you: it reads the actual orientation of
the field you are standing on, locks onto the row you picked, and keeps the mech on that line.

Two modes, two keys. <kbd>K</kbd> steers and leaves throttle and implement to you.
<kbd>O</kbd> runs the whole job — lowers the implement, drives, holds the lane, and puts all of it
back when you press it again.

It steers through the game's own input path — the same entry point your <kbd>A</kbd>/<kbd>D</kbd>
keys use — so tracks and animation behave normally, the physics is untouched, and movement
replicates cleanly in co-op.

## Features

- **One key for the whole job.** <kbd>O</kbd> lowers the implement, takes over the throttle and
  holds the lane. Press it again and the implement comes up, drive is cancelled, the handbrake
  catches the momentum and guidance disengages — one key instead of the usual three.
- **Or steer only.** <kbd>K</kbd> is the classic mode: guidance and nothing else. Shutdown follows
  the mode you started in, so <kbd>O</kbd> never surprises a run begun with <kbd>K</kbd>.
- **Per-field detection.** The row axis and spacing are measured from the crops actually growing
  around you, so it works on every field regardless of how it is rotated.
- **You choose the direction.** On a square field, rows and columns are equally valid. Whichever
  way you face when you engage is the one that is kept.
- **True lane keeping, not just heading.** A heading-only controller cannot tell that it is running
  parallel *beside* the row. This one regulates to a line and corrects lateral drift.
- **Hand back control any time.** Steer against the guidance and it yields, then re-engages by
  itself when you let go — so headland turns work normally.
- **Zero cost when off.** With guidance disabled the mod does not read a single game object.
- **Co-op safe.** No forced rotation, no physics injection.

Measured on a straight run: **16.8° → 0.06°** heading error with no overshoot, holding roughly
**4 cm** of lateral deviation over a 133 m pass.

## Quick start

Everything below is relative to your **game folder** — the one containing
`LightyearFrontier.exe`. On a default Steam install that is `steamapps/common/Lightyear Frontier`.

> [!IMPORTANT]
> Close the game first.

**1.** Install [UE4SS 3.x](https://github.com/UE4SS-RE/RE-UE4SS/releases) — extract it into
`FarMech/Binaries/Win64/`.

**2.** Download [the latest release](https://github.com/sceptiq/LightFrontGPS/releases/latest) and
extract it into that **same folder**. It unpacks straight to `Mods/FieldAlignGPS`.

**3.** Start the game. `FarMech/Binaries/Win64/UE4SS.log` must contain:

```
[FieldGPS] === Feld-GPS bereit ===
```

Get into the mech, switch to tractor mode, drive onto a field, face the way you want to work, and
press <kbd>O</kbd>.

> [!TIP]
> Older UE4SS builds ignore `enabled.txt` and load only what is listed in
> `FarMech/Binaries/Win64/Mods/mods.txt`. If the line above never appears, add
> `FieldAlignGPS : 1` to that file — **above** the `Keybinds` entry, which must stay last.

To uninstall, delete `Mods/FieldAlignGPS` (and the `mods.txt` line, if you added one).

## Usage

| Key | Effect |
|---|---|
| <kbd>O</kbd> | **full auto** — implement down, drive, keep the lane / undo all of it |
| <kbd>K</kbd> | **guidance only** — keep the lane, throttle and implement stay yours |
| <kbd>L</kbd> | write diagnostics to the UE4SS log |
| <kbd>F9</kbd> | reload the mod's modules without restarting the game |

Both keys stop the same way they started. In auto mode, the second press raises the implement,
cancels auto-drive, applies the handbrake against the remaining momentum and disengages guidance,
leaving the mech stopped with the tool up, ready to turn. Every part can be switched off on its
own — `LowerToolOnStart`, `AutoDriveOnStart`, `LiftToolOnStop`, `StopAutoDriveOnStop`,
`HandbrakeOnStop`.

The mech's **headlights indicate the state**: on means guidance is active. Your previous headlight
setting is remembered and restored.

Engaging prints the essentials to the log:

```
[FieldGPS] Spuranker gesetzt -- Spurabstand 150 uu
[FieldGPS] Spurhaltung an -- Spur 34 Grad (Feldfruechte (60 Stueck, Abstand 149 uu)), Abweichung 5.8 Grad
```

Guidance releases itself when you leave tractor mode or exit the mech, and yields while you steer
more than `PlayerOverrideDegrees` away from the target heading.

> [!NOTE]
> Code comments and log output are German. Everything you need to configure is documented in
> English below and in `config.lua`.

## How it works

The mech has two movement systems, and only one of them drives in tractor mode:

```
AMechCharacter
  .MovementComponent .......... UBipedalMovementComponent        walking mech
  :GetEquippedLegModule() ..... ATreadsLegModule
     .MovementComponent ....... UCustomVehicleMovementComponent  tractor mode
                                : UChaosWheeledVehicleMovementComponent, bIsTank = true
```

Steering goes to the leg module's `SetSteering(-1..1)` and is read back with `GetSteering()` on
every write, so the mod always knows whether its input actually landed. Because `bIsTank` is set,
full steering at zero throttle spins the mech in place — so steering authority scales with speed
and is disabled below a threshold.

Guidance follows the AB-line principle used by real agricultural systems. Engaging anchors a
reference line at your position along your heading; parallel lines sit one row apart. The
controller aims at a point on the line ahead of you, so the further off you are the sharper it
converges, and the approach flattens out by itself. Because it always regulates to the *nearest*
line, deliberately moving over to the next row latches there instead of dragging you back.

The field axis comes from the crops themselves. Planted crops in this game are not actors; the
`CropManager` holds them as data. The axis is averaged over every crop in range — circularly and
at four times the angle, because row directions are equivalent modulo 90° and a plain mean of 89°
and 1° would give 45°. Row spacing is the median, so one diagonal neighbour cannot drag it. A slow
realignment every 10 m rotates the line about the mech rather than the distant anchor, so
correcting the angle cannot jump the cross-track.

> [!NOTE]
> Auto-drive cannot be *started* from Lua — the action is bound natively and its handler is not
> reachable through reflection. In auto mode the mod therefore holds the throttle itself, from the
> tick, because the game rewrites it every frame. Stopping is unaffected: `StopAutoMoving()` works.

## Configuration

All settings live in
[`Mods/FieldAlignGPS/scripts/config.lua`](Mods/FieldAlignGPS/scripts/config.lua), and every one of
them is commented in place.

> [!TIP]
> UE4SS loads Lua only at game start — but you do not have to restart to try a new value. Save the
> file, copy it into the game's `Mods` folder, and press <kbd>F9</kbd>. The log must then read
> `=== Module neu geladen ===`; without that line the old values are still running.
>
> `main.lua` and `hook.lua` are deliberately excluded — they hold the key bindings and the
> per-frame hook, which cannot be withdrawn. Changes there still need a restart.

| Symptom | Setting |
|---|---|
| Oscillates around the line | raise `VehicleKd`, lower `VehicleKp` |
| Converges too slowly | raise `VehicleKp` |
| Steering feels jerky | raise `VehicleRateSmoothing`, lower `VehicleSlewPerSecond` |
| Twitches on the ideal line | raise `VehicleDeadzone` |
| Cuts in too aggressively | raise `TrackLookahead` |
| Leaves a strip at the edge of a row | lower `VehicleDeadzone` and `TrackLookahead` |
| Drifts off the line over a long pass | lower `AxisCorrectionDistance` |
| Turns while nearly stopped | raise `VehicleMinSpeed` |
| Yields to your input too easily | raise `PlayerOverrideDegrees` |
| Auto mode drives too fast | lower `AutoDriveThrottle` |
| Auto mode should not touch the implement | `LowerToolOnStart = false` |
| Auto mode should only steer | `AutoDriveOnStart = false` |
| Coasts too far after stopping | raise `StopBrakeSeconds` |
| Axis should follow the field while driving | `HoldAxisWhenLocked = false` |
| No headlight indicator wanted | `UseHeadlightIndicator = false` |
| Field not detected | raise `CropSearchRadius` |
| A key collides with another mod | `KeyLock`, `KeyAuto`, `KeyDebugDump`, `KeyReload` |

Set `VerboseTick = true` to log one controller line per frame — heading error, turn rate, steering
output and cross-track offset — or `DriftLogSeconds = 3` for one drift summary every few seconds.
Useful for tuning, but the log grows fast.

## Troubleshooting

Press <kbd>L</kbd> in game first: it reports the detected mech, the leg module with its live
steering/throttle/speed values, and which field sources are in range. Everything lands in
`FarMech/Binaries/Win64/UE4SS.log`, which is truncated on every game start.

| Message in the log | Meaning |
|---|---|
| `Nicht moeglich: kein Pawn` | you are not in the mech |
| `Nicht moeglich: nicht im Traktormodus` | switch to tractor mode first |
| `Kein Feld erkannt: ...` | no crops, plots or plants in range — drive onto the field |
| `Kein Beinmodul erreichbar` | the leg module is not exposed; usually a mid-transform frame |
| `Takt: Hook nach 30 Versuchen nicht gesetzt` | the per-frame hook failed; the mod falls back to a timer |

Nothing at all in the log means UE4SS did not load the mod — re-check step 2 and the `mods.txt`
tip above.

## Known limitations

- **No headland turns.** The mod holds a lane; it does not turn you around at the end of one.
  Steering against it hands control back, and <kbd>K</kbd> / <kbd>O</kbd> ends the run.
- **Lane spacing is the crop row spacing**, not the implement's true working width — so moving over
  to the next lane is your call, not the mod's.
- **No on-screen text.** Creating and displaying UMG widgets from Lua could not be made to work in
  this build: `DrawDebugLine` is compiled out and the game has no `AHUD` subclass. State is shown
  through the headlights instead.
- Developed against the game build dated 2026-04-15. Major updates can rename classes; the
  diagnostics on <kbd>L</kbd> report what is actually present.

## How this was built

The game has no modding API and no documentation. Everything this mod relies on was found by
dumping the game's own class layout with UE4SS (<kbd>Ctrl</kbd>+<kbd>H</kbd>) and then measuring
behaviour in game. That method leaves a mark on the code: **every write to the game is read back**,
because a call that returns successfully tells you nothing about whether it did anything.

It can be subtler than that. `GetThrottle()` looks like a readback and is not — it returns the
value you just wrote, and it read `0.0` while the mech accelerated from 519 to 974 cm/s. The honest
reading was `GetThrottleInput()` on the movement component.

Development was done with **[Claude Code](https://claude.com/claude-code)** as a pair programmer,
including the reverse engineering, the controller design and this README. Two things are worth
being explicit about, because they affect how much you should trust the code:

- The measurements quoted here are from real in-game runs, not estimates.
- Several plausible-looking approaches were tried and *measured* to be dead ends before the working
  one was found — steering the walking mech's movement component, forcing actor rotation, driving
  the physics body. [`CLAUDE.md`](CLAUDE.md) records what was ruled out and how, so the same hours
  do not get spent twice.

If you are extending this, read [`CLAUDE.md`](CLAUDE.md) first. It is written for an AI assistant
but the constraints in it apply to anyone.
