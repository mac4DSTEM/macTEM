# P5-04: Maps room complete: property maps, grains, texture and slip traces

- **Repo:** macTEM, workstream Maps room
- **Plan:** phase 5, M5; design `design/orientation-maps-room.md`
- **Prerequisite:** P3-04 merged; joins P5-01..03 as they land
- **Size:** about 8 h

## Scope
The rest of the design: property maps (band contrast, MAD, CI, IQ, fit: the stored columns), grain map and grains table in the bottom pane (size, ASTM number, GOS, mean orientation), KAM and GOS maps, boundary overlay, pole figures / IPF densities / ODF sections in the bottom pane, Schmid and slip-trace overlay per grain, every export with scale bar and key.

## Done when
The design's acceptance list; F11 to F13 on screen; journey; screenshot.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
