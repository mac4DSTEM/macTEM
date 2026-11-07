# P2-05: NLPAR pattern denoising

- **Repo:** macTEM, workstream Processing (TEMCore numerics)
- **Plan:** phase 2; catalogue section 2
- **Prerequisite:** none (runs now)
- **Size:** about 4 h

## Scope
Port `pyebsdindex.nlpar.NLPAR` (Brewick, Kalidindi, Rowenhorst 2019): the lambda optimisation (`opt_lambda`, the chi-square targets), the search window, the noise estimate, the weighted average, on float32 as upstream; the CPU float64 reference path plus a Metal float32 path if the 55 x 75 set takes over 2 s on CPU. pyebsdindex is a US federal work: name it as derived and modified in the Swift header and `NOTICE`. Exposed in P2-01's Processing list once both are in.

## Done when
NLPAR on nickel_ebsd_large: lambda within rtol 1e-4 of pyebsdindex, the denoised set within pyebsdindex's own float32 test tolerance; a Metal path, if added, checked against CPU at that tolerance.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
