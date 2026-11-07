# P5-02: Pole figures, inverse pole figure densities and the ODF (figure F13)

- **Repo:** macTEM, workstream Maps and grains (TEMCore numerics)
- **Plan:** phase 5, M5, figure F13; catalogue section 5
- **Prerequisite:** P3-02 merged
- **Size:** about 6 h

## Scope
orix's `pole_density_function` (the de la Vallée Poussin kernel, half-width, the equal-area grid), pole figures for chosen {hkl} with symmetry, inverse pole figure densities, the ODF by kernel density on SO(3) (Hielscher & Schaeben 2008) and its phi2 sections; rendered to RGBA in TEMCore for the Maps room's bottom pane.

## Done when
F13 reproduced: PF {100}, {110}, {111} and ODF phi2 = 45° sections of the Ti orientations within rtol 1e-4 of orix.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
