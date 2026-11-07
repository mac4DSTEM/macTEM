# P2-03: Image quality and average neighbour dot product maps (figure F3)

- **Repo:** macTEM, workstream Processing (TEMCore numerics + Patterns room map choice)
- **Plan:** phase 2, M2, figure F3; catalogue section 2
- **Prerequisite:** Patterns room on main (#144) for the map choice; numerics run now
- **Size:** about 4 h

## Scope
`get_image_quality` (Krieger Lassen: the FFT power spectrum's inertia, normalised as kikuchipy does, `normalize=True`, the frequency vectors) and `get_average_neighbour_dot_product_map` (window, zero-mean normalised patterns, the dot products, the edge rule) in TEMCore, over the pattern access row by row with progress and cancel. In the Patterns room the map picker (P1-07's `MapChoice`) gains IQ and ADP; Export Map PNG covers them.

## Done when
F3 reproduced: the IQ map of nickel_ebsd_large (after static + dynamic background, as kikuchipy's docs) within rtol 1e-5 of the reference; ADP map rtol 1e-5; both in the room on the demo scan; journey step.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
