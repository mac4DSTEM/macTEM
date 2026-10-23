# fft-parity

ImagoKit's `FFT2D`, `PowerSpectrum` and `Micrograph.cropped` (ADR 027; compiled from `tools/lib/sources.manifest` group
`fft`) against numpy 2.5.4 (pinned: `tools/lib/references-lock.txt`). A `scientific` gate; the pre-registration is
archive: roadmap-registrations-2026-10-15.md V1-6 "Slice A". Run `tools/parity/fft-parity/run.sh`, redirect it to a log, and read the exit code on its own line.

## The reference

For each case, `reference.py` takes the float32 pixels (cropped first when the case has a crop) cast to float64, and
writes `F = fftshift(fft2(x))`; magnitude `|F|` and power `|F|**2` (float64); `axis_x = fftshift(fftfreq(w, d = scale_x))`,
`axis_y` likewise (`d = 1.0`, unit `1/px`, when uncalibrated; else `1/nm`). It also writes `<case>.cropped.in.f32`
for a crop case. Contract: `manifest.json` lists per case the input, size, scales, units, crop, output size, the four
`.f64` files, `axis_units`, `peaks` (bin-centred planted peaks as `[row, col]` in the shifted output, both Friedel
partners) and `crop_of`.

Before anything counts, numpy must agree with the plant (`reference.py` exits 1 otherwise): the DC bin equals
`dc*w*h`; every bin-centred wave holds `A*w*h/2` (within 1 %: off-bin leakage; 5 % with noise) at
`(h//2 + ky, w//2 + kx)` and its Friedel partner, each a local maximum, with `axis[...] = k/(n*d)` there; every
off-bin wave puts under 0.9 of that in its nearest bin and no bin of the 5 x 5 window around it reaches 0.99 of it
(else the plant is bin-centred). Crop cases carry no peak checks: a cropped wave is no longer bin-centred.

## Cases (`make_fixture.py`)

Raw little-endian float32, x fastest; scales 0.0123 nm (x) and 0.0246 nm (y) unless noted; DC 1000, noise-free unless noted.

| case | w x h | planted waves (kx, ky, A) | note |
|---|---|---|---|
| p128x96 | 128 x 96 | (10, -7, 100) bin; (23.4, 5.7, 60) off | radix-2 and vDSP DFT |
| p125x243 | 125 x 243 | (6, -9, 100), (0, 4, 30) bin; (-17.3, 31.6, 60) off | odd w and h; radix-5, radix-3 |
| p127x50 | 127 x 50 | (9, 3, 100) bin; (20.5, -6.25, 50) off | Bluestein |
| p250x250 | 250 x 250 | (12, -20, 100), (31, 17, 40) bin; (33.7, 8.4, 60) off | Bluestein |
| n128x96-noise | 128 x 96 | (15, 6, 100) bin; (-31.5, 12.25, 40) off | N(0, 10), seed 20261012 |
| u125x243-uncal | 125 x 243 | (8, 11, 100) bin; (-22.6, -5.3, 50) off | uncalibrated: scale 1, units "" |
| c250-crop-even / -odd | 250 x 250 | as p250x250 | crop (17, 33, 60 x 100) / (11, 29, 61 x 101), row, col, h x w |
| c128x96-crop-even / -odd | 128 x 96 | as p128x96 | crop (10, 20, 40 x 64) / (5, 7, 31 x 45) |

## Slices B and D (`kind` "profile" and "ifft"; every case has a `kind`, the ten above are "spectrum")

Both sides use one order of operations: `dqx = 1.0/(w*dx)`, `dqy = 1.0/(h*dy)` (scales 1.0 uncalibrated); shifted
index `(r, c)` -> `i = c - w//2`, `j = r - h//2`.

