# profile-parity

macTEM's distance, angle and line profile (`ImageMeasurement.distance` / `.angle`, `LineProfile.sample`; TEMCore, through
Package.swift's `ProfileParity` target) against the closed forms and scikit-image 0.26.0's `measure.profile_line`
with scipy 1.18.1 and numpy 2.5.4 (pinned: `tools/lib/references-lock.txt`; `reference.py` also pins the sha256 of
`skimage/measure/profile.py`). A `scientific` gate (`tools/run-tests.sh scientific`).
Run `tools/parity/profile-parity/run.sh`, redirect it to a log, and read the exit code on its own line.

Pass lines: `profile-parity: all passed — …`, `extra controls (not registered): 4 of 4 caught by their checks` and, last,
`negative controls: 8 of 8 caught by their checks`. A `measured:` line reports the largest differences seen and a `timing:`
line the speed of a 3000-pixel line at width 25 (reported, not gated).

## What is compared

**P1, distance and angle** (closed forms, 1e-12 relative). `distance` gives the length in pixels, √(Δc² + Δr²), and, only
when both axes are calibrated (`AxisCalibration.isCalibrated`) in the SAME unit string, √((Δc·s_x)² + (Δr·s_y)²) and that unit;
otherwise the physical value and the unit are nil. `angle` is atan2(|cross|, dot) at the middle point, 0 to 180°, in the
physical plane (Δc·s_x, Δr·s_y) when the axes allow it and otherwise in pixel space, and says which; nil for a zero arm.
The planted case is a 3-4-5 triangle in anisotropic pixels (0.5 × 0.8 nm): 6 columns = 3 nm and 5 rows = 4 nm, so the
length is 5 nm exactly, and the angles are 90°, atan(4/3) and atan(3/4). `reference.py` works those by hand, requires its own
numpy closed forms to reproduce them, and writes both; also an angle that is 90° in nm and 111.3° in pixels, the refusals
(no calibration, one axis, two units, an empty unit, a zero scale), a zero arm, straight (0°) and folded-back (180°) arms and
an angle of 1e-9 rad between two arms of 1000 px, which arccos loses and atan2 keeps.

