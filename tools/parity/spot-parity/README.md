# spot-parity

macTEM's spot d-spacing (compiled from `tools/lib/sources.manifest` group `spot`) against a numpy 2.5.4 script of the
same estimator (pinned: `tools/lib/references-lock.txt`) and the planted spacing. A `scientific` gate; the
pre-registration is archive: roadmap-registrations-2026-10-15.md V1-6 "Slice C, the spot's d-spacing"; the measurement study behind it is
archive: spot-dspacing-study-2026-10-12.md. Run `tools/parity/spot-parity/run.sh`, redirect it to a log, and read the
exit code on its own line.

## The reference (`reference.py`)

From the float32 pixels cast to float64: `x - x.mean()`; times `np.outer(np.hanning(h), np.hanning(w))`;
`P = |fftshift(fft2(.))|**2`. **Snap**: the argmax of `P` within +-2 bins (rows and cols) of the click, ties to the first
in row-major order. **Centroid**: over the 5 x 5 window around the snapped bin, `(sum P*row)/sum P`, `(sum P*col)/sum P`,
no background. **d**: `i = col_c - w//2`, `j = row_c - h//2`, `qx = i/(w*dx)`, `qy = j/(h*dy)`, `d = 1/sqrt(qx^2+qy^2)`.
**Refusal `nearDC`**: the snapped bin within Euclidean distance 3 bins of `(h//2, w//2)`. **Neighbour flag**: another
local maximum (strictly above its 8 neighbours), other than the 5 x 5 window's own maximum, within Euclidean distance 3
of the snapped bin, with power above 0.1 x the spot's. Contract: `manifest.json` lists per case `name`, `input` (full
path of the float32 file), `width`, `height`, `scale_x`, `scale_y`, `units`, `click_row`, `click_col` (centred-spectrum
index), `kind` (spot or refusal), `snapped_row/col`, `centroid_row/col` and `d` (null for a refusal), `d0`, `tier`,
`neighbour`, `click_offset`, `error` (null or `nearDC`).

Before anything counts, numpy must agree with the plant (`reference.py` exits 1 otherwise): the snap returns the planted
maximum with a relative margin of at least 1e-10 over the runner-up (a 0.5-bin offset makes two bins nearly equal; the
margin is the guard against a float tie); `|d - d0|/d0` is under 0.2 % (clean, P1) or 0.5 % (noisy, P3), the
distribution printed; the refusal is refused and nothing else is; the neighbour flag is set exactly where planted; and
each mutation moves its target by more than 1e-3 px (centroid) or 5 x the band (d).

## Cases (`make_fixture.py`, 38)

Scales 0.0123 nm (x) and 0.0246 nm (y), units `nm`; spot amplitude 1, DC 10, a weak second lattice (0.3, off-bin) at least
6 bins from the spot, its Friedel partner and the centre. Cases `s<w>x<h>-k<5|10|25|40>-a<angle>-o<ox>_<oy>`: sizes 64,
128, 256, 512, 256x128, 96x128 at 5 bins and 0.1/0.25/0.4 Nyquist (k = rel x min(w,h)/2, at least 5; duplicates
dropped), direction 20/70 degrees alternating, sub-bin offsets {0, 0.25, 0.5} cycling, the click 0, 1 or 2 bins off the true
maximum cycling (22 cases). `x128-*` (4): 128 x 128 at 5 bins, offsets 0 to 0.5, clicks 2 bins off. `dc1000-*` (2): DC 1000,
where a missing mean subtraction leaks into the window. `noisy<N>-*` (8): sigma 1, N = 256 and 512, k >= 0.1 Nyquist, seeds
20261012-20261019, tier noisy. `refuse-nearDC`: a spot at (2, 1) bins. `neighbour-3bins`: a second spot 3 bins away at
amplitude 0.4 (16 % of the power); tier noisy because the second spot biases d by up to ~0.3 % (study finding 6).

## Negative controls (run.sh)

Each mutation must make the Swift harness exit 1 with a `FAIL` of the targeted check: no-mean and the DC 1000 case's
d (the spot is refused near DC); no-hann, window-3x3, magnitude-weights on `s128x128-k5-a70-o0.25_0.5` centroid; no-snap on
`x128-k5-o0.25_0.25-c0_2` centroid; one-spacing and qx-only on `s128x128-k5-a70-o0.25_0.5` d. `reference.py` shows the
numpy version of each mutation moves its target far outside the band, so the Swift side cannot pass by accident.