**Profile**: `q = sqrt((i*dqx)**2 + (j*dqy)**2)`, `k = floor(q / wb)`, `wb` the case's bin width (`bin_width_given`:
null = `max(dqx, dqy)`); numpy's power `|fftshift(fft2(x))|**2`; `mean[k] = bincount(k, P) / count[k]`, the DC in bin 0.
Writes `<case>.pmean.f64`, `<case>.pcount.i64`; manifest `bin_width`, `bin_width_given`, `ring_bin = floor(q0/wb)`,
`nbins`. Plant (exit 1 otherwise): the profile's peak (bin 0 excluded) is `ring_bin`, 1.2 x the next bin. The planted
image is `100 exp(-r^2/2 sigma^2) cos(2 pi q0 r)`, `r` the physical radius from the centre, DC 1000. A bin narrower
than a frequency pixel is sparse, so `q0` was scanned for the cases where the peak falls in `q0`'s bin at both widths.

**Masked inverse**: spots `{kx, ky, r, e}` (index units from the centre) and their Friedel partners `(-kx, -ky)`;
`d = sqrt((i-kx)**2 + (j-ky)**2)`; `m = 1` for `d <= r`, `0.5(1+cos(pi(d-r)/e))` for `e > 0, r < d < r+e`, else 0;
`M` the maximum; result `ifft2(ifftshift(fftshift(fft2(x)) * M))`. Writes `<case>.ifft.f64` (real part); manifest
`spots`, `mask_lattice`, `imag_max`, `real_max`, `corr_masked`, `corr_other`. Plant: the result correlates > 0.99 with
the planted masked lattice and < 0.1 in magnitude with the other, the imaginary part is below 1e-9 of the real, and
no other wave lies within `r + e + 2` of a masked spot.

| case | w x h | note |
|---|---|---|
| pr128x96, pr128x96-half | 128 x 96 | ring q0 8.06 /nm, sigma 2 nm; default bin width / `min(dqx,dqy)/2` |
| pr125x243, pr125x243-half | 125 x 243 | ring q0 7.70 /nm; anisotropic |
| pru125x243-uncal | 125 x 243 | scale 1, ring q0 0.098 /px, sigma 20 px |
| ifA-128x96, ifA-127x50 | | lattice A (100) at (9.1, 3.9), (-4.1, 7.9) masked r 2.5, e 2; lattice B (20) at (21.9, -9.1), (-15.1, 10.9) |
| ifB-128x96, ifB-127x50 | | same images, B masked r 3, e 0 (hard) |

## Negative controls

Sixteen, six from slice A and ten from B and D (below the first six). The profile controls except `profile-ring-scale` recompute a broken profile in the harness (`brokenProfile`): they show the checks see those faults; the unit tests break RadialProfile itself. `profile-ring-scale` scales every non-DC bin by 1.001 and must fail `pru125x243-uncal profile-away` — the check against the largest non-DC bin, added after the Gate B review because the registered band, relative to the DC bin, is up to 6x the ring there.

Six (`MACTEM_PARITY_MUTATE`, in `main.swift`), each caught only when the harness exits 1 and the target check is among
the failures: `no-shift` -> `p128x96 magnitude`; `shift-odd` -> `p125x243 magnitude` (odd width and height, so shift
`(n-1)/2` differs from `n/2` on both axes); `x-scale-both` -> `p128x96 axis_y`; `power-is-magnitude` -> `p128x96 power`;
`fftfreq-n-minus-1` -> `p128x96 axis_x`; `crop-origin` -> `c128x96-crop-even crop` (offset 10, 20 is non-zero).

Slice B: `profile-pixel-bins` and `profile-dqx-both` -> `pr125x243 profile`; `profile-round`, `profile-sum` -> `pr128x96
profile`; `profile-drop-dc` -> `pr128x96 counts`. Slice D: `ifft-no-friedel`, `ifft-hard-edge`, `ifft-partner-off`,
`ifft-unscaled` -> `ifA-128x96 ifft` (even size, e = 2; numpy-measured change from the unmutated result, relative to the
real maximum: 0.50, 0.071, 0.037, 1.2e4).
