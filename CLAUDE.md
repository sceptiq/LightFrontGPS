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

UE4SS loads Lua only at game start, so a naive change costs a full restart. `F9` avoids that for
everything except `main.lua` and `hook.lua`:

1. Copy `Mods/FieldAlignGPS` into `<game>/FarMech/Binaries/Win64/Mods/` — `deploy.ps1 -Live` does
   exactly this and works while the game is running, because UE4SS reads the `.lua` files only at
   load time. (See README for the install layout and the older-UE4SS `mods.txt` caveat.)
2. Press `F9` in game.
3. Confirm the swap actually happened — the log must contain `=== Module neu geladen ===`. Without
   that line, any "nothing changed" report is meaningless, because the new code never ran. The
   same applies to a cold start and `[FieldGPS] === Feld-GPS bereit ===`.

Touching `main.lua` or `hook.lua` still means a restart. That is the cost of putting anything
there, and the reason `control.lua` exists.

Log: `<game>/FarMech/Binaries/Win64/UE4SS.log`, truncated on every game start.

`Config.VerboseTick = true` logs one controller line per frame (heading error, turn rate, steering
written vs. read back, cross-track offset). That is the instrument for tuning the gains.

## Commits and the changelog

This mod is published on Nexus Mods as well as GitHub, and that side is driven by hand: the
changelog is pasted into a web form, in BBCode rather than Markdown. Everything that can be
prepared mechanically therefore is — but the text itself is not generated.

**`CHANGELOG.md` is written by hand, and it is written for players.** Commit subjects are
written for whoever maintains this; "split out the state machine" tells a player nothing about
whether to download. Generating the changelog from `git log` would ship the wrong register, which
is why the release workflow only *reformats* a hand-written section.

Two formatting rules exist solely so the text survives a web form:

- **One line per bullet, no hard wrapping.** Wrapped lines re-wrap badly in a textarea.
- **No HTML.** Write `the O key`, not `<kbd>O</kbd>`. Markdown bold, links and inline code are
  fine — the workflow converts them; anything else passes through untouched.

Pushing a version tag then does the rest: the section for that version becomes the GitHub release
body, and a BBCode and a plain-text rendering land in the workflow's **job summary**, ready to
copy straight out of the browser with nothing to download. A version with no section is not an
error — the release quietly falls back to GitHub's generated notes, so the changelog entry is the
one thing to write *before* tagging.

### Clean commits, because the changelog is written from them

The existing history is the pattern. Imperative subject under 60 characters, no `feat:`/`fix:`
prefixes, and a body that explains *why* with the measurement that decided it — "`GetThrottle()`
read 0.0 while the mech accelerated from 519 to 974 cm/s" is worth more than any restatement of
the diff.

Two rules earned the hard way:

- **One concern per commit.** A commit that fixed lane drift *and* added an unfinished headland
  turn could not be released without shipping the turn — and its width measurement was wrong in a
  way that would have made lane spacing a third too narrow. History had to be rewritten to get
  the drift fix out. Bundling costs more than it saves.
- **Never commit a bench-test value.** `AutoTurnEnabled`, `VerboseTick` and `DriftLogSeconds` are
  the repeat offenders. Check them before staging, not after tagging.

Commits are authored by the repository owner alone — no `Co-Authored-By` trailer. The AI
involvement is stated openly in the README and in this file, which is the honest place for it;
repeating it on every commit adds noise, not transparency.

## In-game keys

| Key | Effect |
|---|---|
| `K` | lane keeping on/off — the only control |
| `L` | diagnostics + field-source report into the log |
| `F9` | reload config/control/field/steer/vehicle/indicator in place |
| `Ctrl+H` | UE4SS: dump full C++ SDK **with offsets** to `CXXHeaderDump/` |
| `Ctrl+J` / `Ctrl+Num6` / `Ctrl+Num7` | UE4SS: all objects / usmap / all actors |

## Architecture

```
main.lua       keybinds, tickEntry, LoopAsync fallback, module reload  <- NOT reloadable
hook.lua       RegisterHook on the BP tick                             <- NOT reloadable
control.lua    the state machine: on/off, control loop, diagnostics
vehicle.lua    the tracked chassis — steering, throttle, implement
steer.lua      the PD controller (the only one)
field.lua      field axis, row spacing, AB-line anchor, cross-track error
indicator.lua  state display via the mech's headlights
util.lua       logging, angle math, defensive UObject access
```

### Reload, and why the split exists

`F9` drops everything except `main.lua` and `hook.lua` from `package.loaded` and re-requires it,
so tuning a gain costs a keypress instead of a game restart. That is the *reason* the state
machine lives in `control.lua` rather than in `main.lua`: the two excluded files hold the key
bindings and the per-frame hook closure, neither of which can be withdrawn once registered.
Anything put in `main.lua` becomes restart-only — keep it thin.

`main.lua` reaches the current modules through upvalues (`Control`, `Config`, `Util`) that the
reload reassigns, which is what makes the already-registered keybind closures pick up new code.
Log each reload step *before* running it: an early version hung mid-reload and the last log line
was from `Steer.release`, with nothing after it to say where.

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

The same leg module also owns the implement and the throttle, which is what lets `K` end the whole
job rather than just the guidance:

```
AMechCharacter    StopAutoMoving()                                  <- cancels auto-drive
ATreadsLegModule  SetAttachmentActive(bool) / IsAttachmentActive()  <- the implement
AMechLegModule    SetHandbrake(bool) / GetHandbrake()               <- kills residual momentum
```

### Auto-drive lives on the mech, not on the chassis

Cancelling auto-drive cost three wrong attempts, all on the leg module. Measured, in order:

- **`SetThrottle(0, true)` does nothing.** `GetThrottle()` read back `0.0` while the mech
  *accelerated* from 519 to 974 cm/s. The game rewrites `RawThrottleInput` every frame.
- **`GetThrottle()` is not a readback.** It returns the value *we* just wrote, not the one the
  component drives with. The honest reading is `GetThrottleInput()` on the movement component —
  it showed `1.0` throughout. A readback that only echoes your own write proves nothing.
- **`SetHandbrake(true)` stops the mech but does not cancel anything.** Speed goes to 0 with
  throttle still at `1.0`; release the brake and it drives straight off again.

`AMechCharacter::StopAutoMoving()` is the actual lever — parameterless, on the *pawn*, not the
chassis. After it, `GetThrottleInput()` reads `0.0` and stays there. `AFarmerCharacter` carries
the same pair plus `ToggleAutoMove()`, which is the key the player presses.

There is no `IsAutoMoving()`; verify through `GetThrottleInput()` instead.

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
