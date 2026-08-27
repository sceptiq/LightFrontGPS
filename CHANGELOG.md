# Changelog

Newest first. Version numbers match the [release tags](https://github.com/sceptiq/LightFrontGPS/releases).

Bullets are deliberately kept on one line each and free of HTML, so the text survives being pasted into a web form. See `CLAUDE.md`.

## 1.1.0 — 2026-08-27

**Added**

- Fully automatic mode on the O key: it lowers the implement, drives, and holds the lane. Pressing O again raises the implement, cancels auto-drive, catches the momentum with the handbrake and disengages — one key instead of the usual three.
- Live reload on F9. Changing a setting no longer costs a game restart.

**Fixed**

- Lane drift over a long pass. The field axis is now averaged over every crop in range instead of a single pair of plants, which cut the measured scatter from 0.5° to 0.02°, and the line is gently realigned every 10 m.

**Changed**

- The K key behaves exactly as in 1.0.0 — guidance only, with throttle and implement left to you. Shutdown always follows the mode the run was started in, so O never surprises a run begun with K.
- The drift log is off by default. It is a measuring tool for long passes, not something to run permanently; set `DriftLogSeconds` to re-enable it.

## 1.0.0 — 2026-08-26

**Added**

- Initial release. AB-line lane guidance for the harvester mech in tractor mode, on the K key.
- The row axis and spacing are measured from the crops actually growing around you, so any field orientation works.
- Steering against the guidance hands control back, and it re-engages by itself when you let go.
- The mech's headlights indicate the state; your previous headlight setting is restored on disengage.
