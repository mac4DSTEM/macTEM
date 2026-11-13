# P3-01: Orientation core: rotations, point groups, orientations and misorientations (figure F6, first half)

- **Repo:** macTEM, workstream Orientation core (TEMCore)
- **Plan:** phase 3, M3, figure F6; catalogue section 3
- **Prerequisite:** none (runs now); the foundation every later orientation brief imports
- **Size:** about 6 h

## Scope
`Sources/TEMCore/Orientation/`: `Rotation` (unit quaternion, Rowenhorst 2015 conventions, passive, P = -1) with every conversion of `orix.quaternion._conversions` (Euler Bunge, axis-angle, matrix, Rodrigues, homochoric, cubochoric) and composition, inverse, angle, outer products; `Symmetry` for the 32 point groups and 11 Laue groups (orix's generator lists, `proper_subgroup`, `laue`, `fundamental_sector`); `Orientation` and `Misorientation` (`map_into_symmetry_reduced_zone`, `angle_with`, the disorientation angle, `get_distance_matrix`), the orientation region. Vectorised over arrays of rotations on Accelerate. Keep `ANGReader.quaternion(fromBungeEuler:)` working (route it here).

## Done when
Every conversion round trip and orix's own test values within atol 1e-7; point-group element sets equal; disorientation angles on the Ti orientations within atol 1e-7 of orix; a new m3 bundle.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
