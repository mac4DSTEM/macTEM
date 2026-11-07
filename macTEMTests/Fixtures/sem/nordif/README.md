# NORDIF fixtures

kikuchipy 0.13.1's `kikuchipy/data/nordif/` (GPL-3.0-or-later, the kikuchipy developers; the patterns are from the
recrystallised nickel dataset of Ånes et al. 2020, CC BY 4.0), copied unchanged: a 3 x 3 scan of 60 x 60 px patterns
(`Pattern.dat`, `Setting.txt`), the static backgrounds, two calibration patterns and three damaged settings files.
`reference.json` is what `kikuchipy.load` reads from them, written by `tools/parity/sem/nordif/reference.py`; the
`files` block holds each file's SHA-256 so the test knows the reference read these bytes.
