<div align="center">

# Field GPS for Lightyear Frontier

**Automatic lane guidance for the harvester mech — press one key and drive straight rows.**

[Features](#features) · [How it works](#how-it-works) · [Requirements](#requirements) · [Install](#install) · [Usage](#usage) · [Configuration](#configuration) · [Troubleshooting](#troubleshooting)

</div>

---

Working a field in tractor mode means holding a straight line by eye, and every degree of drift
compounds over the length of a row. This mod does the steering for you: it reads the actual
orientation of the field you are standing on, locks onto the row you picked, and keeps the mech
on that line while you drive.

It steers through the game's own input path — the same entry point your <kbd>A</kbd>/<kbd>D</kbd>
keys use — so tracks and animation behave normally, the physics is untouched, and movement
replicates cleanly in co-op.

## Features

- **One key.** <kbd>K</kbd> toggles lane keeping. Nothing else to learn.
- **Per-field detection.** The row axis and row spacing are measured from the crops actually
  growing around you, so it works on every field regardless of how it is rotated.
- **You choose the direction.** On a square field, rows and columns are equally valid. Whichever
  way you are facing when you engage is the one that is kept — the axis freezes at that moment.
- **True lane keeping, not just heading.** A heading-only controller cannot tell that it is
  running parallel *beside* the row. This one regulates to a line and corrects lateral drift.
- **Hand back control any time.** Steer against the guidance and it yields, then re-engages by
  itself when you let go — so headland turns work normally.
- **Zero cost when off.** With lane keeping disabled the mod does not read a single game object.
- **Co-op safe.** No forced rotation, no physics injection.

Measured on a straight run: **16.8° → 0.06°** heading error with no overshoot, holding roughly
**4 cm** of lateral deviation.

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
every write, so the mod always knows whether its input actually landed.

Because `bIsTank` is set, full steering at zero throttle spins the mech in place. Steering
authority therefore scales with speed and is disabled below a threshold.

Guidance follows the AB-line principle used by real agricultural systems. Engaging lane keeping
anchors a reference line at your current position along your current heading; parallel lines sit
one row apart. The controller aims at a point on the line ahead of you, so the further you are
off, the sharper it converges — and the approach flattens out by itself. Because it always
regulates to the *nearest* line, deliberately moving over to the next row latches there instead
of dragging you back.

The field axis comes from the crops themselves. Planted crops in this game are not actors; the
`CropManager` holds them as data. The mod queries the crops around the mech and derives the axis
and row spacing from their geometry, which is immune to individual plants being randomly rotated.
Mound plots and plant actors serve as fallbacks where no crops are readable.

## Requirements

- **Lightyear Frontier** (developed against Unreal Engine 4.27.2)
- **[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) 3.x**

> [!NOTE]
> The game ships unencrypted, unsigned packages and runs no anti-cheat, so UE4SS works without
> any special handling.

## Install

All paths below are relative to your **game folder** — the directory containing
`LightyearFrontier.exe`. On a default Steam install that is
`steamapps/common/Lightyear Frontier`.

> [!IMPORTANT]
> Close the game before installing.

**1. Install UE4SS** (skip if you already have it)

Download the latest `UE4SS_v3.x.x.zip` from the
[UE4SS releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases) and extract its contents
into:

```
FarMech/Binaries/Win64/
```

That folder should then contain `dwmapi.dll`, `UE4SS.dll`, `UE4SS-settings.ini` and a `Mods/`
directory.

**2. Install the mod**

Copy the `Mods/FieldAlignGPS` folder from this repository into UE4SS's mods directory:

```
FarMech/Binaries/Win64/Mods/FieldAlignGPS/
```

The result must look like this:

```
FarMech/Binaries/Win64/Mods/FieldAlignGPS/
├── enabled.txt
└── scripts/
    ├── config.lua
    ├── field.lua
    ├── hook.lua
    ├── indicator.lua
    ├── main.lua
    ├── steer.lua
    ├── util.lua
    └── vehicle.lua
```

**3. Start the game** and check `FarMech/Binaries/Win64/UE4SS.log` for:

```
[FieldGPS] === Feld-GPS bereit ===
```

> [!TIP]
> Older UE4SS builds ignore `enabled.txt` and load only what is listed in
> `FarMech/Binaries/Win64/Mods/mods.txt`. If the line above does not appear, add
> `FieldAlignGPS : 1` to that file — **above** the `Keybinds` entry, which must stay last.

To uninstall, delete the `Mods/FieldAlignGPS` folder (and the `mods.txt` line, if you added one).

## Usage

Get into the mech, switch to tractor mode, drive onto a field, face the direction you want to
work in, and press <kbd>K</kbd>.

| Key | Effect |
|---|---|
| <kbd>K</kbd> | lane keeping on/off |
| <kbd>L</kbd> | write diagnostics to the UE4SS log |

The mech's **headlights indicate the state**: on means lane keeping is active. Your previous
headlight setting is remembered and restored when you disengage.

Engaging prints the essentials to the log:

```
[FieldGPS] Spuranker gesetzt -- Spurabstand 150 uu
[FieldGPS] Spurhaltung an -- Spur 34 Grad (Feldfruechte (60 Stueck, Abstand 149 uu)), Abweichung 5.8 Grad
```

Guidance releases itself when you leave tractor mode or exit the mech, and yields while you steer
more than `PlayerOverrideDegrees` away from the target heading.

> [!NOTE]
> Code comments and log output are German. Everything you need to configure is documented in
> English in the table below.

## Configuration

All settings live in
[`Mods/FieldAlignGPS/scripts/config.lua`](Mods/FieldAlignGPS/scripts/config.lua), and every one
of them is commented in place.

> [!IMPORTANT]
> UE4SS loads Lua mods only at game start. Restart the game after editing the config.

| Symptom | Setting |
|---|---|
| Oscillates around the line | raise `VehicleKd`, lower `VehicleKp` |
| Converges too slowly | raise `VehicleKp` |
| Steering feels jerky | raise `VehicleRateSmoothing`, lower `VehicleSlewPerSecond` |
| Twitches on the ideal line | raise `VehicleDeadzone` |
| Cuts in too aggressively | raise `TrackLookahead` |
| Approaches the line too flat | lower `TrackLookahead` |
| Turns while nearly stopped | raise `VehicleMinSpeed` |
| Yields to your input too easily | raise `PlayerOverrideDegrees` |
| Axis should follow the field while driving | `HoldAxisWhenLocked = false` |
| No headlight indicator wanted | `UseHeadlightIndicator = false` |
| Field not detected | raise `CropSearchRadius` |
| <kbd>K</kbd> or <kbd>L</kbd> collide with another mod | `KeyLock`, `KeyDebugDump` |

Set `VerboseTick = true` to log one controller line per frame — heading error, turn rate, steering
output and cross-track offset. Useful for tuning the gains, but the log grows fast.

## Troubleshooting

Press <kbd>L</kbd> in game first: it reports the detected mech, the leg module and its live
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

## How this was built

The game has no modding API and no documentation. Everything this mod relies on was found by
dumping the game's own class layout with UE4SS (`Ctrl`+`H`) and then measuring behaviour in game.
That method leaves a mark on the code: **every write to the game is read back**. `SetSteering()`
is followed by `GetSteering()` on the same frame, because a call that returns successfully tells
you nothing about whether it did anything — an early version of this mod wrote steering values
that were silently discarded and looked, from the log, like they were working.

Development was done with **[Claude Code](https://claude.com/claude-code)** as a pair programmer,
including the reverse engineering, the controller design and this README. Two things are worth
being explicit about, because they affect how much you should trust the code:

- The measurements quoted above (16.8° → 0.06°, ~4 cm lateral deviation) are from real in-game
  runs, not estimates.
- Several plausible-looking approaches were tried and *measured* to be dead ends before the
  working one was found — steering the walking mech's movement component, forcing actor rotation,
  driving the physics body. [`CLAUDE.md`](CLAUDE.md) records what was ruled out and how, so the
  same hours don't get spent twice.

If you are extending this, read `CLAUDE.md` first. It is written for an AI assistant but the
constraints in it apply to anyone.

## Known limitations

- **No on-screen text.** Creating and displaying UMG widgets from Lua could not be made to work in
  this build: `DrawDebugLine` is compiled out and the game has no `AHUD` subclass. State is shown
  through the headlights instead.
- **Angle and lane only.** The mod does not control throttle, turn at headlands, or lift
  implements.
- Developed against the game build dated 2026-04-15. Major updates can rename classes; the
  diagnostics on <kbd>L</kbd> report what is actually present.
