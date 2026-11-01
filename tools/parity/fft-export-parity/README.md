# fft-export-parity

macTEM's export from the FFT room (`FFTExport`, `RadialProfileCSV`, `SpotsCSV`, and `ImageExport`'s provenance and
spot marks; TEMCore, through Package.swift's `FFTExportParity` target) read back with Pillow
12.3.0, numpy 2.5.4 and Python's own `float` (pinned: `tools/lib/references-lock.txt`; `reference.py` refuses any other version).
A `scientific` gate (`tools/run-tests.sh scientific`).
Run `tools/parity/fft-export-parity/run.sh`, redirect it to a log, read the exit code on
its own line.

Pass lines: five `ok` lines (F-1 to F-5, with the measured numbers), `fft-export-parity: all passed — N checks`, then
`negative controls: 14 of 14 caught by their checks`.

## How the pieces fit

1. `reference.py plant` writes two images with lattices on whole bins (so a spot's truth is by construction): `whole`, 256 x 200 in
   metres (5e-11 and 8e-11 m: the Velox case, the shown unit is nm^-1 by a factor), default window; `region`, a 192 x 160 region
   of an anisotropic nm image (0.05 x 0.08 nm), an explicit window [-6, 1]; the clicks (two on spots, one refused near the DC or an
   edge), the In Mask flags, and the grey look-up table (the identity; a unit test holds `Colormaps.lutRGBA(.gray)` to it).
2. `main.swift` does what the room does (the transform, `SpectrumDisplay`, the canvas normalised over its finite range, the radial
   profile, `SpotMeasurement` at each click), writes four PNGs (`plain`: no overlays; `full`: spots and bar; `rings`: spots alone on
   black; `bar`: the bar alone on black) and the two CSVs with the production writers, and dumps what it held in memory. It checks nothing.
3. `reference.py check` reads it back.

## What is checked

**F-1** profile CSV: every mean, centre and count re-reads bit-equal to the in-memory value; the shown column is the unit column times
the factor (1e-9 for a metre axis); rows are the bins with a pixel, bin 0 (the DC) not written, as the room's chart does not draw it; the header (software, file, subject, scales, Δq,
"NO window", validation, lineage) equals the plant's; and numpy's own FFT of the region gives the same counts exactly and the same
means within float32's noise (measured 1.1e-6).
**F-2** spots CSV: every number bit-equal; the shown d and |q| are the unit columns times / over 1e9 (m) or 1 (nm); flags, clicks and the header's listed / not-listed counts, mask and notes; and each spot's |q|
(2.2e-5 relative) against the planted lattice.
**F-3** transform PNG: W x H bins, RGB, sRGB; the Description's `fft` block, scales (nm^-1), window, masked count, validation and
lineage equal the plant's; the `plain` export equals the shader's mapping of the dumped canvas exactly (0 levels) and numpy's own
log-power transform within 1 level; the DC bin is the masked grey.
**F-4** the reciprocal bar (on black): label, drawn length (round half up) and per-pixel step equal the hand-worked ones; the longest run of
exact white in the bottom-left plate region times the step equals the label within one export pixel; the bar measures x (Δq_x differs from Δq_y).
**F-5** rings (on black): the yellow-weighted centroid of each ring is within 0.15 export px of its measured centroid (+1/2), and its mean
radius within 3/4 px of 7u. **F-6** the full export lists the spots it drew, labelled by number.

## Negative controls

Fourteen mutations of copies of `FFTExport.swift`, `ImageExport.swift` and `ImageExport+Overlays.swift`, each caught by the check it targets:
the mean at nine digits, the centre at the bin's edge, the DC bin written, the shown unit dropped, "Hann" in the transform's note, In Mask inverted, d not converted, qx and qy swapped, the space "real", the bar on Δq_y, the provenance's validation
kept, the ring without the half pixel, a ring of radius 3, a spot not drawn. ("Empty bins kept" is not a control here: no default-width
profile of these images has an empty bin; the unit test takes a finer width.)
