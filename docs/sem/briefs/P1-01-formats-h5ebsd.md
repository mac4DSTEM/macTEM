# P1-01: h5ebsd readers (kikuchipy, Bruker, EDAX, Oxford h5oina)

- **Repo:** macTEM, workstream Formats
- **Plan:** `docs/sem/plan.md` phase 1, milestone M1; catalogue section 1
- **Prerequisite:** `tools/parity/sem` emits the h5ebsd references (reference arrays and header fields per file)
- **Size:** about 3 h

## Scope
`Sources/TEMCore/SEM/EBSDFile.swift` and one reader per layout over FormatoKit's HDF5 layer (`FormatoHDF5`): kikuchipy h5ebsd (`nickel_ebsd_large/patterns_v2.h5`, the north-star file), Oxford h5oina, Bruker h5ebsd, EDAX h5ebsd. One `EBSDDataset` value: navigation shape, pattern shape, dtype, the pattern array by chunk (lazy by row block, Float32 on request), scan step and unit, the static background when the file carries one, the detector (PC in the file's convention plus the converted Bruker convention, sample tilt, detector tilt, binning, pixel size), phases (name, space group, lattice), and the file's own indexing results (Euler angles, phase id, quality fields) as an optional map. Header fields exact; conventions as `kikuchipy.detectors` converts them. Sniffing by group names so Open routes the file to the Patterns room (`FileRouting`).

## Done when
Each sample file in `macTEMTests/Fixtures/sem/` (the in-package kikuchipy and EDAX files, the dummy Bruker and Oxford files written by the parity scripts) reads with every field equal to the kikuchipy reference JSON and the first and last pattern bit-exact; the north-star file reads in under 1 s on the CI runner; a non-EBSD HDF5 file is refused with a sentence naming the missing group.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch.
- A test that fails before and passes after. Numerics compare against `tools/parity/sem` references within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body.
- `tools/run-tests.sh unit` and `core` green; the Swift 6 rules (TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app).
- UI work loads the `swiftui-macos` skill; pure SwiftUI, AppKit only where named in code; a change to what the app draws carries a screenshot in the PR and an XCUITest journey; say "unverified on screen" for anything no drive saw.
- `CHANGELOG` line through the PR title; `docs/status.md` and `ROADMAP.md` updated; leftover work becomes an issue, not a comment.
- No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md`.
