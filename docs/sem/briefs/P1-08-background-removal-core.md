# P1-08: Static and dynamic background removal in TEMCore (figure F2)

- **Repo:** macTEM, workstream Processing (parity-backed, no room needed)
- **Plan:** phase 1 end, M1, figure F2; catalogue section 2
- **Prerequisite:** parity references for `remove_static_background` and `remove_dynamic_background`
- **Size:** about 3 h

## Scope
`PatternProcessing` in `Sources/TEMCore/SEM/`: static background subtract and divide with kikuchipy's rescale rules per dtype (`_remove_static_background_subtract/_divide`, `rescale_intensity`), the static background from the file or the mean pattern; dynamic background by Gaussian blur in frequency space (`_dynamic_background_frequency_space_setup`, sigma = pattern width / 8 default, the padding and the truncate rule) and in spatial space (scipy `gaussian_filter` semantics), subtract and divide; `get_dynamic_background`. Float64 on Accelerate as the reference path; ImagoKit's FFT for the frequency route. Exposed to the room in phase 2 (P2-01); this brief lands the numbers and their tests only.

## Done when
F2 reproduced: pattern (0,0) of nickel_ebsd_large after static (subtract) then dynamic (subtract, frequency, sigma default) removal equals the reference within kikuchipy's own tolerance (uint8 output exact after rescale; the float32 intermediate at rtol 1e-5), the whole 55 x 75 set within the same bound; rows in `docs/parity.md`.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch.
- A test that fails before and passes after. Numerics compare against `tools/parity/sem` references within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body.
- `tools/run-tests.sh unit` and `core` green; the Swift 6 rules (TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app).
- UI work loads the `swiftui-macos` skill; pure SwiftUI, AppKit only where named in code; a change to what the app draws carries a screenshot in the PR and an XCUITest journey; say "unverified on screen" for anything no drive saw.
- `CHANGELOG` line through the PR title; `docs/status.md` and `ROADMAP.md` updated; leftover work becomes an issue, not a comment.
- No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md`.
