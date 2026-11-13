# P3-03: The crystal map model and the misorientation angle distribution (figure F7)

- **Repo:** macTEM, workstream Orientation core (TEMCore)
- **Plan:** phase 3, M3, figure F7; catalogue section 3
- **Prerequisite:** P3-01 merged; #142 (readers folded into EBSDDataset) merged
- **Size:** about 4 h

## Scope
One `CrystalMap` in TEMCore for every reader (h5ebsd crystal map, `.ang`, `.ctf`, later indexing results): rotations, phase ids, `PhaseList` (name, point group, structure, colour), properties by name, x/y and step, the not-indexed phase, slicing by phase and by mask; replaces `EBSDCrystalMapData` and the reader-specific types (one migration in this PR). The misorientation angle distribution between neighbours (`Misorientation` of horizontal and vertical neighbours, histogram as orix's example).

## Done when
F7 reproduced: the neighbour misorientation angle histogram of Ti_orientations.ctf equals orix's (counts exact, bin edges exact); every reader's crystal map fixture reads into `CrystalMap` with its existing truth.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
