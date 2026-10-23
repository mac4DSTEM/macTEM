# ellipse-parity

macTEM's ring/ellipse fit (`EllipseCalibration.fit1D`, copied verbatim from mac4DSTEM `5b696589`; `tools/lib/sources.manifest`
group `ellipse`) against a planted ellipse and a numpy 2.5.4 / scipy 1.18.1 optimum of the same objective. The
pre-registration is archive: roadmap-registrations-2026-10-15.md V1-7 "S2, the ring/ellipse fit" (commit 4a89e17). Run `tools/parity/ellipse-parity/run.sh`,
redirect to a log, read the exit code on its own line. Not yet in `tools/run-tests.sh`'s `scientific` array.

**At `5b696589` (2026-10-13, the re-sync)**: the stop-rule fix holds — 0 of 84 clean plants and 0 of 144 noisy ones
refused (S2 saw 12 and 14). The run still exits 1: its 140 failures are all `radius` and `axes` on the 70 clean plants at
R 80–160 against the registered 0.05 % band — the conic's documented bias (+0.2456 % at R 80, s 3), now a note on `fit1D`
upstream, not a defect. Swift equals scipy's optimum (centre ≤ 4.4e-7 px, axes ≤ 1.9e-9 relative). S2 stays closed;
camera length is Diffraction S3, on the profile fit.

## The plant (`make_fixture.py`)
Float32 images, rows H x columns W; `I = exp(-((rho - 1) R)^2 / 2 s^2)`, `rho^2 = u^2/a^2 + v^2/b^2` in the frame rotated by
theta (the major axis a along `(cos t, sin t)` in (row, column); t = 0 is along the rows), `R = (a + b)/2`, `a/b = 1 + eps`,
`s = 3 px`, the centre off the grid. The fit's "qx" is the row, "qy" the column. 512 x 512 (R 80, 140, 200) and
384 x 512 (R 80, 120, 160: 200 does not fit 384 rows uncut); eps 0, 1, 3 %; theta from 0 to 179 degrees (none at eps 0:
undefined); a missing arc of 0 or 60 degrees; noise 0 (clean, 84 cases), 3 % and 10 % of the peak of 1 (noisy, 144 cases,
two seeded realisations); refusals arc120, arc60, gap80 (29 of 36 bins) -> `insufficientAngularCoverage`, empty ->
`insufficientSignal`. The fit is `fit1D` (the registered conic), start centre = plant + (1.3, -0.9) px, annulus
(b - 20, a + 20) px about the start centre. Not tuned: `s`, the margin and the start are as first chosen.

## The reference (`reference.py`)
The weighted conic of the definition, minimised by `scipy.optimize.least_squares` (lm); (A, B, C) -> (a, b, theta) by numpy's
eigensolver; the coverage and annulus pixel count by numpy. Exit 1 unless the plant survives the conic round trip, the
image equals an independent conic-form rendering (noise: planted mean and sd), fit cases hold >= 30 bins and refusals < 30.

## Checks (`main.swift`)
Clean: `centre` 0.05 px and `radius` 0.05 % (registered); `axes` 0.05 % (the radius band, not registered); `theta` 2 degrees
(not registered; above the 1.2 degrees the numpy optimum measured); `coverage` (bins and pixel count equal numpy's).
Noisy: nothing gated, the distribution printed. Refusals: the `FitError` name (and its bin count). Printed: Swift against
the scipy optimum. Controls (`MACTEM_PARITY_MUTATE`): `xy-swap` (centre), `ab-swap` (axes), `theta-sign` (theta),
`mean-radius-major` (radius), `no-weight` (centre; EMULATED on the output, the weight is inside the verbatim copy).
`sqrt(a b)` as the mean radius differs from `(a + b)/2` by under 1.2e-4 at eps 3 %, inside the radius band: not catchable.
