# Decisions

Engineering decisions taken without asking, as the SEM program requires (Paul, 2026-11-06: "decide and log in
docs/decisions.md, never ask"). One entry per decision: date, what, why, what would reverse it. Newest at the bottom.

## 2026-11-06 — CI: every PR check on GitHub's runners, only the UI journeys on the Mac

**What.** `core` and `inventory` move from the org's Mac runner to `macos-26`, where `unit` already ran; the four
required checks (`unit`, `core`, `inventory`, `kit boundary`) and the lint jobs now never touch the Mac. A new workflow
`ui.yml` runs the XCUITest journeys on the Mac runner nightly (03:30 UTC) and by hand, uploads the step screenshots and
the result bundle as run artifacts, and has no fallback to a GitHub runner: while the Mac is offline it queues. The
SwiftPM repository cache (`~/Library/Caches/org.swift.swiftpm`) is restored per `Package.resolved` in the three macOS
jobs so the kit clones are not fetched again on an unchanged pin set; the builds themselves still start from scratch,
which the zero-warnings gate needs.

**Why.** The last PR run before this change had `core` queued 15 minutes on the Mac (run 42277943410); with the Mac
asleep a PR could not merge at all. On `macos-26` the same jobs took about 3 min (`core`) and under 1 min
(`inventory`) in late October, and `unit` takes 8 to 10 min. Only the journeys need a screen and the Mac's permission
grants, so only they stay.

**Also decided.** `ui.yml` uses the Mac's selected Xcode, not ci.yml's pinned 26.6: the UI runner app keeps its Screen
Recording and Accessibility grants by path, and that path is what the Mac's own toolchain builds and what Paul drives.
`ui.yml` is not a pull-request trigger and not a required check: a room PR runs the journeys by hand
(`workflow_dispatch` with its journey names) and attaches the artifact's screenshots to `release-assets/sem/`.
`scientific` stays unrun in CI until the parity environment of the SEM program exists (`tools/parity`).

**Reversal.** Set the jobs' `runs-on` back to the `vars.MACEM_MAC_RUNNER` expression (git history of ci.yml, before
this entry) if the hosted macOS queue (free plan, few concurrent macOS jobs) becomes the slower path again.
