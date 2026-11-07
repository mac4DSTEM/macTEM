# P3-02: Vectors, Miller indices, stereographic projection and IPF colour keys (figure F6, second half)

- **Repo:** macTEM, workstream Orientation core (TEMCore)
- **Plan:** phase 3, M3, figure F6; catalogue section 3
- **Prerequisite:** P3-01 merged
- **Size:** about 5 h

## Scope
`Vector3d`, `Miller` (hkl, uvw, hkil, the lattice from a `Phase`), `StereographicProjection` and its inverse (upper and lower hemisphere), `IPFColorKeyTSL` (Nolze & Hielscher 2016 via orix: the fundamental sector, the colour from the direction, the key image), Euler colours (DefDAP `calc_euler_colour`). The key image renders to RGBA in TEMCore for the Maps room to draw.

## Done when
F6 complete: the IPF-Z colours of the sdss_ferrite_austenite map within 1e-6 of orix's RGB; the key images for m-3m and 6/mmm equal orix's within 1/255; projections atol 1e-7.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
