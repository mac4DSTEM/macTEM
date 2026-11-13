# P4-01: Hough indexing: band detection and triplet voting (figure F8)

- **Repo:** macTEM, workstream Indexing (TEMCore numerics)
- **Plan:** phase 4, M4, figure F8; catalogue section 4
- **Prerequisite:** P3-01 and P2-04 merged
- **Size:** about 8 h

## Scope
Port pyebsdindex (US federal work; derived-and-modified notice): the Radon transform on the detector (`radon_fast`), the band detection (`band_detect`: the Laplacian of Gaussian peak finding, `nBands`, `rSigma`, `tSigma`), the triplet-voting indexer (`tripletvote`: the reflector library per phase, angle tolerance, the fit, the confidence metrics), `ebsd_index.EBSDIndexer` with its PC in Bruker convention; CPU float64 reference, Metal float32 for the Radon transform if a 55 x 75 run takes over 5 s. Results go into `CrystalMap` (fit, CI, number of bands as properties).

## Done when
F8 reproduced: the Hough-indexed IPF-Z map of nickel_ebsd_large; bands within 1 px / 1°, orientations within 1° of pyebsdindex for at least the fraction it indexes, fraction indexed equal.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
