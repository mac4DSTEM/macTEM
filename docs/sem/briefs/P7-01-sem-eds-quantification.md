# P7-01: SEM-EDS in the EDS room: line intensities with background windows and k-factor quantification (figures F16, F17)

- **Repo:** macTEM, workstream SEM-EDS (EDS room)
- **Plan:** phase 7, M7, figures F16 and F17; catalogue section 7; design `design/sem-eds-room.md`
- **Prerequisite:** none (runs now; the TM002 spectrum opens since #127)
- **Size:** about 6 h

## Scope
In macTEM only (SpectroKit unchanged: anything missing is ported into TEMCore): exspy's `EDSSEMSpectrum` behaviour for a SEM spectrum (beam energy, take-off angle, live time from the file), `estimate_background_windows` and `estimate_integration_windows`, `get_lines_intensity` with background subtraction, the elements/lines from exspy's database where SpectroKit's table differs, k-factor quantification with user k-factors (`validation: none` beyond exspy, decision D-SEM-7); the design's SEM additions to the EDS room (SEM header rows, the windows drawn on the spectrum).

## Done when
F16 reproduced: TM002 line intensities (C, Al, Mn, Cu, Zr) with background windows within rtol 1e-7 of exspy (the m7 bundle in `tools/parity/sem`); F17 with the reference k-factors; journey on Try Demo Data's spectrum.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
