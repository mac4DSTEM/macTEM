# P5-01: Grains, boundaries, KAM, GOS and GROD (figures F11, F12)

- **Repo:** macTEM, workstream Maps and grains (TEMCore numerics)
- **Plan:** phase 5, M5, figures F11 and F12; catalogue section 5
- **Prerequisite:** P3-03 merged
- **Size:** about 6 h

## Scope
DefDAP (Apache-2.0, notice kept): `find_boundaries` (misorientation threshold between neighbours, phase boundaries), `find_grains` (flood fill, minimum size), grain sizes and equivalent diameters, the neighbour network; KAM (`calc_kam`, the kernel and threshold), GOS and grain average orientation (`calc_grain_av_oris`, `calc_grain_mis_ori`), GROD; ASTM E112 grain size number from the mean intercept (formula by the standard; tested on hand numbers).

## Done when
F11 reproduced: grain labels on Ti_orientations.ctf equal DefDAP's up to relabelling, sizes equal; F12: KAM atol 1e-6 rad, GOS atol 1e-6.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
