# export-parity

macTEM's export from the Image room (V1-10 slice 1: `ImageExport.render`, `ProfileCSV.text`, `ExportFile`; TEMCore, through
Package.swift's `ExportParity` target) read back with Pillow 12.3.0, numpy 2.5.4 and Python's own `float`
(pinned: `tools/lib/references-lock.txt`; `reference.py` refuses any other version, and the sha256 of ncempy's `dm.py`).
A `scientific` gate (`tools/run-tests.sh scientific`); the pre-registration is archive: roadmap-registrations-2026-10-15.md V1-10, "Completed at pickup — slice 1"
(P1, P3, P4 and the two added checks P5 and P6; Gate B round 1 added to P3 and P5 and the check P7, below). Run
`tools/parity/export-parity/run.sh`, redirect it to a log, and read the exit code on its own line.

Pass lines: one `ok` line per check family, `export-parity: all passed — …`, then `extra controls (not registered): 13 of 13
caught by their checks` and, last, `negative controls: 36 of 36 caught by their checks`. The `ok` lines carry the measured numbers
(the largest pixel difference, the largest bar, centroid, band and label errors).

## How the pieces fit

1. `reference.py plant` writes every input and its truth into a scratch directory: raw float32 pixels (NaN and inf included), two
   look-up tables, and `manifest.json` (calibrations, windows, gammas, marks, profile ends, and the bar each case must draw,
   worked by hand in the case's comment).
2. `main.swift` (the harness) renders and writes every PNG and CSV with the production code, and dumps what it held in memory: the
   profile's samples and positions as little-endian Doubles, the bar plan `render` returned, the window fractions it passed, and
   the real images `ImageOpening` returned; for P7 it also draws each label alone, upright, in a plain CoreGraphics context (no
   flip) and dumps the bitmap. It does no checking. It builds the canvas as the app does (`FloatImage.normalized()`,
   the finite range) and restates `DisplayWindow.fractions` (TEMSession is not in the closure).
3. `reference.py check` reads all of it back and prints one `  FAIL  <check>: <detail>` line per failure, then
   `export-parity: N FAILURES in M checks` (exit 1) or `export-parity: all passed — …` (exit 0).
4. The negative controls (below) build the harness against edited COPIES of `ProfileCSV.swift`, `ImageExport.swift` and
   `ImageExport+Overlays.swift` and must each turn `check` red on the check they target.

## What is checked

**P0-open** (support): the planted DM fixture and `test_STEM_image.dm3` (RosettaSciIO at its pin, sha256 and registry checked)
opened by `ImageOpening` equal ncempy 1.16's reading: every pixel, each axis's scale, units and origin, the file name.

**P1, CSV** (`P1-values`, `P1-positions`, `P1-rows`, `P1-header`). Every sample and position cell re-reads with `float()` bit-equal
(`struct.pack("<d")`) to the in-memory Double, `nan` exactly where the sample is NaN; the rows equal the samples in count and order
and the count is ⌈hypot + 1⌉ by the rule; the positions also equal i/(n − 1) of the planted length (the physical length in the
file's unit when both axes are calibrated in one unit, pixels otherwise, 1e-12 relative); on the ramp and the planted DM fixture
the samples equal the analytic profile (1e-5 relative, measured 3e-8). The header: the fixed keys in the registered order, start
and end re-read bit-equal to the planted points, width, samples, image size, each axis's scale, unit and origin (`none` when not
calibrated), the length, the position sentence, the `shown` line only when planted, notes joined by `; ` or `none`, the
`unvalidated (reader note)` clause only when a note says so, the control characters, U+0085, U+2028 and U+2029 turned into
spaces, and the RFC 4180 column header (parsed with `csv`, so a unit with a comma and a quote is read back whole). No BOM, no CR,
one final LF. A profile of no samples writes no file.

**P3, the bar** (`P3-length`, `P3-drawn`). On the export that has the bar and no marks: the label, value, unit, per-pixel scale
and unit, and the planned length (nice / per pixel) equal the case's hand-worked ones (1e-12 relative); Python finds the longest
run of exact white in the bottom-left W/2 × H/3 region itself, and run × x scale equals the label's length within one export pixel
(measured ≤ 0.500, the exact tie of `tie512`; predicted ≤ 0.5), with the unit conversion (nm, µm, mm, m, Å, pm, 1/nm, px) in Python; the run equals the
metadata's `drawn_px` on every one of the bar's 2u rows, exactly, with no white beside it, above or below; `drawn_px` is the
planned length rounded half up (`tie512` plants an exact tie, 62.5 → 63, which half-to-even gets wrong; `frac40` plants 74.40 → 74,
which a bias of +0.2 px gets wrong; a bias below 0.095 px cannot be seen at any fraction); x₀ = 16u, top = H − 15u, height = 2u;
the plan `render` returned equals the metadata. A case whose plate cannot fit is left out and says so.

**P4, the PNG** (`P4-format`, `P4-pixels`). The container, parsed here chunk by chunk: signature, every CRC (the three text
chunks are written by `ImageExport` itself, with its own CRC-32), IHDR W × H, 8 bit, colour type 2 (RGB), an `sRGB` (or an sRGB
`iCCP`) chunk before the image data; Pillow reads mode RGB; `Title`, `Software` and `Description` as text chunks that Pillow's
`im.text` shows too; the Description as JSON with sorted keys at every level and every value equal to the planted truth
(software, file, object, size, both scales or null, the finite raw range, colormap, window in raw values and as the float32
fractions, gamma, masked count, notes, overlay scale, anisotropy, `validation`, `lineage`, the bar entry, the marks' kinds, widths,
labels and points re-read bit-equal). Without overlays, every channel equals the recomputation of the shader's mapping from
the canvas, window, gamma and LUT, round half up, in Double: 0 levels over 36.5 million pixels. The rounding is exact half up
(floor, plus one when the fraction is at least a half), not `floor(x + 0.5)`, which rounds 0.49999999999999994 up. `pow` is
evaluated once per distinct canvas value with `math.pow`, the C library's `pow` that Swift's calls too; numpy's vectorised
`np.power` gives the same bytes on every case (measured once, 2026-10-13, 0 of 36.5 million differ). The canvas is
`FloatImage.normalized()` restated in float32 and the window `DisplayWindow.fractions` restated in float32, so the whole chain
(raw pixel → canvas → window → gamma → LUT → bytes) is Python's own. `uncal640` makes 304,407 of its 307,200 pixels exact ties
(canvas j/256, gamma 1, the gray LUT: t = ½ between two texels, the value i + ½ exactly), where round half up and round half to
even part.

**P5, marks** (`P5-stroke`, `P5-ring`). On black 512² and 1024² plants (u = 1 and 2, no labels): the yellow-weighted centroid
(the red channel) across a horizontal, a vertical, and a 30° stroke in both senses, at every cross-section away from the end
rings, lies within 0.15 export px of the line through the points' pixel centres (the perpendicular offset; measured ≤ 0.066), and
the stroke's weight is 1.5u/cos θ; each ring's centre, on a ring-only plant (a mark whose two points coincide, so no stroke
biases it), within 0.15 px (measured ≤ 0.017), at sub-pixel positions.

**P5-band, a profile's band and an angle's arms** (Gate B round 1; `p5x-u1`, `p5x-u2`, black, no labels). Three profile marks of
width 7, 9 and 11 (× u) at sub-pixel positions (a horizontal, a vertical and a 30° one), and an angle of three non-collinear
points. Away from the line itself and the end rings, every pixel's red channel equals 45.9 times the share of that pixel the
width × length rectangle covers (an 8 × 8 supersample worked out in Python), within 12 levels (measured ≤ 3.8): a band twice as
wide, a band along the line instead of across it, a band scaled by u or no band at all differs by 34 to 46 levels. The angle's
two arms are checked as strokes with P5's own test (`P5-stroke/p5x-u1/angle-arm-1` and `-arm-2`, centroids within 0.15 px), so
an angle drawn through the wrong vertex leaves its first arm with no yellow at the planted place.

**P7, the label** (`P7-label`; `p7-u1`, `p7-u2`, black, three labelled marks and the bar). The harness draws each label alone and
UPRIGHT in a plain CoreGraphics context with the settings the export draws text under (the bytes read top to bottom are the
picture as a person sees it; it does not use `draw`), and `reference.py` cuts the PNG at the place the registration puts the
label (a mark's box at x = min(max(ax + 6u, 2u), …); the bar's label 3u above the bar at x = 16u; the anchors are whole pixels)
and compares: within 2 levels (measured 0). A label never drawn, drawn without its unit, drawn one point off, or drawn upside
down differs by 229 to 255 levels, and a constant bias of 0.04 px in every mark moves the label's crop (P5's 0.15 px band does not
see it). What it shares with the export: the two fonts (`markFont`, `scaleBarFont`), so a changed font size is not caught here
(a look, not a number).

**P6, the footprint** (`P6-footprint`). Outside the plate's and the marks' grown boxes (the plate's box is the largest the fit
rule allows around a generous bound on the label, not the writer's own layout numbers; the marks' boxes grow by the ring, the
stroke, the band and a generous label box, plus 3 px), the export with both overlays equals the overlay-free export bit for bit;
with the marks off, the marks' boxes equal it; with the bar off, the plate's box does; the export with both equals the three
composed (plain, the bar's box from the bar-only export, the marks' boxes from the marks-only export); and each overlay does
change pixels inside its own box (not vacuous). The overlay-free export is P4's numpy recomputation, not the harness's own plain
PNG (see the notes on the controls). A bar that is left out changes nothing. Cases of 4096² are not run through P6 (the boxes
are the same; the two plain exports are P4's).

**R-P1, the Results room's CSV** (`R-P1/header`, `/text`, `/values`, `/mark-values`, `/spot-values`, `/closed-form`, `/planted`; and
R-P2's reference side, `R-P2/sentences`, `/never-validated`; V1-10 slice 3, archive: roadmap-registrations-2026-10-15.md "Slice 3, the Results room and one tidy
CSV"). One case, `results`, on a 128 × 128 lattice with two non-dyadic frequencies (0.1731 and 0.0627 cycles per pixel) at 0.0731 ×
0.0789 nm: three marks of every kind built by `ResultRow`'s builders from non-dyadic points (a second distance and angle with no
calibration, an angle with an arm of zero length), three spot clicks through ImagoKit's `SpotMeasurement.measure` (the peak, the peak on a 64 × 64
crop, the DC: refused), and one raw row of planted bit patterns (+0, −0, NaN, ±inf, the smallest and the largest Double, 0.1, 1/3,
a words-only entry, and a label, unit, text and refusal each holding a comma, a quote and a newline). The file is written by
`ResultsCSV.text` and read back with Python's `csv` and `float`: the columns; one line per quantity (and one `outcome` line per
refusal); every value bit-equal to the Double in memory (`nan` for NaN, empty for a words-only line); every group, id, label,
quantity, unit, text, validation and lineage cell equal to the row's; the numbers equal the owners' own (`ImageMeasurement` and
`SpotMeasurement` read by the harness directly, so a builder that files the wrong number under a name is not its own witness) and
the closed forms to 1e-12 relative (distance, angle, |q| = hypot(qx, qy), d = 1/|q|); the header's software, file, object, size,
scales, session and notes, and **one `# validation (<product>):` line per product present, each the producer's constant the
harness dumped** (`ImageMeasurement.validation`, `ProfileCSV.validation`, `FFTExport.spotsValidation`) and none for an absent
product. R-P2's reference side: every product has a sentence (all nine of `ResultRow.Product`, named in reference.py's `RESULTS_PRODUCTS`,
which a unit test holds equal to the app's list; calibration and ring come from the Diffraction room, edsComposition from the EDS room, eelsThickness and eelsEdge from the EELS room) and no sentence claims "validated" (only "unvalidated" may contain it).
A second case, `results-unvalidated`, plants the same pixels in a file whose reader notes say "Unvalidated scale (test)": every
`# validation (...)` header line and every validation cell must then end with `, unvalidated (reader note)`, as the profile CSV's
does (unvalidated stays labelled); control (42) drops it. A profile row's sentence is `ImageMeasurement.validation`, then `; samples (the
Image room's profile CSV): `, then `ProfileCSV.validation` (its numbers are closed forms, its samples scikit-image's).
Controls (37)-(41) are registered with it; (42) is an extra.

