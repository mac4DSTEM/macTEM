# ring-fit-parity

macTEM's fit-driven ring calibration (`RingCalibration.fit`, `Sources/TEMCore/Analysis/RingCalibration+Fit.swift`,
compiled from `tools/lib/sources.manifest` group `ring`) on planted rings against their truth, with scipy's optimum of the
same model printed beside it. The pre-registration is archive: roadmap-registrations-2026-10-15.md "Diffraction S3, Camera length from one ring of known d",
slice **S3-b**. Run `tools/parity/ring-fit-parity/run.sh`, redirect it to a log, and read the exit code on its own line; a full
run takes about three minutes.

**Classified `diagnostic`** (`tools/run-tests.sh`): S3-b's P1 and P2 FAILED on 2026-10-13 and S3 closed (archive: roadmap-registrations-2026-10-15.md, "Result
S3-b"); this harness is that result's evidence and the base the next registration builds on. It exits 1 today, by its
registered checks, not by a defect in the harness.

The closed forms (λ, 2θ, L_px, Δq, L_mm) and the refusal thresholds are `tools/parity/ring-calibration-parity`'s (scientific, to
1e-12); this harness checks what a fit hands them.

## The plants (`plants.py`)

Float32 images, rows × columns, the centre off the grid with row ≠ column; the fit's "qx" is the row, "qy" the column. The
in-family ring is `tools/parity/ellipse-parity`'s: I = exp(−((ρ − 1) R)² / 2s²), ρ the elliptical radius, R = (a + b)/2, s = 3 px —
the asymmetric-Gaussian model's own family. Every fit case carries a (material, hkl, d, V) from S3-a's set (Au, Al; 80, 200,
300 kV) and a 14 µm pitch, so L_px and L_mm are checked as well as Δq. The start centre is the plant's plus (+1.3, −0.9) px;
the annulus (b − 20, a + 20) px about it unless a tier sets the margin.

| tier | plants | gated |
|---|---|---|
| `clean` | `ellipse-parity`'s 84 (R 80–200 px, ε 0/1/3 %, gap 0° or 60°), the same generator and order | P1 on the accepted ones |
| `noisy` | its 144 (3 and 10 % of the peak, two seeded realisations) | printed |
| `width-px`, `bg-*`, `lorentz`, `skew`, `neighbour-1.155`, `annulus-*`, `radius-*`, `sigma-*` | two each: width constant in px, constant / 1/r² / 1/r³ / exponential backgrounds, a Lorentzian of the same FWHM, a gamma-skewed ring (k = 4, mode at R), a neighbour ring at 1.155 R, annulus half-widths 10–40 px, R 40/60/250 px, s 1.5/5/8 px | printed |
| `refusal` | the registered plants: a 120° gap (and `ellipse-parity`'s 240°/300° arcs and 80° gap), an empty pattern, a two-ring annulus (1.13 R), the 1/r³ background at 1.0 of the peak, a ring without V, 12 % ellipticity | P2 |

scipy's optimum of the same 11-parameter model (written from `fitAmorphousRing`'s `predictions`), started at the plant, over
the same annulus pixels, is computed for the clean tier: it separates the model from the Swift optimiser. Printed, not gated.

## Checks (`main.swift`)

P1, every accepted clean ring: `dq` |Δq/Δq₀ − 1| ≤ 1e-3; `length` L_px and L_mm within 1e-3; `centre` both coordinates within
0.05 px. P2: `refuse` — the plant's refusal is in the list and nothing is calibrated (the coverage plants: first, with no
fit; the ring without V: the only refusal, Δq given within 1e-3, no L); `throws` — the empty pattern's fit error reaches
the caller. Per tier, printed: n, accepted, refused by name, thrown; median / p90 / max (nearest rank) of |ΔΔq/Δq| and of the
centre error over the accepted rings, and |ΔΔq/Δq| over the refused-but-fitted ones.

## Controls (`run.sh`)

Emulated in `main.swift` (the entry point has no switch to break): the harness re-runs the wrapper's steps with one change.
Each runs on its target case alone, which must pass unmutated first (exit 0), then exit 1 with a FAIL of its check.

