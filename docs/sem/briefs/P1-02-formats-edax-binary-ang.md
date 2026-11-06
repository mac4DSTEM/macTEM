# P1-02: EDAX binary patterns (.up1/.up2) and .ang maps

- **Repo:** macTEM, workstream Formats
- **Plan:** phase 1, M1; catalogue section 1
- **Prerequisite:** P1-01's `EBSDDataset` type merged (the value this reader fills)
- **Size:** about 2 h

## Scope
`.up1`/`.up2` header (version, pattern width and height, offset, the square/hex grid flag and step in version 3 files) and patterns as kikuchipy's `edax_binary` reads them; a hex grid refused with a sentence (D-SEM-9). `.ang` reader as orix's `ang.file_reader`: header (phases, grid, step, PC), columns (Euler angles in radians, x, y, IQ, CI, phase id, detector signal, fit), vendor detection (EDAX, EMsoft, orix) and the column names per vendor; into a `CrystalMapData` value (navigation shape, rotations as quaternions, phase ids, property columns). Pair an `.up` with its `.ang` by name next to it.

## Done when
`edax_binary.up1`/`.up2` fixtures read bit-exact; `sdss_ferrite_austenite.ang` reads with every column equal to the orix reference at 1e-12 and the phase list exact; a hex `.up2` is refused in words.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch.
- A test that fails before and passes after. Numerics compare against `tools/parity/sem` references within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body.
- `tools/run-tests.sh unit` and `core` green; the Swift 6 rules (TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app).
- UI work loads the `swiftui-macos` skill; pure SwiftUI, AppKit only where named in code; a change to what the app draws carries a screenshot in the PR and an XCUITest journey; say "unverified on screen" for anything no drive saw.
- `CHANGELOG` line through the PR title; `docs/status.md` and `ROADMAP.md` updated; leftover work becomes an issue, not a comment.
- No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md`.
