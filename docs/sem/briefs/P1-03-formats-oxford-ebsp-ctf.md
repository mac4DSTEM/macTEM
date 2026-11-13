# P1-03: Oxford binary patterns (.ebsp) and .ctf maps

- **Repo:** macTEM, workstream Formats
- **Plan:** phase 1, M1; catalogue section 1
- **Prerequisite:** P1-01's `EBSDDataset`, P1-02's `CrystalMapData`
- **Size:** about 2 h

## Scope
`.ebsp` as kikuchipy's `oxford_binary` reads it: version, pattern positions and sizes from the header table, the per-pattern footer (row, column, used flag), compressed patterns refused by name, patterns returned in map order; the pattern size when the header omits it. `.ctf` as orix's `ctf.file_reader`: header (phases with lattice and space group, grid, step), columns (phase, x, y, bands, error, Euler in degrees, MAD, BC, BS) and the vendor's column names.

## Done when
`oxford_binary/patterns.ebsp` reads bit-exact against the kikuchipy reference; `Ti_orientations.ctf` reads equal to orix at 1e-12 with the hexagonal phase and its point group exact.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch.
- A test that fails before and passes after. Numerics compare against `tools/parity/sem` references within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body.
- `tools/run-tests.sh unit` and `core` green; the Swift 6 rules (TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app).
- UI work loads the `swiftui-macos` skill; pure SwiftUI, AppKit only where named in code; a change to what the app draws carries a screenshot in the PR and an XCUITest journey; say "unverified on screen" for anything no drive saw.
- `CHANGELOG` line through the PR title; `docs/status.md` and `ROADMAP.md` updated; leftover work becomes an issue, not a comment.
- No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md`.
