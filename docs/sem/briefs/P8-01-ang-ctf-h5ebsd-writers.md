# P8-01: Writers: .ang, .ctf, kikuchipy h5ebsd and orix HDF5 (figure F18)

- **Repo:** macTEM, workstream Export (TEMCore writers)
- **Plan:** phase 8, M8, figure F18; catalogue section 9; design `design/export-and-reports.md`
- **Prerequisite:** P3-03 merged
- **Size:** about 5 h

## Scope
`orix.io.plugins.ang.file_writer` (TSL column layout, the header with phases), a `.ctf` writer following the Oxford spec (read back by orix), the kikuchipy h5ebsd writer and orix HDF5 crystal map writer through FormatoKit's HDF5 write API if it has one (no kit change: if FormatoKit cannot write datasets, ship `.ang`/`.ctf` and log the HDF5 writers as an issue with that reason).

## Done when
F18: `.ang` and `.ctf` round trips of the sdss and Ti maps read back by orix equal the originals (columns exact to the written precision); h5ebsd round trip read back by kikuchipy, if written.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