## Datasets (`reference.py plant`)

Integer-valued pixels (so a window and a raw range are exact in float32), asymmetric under flips and transposes, with the
bottom-left W/2 × H/3 region capped at 30 % of the range so that no pixel under or around the plate can be exact white; the range
is pinned by a minimum at (0, 0) and a maximum at (0, W − 1). Two LUTs: `gray` (texel i = (i, i, i)) and `planted-a` (random
texels 0–250 per channel, so nearest sampling and linear interpolation differ almost everywhere and no colour is exact white).
The bar each case must draw is worked by hand in `reference.py` (target T = min(70u, W/4) px; nice = the nearest of 1, 2, 5, 10 ×
10ⁿ to per pixel × T, the boundaries at mantissa 1.5, 3.5, 7.5, an equal mantissa going up; drawn = nice / per pixel rounded half up):

| Case | Size, u | Calibration | LUT, window, gamma | Bar (label, length, drawn) |
|---|---|---|---|---|
| `aniso512` | 512 × 384, 1 | x 0.5 nm, y 0.8 nm | planted-a, full, 1 | 50 nm, 100.0, 100 (35 nm is on the 3.5 boundary and goes up; on y's scale it would be 62.5 → 63) |
| `big4096` | 4096², 8 | 5 nm | gray, full, 2.2 | 2 µm (2000 nm laddered), 400.0, 400 |
| `up512` | 512², 1 | 0.0004 µm | planted-a, 16384–40960, 0.5 | 20 nm (0.02 µm laddered down), 50.0, 50 |
| `velox4096` | 4096², 8 | 4.46179e-11 m (shown in nm) | gray, 1024–3072, 1 | 20 nm, 448.25, 448; notes with `unvalidated` |
| `ang1000` | 1000 × 700, 1 | 0.1 Å, file name `sample Å µ.dm4` | planted-a, full, 2.2 | 5 Å, 50.0, 50; a mark labelled `1.25 Å` |
| `recip256` | 256², 1 | 2 1/nm | gray, full, 0.5 | 100 nm⁻¹, 50.0, 50 |
| `uncal640` | 640 × 480, 1 | none | gray, full, 1; every integer 0–256 (ties) | 50 px, 50.0, 50 |
| `frac512` | 512², 1 | 0.66 nm | gray, full, 1 | 50 nm, 75.76, 76 (a floor gives 75) |
| `tie512` | 512², 1 | x 0.8 nm, y 0.5 nm (x coarser than y) | gray, full, 1 | 50 nm, 62.5, 63 (an exact tie; half-to-even gives 62; the bar on y would be 100 px) |
| `frac40` | 512², 1 | 0.672 nm | gray, full, 1 | 50 nm, 74.40, 74 (a bias of +0.2 px gives 75) |
| `unitsmix512` | 512 × 384, 1 | x 0.5 nm, y 0.5 Å (the same number, two units) | gray, full, 1 | 50 nm, 100.0, 100; `anisotropic` must be true |
| `yonly512` | 512 × 384, 1 | no x, y 0.8 nm | gray, full, 1 | 50 px, 50.0, 50 (the unit is x's, so pixels); `y_scale` is still the file's |
| `nan400` | 400 × 300, 1 | 1.25 nm | planted-a, 8192–49152, 1; 2 % NaN / ±inf | 100 nm, 80.0, 80 |
| `mid1024` | 1024², 2 | 0.3 nm | gray, full, 1; three marks | 50 nm, 166.67, 167 |
| `tiny64` | 64 × 48, 1 | none | gray | left out (the plate is at least 16 + 20 px wide, the image allows 32) |
| `planted2d`, `stem` | 40 × 24, 68 × 68 | the DM fixture (0.0123 nm); `test_STEM_image.dm3` (0.2485 nm) | gray | left out (8 + 16 > 20; 20 + 16 > 34); opened by `ImageOpening` |
| `p5-u1`, `p5-u2` | 512², 1024² | none | gray, black pixels | no bar; four strokes (horizontal, vertical, 30° down and up) and four rings, no labels |
| `p5x-u1`, `p5x-u2` | 512², 1024² | none | gray, black pixels | no bar; three profile marks (widths 7, 9, 11 × u) and an angle, no labels (P5-band, the angle's arms) |
| `p7-u1`, `p7-u2` | 512², 1024² | none | gray, black pixels | 50 px (u = 1), 100 px (u = 2); a distance, a profile and an angle, each with a label, anchors on whole pixels (P7) |

`aniso512`, `mid1024` and `ang1000` also render with the marks (a distance, an angle, a profile of width 5, each with its label)
for P6; `p5-u1`'s strokes are 160–200 px long at sub-pixel positions (y = 80.3, x = 300.6, a 30° line from (60.4, 300.2)). The CSV
cases: `csv-ramp` and `csv-ramp-w4` (the 37 × 53 ramp, nm axes, widths 3 and 4: 49 and 43 samples, analytic truth), `csv-wave-uncal`
and `csv-wave-units` (profile-parity's wave, no axes / nm and µm: positions in px), `csv-velox` (the 4096² metre axes, `shown` nm ×
10⁹: 4722 samples), `csv-evil` (a unit `a,b"c`, a file name with CR, LF, U+2028, U+0085 and DEL, an object with TAB and U+0001,
a note with `Unvalidated`), `csv-nan` (a line through two NaN pixels: 4 `nan` rows of 24), `csv-empty` (an end at 2e15 px: no
file), `csv-dm4` (the planted DM fixture, analytic) and `csv-stem` (the real image, 78 samples).

## Negative controls

Thirty-six registered and thirteen more, all SOURCE mutations: each edits a COPY of `ProfileCSV.swift`, `ImageExport.swift`,
`ImageExport+Overlays.swift`, `ResultsCSV.swift` or `ResultRow.swift` in the scratch directory (the edit must match its target text exactly once, so a changed line fails
loudly instead of testing nothing; the build has `-warnings-as-errors`), the harness is compiled against it and run on the case
and variants the mutation is aimed at (the optional arguments of `main.swift` and `reference.py check`), and the mutant counts as
caught only when `reference.py` exits 1 and its log holds a `  FAIL  ` line of EVERY check the mutation targets (a target also
names the checks below it: `P5-ring/p5-u1` is every ring of that plant). A harness that fails to render is not a catch. The
mutants build and run six at a time (the whole gate takes about two minutes on this Mac).

| # | Mutation | Check that must fail | Planted case that makes it red |
|---|---|---|---|
| 1 | `%.15g` for `%.17g` | `P1-values/csv-ramp` | `csv-ramp`: doubles that need 17 digits |
| 2 | positions in px although calibrated | `P1-positions/csv-ramp` | `csv-ramp`: nm axes 0.5 and 0.8 |
| 3 | positions in the shown unit (× 10⁹) | `P1-positions/csv-velox` | `csv-velox`: a metre axis, `shown` nm |
| 4 | the profile reversed | `P1-values/csv-ramp` | `csv-ramp`: a ramp, no two samples alike |
| 5 | NaN written as 0 | `P1-values/csv-nan` | `csv-nan`: 4 NaN samples |
| 6 | x and y swapped in the header's start | `P1-header/csv-ramp` | `csv-ramp`: start x = 7.8, y = 3.3 |
| 7 | the bar on y's scale | `P3-length/aniso512` | `aniso512`: 63 px labelled 50 nm instead of 100 px |
| 8 | the bar's length from the label's number after `ladder` | `P3-length/big4096` | `big4096`: 2 µm becomes 0.4 px, so the bar is left out: this control shows a MISSING bar, not a wrong length (the wrong-length demonstration is #7) |
| 9 | the length floored | `P3-drawn/frac512` | `frac512`: 75.76 → 75, planted 76 |
| 10 | the bar not snapped (half-pixel offset, antialiased) | `P3-drawn/aniso512` | `aniso512`: the white run is 99, not 100, and 0 from x₀ |
| 11 | flipped vertically | `P4-pixels/up512` | `up512`: asymmetric content |
| 12 | flipped horizontally | `P4-pixels/up512` | `up512` |
| 13 | transposed | `P4-pixels/up512` | `up512`: square (the only square case in the subset) |
| 14 | gamma as v^γ | `P4-pixels/up512` | `up512`: gamma 0.5 |
| 15 | the window ignored | `P4-pixels/up512` | `up512`: window 16384–40960 |
| 16 | window and gamma in the wrong order | `P4-pixels/up512` | `up512`: window and gamma 0.5 together |
| 17 | the LUT sampled nearest | `P4-pixels/aniso512` | `aniso512`: the random LUT |
| 18 | a masked pixel through the LUT | `P4-pixels/nan400` | `nan400`: 2 % non-finite |
| 19 | the colour tag dropped | `P4-format/aniso512/plain/srgb` | `aniso512`: the bitmap in `genericRGBLinear`, so an iCCP and no sRGB chunk |
| 20 | RGBA written | `P4-format/aniso512/plain/ihdr` and `/pillow` | `aniso512`: colour type 6, mode RGBA |
| 21 | a mark at the pixel's corner (no + 0.5) | `P5-stroke/p5-u1/horizontal` and `P5-ring/p5-u1` | `p5-u1`: 0.57 px off (the 30° strokes 0.20, the rings 0.5) |
| 22 | a mark's x and y swapped | `P5-stroke/p5-u1/30deg` and `P5-ring/p5-u1` | `p5-u1`: the 30° stroke is not symmetric about the diagonal, so it moves |
| 23 | a plate over the whole image | `P6-footprint/aniso512/outside` | `aniso512`, both overlays on |
| 24 | the marks option ignored | `P6-footprint/aniso512/bar-only-marks-untouched` | `aniso512`, bar on and marks off: marks drawn anyway |
| 25 | the drawn length biased by +0.2 px | `P3-drawn/frac40` | `frac40`: 74.40 → 74, planted 74, drawn 75 |
| 26 | the drawn length rounded half to even | `P3-drawn/tie512` | `tie512`: 62.5 → planted 63, drawn 62 |
| 27 | a profile's band twice as wide | `P5-band/p5x-u1` | `p5x-u1`: the band's red channel off by 34–46 levels |
| 28 | a profile's band never drawn | `P5-band/p5x-u1` | `p5x-u1`: 46 levels where the band should be |
| 29 | an angle drawn through the wrong vertex (arms p0–p2, p2–p1) | `P5-stroke/p5x-u1/angle-arm-1` | `p5x-u1`: arm 1 has no yellow weight at its planted place |
| 30 | a mark's label never drawn | `P7-label/p7-u1/mark-0` | `p7-u1`: the label's crop is black, the upright string is not |
| 31 | every label drawn upside down | `P7-label/p7-u1/mark-0` and `/bar` | `p7-u1`: the crops differ from the upright strings by 229–255 levels |
| 32 | *extra:* the scale bar option ignored | `P6-footprint/aniso512/marks-only-plate-untouched` | `aniso512`, marks on and bar off |
| 33 | *extra:* round half to even (the colour) | `P4-pixels/uncal640` | `uncal640`: 304,407 exact ties |
| 34 | *extra:* the overlay scale from min(W, H)/256 | `P3-drawn/aniso512` | `aniso512`: u = 2, x₀ = 32, not 16 |
| 35 | *extra:* header values not sanitised | `P1-header/csv-evil` | `csv-evil`: CR, LF, U+2028 in the file name |
| 36 | *extra:* RFC 4180 quoting inverted | `P1-header/csv-evil` | `csv-evil`: a unit with a comma and a quote |
| 37 | *extra:* a band along the line instead of across it | `P5-band/p5x-u1` | `p5x-u1`: a degenerate band |
| 38 | *extra:* a band scaled by u | `P5-band/p5x-u2` | `p5x-u2`: u = 2, the band twice as wide |
| 39 | *extra:* a label drawn without its unit | `P7-label/p7-u1/mark-0` | `p7-u1`: "75.3" for "75.3 nm" |
| 40 | *extra:* a label one point further right | `P7-label/p7-u1/mark-0` | `p7-u1`: the box is one pixel off |
| 41 | *extra:* every mark biased by 0.04 px | `P7-label/p7-u1/mark-0` | `p7-u1`: P5's 0.15 px band does not see it; the label's crop does |
| 42 | *extra:* `anisotropic` ignores the units | `P4-format/unitsmix512` | `unitsmix512`: 0.5 nm against 0.5 Å, `anisotropic` false instead of true |
| 43 | *extra:* `y_scale` hidden when x has no calibration | `P4-format/yonly512` | `yonly512`: `y_scale` null instead of the file's |

Notes on the readings. **(19)**: a DEVICE RGB context is not a mutation: ImageIO tags it with an sRGB chunk as well (measured
2026-10-13 on macOS 27.0.1), so the control puts the bitmap in another colour space. The check accepts only the standard `sRGB`
chunk or an `iCCP` named `sRGB IEC61966-2.1` (a profile named "Linear sRGB" is not sRGB). **(8)**: with the bar computed from the
laddered number the planned length is 0.4 px and the plate fit rule drops the bar; the check sees the missing bar (a wrong length
at 1000 times the true one cannot be drawn on that plant, so #7 is the wrong-length demonstration). **(25)–(31)**: Gate B round 1 (2026-10-13) showed that these seven mutants of registered claims stayed green against the first
twenty-four and all four unit-test classes, and added the plants and checks that catch them (`tie512`, `frac40`, `p5x-*`,
`p7-*`); they answer registered claims (the length "rounded half up", the marks "where they were measured", the band at the
width the profile averages over, the label a mark carries), so they are registered. **(21)**: a
half-pixel shift moves a 30° stroke only 0.2 px along its normal, just outside the 0.15 band, which is why the target is the
horizontal stroke and the rings. **(23), (24), (32)**: P6's baseline is the recomputation of the plain export, not the harness's
own plain PNG; the option mutations change the plain export too, so against its own plain PNG they would pass.

**(37)-(41), R-P1 (Results, slice 3; case `results`).** (37) `%.15g` (`R-P1/values`); (38) the cells written without quoting
(`R-P1/text`: the planted label splits its line); (39) NaN written as 0 (`R-P1/values`); (40) the angle's validation line omitted
from the header (`R-P1/header`); (41) a spot's |q| filed under d (`R-P1/spot-values`, and the closed form).

## What the harness restates, and what it does not check

`main.swift` restates `DisplayWindow.fractions` (TEMSession is not in the closure) and builds the canvas as `AppState.canvas(for:)`
does; `reference.py` recomputes both (`P4-format/<case>/window-fractions` compares what the harness passed). The unit table that
turns "20 nm" and a metre axis into comparable lengths, the 1-2-5 rule and the footprint bounds are `reference.py`'s own, written
from the registration. Not checked here: the look of the plate, the label's typeface (P7 compares the label's pixels against the
same fonts, so a changed font size is not caught here), the twins against the app's functions and the GPU (ImageExportTwinTests,
ImageExportGPUTests), `ExportFile.write` and the sandboxed save panel (ImageExportRenderTests, ExportFileTests and the drive), and
the PNG's alpha-blended overlay colours.
