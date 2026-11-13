# P4-02: Dictionary indexing with the Ni master pattern (figure F9)

- **Repo:** macTEM, workstream Indexing (TEMCore numerics)
- **Plan:** phase 4, M4, figure F9; catalogue section 4
- **Prerequisite:** P3-05 (sampling) and P6-01 (master pattern projection) merged
- **Size:** about 6 h

## Scope
`kikuchipy.indexing.dictionary_indexing`: the dictionary from the master pattern projected on the detector for every sampled orientation (P6-01), the experimental patterns normalised as kikuchipy does, the NCC and NDP metrics (`similarity_metrics`), `keep_n` best matches, chunking by memory; Metal float32 for the matrix product of patterns x dictionary (the size pays), checked against the CPU float64 path; the result as a `CrystalMap` with `scores` and `simulation_indices`.

## Done when
F9 reproduced: on the north-star grid the best-match simulation index equals kikuchipy's, scores within rtol 1e-4; the IPF-Z map of the result matches F9's figure.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
