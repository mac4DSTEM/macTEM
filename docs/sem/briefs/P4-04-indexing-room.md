# P4-04: Indexing room ⌘7: index the open patterns and see the map grow

- **Repo:** macTEM, workstream Indexing room
- **Plan:** phase 4, M4; design `design/indexing-room.md`
- **Prerequisite:** P4-01 merged (Hough first; dictionary and refine join as P4-02/P4-03 land)
- **Size:** about 8 h

## Scope
The design's room: phases (from a CIF through DiffractoKit's structure reading, read-only use, or a built-in list), detector and PC from the dataset or P2-04's calibration, method (Hough; dictionary and refine as they land), Index runs over the scan with progress, cancel and the map growing in place, hover shows the experimental pattern with the indexed solution's bands (P6-02 when in; until then the band list as text), results as a `CrystalMap` the Maps room opens. Room keys: Indexing ⌘7, Maps ⌘8, Results ⌘9 (design D1).

## Done when
The design's acceptance list; F8 on screen from Try Demo Data's nickel scan; journey; screenshot.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
