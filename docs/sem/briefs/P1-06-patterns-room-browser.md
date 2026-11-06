# P1-06: Patterns room, the browser (navigator, map, live pattern pane)

- **Repo:** macTEM, workstream Patterns room
- **Plan:** phase 1, M1; design `docs/sem/design/ebsd-patterns-room.md`
- **Prerequisite:** P1-01 merged; the design doc merged
- **Size:** about 4 h

## Scope
The Patterns room ⌘6 (sidebar after Diffraction; Results moves to ⌘9): `EBSDSession` owner in TEMSession (the open dataset, the current pattern position, the virtual images, the display state); a main pane showing the navigation map (the mean-intensity image until P1-07 adds virtual BSE images) with a crosshair; the live pattern pane open by default showing the pattern under the cursor, arrow keys moving by one, the pattern drawn through MacEMUI's Metal image view with the Display pattern (colormap, histogram, gamma); inspector `Calibration · Display · Virtual images · Processing · Export` with Calibration showing the file's step, PC and tilts; status line `row · col · intensity`; Open routes an EBSD file here (`FileRouting`), the file's row in Open Files shows the navigation shape. Toolbar verb: none yet in phase 1 (the room shows data; Process arrives in phase 2).

## Done when
The north-star file opens from ⌘O into the room in under 1 s, the pattern pane follows the cursor and the keys, the XCUITest journey `PatternsJourney` drives open, hover, arrow keys and the Display popover with screenshots in `release-assets/sem/`; unit tests pin the session's position arithmetic and the routing.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch.
- A test that fails before and passes after. Numerics compare against `tools/parity/sem` references within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body.
- `tools/run-tests.sh unit` and `core` green; the Swift 6 rules (TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app).
- UI work loads the `swiftui-macos` skill; pure SwiftUI, AppKit only where named in code; a change to what the app draws carries a screenshot in the PR and an XCUITest journey; say "unverified on screen" for anything no drive saw.
- `CHANGELOG` line through the PR title; `docs/status.md` and `ROADMAP.md` updated; leftover work becomes an issue, not a comment.
- No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md`.