| mutation | change | check |
|---|---|---|
| `recover` | the next family's d ({111} → {200}, d / 1.1547) | `clean-512x512-r140-e3-t90-g0-s0 dq` |
| `radius-a` | R = a, not (a + b)/2 (ε 3 %) | the same `dq` |
| `centre` | the fit's row and column swapped (9.6 px apart) | the same `centre` |
| `refuse-conic` | `modelNotAsymmetricGaussian` dropped | `refuse-conic-… refuse` |
| `refuse-gap` | `acceptSparseCoverage: true` and the coverage refusal dropped | `refuse-gap120-… refuse` |
| `accept-sparse` | `acceptSparseCoverage: true` alone (the registered mutation) | the same `refuse`: Δq is still withheld by the bin bound in `refusals`, so it is caught only because a fit now comes back |
| `refuse-noV` | a missing V taken as 200 kV | `refuse-noV-… refuse` |

**DiffractoKit 0.1.0 (archive: roadmap-registrations-2026-10-15.md "DiffractoKit 0.1.0: the re-pin"):** the plant is an accepted plant, `accept-bound` (kind `accepts`, gated like a clean ring), and the control name is gone. Before: the registered `refuse-bound` control was not run: its plant does not reach the sigma bound unmutated (P2's failure), so
dropping the refusal changes nothing. `tools/parity/ring-calibration-parity` holds that refusal on both sides of its threshold.

## The Au first look (`au.swift`, printed, never gated)

When `tools/parity/au-ring-pattern/` has derived the public Au 200 kV mean pattern into `References/`, `run.sh` fits its 220, 331,
422 and 440 rings (annuli ±3 px about the radii the reference search measured; V 200 kV, p 0.1 mm) and prints each fit,
its refusals and its Δq. It is not S3-c: S3 closed before a real ring was registered against.

## Result, 2026-10-13 (scratchpad `fp/run-4.log`; Gate B: an independent Sonnet refuter, upheld with findings)

275 plants, 186 checks, 11 failures; 7 of 7 controls caught. **Δq and L held** on every accepted clean ring: 59 accepted,
|ΔΔq/Δq| max 0.0672 % (the 41 gap-free: max 0.0192 %, centre ≤ 0.003 px); 25 refused `modelNotAsymmetricGaussian`, as
predicted. **The centre clause failed**: 10 `centre` failures, all on 60°-gapped rings (0.078–0.130 px; the band was never
tried on gapped rings before this run). scipy's optimum of the same model, started at the plant, shows the same shift (up to
0.128 px, converged, ~1/R): the model's optimum on a hard-cut ring, not the Swift optimiser. Profile fits only, Swift against
scipy: radius max 0.126 %, centre max 0.10 px, all on gapped rings (scipy has no MAD refit). **`refuse-bound` failed**: the
1/r³ plant here (R 120, ε 1 %, θ 20°) is accepted at 0.014 %; it is not the study's geometry (R 100, ε 3 %, θ 40°), and the
refuter's scipy runs found several minima on both (−0.03 % and +1.46 %, neither with σ at the bound), so no plant here fires
the refusal; it is held only by `tools/parity/ring-calibration-parity`. No plant tests `excessiveResidual` (likewise held there).
**Noisy** (printed): 109 of 144 accepted, |ΔΔq/Δq| p90 7.6 %, max 47 %, centre max 8.6 px; the refuter's scipy optimum of
the same model from the plant reads ≤ 0.133 % on all 144, so the large errors are the Swift path's (seed, stop rule, refit or
start), not the model's — under Gate D. Printed tiers to read first: skew 0.55 %, neighbour ring 0.28 %, annulus ±40 0.14 %,
all accepted. **Au first look**: 220, 331 and 422 refused `insufficientAngularCoverage` (22, 24, 21 of 36 bins: the rings
are speckled by grain texture, per-10° means 1.7–15 counts on 220), 440 fitted (R 66.81 px) but refused
`sigmaAtAnnulusWidth`; nothing was calibrated.
