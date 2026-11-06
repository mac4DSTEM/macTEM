# P1-04: NORDIF (Pattern.dat + Setting.txt) and calibration patterns

- **Repo:** macTEM, workstream Formats
- **Plan:** phase 1, M1; catalogue section 1
- **Prerequisite:** P1-01's `EBSDDataset`
- **Size:** about 1.5 h

## Scope
`Setting.txt` parsing as kikuchipy's `nordif` reader (microscope, detector, acquisition, calibration sections; step, pattern size, binning, PC, tilt, HV, working distance); `Pattern.dat` as a uint8 block in map order with the size from the settings; the calibration `.bmp` patterns with their positions (`nordif_calibration_patterns`); the three bad settings files refused each with its sentence.

## Done when
The in-package NORDIF folder reads equal to the reference (settings exact, patterns bit-exact, calibration positions exact); `Setting_bad1-3.txt` are refused with the sentence the parity JSON states.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch.
- A test that fails before and passes after. Numerics compare against `tools/parity/sem` references within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body.
- `tools/run-tests.sh unit` and `core` green; the Swift 6 rules (TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app).
- UI work loads the `swiftui-macos` skill; pure SwiftUI, AppKit only where named in code; a change to what the app draws carries a screenshot in the PR and an XCUITest journey; say "unverified on screen" for anything no drive saw.
- `CHANGELOG` line through the PR title; `docs/status.md` and `ROADMAP.md` updated; leftover work becomes an issue, not a comment.
- No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md`.
