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

## 2026-11-06 — SEM program: D-SEM-1 to D-SEM-16

Numbered so briefs and PRs can cite them; the room designs keep their own D1-D8 in `sem/design/README.md`. One line of context, the decision, the reason.

| # | Date | Decision | Reason |
|---|---|---|---|
| D-SEM-1 | 2026-11-06 | SEM code lives in `Sources/TEMCore/SEM/` (readers, patterns, rotations, indexing, maps) and `Sources/TEMSession/` owners, over FormatoKit's HDF5 layer and ImagoKit's images; no kit changes | the program's boundary; a kit move is a later program once the API has settled |
| D-SEM-2 | 2026-11-06 | North star: kikuchipy `nickel_ebsd_large` (EBSD) and exspy `EDS_SEM_TM002` (SEM-EDS) | both public, licensed (CC BY 4.0, GPL-3.0), small enough to ship as demo data, with published figures and Python code that emits every reference number |
| D-SEM-3 | 2026-11-06 | The parity Python environment is `tools/parity/sem` on CPython 3.14 with a full lock (`requirements.lock`), separate from the existing TEM lock | built 2026-11-06: kikuchipy 0.13.1, pyebsdindex 0.3.10.1, numba 0.68.1, orix 0.15.0, diffsims 0.7.0, hyperspy 2.5.0, exspy 0.3.2, rosettasciio 0.15.0 and numpy 2.5.4 install and import on 3.14.6; one stack per program keeps each lock reproducible |
| D-SEM-4 | 2026-11-06 | pyebsdindex is ported although it is not GPL: it is a US NRL public-domain work with a worldwide grant; `NOTICE` acknowledges NRL and marks the port as a modified derivative | the licence asks exactly that; it is the only open Hough indexer with tests |
| D-SEM-5 | 2026-11-06 | Rooms: Patterns ⌘6, Indexing ⌘7, Maps ⌘8, Results moves to ⌘9; no Simulation room | nine rooms is the ceiling of the ⌘1-9 keys; the simulation is a layer of the Indexing room's pattern pane. Room design decisions D1-D8: `sem/design/README.md` |
| D-SEM-6 | 2026-11-06 | Briefs live in `docs/sem/briefs/` in the repo (and are copied to the project's shared folder) | the program runs from the repo; the shared folder is not versioned |
| D-SEM-7 | 2026-11-06 | SEM-EDS quantification ships what exspy ships (line intensities, k-factor quantification with supplied factors); no ZAF | there is no GPL Python ZAF reference with tests; DTSA-II is Java and public domain and can become a later reference |
| D-SEM-8 | 2026-11-06 | Grains, KAM, GOS and GND take DefDAP (Apache-2.0) as the reference, orix for everything orientation | orix has no grain segmentation; DefDAP's is tested and its licence is compatible |
| D-SEM-9 | 2026-11-06 | Hex-grid EBSD maps are refused with a sentence in phase 1 | kikuchipy refuses them; square-grid conversion is a phase 5 issue |
| D-SEM-10 | 2026-11-06 | Zenodo-only datasets (si_wafer, ni_gain, master patterns) are fetched on the Mac; the cloud sandbox reaches PyPI and raw.githubusercontent.com only | measured 2026-11-06: zenodo.org is refused by the sandbox proxy |
| D-SEM-11 | 2026-11-06 | Phase 1 orders the formats kikuchipy h5ebsd first (the north-star file), then Oxford h5oina, Bruker and EDAX h5ebsd, EDAX binary, Oxford binary, NORDIF, ctf and ang maps | the first figure needs the first; the others follow by how common they are in labs |
| D-SEM-12 | 2026-11-06 | References are committed bundles under `tools/parity/sem/references/<milestone>/<case>/` (a `manifest.json` with package, version, function, stack, input sha256, values, scalars and arrays with rtol/atol; raw little-endian `.bin`), emitted by `emit.py`, held to the stack by `check.py` in `.github/workflows/sem-parity.yml` (Linux); Swift ports compare in `macTEMTests` through `SEMParityReference.swift` | small committed references let every port test run on hosted macOS without Python; drift on either side is red |
| D-SEM-13 | 2026-11-06 | Tolerances: readers, indices and metadata exact; float64 reductions rtol 1e-7; uint8-rounded results within 1 count; float32 matching scores rtol 1e-5; never stricter than the reference package | the suite's numbers rule (match, never exceed) |
| D-SEM-14 | 2026-11-06 | Nothing over 1 MiB is committed; datasets come through `fetch-data.sh` from `data-manifest.txt` (sha256), Zenodo items marked manual | the repo stays small; D-SEM-10 |
| D-SEM-15 | 2026-11-06 | The Oxford `.ctf` reader is tested on a planted 4×5 two-phase file (`make_fixtures.py`); the Tescan TIFF reader waits for a public fixture | orix 0.15.0 has no ctf writer and no public `.ctf` of known licence was found; no public Tescan TIFF |
| D-SEM-16 | 2026-11-06 | The SEM TIFF metadata reference is `hyperspy.api.load` over rsciio's tiff plugin | the vendor-tag parse happens on that path, not in `rsciio.tiff.file_reader` alone |
| D-SEM-17 | 2026-11-06 | The frequency-domain dynamic background (`PatternProcessing.dynamicBackground`) is the direct separable nearest-edge correlation with kikuchipy's Gaussian window, not a padded FFT | kikuchipy's window is an outer product of one `scipy.signal.windows.gaussian`, its padding is edge replication and its crop reads no zero sample, so the padded real FFT evaluates exactly this correlation (parity 5e-7 relative, `docs/parity.md`); the direct form keeps the float64 reference path with no padding bookkeeping; a Metal or Accelerate path behind the same parity test is phase 2's optimisation |
| D-SEM-18 | 2026-11-06 | Integer patterns match kikuchipy within one grey level on at most 1 % of a pattern's pixels (0.2 % of a whole set); rescaled float values within 1e-5 relative | kikuchipy rescales in float32 under numba fastmath and truncates to the integer type, so a float64 port lands one level lower or higher where the float32 value crosses an integer (measured 0.006 % to 0.10 % of the nickel set's pixels); exactness would mean reproducing float32 fastmath rounding instead of the reference numbers |
| D-SEM-19 | 2026-11-06 | The Oxford readers return value types of their own (`OxfordBinaryReader` → `EBSDPatternSet`, `CTFReader` → `CrystalMapData`) instead of waiting for P1-01's `EBSDDataset` (macTEM#125); a follow-up issue folds them together once both are on `main`. orix-data's `Ti_orientations.ctf` is an MTEX export without the Channel Text File header (first line names thirteen columns); `CTFReader` reads that form too, keeps every column under its name and leaves the phase to the caller, and the parity test attaches 622 as `orix.data.ti_orientations` does | the brief allows own types with adoption at closeout and the PRs stay independent; orix's reference reading of the Ti file has no phase list, so inventing a header would test numbers orix never produced |
| D-SEM-20 | 2026-11-06 | A hexagonal-grid EDAX `.up2` is read by `EDAXBinaryReader` as one row of patterns with kikuchipy's warning as its note, and refused at the app's door (`EDAXOpening`) together with a `HexGrid` `.ang` | the reader stays parity-exact with kikuchipy, which reads such a file rather than refusing it; the app lays out square grids only (D-SEM-9) |
| D-SEM-26 | 2026-11-06 | No stop at the phase-1 gate and no 24 h objection window at later gates: each gate posts its figures beside the references for review and the next wave starts as soon as its prerequisites are on `main` (`briefs/README.md`, phases 2 to 8 written now) | Paul, 2026-11-06 22:32: "why stop until i say continue? … finish macEM fully"; numbered 26 because 21 to 25 are taken by open PRs (#144, P1-07) |
