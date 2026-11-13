# P3-04: Maps room ⌘8: open a crystal map and see its IPF map with the colour key

- **Repo:** macTEM, workstream Maps room
- **Plan:** phase 3, M3; design `design/orientation-maps-room.md`
- **Prerequisite:** P3-02 and P3-03 merged
- **Size:** about 6 h

## Scope
The design's first drivable slice: `.ang`, `.ctf` and the crystal map of an h5ebsd/h5oina open into the Maps room (FileRouting; a lone `.ctf`/`.ang` stops being refused); the map pane with IPF-X/Y/Z and phase maps, the colour key in the bottom pane, the live pattern pane when the file carries patterns, hover readout (phase, Euler, the property values), the inspector's Map and Info sections, PNG export with the key. Results moves to ⌘9 when Indexing (P4-04) lands; Maps takes ⌘8 now if Indexing is not built yet (follow D-SEM room-key rule: one key per built room, in design order).

## Done when
The design's acceptance list for the slice; the sdss map's IPF-Z on screen equals F6's numbers; journey on the shipped or a fixture map; screenshot in the PR.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
