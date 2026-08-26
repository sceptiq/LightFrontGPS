# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Published deliberately. This mod was built with AI assistance, and this file is the decision
> record that came out of it: what the game's movement actually does, which approaches were
> measured as dead ends, and which constraints will bite anyone writing UE4SS Lua for this title.
> It is addressed to an AI assistant, but the content applies to any contributor. See the
> "How this was built" section of the README.

UE4SS Lua mod for **Lightyear Frontier** (UE 4.27.2). Adds GPS lane guidance to the mech's
tractor/harvester mode: it steers the tracked chassis onto the field's row axis and holds the
lane. Code comments and log output are German — keep it that way. The README is English.

## No build, no tests, no lint

There is nothing to compile and no test suite. There is also **no Lua interpreter on this
machine**, so syntax errors are only caught by the game refusing to load the mod. Before handing
over an edit, at minimum re-read it for balanced `if`/`function`/`end` blocks and for code after a
top-level `return` — the latter produces Lua's misleading `<eof> expected` pointing at the wrong
line.

Verification means running it in game.

## The iteration loop

UE4SS loads Lua only at game start, and there is no live-reload path in this repo. Every change
costs a full restart:

1. Copy `Mods/FieldAlignGPS` into `<game>/FarMech/Binaries/Win64/Mods/` (see README for the
   install layout and the older-UE4SS `mods.txt` caveat).
2. Start the game.
3. Confirm the mod actually loaded — the log must contain `[FieldGPS] === Feld-GPS bereit ===`.
   Without that line, any "nothing happened" report is meaningless, because the new code never ran.

Log: `<game>/FarMech/Binaries/Win64/UE4SS.log`, truncated on every game start.

`Config.VerboseTick = true` logs one controller line per frame (heading error, turn rate, steering
written vs. read back, cross-track offset). That is the instrument for tuning the gains.

## In-game keys

| Key | Effect |
|---|---|
| `K` | lane keeping on/off — the only control |
| `L` | diagnostics + field-source report into the log |
| `Ctrl+H` | UE4SS: dump full C++ SDK **with offsets** to `CXXHeaderDump/` |
| `Ctrl+J` / `Ctrl+Num6` / `Ctrl+Num7` | UE4SS: all objects / usmap / all actors |

## Architecture

```
main.lua       keybinds, on/off state, tickEntry, diagnostics
hook.lua       RegisterHook on the BP tick; falls back to LoopAsync
vehicle.lua    the tracked chassis — THE steering channel
steer.lua      the PD controller (the only one)
field.lua      field axis, row spacing, AB-line anchor, cross-track error
indicator.lua  state display via the mech's headlights
util.lua       logging, angle math, defensive UObject access
```

### The mech has two movement systems

This is the single most important fact in the project:

```
AMechCharacter
  .MovementComponent ........... UBipedalMovementComponent      <- walking mech
  :GetEquippedLegModule() ...... ATreadsLegModule / BP_HarvesterLegModule_C
     .MovementComponent ........ UCustomVehicleMovementComponent
                                 : UChaosWheeledVehicleMovementComponent, bIsTank = true
```

In tractor mode the **vehicle** component drives. The bipedal component still ticks but steers
nothing — its `ActiveInputVector` reads `(0,0)` at 364 cm/s, and calling `ClearInput()` every
frame for 121 frames did not slow the mech at all. Anything that touches `AddMovementInput`, actor
rotation, body physics or controller yaw is working on the wrong component; an earlier attempt to
steer by rotating the actor produced visible body twisting.

Steering goes through the leg module's own API, the same entry point the game's A/D keys use:

```
mech:GetEquippedLegModule() -> SetSteering(-1..1) / GetSteering() / GetThrottle() / GetForwardSpeed()
```

`GetSteering()` is read back on every write — that readback is the reason this path was confirmed
working on the first try. Keep it.

Because `bIsTank = true`, full steering at zero throttle spins in place. Steering is gated below
`VehicleMinSpeed` and scaled up to `VehicleFullSteerSpeed`.

### Lane guidance, not just heading

