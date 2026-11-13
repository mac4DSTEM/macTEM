# P1-09: Shipped demo EBSD data and the "Try Demo Data" door

- **Repo:** macTEM, workstream Demo data
- **Plan:** phase 1, M1; `docs/data-sources.md`
- **Prerequisite:** P1-01 (the reader), `data-sources.md` merged with the licence lines
- **Size:** about 2 h

## Scope
Ship `nickel_ebsd_large/patterns_v2.h5` (15.4 MB, CC BY 4.0, Aanes et al.) in the app bundle as a resource with its licence text in `Licenses/` and a `NOTICE` line; `tools/large-files.allow` gets the row with its reason; the welcome window's "Try Demo Data" opens it into the Patterns room (`DemoDocuments` grows an `ebsd` case that is a file, not a generator, with its truth: shape 55 x 75, 60 x 60, md5); `--demo-ebsd` launch argument for the journeys; the SEM-EDS demo spectrum (`EDS_SEM_TM002.hspy`, 31 KB) ships the same way for the EDS room in phase 7 and opens today as a spectrum.

## Done when
"Try Demo Data" lists the EBSD set and opens it; `DemoDataTests` pins the md5 and the shape; `inventory` passes with the allow row; the journey `DemoDataJourney` extended; the App Store build size stays under the store's cellular limit note in `docs/app-store/`.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch.
- A test that fails before and passes after. Numerics compare against `tools/parity/sem` references within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body.
- `tools/run-tests.sh unit` and `core` green; the Swift 6 rules (TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app).
- UI work loads the `swiftui-macos` skill; pure SwiftUI, AppKit only where named in code; a change to what the app draws carries a screenshot in the PR and an XCUITest journey; say "unverified on screen" for anything no drive saw.
- `CHANGELOG` line through the PR title; `docs/status.md` and `ROADMAP.md` updated; leftover work becomes an issue, not a comment.
- No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md`.
