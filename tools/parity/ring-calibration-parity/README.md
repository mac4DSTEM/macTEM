# ring-calibration-parity

macTEM's camera-length closed forms, `calibrate` and refusal decision (`RingCalibration`, compiled from
`tools/lib/sources.manifest` group `ring`) against `reference.py`: the closed forms from the definitions, with CODATA 2018
constants, evaluated in 60-digit decimal arithmetic. A `scientific` gate; the pre-registration is archive: roadmap-registrations-2026-10-15.md "Diffraction S3,
Camera length from one ring of known d", slice **S3-a** (the closed forms and the refusal enum, no fit); the plan behind it is
archive: s3-camera-length-plan-2026-10-12.md. Run `tools/parity/ring-calibration-parity/run.sh`, redirect it to a log, and read
the exit code on its own line.

The group `ring` is `Data/DiffractionPattern.swift`, `Analysis/EllipseCalibration.swift` (the copies the `ellipse` group
already names: `RingCalibration.FitReport` carries an `EllipseCalibrationModel`) and `Analysis/RingCalibration.swift`.

This harness says nothing about a fit, a ring, or a real pattern: S3-b (the fit-driven calibration on planted rings) and S3-c
(the owner's real pattern) add their own checks, and the product stays `validation:"none"` until S3-c holds.

## The reference (`reference.py`)

Constants, CODATA 2018 (Tiesinga, Mohr, Newell, Taylor, Rev. Mod. Phys. 93, 025010 (2021)): h = 6.626 070 15e-34 J s,
c = 299 792 458 m/s, e = 1.602 176 634e-19 C (all three exact since the 2019 SI) and m0 = 9.109 383 7015e-31 kg (recommended
value, relative standard uncertainty 3.0e-10). Stated once, in `reference.py`; the Swift constants are compared to them.

| quantity | closed form (Å, rad) |
|---|---|
| λ(V) | h c / sqrt(e V (2 m0 c² + e V)), V in volts; cross-checked against h / sqrt(2 m0 e V (1 + e V / 2 m0 c²)) |
| 2θ | 2 arcsin(λ / 2d), Bragg's law, first order |
| L_px | R / tan 2θ, a flat detector perpendicular to the beam (the registered exact form, not the small-angle λL = Rd) |
| Δq | (1/d) / R, Å⁻¹ per pixel; no wavelength |
| L_mm | p · L_px, p the detector pixel pitch in mm |

Every case is evaluated from its exact float64 inputs in 60-digit decimal arithmetic (arcsin by its power series; tan 2θ by
the algebraic identity 2s sqrt(1 − s²) / (1 − 2s²), s = λ/2d, so no trigonometric library is trusted) and rounded once to
float64. numpy's own `arcsin`/`tan` route is computed beside it and must agree to 1e-14 relative; the three evaluations of λ
(decimal, numpy square-root form, numpy de Broglie form) must agree to 1e-14 and with the 3-digit textbook wavelengths at 100,
120, 200 and 300 kV (Williams and Carter, *Transmission Electron Microscopy*). `reference.py` exits 1 if any of that fails.

**Cases (320)**: V in {60, 80, 120, 200, 300} kV; d of Au {111} {200} {220} {311} {422} (a = 4.0782 Å) and Al {111} {200}
{220} (a = 4.0495 Å), d = a / sqrt(h² + k² + l²); R in {40, 80, 200, 250} px; p in {0.014, 0.05} mm. The lattice constants are
Diffraction S1's, named as the reference until a CIF is pinned (archive: roadmap-registrations-2026-10-15.md V1-8 "S1"; `tools/parity/crystal-parity/reference.py`;
mac4DSTEM's presets, `Sources/TEMCore/Crystal/Crystal.swift`); every reflection is fcc-allowed.

**Refusals (68 plants)**, decided in plain Python from the registered thresholds (`decide` in `reference.py`), each registered
refusal alone on its own boundary with the other inputs clean. The reference's names are the Swift enum's `name`.

| refusal (check) | threshold (registration) | plants |
|---|---|---|
| `modelNotAsymmetricGaussian` (`refuse-conic`) | model other than the asymmetric Gaussian | the Gaussian accepted; the conic, with and without sigmas, refused |
| `insufficientAngularCoverage` (`refuse-bins`) | fewer than 30 of 36 azimuthal bins | 36, 31, 30 accepted; 29, 12, 0 refused |
| the same, by flag (`refuse-gap`) | the fit's sparse-coverage flag (a fit accepted only on the caller's assertion) | clear accepted; flagged refused, at 36 and 30 bins |
| `sigmaAtAnnulusWidth` (`refuse-bound`) | the larger of the inner and outer sigma at or above the annulus width | width·(1 − 1e-9) and the double below it accepted; the width itself, the double above it, width·(1 + 1e-9) and 243 px refused, on the inner sigma and on the outer; both at the width; the larger of two straddling it |
| `excessiveResidual` (`refuse-residual`) | residual above 0.22 (mac4DSTEM's cap, inherited) | 0.22, 0.22 − 1e-9 and 0 accepted; the double above 0.22, 0.22 + 1e-9 and 0.336 refused |
| `excessiveEllipticity` (`refuse-ellipticity`) | a/b − 1 above 0.093, the major axis either way | 0.093 ∓ 1e-9 and ∓ 1e-6, a-major and b-major, 0.2, and a circle; the cap is *derived*: `reference.py` finds the a/b − 1 at which (a+b)/2 and sqrt(ab) differ by 0.1 % and asserts the registered 0.093 lies just below it |
| `noHighTension` (`refuse-noV`) | V missing (Δq is still given: `withholdsDeltaQ` false) | missing refused, present accepted |
| several at once (`refuse-several`) | every applicable refusal, in the order model, coverage, sigma, residual, ellipticity, high tension | all six; sigma + residual + ellipticity; bins and the flag together (one entry, not two); model + high tension |
| `invalidInput` (`refuse-invalid`) | a number that is not finite and positive, a bin count outside 0...36, or a negative residual: refused alone (beyond the registration: a NaN passes every comparison) | 19 plants, each field in turn, and a NaN beating the conic |

Each refusal also reports its number (bins, the larger sigma and the annulus width, the residual, a/b − 1) and whether it
withholds Δq (everything but `noHighTension` and `braggLimit`); both are compared.

The **Bragg limit** (`refuse-bragg`, 18 plants): a flat detector perpendicular to the beam shows no ring at 2θ ≥ 90°, i.e.
λ/2d ≥ 1/√2 (an addition beyond the registration, which lists no Bragg bound: 2θ ≥ 90° makes tan 2θ negative; the Swift
file's header says so). Planted at 60, 200 and 300 kV with d
set from λ in decimal arithmetic, on both sides at 1e-9 and 1e-6 relative and at a factor 2; checked through `twoTheta` (NaN
outside) and `calibrate` (Δq still given, V and λ shown, `braggLimit` carrying λ/2d, no L).

The **radius** (`radius`, 10 plants): `FitReport.radius` = (a + b)/2, py4DSTEM's `R = np.mean((a, b))`, on semi-axes planted
with 3 % ellipticity (a/b − 1 = 0.03, under the 0.093 cap), the major axis either way, at a minor axis of 40, 80, 100, 200 and
250 px. The expected radius is numpy's mean of the two float64 axes, which `reference.py` checks against the decimal sum of the
same two numbers; the mean differs from the larger and from the smaller axis by 1.5 %, so a radius taken as one axis cannot pass.

## Checks (main.swift)

`CODATA-2018 constants`: the Swift constants equal the reference's, exactly (hc/e and m0c²/e within 1e-14). `<lambda-NNkV>
wavelength`: λ(V) within 1e-12 relative at each of the five voltages. `<case> formula`: 2θ from the reference's λ and d, L_px from
the reference's R and 2θ, Δq from d and R, L_mm from the reference's p and L_px, each within 1e-12 relative; every function is
handed the reference's own inputs, so a wrong wavelength cannot hide a wrong formula nor the reverse. `<case> chain`:
`calibrate` end to end from V, d, R and p (λ, 2θ, L_px, Δq, L_mm within 1e-12), without a pitch (L_mm absent) and without V
(Δq given, L absent, `noHighTension`: V is never defaulted). `<plant> refuse-…`: the refusal list, its numbers and
`withholdsDeltaQ` equal the table. `<plant> radius`: `FitReport.radius` within 1e-12 relative of numpy's mean of the axes.
`<plant> refuse-bragg`: `twoTheta` and `calibrate` on both sides of λ/2d = 1/√2. The worst relative error per quantity is
printed as an `info` line. `main.swift` has a `precondition` that the manifest's tolerance is at most the registered 1e-12, so
a manifest that loosened the band cannot pass.

## Negative controls (run.sh)

Each mutation must make the harness exit 1 with a `FAIL` of the targeted check (`reference.py` shows first that each moves its
target quantity far outside the 1e-12 band):

| mutation | what the broken code does | check | moves |
|---|---|---|---|
| `q-two-over-d` | Δq = (2/d)/R | `Au422-80kV-R200-p0.014 formula` | ×2 |
| `a-for-nm` | d in Å read as nm | same | ×10 |
| `small-angle` | L_px = R d / λ | same | 9.45e-4 relative at 80 kV Au {422} (4.25e-5 at 200 kV {111}) |
| `pitch-um` | the pitch in µm used as mm | same | ×1000 |
| `non-relativistic` | λ = h / sqrt(2 m0 e V) | `lambda-80kV wavelength` | 3.84 % at 80 kV |
| `kv-as-v` | the kV number passed as volts | same | ×32.8 at 80 kV (λ of 80 V over λ of 80 kV) |
| `v-default` | a missing V taken as 200 kV | `noV-missing refuse-noV` | the refusal does not fire |
| `radius-a` | `FitReport.radius` taken as the first axis, not (a + b)/2 | `ellipse-3pct-minor100-a-major radius` | 1.48 % at 3 % ellipticity |

The closed-form mutations and `radius-a` are emulated on the functions' (and `FitReport.radius`'s) outputs (they take plain
numbers and have no option to break); `kv-as-v` and `v-default` change what is passed to them. The registration's other
mutations (`recover`, `centre`, `refuse-conic`, `refuse-gap`, `refuse-bound` as fit options) need the fit and belong to S3-b;
here those refusals are held on both sides of their thresholds instead, and the registered `radius` is held on
`FitReport.radius` (the radius a fit hands to `calibrate` is S3-b's).
