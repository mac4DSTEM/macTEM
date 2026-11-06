# Parity

Every SEM-program function the app computes itself (not through a kit), its reference, its state and its tolerance; the kits'
own functions are listed in their `docs/parity.md`. The rule: match the pinned Python reference within the tolerance that
package's own tests use, never stricter. References are pinned in `tools/parity/sem` (kikuchipy 0.13.1, orix 0.15.0, pyebsdindex
0.3.10.1, exspy 0.3.2, rosettasciio 0.15.0).

## Readers (exact)

| Function | Reference | Test | Tolerance | Notes |
|---|---|---|---|---|
| `EBSDH5Reader.read` (kikuchipy h5ebsd) | `kikuchipy.io.plugins.kikuchipy_h5ebsd.file_reader` | `EBSDH5ReaderTests` on `ebsd-kikuchipy-h5ebsd.h5` | header fields, static background and patterns exact; PCs exact | the crystal map's Euler angles are the stored Bunge angles in radians |
| `EBSDH5Reader.read` (Bruker h5ebsd) | `kikuchipy.io.plugins.bruker_h5ebsd.file_reader` | `ebsd-bruker-h5ebsd.h5`, `ebsd-bruker-roi-h5ebsd.h5` | exact | matched upstream: `sample_tilt` is read from `Sample Tilt` (with a space), so it is 0 where Esprit writes `SampleTilt`; for a region of interest the patterns are reordered to map positions but the per-pattern PCs stay in file order, as kikuchipy leaves them |
| `EBSDH5Reader.read` (EDAX h5ebsd) | `kikuchipy.io.plugins.edax_h5ebsd.file_reader` | `ebsd-edax-h5ebsd.h5` | exact; PC converted TSL to Bruker | hex grids refused with the same sentence |
| `EBSDH5Reader.read` (Oxford H5OINA 6.0 and 7.0) | `kikuchipy.io.plugins.oxford_h5ebsd.file_reader` | `ebsd-oxford.h5oina`, `ebsd-oxford-6.h5oina` | fields exact; tilts (radians to degrees) within 1e-12 relative; PC converted Oxford to Bruker | binning from the camera mode string as upstream (`1024 / height`, 88 rows = 8) |
| `EBSDDetectorGeometry.brukerCenter` / `center` | `EBSDDetector._get_pc_in_bruker_convention`, `_get_pc_in_convention` | `testProjectionCenterConventionsRoundTrip` | 1e-12 | TSL, Oxford, EMsoft 4 and 5 |
