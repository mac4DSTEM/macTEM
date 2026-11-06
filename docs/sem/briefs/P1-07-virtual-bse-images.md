# P1-07: Virtual BSE images (milestone 1, figure F1)

- **Repo:** macTEM, workstream Patterns room
- **Plan:** phase 1, M1, figure F1 in `docs/sem/north-star.md`
- **Prerequisite:** P1-06; parity references for `VirtualBSEImager`
- **Size:** about 3 h

## Scope
`VirtualBSEImaging` in `Sources/TEMCore/SEM/`: a detector grid (rows x columns, 5 x 5 default), the sum of each tile per pattern as an image, an ROI image from a rectangle, and the RGB image from three tiles (kikuchipy's `get_rgb_image` with its per-channel rescale and the `percentiles` and `dtype_out` rules); Accelerate for the sums, float64 reference path first. The inspector's Virtual images section: grid rows and columns, the three tile pickers for R, G, B, a "Tiles" button that shows all tiles as a grid in the bottom pane, the ROI tool on the live pattern pane; the navigator map switches to the RGB image when one is set.

## Done when
F1 reproduced: the 5 x 5 grid images and the RGB image of nickel_ebsd_large equal the reference arrays (sums exact, RGB exact after the same rescale), posted beside the reference figure in the PR; journey extended with the Virtual images section; screenshot.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch.
- A test that fails before and passes after. Numerics compare against `tools/parity/sem` references within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body.
- `tools/run-tests.sh unit` and `core` green; the Swift 6 rules (TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app).
- UI work loads the `swiftui-macos` skill; pure SwiftUI, AppKit only where named in code; a change to what the app draws carries a screenshot in the PR and an XCUITest journey; say "unverified on screen" for anything no drive saw.
- `CHANGELOG` line through the PR title; `docs/status.md` and `ROADMAP.md` updated; leftover work becomes an issue, not a comment.
- No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md`.
