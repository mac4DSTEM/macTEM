# diffraction-room-parity

The Diffraction room's slice 1a (archive: roadmap-registrations-2026-10-15.md "Diffraction room, slice 1a: the core and tools/parity/diffraction-room-parity" and its
2026-10-15 lane B addendum, tier 1; design archive: diffraction-room-design-2026-10-15.md) against numpy and planted truth. The
core is `Sources/TEMCore/Diffraction/` (`StandardCrystals`; `RingOverlay`, `IndexingDisplay` and `CrystalLoading` are DiffractoKit's since the 2026-10-20 switch); it calls (RingScale is DiffractoGeometry's since 0.4.0)
DiffractoKit `0.3.1` directly (no `RingMeasurement` or `RingGeometry` interim, by the addendum). `scientific` in `tools/run-tests.sh`.
**R8, the seed-rule grid, is not built**: `plants.py` writes it, nothing reads it yet (`run.sh` asks for the half grid, which is cheap).
`run.sh` (about five minutes: the fits dominate) runs plants.py, reference.py, `main.swift` (Package.swift's
`DiffractionRoomParity` target), then 34 negative controls; each must exit 1 with a FAIL line of its named kind on a run that passed unmutated.

## Files

| file | what |
|---|---|
| `plants.py <out> [--r8 full\|half]` | R1's 48 new planted rings (+ the retired ring-fit harness's 84 clean, listed unchanged), R4's 48 two-ring plants, R8's 144 images and 10368 cells (or the half grid), `rfp/` (the retired ring-fit harness's 275 plants, for R2), `manifest.json`. Seeds are fixed in the file (`SEED_R8_GEOM = 2026101581`, `SEED_R8_NOISE = 2026101582`; R1 and R4 are deterministic). |
| `reference.py <scattering_factors.txt> <out> [--plants <plants-out>] [--cif-dir D]...` | `reference.json` (R3, R4, R5, R6, R7, R9, the ellipse-distance vectors, the mutation-moves) and `r9/*.cif` (the planted CIF byte files). Exits 1 on any failed self-check. |
| `reference.py --distance-check in.json out.json` | the R1 polyline helper: the orthogonal distance of points to an ellipse (`{"items":[{"name","cx","cy","a","b","theta","points":[[x,y],...]}]}` in, distances out; x = column, y = row, the plants' axes). |

Everything is generated on each run under a scratch directory (`$WORK`), never committed. Floats are `%.17g`; NaN and the
infinities are the strings `"NaN"`, `"Infinity"`, `"-Infinity"`. Run with the lock's interpreter and `-I -B`.

## The clauses and where their truth is

| clause | reference | notes |
|---|---|---|
| R1 | `manifest.json` `r1`: truth (`x_truth` = column, `y_truth` = row, `a`, `b`, `theta`; the kit's order is (row, column)) | the polyline checks use `--distance-check` or a Swift port of the same Newton iteration, compared to `ellipse_distance_vectors` (576 points, exact to 1e-13 px) |
| R2 | `rfp/planted.json` (`ring_fit_plants.py`, the retired ring-fit harness's plants, unchanged) | the Swift side compares two calls of its own; the plants are the only input from here |
| R3 | `reference.json` `r3`: 320 cases x 7 radii, `invalid` | inputs are the written float64 `lambda_A` and `l_px`; expected values are evaluated from exactly those in 60-digit decimal |
| R4 | `r4.radii` (680, = R(g) for each case and each family of its material), `r4.ellipses` (48, the scaled ellipse of each R4 plant) | R4's plants are the three physical Au pairs (see `plants.py`), ring 2 at its flat-detector radius |
| R5 | `r5`: 694 spellings (incl. case, space, decomposed-accent, padded variants), 19 rejects, 15 invalid values, 96 fit-vs-file pairs | |
| R6 | `r6.t1` (2646 plants), `r6.t4` (25) | compare odds only where `odds_beyond_1e6` is false (exp(margin) overflows); the verdict names, indices and every other field are exact |
| R7 | `r7.standards`: Au, Al, Si (and Mg, Cu3Au-occ as extra controls) at k_max 1.2 and 2.0 | Au 8 / 22 families, Al the same, Si 10 / 28 (printed by the self-check) |
| R8 | `manifest.json` `r8`: images, cells, controls, `estimate`; **no reference value: the Swift side prints** | the band rule is in `band_rule`; `in_band_subset` marks its 2592 cells |
| R9 | `r9.files`: SHA-256 of every CIF in `--cif-dir` and of the planted files | the cap files are exactly 5 MiB and 5 MiB + 1 |

`reference.py`'s self-check (what it proves before anything counts): Au {111} d = 2.3545498678091317 Å; λ(200 kV) equal to
the decimal chain of the retired ring-calibration harness (now DiffractoKit's parity target); R -> q -> R within 1e-9 px over all cases; the numpy route against the decimal
chain at 3e-16; the exact-vs-linear difference; Au 8 / 22, Si 10 families; every T4 verdict equal to the rule's; the distance
helper exact to 1e-9 px; every registered mutation moves its target by more than 1e-6 (the ones R3 to R7 name).

## What main.swift checks, and what it learned

Kinds: R1 ellipse / on-fit / on-truth / distance-helper; R2 pin; R3 q / radius / roundtrip / cal-ring / linear / invalid; R4 radius / ellipse /
on-truth; R5 spelling / reject / invalid-value / fit-vs-file; R6 verdict / family / sigma-q / delta / delta-pct / abs-dd / z / odds / margin / d;
R7 standard / count / family; R9 hash / read / refuse / cap / text. `MACTEM_PARITY_SECTIONS` and `MACTEM_PARITY_ONLY` restrict a run;
`MACTEM_PARITY_MUTATE` applies one control (listed in main.swift's header). The mutations are emulated on the core's outputs or on what is passed
to it, since the core has no option to break.

- JSON numbers are read as strings and parsed with `Double(String)`: `JSONSerialization` returns some `%.17g` literals one ulp off, which turned
  the R3 linear form's bit-for-bit clause red until fixed.
- R6: the T1 plants at s = 0 are built on the REFERENCE's g, which differs from the kit's by an ulp, so delta is 2.2e-16 and z up to 2.6e-13 where
  the reference says 0; those four fields carry an absolute floor (1e-15, 1e-13, 1e-15, 1e-12) beside the 1e-12 relative band. Nothing else needed one.
- R4 fits ring 1 in the click rule's annulus (`rule_inner`, `rule_outer`, half-width 10 px): the plants' full annulus holds ring 2 and the kit
  refuses it (`secondRingInAnnulus`). The predicted polyline's worst distance to the planted ring 2 is printed (registered prediction 0.3 px; band 0.5 px).
- R9: whether "fingerprint over re-encoded text" is separable is printed by the run (the control's own check, `R9 hash`, decides).
- 2026-10-15: R1's 0.05 px centre band holds on whole rings only (60° gap plants reach 0.13 px, held to the 0.5 px polyline band); R4's predicted 0.3 px measured 0.35 px, the 0.5 px band holds — likely ring 1's fit error scaled by the radius ratio (not investigated).
