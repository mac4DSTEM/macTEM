# Parity

What the app computes itself, against which pinned Python reference, at which tolerance (the suite's rule: the
tolerance the reference's own tests use, never stricter). Kit functions are the kits' own `docs/parity.md`; this page
lists the app's readers and numerics in `Sources/TEMCore`. The TEM harnesses are `tools/parity/*` (`scientific` lane,
nightly); the SEM program's references are `tools/parity/sem` (kikuchipy 0.13.1, orix 0.15.0, CPython 3.13), written
into `macTEMTests/Fixtures/sem/` and compared by the unit tests on every push.

## SEM readers

| Function | Reference | Test | Tolerance | State |
|---|---|---|---|---|
| `NORDIFSettings` (`Setting.txt`) | `kikuchipy.io.plugins.nordif._get_settings_from_file` | `NORDIFReaderTests` on `Fixtures/sem/nordif` | exact | live |
| `NORDIFScan` (`Pattern.dat`, static background) | `kikuchipy.load("Pattern.dat")` | same | bit-exact (SHA-256 of the uint8 block in map order) | live |
| `NORDIFCalibrationPatterns` (`Calibration (x,y).bmp`, positions, area, ROI, scaled) | `kikuchipy.load("Setting.txt")` (`nordif_calibration_patterns`) | same | exact; bit-exact patterns | live |
| `NORDIFBitmap` (8-bit greyscale BMP) | `matplotlib.pyplot.imread` (Pillow mode L) | same | bit-exact | live |

Known deviations, by choice: none. `Setting_bad3.txt` reads in both (its missing `Top` corner counts as 0, its missing
electron-image `Resolution` leaves the area shape unknown); `Setting_bad1.txt` and `Setting_bad2.txt` are refused for
calibration patterns with one sentence, where kikuchipy raises `ValueError("No calibration patterns found in settings
file")`; all three read the acquisition patterns.
