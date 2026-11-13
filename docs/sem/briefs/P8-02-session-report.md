# P8-02: Session report and figure export for the SEM rooms

- **Repo:** macTEM, workstream Export and reports
- **Plan:** phase 8, M8; design `design/export-and-reports.md`
- **Prerequisite:** P3-04 merged; the rooms present join as they land
- **Size:** about 5 h

## Scope
The design's Export sections of the Patterns, Indexing and Maps rooms (PNG/PDF with scale bar and colour key through the app's `ImageExport`), the Results room rows for SEM numbers (grain statistics, indexing rates, EDS quantification), and the session report (every figure of the session with its parameters, the parity references named) as one PDF.

## Done when
The design's acceptance list; snapshot tests of the report on the demo data; journey.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
