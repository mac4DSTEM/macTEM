# P2-04: Detector geometry: PC conventions, moving-screen PC and TKD geometry (figure F5)

- **Repo:** macTEM, workstream Processing (TEMCore numerics)
- **Plan:** phase 2, M2, figure F5; catalogue section 2
- **Prerequisite:** none (runs now); `EBSDDetectorGeometry` from #125
- **Size:** about 5 h

## Scope
Complete `EBSDDetectorGeometry` against kikuchipy's `EBSDDetector`: every PC convention (Bruker, TSL/EDAX, Oxford, EMsoft 4 and 5) both ways, `px_size`, `binning`, `sample_tilt`, `tilt`, `azimuthal`, `twist`, the gnomonic bounds and coordinates (`gnomonic_bounds`, `x_range`, `y_range`, `r_max`), the detector-to-sample rotation used later by projection and indexing; `PCCalibrationMovingScreen` (Hjelen 1991: two patterns at known detector distances, the zone-axis points, PC and its uncertainty); TKD geometry (transmission: sample tilt below the beam, detector tilt and off-axis azimuth, as `EBSDDetector` takes it). Data: kikuchipy's `si_ebsd_moving_screen_in/out` (download in `fetch-data.sh`, CC BY 4.0) with kikuchipy's published points.

## Done when
F5 reproduced: the moving-screen PC of si_in/out within rtol 1e-5 of kikuchipy; every convention round trip exact to 1e-12; gnomonic bounds rtol 1e-7; TKD geometry cases from kikuchipy's tests exact.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
