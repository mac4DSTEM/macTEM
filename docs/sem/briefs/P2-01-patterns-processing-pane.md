# P2-01: Processing sections of the Patterns room (background, rescale, binning)

- **Repo:** macTEM, workstream Patterns room
- **Plan:** phase 2, M2; catalogue section 2; design `design/pattern-processing.md`
- **Prerequisite:** Patterns room on main (#144); P1-07 virtual BSE merged or rebased onto
- **Size:** about 5 h

## Scope
The design's Processing sections in the Patterns room inspector: static background (subtract, divide, scale; from the file or the mean pattern), dynamic background (frequency or spatial, sigma), rescale and normalise intensity (`rescale_intensity`, `normalize_intensity`: zero mean, unit variance), binning/downsample (`EBSD.downsample`, `_bin2d`). Live on the pattern pane (processed beside raw, toggle), applied to the whole set as the room's verb with progress and cancel, the result a processed dataset in memory the map and the next steps read. `PatternProcessing` (#133) holds the background numerics; add rescale, normalise and binning there with parity rows.

## Done when
The design's acceptance list; rescale/normalise/binning exact (float32 rounding) against new m2 bundles; F2 reproduced through the room on the shipped nickel scan (pattern (0,0) bit-identical to the reference after static + dynamic subtract); journey step.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes mac4DSTEM/macTEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