**P2, profiles** (scikit-image 0.26.0). The reference call is `profile_line(image, (r0, c0), (r1, c1), linewidth=w, order=1,
mode="reflect", reduce_func=np.mean)` on the float32 image, as the app holds it. A sample passes when it is within
1e-5 × max(|reference|, 0.1 × the image's largest magnitude); the registered floor was 1e-5 × the image's largest magnitude,
and this one is ten times tighter. The sample count must be equal, and the positions i/(n−1) of the line's length, in the axes'
unit when both axes are calibrated in one unit and in pixels otherwise (also the unit and the width). Every sample must also
equal scikit-image's run on the image cast to float64, to 1e-12 of the image's largest magnitude: the port works in Double, and
this is what shows that the float32 comparison hides no difference of algorithm. On the planted ramps the samples must also
equal the analytic value at the sample points (same 1e-5 band).

## Datasets (`reference.py`)

- `wave`: 37 × 53 float32 (columns × rows), pixels 0.5 × 0.8 nm, a sinusoid in both directions plus a cosine and a signed
  ramp: values of both signs, so many samples are near zero, and variation across every line's perpendicular, so the width
  matters. Lines: horizontal, vertical, diagonal, reverse diagonal, sub-pixel, short sub-pixel, the 3-4-5 diagonal (n = 6
  exactly), length 10 exactly, length 10 + 1e-7 (one sample more), crossing the border, far outside it, starting outside,
  along the top and right edges, of zero length and of length 1e-7 (two samples), anti-diagonals in both senses and exact
  45° lines in both senses (added after a review, 2026-10-13: five wrong-profile mutants passed without them); widths 1, 2,
  3 and 4, and 5 and 25 on some lines.
  `wave uncalibrated` and `wave units differ` (nm and µm) carry four lines each: positions in pixels.
- `ramp`: the same size, 1000 + 3.7 r + 2.1 c + 0.013 r·c, bilinear, so bilinear interpolation reproduces it exactly: five
  interior lines (with an anti-diagonal and a 45° line) at widths 1, 2, 3 and 4 carry the analytic truth by construction.
- `planted-2d.dm4`: the committed 40 × 24 fixture (value 1000 r + c − 12000, linear: analytic too on interior lines), with its
  own calibration, read from `planted-2d.truth.json` (whose sha256 must match the file).
- Two real RosettaSciIO images at the lock commit `049e7d70` (the registry's sha256 is pinned, as in
  `tools/parity/metadata-parity`): `test_STEM_image.dm3` (68 × 68, nm) and `test_diffraction_pattern.dm3` (87 × 87, 1/nm). Their
  pixels and calibration are what ncempy 1.16 reads; the reader itself is FormatoKit's to check, so this harness does not
  open DM files (`ImageOpening`'s closure is not in group `profile`).
- Three thin images with seeded noise, 1 × 15, 17 × 1 and 2 × 3: scipy maps a length-1 axis to index 0, and every coordinate of
  a length-2 axis is within one pixel of an edge.

## The comparator, checked before the app is

`reference.py` does not trust scikit-image blindly: (1) a profile geometry written from the definition (unit-vector
perpendicular, no arctan2) must equal `_line_profile_coordinates`; (2) scikit-image's float64 profile must equal an
independent bilinear interpolation of the half-sample symmetric extension (`numpy.pad` mode "symmetric", no scipy) on every
line, to 1e-12 of the image maximum, so what scipy's "reflect" does outside the image is measured, not assumed; (3) the ramps
must equal their analytic value. Any disagreement exits 1 before a byte is written.

## scikit-image and scipy, what the port copies

- **Count and positions**: n = ⌈hypot(Δr, Δc) + 1⌉; `numpy.linspace` from the start to the end, end included.
- **Perpendicular**: offsets (cos θ, −sin θ)·(w − 1)/2, θ = atan2(Δr, Δc), `linspace`d over w points, so the points are one pixel
  apart and centred. The mean is over those w points (the order does not matter).
- **Interpolation**: `ndimage.map_coordinates(order=1, mode="reflect")` (skimage passes "reflect" through unchanged; only
  "constant" and "wrap" are renamed to their grid variants). In scipy 1.18.1's `ni_interpolation.c` a coordinate is first
  mapped by `map_coordinate` (reflect: about −0.5 and n − 0.5, period 2n), then the two neighbours' integer indices are mapped
  the same way, so the result is the bilinear interpolation of the half-sample symmetric extension d c b a | a b c d | d c b a.
  The port folds the coordinate into [−0.5, n − 0.5] and clamps the neighbours, which is the same function (`reference.py` gates it
  against `numpy.pad` at 1e-12 of the maximum, far outside the image included).
- **dtype**: scikit-image returns float32 for a float32 image (`map_coordinates` writes the image's dtype, `np.mean` accumulates
  in float32), which is why P2 carries a 1e-5 band; the port works in Double. DEVIATION noted in `LineProfile.swift`.

## Negative controls

The eight registered controls and four more are SOURCE mutations: each edits a COPY of `ImageMeasurement.swift` or
`LineProfile.swift` in the scratch directory (the edit must match its target text exactly once, so a changed line fails loudly
instead of testing nothing), the harness is compiled against it, and the mutant counts as caught only when it exits 1 and
its log holds a `  FAIL  ` line of the check the mutation targets.

| Mutation | Check that must fail |
|---|---|
| s_x and s_y swapped | `distance 3-4-5 anisotropic physical` |
| s_x for both axes | `distance 3-4-5 anisotropic physical` |
| the angle in pixel space although calibrated | `angle right angle in nm not in pixels degrees` |
| n without the +1 | `profile wave horizontal w1 count` |
| the width ignored | `profile wave horizontal w3 samples` |
| "nearest" for "reflect" | `profile wave border-crossing w1 samples` |
| the perpendicular's sign flipped | `profile wave diagonal w3 samples` |
| row and column swapped in the interpolation | `profile wave horizontal w1 samples` |
| *extra:* arccos for atan2 | `angle nearly parallel arms degrees` |
| *extra:* "mirror" for "reflect" | `profile wave border-crossing w1 samples` |
| *extra:* positions i/n | `profile wave horizontal w1 positions` |
| *extra:* positions in pixels although calibrated | `profile wave horizontal w1 positions` |

The registered "perpendicular's sign flipped" needs a reading. Flipping the whole perpendicular offset (both components) gives
the same w points and the same mean, so no check could see it. The control flips ONE component (`sin(-theta)` written
`sin(theta)`), the bug a transcription makes; it is not perpendicular on any oblique line, and a horizontal or a vertical
line cannot see it (sin θ or cos θ is zero), which is why the target is the diagonal at width 3. "mirror" is scipy's name for
reflection about the pixel centres (c b a | a b c d | c b a); numpy's "reflect" is a different thing, and the two names are
exchanged between `numpy.pad` and `scipy.ndimage`.

## The reference stack

scikit-image 0.26.0 adds four packages to `tools/lib/references-lock.txt`: itself (a cp314 arm64 wheel), `lazy-loader` 0.5,
`networkx` 3.6.1 and `ImageIO` 2.37.4 (pure Python wheels, each at least two weeks old on 2026-10-13); its other requirements
(numpy, scipy, pillow, tifffile, packaging) are in the lock already. `python.sh` compares the lock's lines with `pip freeze`, which spells the package
`ImageIO`; the lock must say it that way.
