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

## 2026-11-06 — SEM program: D-SEM-1 to D-SEM-24

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
| D-SEM-21 | 2026-11-06 | The Patterns room holds one dataset per window, as the EDS and EELS rooms do: no Open Files row, the batch's first EBSD file is the one opened | the sidebar's file list is the image rooms'; sifting several scans (design §1) is a later slice with its own issue |
| D-SEM-22 | 2026-11-06 | Patterns takes ⌘6 at once and Results moves to ⌘7; Results moves again to ⌘9 as Indexing and Maps land (the room list is one row per built room, `WorkspaceArea.allCases`) | a key for a room that does not exist yet would open nothing; design D1's final order holds once the rooms do |
| D-SEM-23 | 2026-11-06 | The Patterns room's demo entry (Help > Open Demo Data, Try Demo Data) opens the shipped nickel scan (`DemoDocuments.Shipped.nickelEBSD`, #127) through the app's own Open; the room's tests and journey use a generated dataset (`DemoDocuments.ebsd`, six grains of cosine bands, `--demo-ebsd-fixture`) answered from memory through `EBSDPatternAccess` | the menu shows real data as every other shipped entry does; the tests need planted numbers to assert against, and FormatoKit has no HDF5 writer, so the generated set is in memory, not a file |
| D-SEM-24 | 2026-11-06 | P1-06's scan map is the mean intensity of every pattern; P1-07 replaces it with the virtual BSE and adds the tiles, the bottom pane, ⌘P's pinned list and the ROI tool | the design's first picture is the virtual BSE (§2); the mean is its one-tile case and lets the room land before `VirtualBSEImaging` exists, with no placeholder in the code |
| D-SEM-35 | 2026-11-06 | The orientation core (P3-01) is orix 0.15.0 ported into TEMCore (`Sources/TEMCore/SEM/Orientation/`) as plain float64 Swift loops on `SIMD4<Double>` quaternions, not DiffractoKit's `DiffractoOrientation` and not Accelerate; `PointGroup.axisOrders` groups rotation axes by their 10-decimal rounding where orix's `get_axis_orders` compares them exactly; `reduce` keeps orix's loop for two different groups | DiffractoOrientation is matrix-based, holds the proper Laue groups only and returns the smallest-angle equivalent where orix does not, so it cannot be held to orix's numbers; the kit-boundary gate (D15) keeps Accelerate and simd out of the app and a quaternion loop is cheap (a 1000 x 1000 map reduces in one pass over 12 to 24 elements); exact float comparison of axes would split a four-fold axis on a 1-ulp product difference, rounding gives orix's intended orders (all 41 group objects and 69 zones match orix within 1e-10); parity is the claim of every SEM port, so orix's reduce is kept and its multi-phase caveat stated in docs/parity.md |
| D-SEM-36 | 2026-11-06 | The image quality and average neighbour dot product maps (`PatternQuality`, figure F3) match kikuchipy within rtol 1e-5 on kikuchipy's own input patterns; the end-to-end F3 chain on the app's own corrected patterns within rtol 1e-2 (IQ) and 5e-3 (ADP); both maps run on the CPU in float64 without a Metal path | the image quality moves about 5e-4 relative when 0.2 % of the pixels shift by one grey level, so D-SEM-18's background differences propagate into the chain (float64 replica: 5.3e-3 and 1.1e-3 at worst); the function itself agrees to 1e-7 (IQ) and 6e-7 (ADP); 4125 patterns of 60 x 60 take well under a second (`docs/parity.md`, Pattern quality) |
| D-SEM-38 | 2026-11-06 | The Nye tensor and GND density (P5-03, `NyeTensor`) keep the x and y lattice-curvature derivatives apart by default (`.separate`); DefDAP 1.3.1's numbers stay one switch away (`.defdap131`) and both are held to bundles: `gnd`/`nye_window` from DefDAP's own `calc_nye` with its line `betadery = betaderx` replaced by a second array, `gnd_defdap_1_3_1`/`nye_defdap_1_3_1_window` from DefDAP as shipped, rtol 1e-5 with atol 1e6 m⁻² | that line makes both derivative arrays one object, so DefDAP builds the Nye tensor from the y neighbour twice and its GND map is not Pantleon's (2008); the line is the same on DefDAP's master and develop branches today. Scientifically correct is the program's bar, parity the method: the corrected reference is DefDAP's code with one asserted line changed, not a rewrite. The atol sits nine decades below any physical density and above the rounding of R − I between identical neighbours (about 10 m⁻²) |
| D-SEM-39 | 2026-11-06 | The slip-analysis references (`m5/slip-ti`, `m5/slip-sdss`) build DefDAP's map from float64 numbers of the files (`PythonDictLoader`), not DefDAP's .ang loader: the EDAX angles get that loader's frame change (φ1 − π/2, wrapped into [0, 2π)) in float64 and the sdss phases are named by space group (austenite 225 → `cubic_fcc`, ferrite 229 → `cubic_bcc`); the Ti map (an MTEX export without a phase header) takes α-Ti a = 2.951 Å, c = 4.684 Å. The app's Schmid and trace views use `SlipPhase.analysisSlipSystems`, DefDAP's systems without the twelve rows of `cubic_bcc` whose slip direction leaves its {123} plane; parity tests the file as DefDAP reads it | DefDAP's .ang loader parses in float32 and names every cubic phase bcc (space group 229, "can't determine"), which would test float32 rounding and slip the austenite on bcc systems; trace angles are arccos values, where float32 inputs move the angle by up to 1e-4 rad near 0 and π against a 1e-6 tolerance. Twelve of the 24 {123}<111> rows in DefDAP's `cubic_bcc.txt` (e.g. (123)[111], n·d = 6/√42) are no slip system, so their Schmid factors would put physically impossible systems on the map |

## 2026-11-06 — NORDIF: follow kikuchipy on the damaged settings files, read Setting.txt by section and key

**What.** The NORDIF readers (`Sources/TEMCore/SEM/NORDIF`, brief P1-04) treat kikuchipy's three damaged settings
files as kikuchipy 0.13.1 does, not as the brief guessed ("the three bad settings files refused each with its
sentence"): `Setting_bad1.txt` and `Setting_bad2.txt` are refused for calibration patterns with one sentence (kikuchipy
raises `ValueError`), while `Setting_bad3.txt` reads in both readers, its missing `Top` corner counting as 0 and its
missing electron-image `Resolution` leaving the area shape unknown; all three still read the acquisition patterns.
`Setting.txt` is read by section and key, not by kikuchipy's fixed line offsets, which gives the same values on every
file of the parity set and refuses a file whose required line is missing by naming the section and the key.

**Why.** The parity reference is the behaviour, and a reader that refuses what kikuchipy reads would fail the user on
a file the Python stack accepts. The by-key lookup survives a reordered or extended settings file, where an offset
reads the wrong line silently.

**Also decided.** Until P1-01's `EBSDDataset` (macTEM#125) merges, the NORDIF scan is its own value type
(`NORDIFScan`, a uint8 block in map order); adopting `EBSDDataset` is a follow-up issue filed at closeout. The
bitmaps are decoded by a small reader of the 8-bit greyscale BMP NORDIF writes, not by ImageIO, so the parity stays
bit-exact without colour management; a bitmap of any other kind is refused with a sentence.

**Reversal.** Refuse `Setting_bad3.txt` once the Patterns room shows that an unknown area shape breaks a view; add
the sentence to `reference.json` and the test.
