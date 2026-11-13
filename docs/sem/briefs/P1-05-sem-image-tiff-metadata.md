# P1-05: SEM image TIFFs with vendor metadata (Thermo/FEI, Zeiss, Tescan)

- **Repo:** macTEM, workstream SEM images
- **Plan:** phase 1, M1; catalogue sections 1 and 8; design `docs/sem/design/sem-image-room.md`
- **Prerequisite:** parity references for the RosettaSciIO TIFF test files
- **Size:** about 2.5 h

## Scope
The Image room opens SEM TIFFs through FormatoKit's TIFF reader as today and adds `SEMImageMetadata` in `Sources/TEMCore/SEM/`: the FEI/Thermo `[User]/[Beam]/[Scan]/[EScan]/[Stage]/[Image]` text block (tag 34682), Zeiss `CZ_SEM` (tag 34118) and Tescan (tag 50431) parsed as RosettaSciIO's `tiff/_api.py` does; pixel size and unit, HV, working distance, detector name, magnification, dwell, spot, chamber pressure, stage, date; the databar height so the image is cropped to the data (switch in Calibration, on by default, the full frame kept for export). The inspector's Info section shows the fields; the Results room's acquisition rows take them.

## Done when
Each RosettaSciIO SEM test TIFF yields the same axes, units and metadata fields as the reference JSON (exact strings and numbers); the databar crop equals the reference image height; screenshot of the Image room with a Zeiss file and its Info section.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch.
- A test that fails before and passes after. Numerics compare against `tools/parity/sem` references within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body.
- `tools/run-tests.sh unit` and `core` green; the Swift 6 rules (TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app).
- UI work loads the `swiftui-macos` skill; pure SwiftUI, AppKit only where named in code; a change to what the app draws carries a screenshot in the PR and an XCUITest journey; say "unverified on screen" for anything no drive saw.
- `CHANGELOG` line through the PR title; `docs/status.md` and `ROADMAP.md` updated; leftover work becomes an issue, not a comment.
- No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md`.