Heading-only control held 0.24° and still drifted sideways — a heading controller cannot tell it
is running parallel *beside* the row. `field.lua` anchors an AB line when lock-on engages, spaces
parallel lines one row apart, and aims at a point `TrackLookahead` ahead **on the line**. Control
regulates to the *nearest* line, so deliberately moving to the next row latches there. Driving the
row backwards flips the sign — handled explicitly in `Field.guidedYaw`.

The axis is measured per field, from crop geometry (`CropManager.SphereOverlapCrops` +
`FindCrop`), falling back to mound plots, plant actors, then the seed gun's lock-on. It is
canonicalised modulo 90° (`canonAxis`) — without that, rows and columns look like a field change
on every other measurement. A stored axis is wrong by construction, because plots rotate freely;
the only thing frozen is the axis captured at lock-on (`Config.HoldAxisWhenLocked`).

### Tick

`BP_TractorMechCharacter_C:ReceiveTick` is a hookable UFunction. `PlayerTick` is a native virtual
and is **not** hookable. That distinction matters: the LoopAsync fallback lands at an undefined
point in the frame, which is fine for reading but useless for writing movement values.

`tickEntry` checks the on/off state **first**, before touching any UObject. It once called
`getLocalMech()` and two `GetFullName()` per frame regardless of state — four string allocations
at 60 fps, felt as stutter. When lane keeping is off the mod must touch nothing at all.

## Hard-won constraints

- **Check the effect, not the call.** `Util.call` returns pcall success, not whether anything
  happened. `SetVisibility` returned "true" while `bVisible` stayed `false`. Every write to the
  game should have a readback.
- **Never pass self-constructed struct or FName parameters.** `GetInputAxisValue("Horizontal")`
  and `SetText("literal")` on an `FText` parameter both crashed the game instantly; `pcall` does
  not catch a native access violation. Values *read from the game* pass through fine.
- **UE4SS returns TArray elements as `RemoteUnrealParam` wrappers.** Pass one back into a
  UFunction and the call is rejected. Unwrap with `:get()` (see `unwrapValue` in `field.lua`).
- **Out parameters are filled into the table you pass in**, not returned — `FindCrop(id, out)`
  returns only a bool.
- **`Conv_TextToString` + `:ToString()` is a broken instrument here.** It returns the same
  constant garbage for every input, including an `FText` taken straight from the game's own UI.
  Any conclusion drawn from that readback is void. Verify a measuring function against a known
  value before building on it.
- **Cap `FindAllOf` loops.** An uncapped sweep on the game thread is a hang risk; every scan in
  `field.lua` has a `*ScanLimit`.
- **`DrawDebugLine` is compiled out** in this shipping build, and the game has **no `AHUD`
  subclass** — both obvious drawing routes are dead.

## Do not re-add

These were removed deliberately after being measured as dead ends. Re-introducing them costs the
same hours again:

- Steering via `AddMovementInput`, `TargetForwardVector`, `ActiveInputVector`, actor rotation,
  physics angular velocity, or `AddControllerYawInput` — all on the wrong component (see above).
- A steer-mode fallback chain. A single wrong mode name once twisted the mech's body with no
  visible cause. `steer.lua` has one controller and no dispatch.
- Instanced-mesh lane markers via `APlantBaseIndicator_C`: they place correctly (proven with
  `GetInstancesOverlappingSphere`) but never render.
- Self-created UMG widgets: they attach and report visible, opaque, font size 20 — and show
  nothing.
- The keyboard "steer bridge" that wrote a command file for an external script.
- The plough's grid preview as an axis source. It shows the *planned* new grid in the player's
  view direction and ignores the existing field — systematically wrong.

## Reverse engineering

`Ctrl+H` in game writes `CXXHeaderDump/` — every class with offsets and full signatures. This is
the authoritative source; a Lua reflection dump shows only part of the picture. **Generate the
structural dump before probing individual properties** — a negative measurement is not an
exclusion until the structure is known.

Reflection strings can also be pulled straight out of `FarMech-Win64-Shipping.exe`; that is how
`FBipedalMoveRepPacket` was found.

`CXXHeaderDump/` and `*.usmap` are gitignored, and dumps derived from the game's binaries should
stay out of the repository.
