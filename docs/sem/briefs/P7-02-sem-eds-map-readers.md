# P7-02: SEM-EDS map readers: Bruker .bcf, EDAX .spd/.spc/.ipr, JEOL .pts

- **Repo:** macTEM, workstream Formats (TEMCore readers)
- **Plan:** phase 7; catalogue section 1
- **Prerequisite:** none (runs now)
- **Size:** about 8 h

## Scope
Port RosettaSciIO 0.15.0 (`rsciio.bruker` with the SFS container and the packed spectra, `rsciio.edax`, `rsciio.jeol`) into TEMCore readers that hand the EDS room a spectrum image with its axes and SEM metadata, plus the BSE/SE images inside a `.bcf`; FileRouting sends them to the EDS room. Test files from RosettaSciIO's test data (licence check; GPL-3.0-or-later), truth from rsciio.

## Done when
Every rsciio test file of the three formats reads exactly as rsciio does (data sha, axes, metadata fields mapped); refusals with sentences for the variants rsciio refuses.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
