# P6-01: Master patterns: read EMsoft master patterns and project them onto the detector (figure F15)

- **Repo:** macTEM, workstream Simulation (TEMCore numerics)
- **Plan:** phase 6, M6, figure F15; catalogue sections 1 and 6
- **Prerequisite:** P2-04 merged for the detector; runs now on its own `EBSDDetectorGeometry` use
- **Size:** about 6 h

## Scope
Read EMsoft EBSD, TKD and ECP master patterns (`kikuchipy.io.plugins.emsoft_*_master_pattern`: Lambert and stereographic, both hemispheres, energies, uint8 and float) from HDF5 through FormatoKit; ship kikuchipy's Ni 20 kV master pattern as demo data (licence check, `NOTICE`); `EBSDMasterPattern.get_patterns` (the detector direction cosines, the rotation, the square Lambert projection with bilinear interpolation, Rosca 2010), CPU float64 and Metal float32.

## Done when
F15 reproduced: Ni master pattern projected for kikuchipy's docs orientation and PC within rtol 1e-5; reader exact on the in-package file.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
