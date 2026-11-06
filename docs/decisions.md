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

## 2026-11-06 — SEM TIFF metadata in the Image room (P1-05): D-SEM-17 to D-SEM-21

| # | Date | Decision | Reason |
|---|---|---|---|
| D-SEM-17 | 2026-11-06 | SEM TIFF metadata (Thermo/FEI, Zeiss, Tescan) is read in `TEMCore/SEM/SEMImageMetadata.swift` from the vendor tag through FormatoKit's public TIFF tag walker; FormatoKit's `AcquisitionMetadata` stays the Acquisition section's first nine rows and the SEM record adds its rows beneath them, in the design's order | no kit change (D-SEM-1); the kit's nine TEM fields cannot hold pixel size, working distance, stage, pressure or a databar |
| D-SEM-18 | 2026-11-06 | The databar is cut only where the file states its height and the height fits the image: Thermo `[PrivateFei] DatabarHeight` with `[Image] ResolutionY` (all five Helios test files agree), Tescan `[MAIN] ImageStripSize` below the image height. Zeiss files are never cropped | SmartSEM draws its data zone into the scan's own rows and records no height (the `ap_line_counter` of one test file matches the zone's edge; one file is no rule, a later issue if a documented field appears). Nothing is guessed |
| D-SEM-19 | 2026-11-06 | Tescan is read as NexusLIMS's public `tescan_tif` extractor reads tag 50431 (`[MAIN]`/`[SEM]` INI; metres, volts, seconds, pascals), every value marked unvalidated until a public fixture exists (D-SEM-15) | RosettaSciIO has no Tescan branch and no public Tescan test file was reachable; the keys and units come from a published reader, not a guess |
| D-SEM-20 | 2026-11-06 | `Databar · Hide · Show` (Display section, Hide by default) is a UserDefaults setting applied at read time; flipping it reads the selected file again (`OpenItems.reread`). Show shows the whole frame; the design's footer strip under the picture is a follow-up issue | one image per item keeps every room, measurement and export on the same pixels; a second resident copy per item would double the memory of a 4k SEM frame |
| D-SEM-21 | 2026-11-06 | The SEM TIFF parity runs in the unit target on the vendor tags of RosettaSciIO's eight SEM test files (the tag bytes as fixtures, 72 KB, GPL-3.0-or-later) against `macTEMTests/Fixtures/sem-tiff/sem-tiff-reference.json`, written by `tools/parity/sem/sem-image/reference.py` with rsciio 0.15.0 + tifffile 2026.9.20; folding it into `tools/parity/sem/emit.py`'s bundles (D-SEM-12, D-SEM-16) is a follow-up once #130 is on main | the gate runs on every PR on the hosted runner without the 9 MB of images or the network, and the PR stays independent of #130 (one PR, never stacked) |
