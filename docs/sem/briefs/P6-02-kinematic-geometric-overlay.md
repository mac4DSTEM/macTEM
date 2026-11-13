# P6-02: Kinematic master pattern and the geometrical Kikuchi overlay (figure F14)

- **Repo:** macTEM, workstream Simulation (TEMCore numerics + Indexing room overlay)
- **Plan:** phase 6, M6, figure F14; catalogue section 6; design `design/simulation-overlay.md`
- **Prerequisite:** P3-02 merged; P4-04 for the overlay in the room
- **Size:** about 6 h

## Scope
`KikuchiPatternSimulator` (diffsims reflectors from the phase's structure through DiffractoKit's public API, read-only; the structure factors, the band widths from Bragg angles), `on_detector` (band edges and centres, zone axes as gnomonic coordinates, `GeometricalKikuchiPatternSimulation`), `calculate_master_pattern` (kinematic intensities on the Lambert grid). The overlay layer in the Indexing room's pattern pane as the design says.

## Done when
F14 reproduced: band and zone-axis coordinates on pattern (0,0) of the indexed nickel within atol 1e-6 px of kikuchipy; kinematic master pattern rtol 1e-5; overlay journey step.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
