# hrtem-filter-parity

macTEM's HRTEM filters — the ABSF and Wiener filters of D. R. G. Mitchell's `HRTEM_Filter.s` v4.0, after Kilaas 1998
(ImagoKit's `HRTEMFilter`, ADR 027, built from the pinned checkout by `tools/lib/sources.manifest`; macTEM's seam is group `hrtem`) — against
`reference.py`, a float64 numpy reading of the same steps, and the plants' truth. The registration in force is archive: roadmap-registrations-2026-10-15.md
**"V1-6d HRTEM filters, third registration: the products gated"** (the owner's choice, ADR 016); V1-6b and V1-6c, above it,
failed or stopped and are kept as history. Run `tools/parity/hrtem-filter-parity/run.sh`, redirect it to a log, and read the exit
code on its own line; it takes about 15 s. **Classified `scientific`.**

**Licence.** Mitchell's script states no licence. `reference.py` and the Swift are a functional re-implementation of the
registration's steps A1–A6, written by different authors from that text, neither from the script; nothing of the script is in
the repo (ADR 014). The parity is two readings of one description agreeing, never equality with DigitalMicrograph: the product
is badged "not compared with Digital Micrograph".

## The plants (`plants.py`)

Seeds fixed by the registration: SEED0 = 20261015 (V1-6b's 20261013 and V1-6c's 20261014 were seen). Float32 n × n images, DC
1000 + a lattice + an isotropic random-phase continuum (a Gaussian ring at 0.08 n bins and a k^−1.5 power law, rms 15) + white
noise σ 5. The lattice: three cosine waves (amplitudes 20–80) and their second harmonics at half amplitude, inside the
Butterworth's Ro · n/2 = 0.15 n. 41 cases: tiers `bin`, `offbin` (half-integer), `noise`, `ramp`, `nyquist` (a wave at r = n/2 in
the input; the truth is the in-band lattice) at n = 128, 256, 250 (Bluestein); `offbin0`, `offbin25`, `offbin50` (offsets 0,
0.25, 0.5 bins) at 128 and 256; one case per varied parameter on the `bin` plant at 128 and 256 (pct 5 and 20, smoothing off,
order 1 and 8, Ro 1, step 5, delta 20, cycles 3); `lattice-clean` and `constant` at 128.

## The reference (`reference.py`)

numpy 2.5.4 and scipy 1.18.1 (`median_filter(size=3, mode="nearest")`, `map_coordinates(order=1, mode="nearest")`), float64
from the float32 pixels; every stage written as a file `manifest.json` names (W, w, a and M under distinct names: macOS volumes
are case-insensitive). For V1-6d it also writes each bin's first flagged pass, every (pass, bin, margin) with a float64 margin
|c − (100 − t)| below 5 points, and P2's region (r ≤ 0.15 n, DC excluded, outside ± 2 bins of every planted peak and its mirror,
in numpy's unshifted frame). It still runs V1-6c's Float32 emulations and prints their deviations, the off-bin kept amplitudes,
the Nyquist cut and the stop rule per case. Self-checks, exit 1 on any.

## Checks (`main.swift`), as V1-6d registers them

Every case: both outputs within **1e-5** of the float64 output's maximum; W, M, a, w W-weighted (Σ|Δ|·W / Σ|x|·W over r > 0)
within **1e-4** (undefined, and reported, on the constant image, where W off the DC is roundoff); the ABSF output's mean over the
input's within **1e-6** of the float64 mask at the DC; **flags per bin**: δ = 3 × the case's largest pass-1 |Δc| over the disk,
and at the first pass where any bin differs every differing bin's float64 margin on that pass is at most δ (later passes
reported). The noisy tiers at the defaults: each output's energy in P2's region below the input's. Printed: pass 1's c
deviation, the passes, every error, the energy ratios. Controls (`run.sh`), emulated on the Swift output on `bin-128`:
`absf-sign` → absf, `dc-removed` → dc, `flag-moved` → flags, `a-scaled` → a; each must pass unmutated and fail mutated. The
filter's stages are held by the kit's own tests (ImagoKit, ADR 027; macTEMTests/HRTEMFilterTests.swift moved there).

## Result V1-6d, 2026-10-13 (scratchpad `v16d/run-2.log`, `run-3.log`): passed

319 checks over 41 cases, 0 failures; 4 of 4 controls. Both outputs within 1.8e-7 of their maximum (ABSF 9.8e-8; band 1e-5);
every W-weighted stage within 1.5e-6 (band 1e-4); the DC within the band on every case; pass counts equal on all 41; no bin
differs on 26 cases, and on the other 15 one or two bins first differ late in the loop (from pass 7 on the noise-free
lattice, pass 31 or later elsewhere), every one within δ (0.08–0.85 points). Energy outside the lattice bins: 0.002–0.63 of the
input's. Printed by reference.py on the float64 reading: a lattice half a bin off keeps 5–57 % of its amplitude at n = 128 and
77–97 % at 256; the Nyquist wave 1.6e-4. Run 1 crashed in decoding (a NaN in manifest.json, now written as null) before the
Swift ran; run 3 only added the outputs' errors to the printout. Gate B (Sonnet, independent): upheld with findings — its
mutants of the filter (a threshold 2 % off, a 0.05-point bias in c) were caught by the product bands; the cycle cap and the
pass count are printed, not gated (an off-by-one cap passed here; a unit test now catches it).

## History

**V1-6b (`7c3cc89`, SEED0 20261013): failed.** Pass-1 c and the masks were banded at 1e-5, unreachable in Float32 at weak bins;
P2's "closer in RMS to the lattice" failed on the Nyquist plant (an out-of-band wave in the truth) and on off-bin lattices (the
method: an off-bin wave's leakage is not flagged, enters M and is subtracted); 4 of 10 cases cleared the 1e-3-point margin.
**V1-6c (`0d506f5`, SEED0 20261014): stopped at its measurement.** The mean removed before each Float32 transform improved the
products 3–1000× but pass-1 c only 1.2–2× (0.52 points, on degenerate plants), firing its switch to a Double transform; the
owner chose to gate the products instead (V1-6d).
