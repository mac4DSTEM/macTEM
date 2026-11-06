# Parity

Every SEM-program function the app computes itself (not through a kit), its reference, its state and its tolerance; the kits'
own functions are listed in their `docs/parity.md`. The rule: match the pinned Python reference within the tolerance that
package's own tests use, never stricter. References are pinned in `tools/parity/sem` (kikuchipy 0.13.1, orix 0.15.0, pyebsdindex
0.3.10.1, exspy 0.3.2, rosettasciio 0.15.0).

## Pattern processing

References: `tools/parity/sem/background_reference.py` (kikuchipy 0.13.1, numpy 2.5.4, scipy 1.18.1) on `nickel_ebsd_large`
(Aanes et al. 2020, CC BY 4.0); fixtures under `macTEMTests/Fixtures/sem/background/`, tests in `SEMBackgroundParityTests`.
kikuchipy computes in float32 (numba, fastmath) and casts back to the pattern's integer type by truncation; TEMCore computes in
float64. The rescaled values agree to 1e-5 relative (measured at most 1.1e-6); the cast patterns differ by one grey level where
kikuchipy's float32 value lands on the other side of an integer: measured on all 4125 patterns, 0.05 % (static subtract),
0.10 % (static divide), 0.007 % (dynamic, frequency) and 0.006 % (dynamic, spatial) of the pixels, never more than one level.
Upstream's own tests compare hand-written 3 x 3 uint8 answers exactly (`test_remove_static_background`,
`test_remove_dynamic_background_spatial`) and the frequency route at `atol=1e-4` on float answers.

| Function | Reference | Test | Tolerance | Notes |
|---|---|---|---|---|
| `PatternProcessing.rescale` | `pattern._pattern._rescale_with_min_max` | through every row below | values 1e-5 relative | a flat pattern (max == min) is refused with `.nonFinite`; kikuchipy returns NaN |
| `PatternProcessing.removeStaticBackground` / `...Values` (subtract, divide, `scaleBackground`) | `_remove_static_background_subtract` / `_divide` | `testStaticBackground…` | values 1e-5 relative; uint8 within one grey level on at most 1 % of a pattern's pixels (measured 22 of 3600 at worst), 0.2 % of a whole set | uint16 rescales to 0 … 65535 (`dtype_range`); a zero in a divided background is refused with `.nonFinite` |
| `PatternProcessing.meanBackground` | `patterns.mean(axis=0).astype(dtype)` | `testMeanBackground…` | exact | the static background of a file that carries none |
| `PatternProcessing.dynamicBackground` (frequency) | `get_dynamic_background` / `filters.fft_barnes._fft_filter` with `_dynamic_background_frequency_space_setup` | `testDynamicBackgroundFrequency…` | 1e-5 relative (measured 4.9e-7) | computed as the separable nearest-edge correlation with the `int(truncate · std)` px `scipy.signal.windows.gaussian` window, the operator the padded real FFT evaluates (taps i − 15 … i + 14 for the default 30 px window, symmetric for an odd one); not an FFT, decision D-SEM-17 |
| `PatternProcessing.dynamicBackground` (spatial) | `scipy.ndimage.gaussian_filter(sigma=std, truncate=truncate)` | `testDynamicBackgroundSpatial…` | 1e-5 relative (measured 6.7e-8) | ImagoKit's `SeparableFilters.gaussianFilter`, mode reflect |
| `PatternProcessing.removeDynamicBackground` / `...Values` (subtract, divide; frequency, spatial; `std`, `truncate`) | `_remove_dynamic_background` | `testRemoveDynamicBackground…`, `testFigureF2…`, `testWholeSetF2…` (opt-in, `$MACEM_DATA/sem/nickel_ebsd_large`) | as the static rows | `std` defaults to the pattern width / 8 |

### Known limits and decisions

- D-SEM-17 (2026-11-06): the frequency-domain dynamic background is the direct separable correlation, not a padded FFT. Reason:
  kikuchipy's window is an outer product of one `scipy.signal.windows.gaussian`, its padding is edge replication and its crop
  reads no zero-padded sample, so the padded real FFT evaluates exactly this correlation; the direct form keeps the float64
  reference path, has no padding bookkeeping and costs 2 · M multiplies per pixel (M = 30 by default). A Metal or Accelerate
  path behind the same parity test is phase 2's optimisation (P2-01, the Patterns room's processing).
- Figure F2 (`docs/sem/north-star.md`): `tools/parity/sem/background_figure.py` draws the reference pattern beside the one the
  unit test `testFigureF2PatternZeroAfterStaticAndDynamicBackground` writes to `$TMPDIR/macTEM-F2-ours.u8` (and prints as base64).
