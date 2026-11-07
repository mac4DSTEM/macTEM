# P5-03: GND density, Schmid factors and slip-trace analysis

- **Repo:** macTEM, workstream Maps and grains (TEMCore numerics)
- **Plan:** phase 5; catalogue section 5
- **Prerequisite:** P3-01 merged (P5-01 for per-grain values)
- **Size:** about 6 h

## Scope
DefDAP: `calc_nye` (the Nye tensor from lattice curvature, Pantleon 2008, the GND density), `defdap.crystal.SlipSystem` with DefDAP's slip-system files (fcc, bcc, hcp; Apache-2.0 data), Schmid factors per system and per grain for a loading direction, `Grain.calc_slip_traces` (trace angles in the map plane per system).

## Done when
GND rtol 1e-5, Schmid factors atol 1e-6, slip-trace angles within 1e-6 rad of DefDAP on Ti_orientations.ctf (hcp) and the sdss phases (bcc, fcc).

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
