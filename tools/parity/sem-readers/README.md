# sem-readers

The fixtures and truth of the SEM program's file readers (`Sources/TEMCore/SEM/`), written by the Python references' own readers
so a reader is tested against what the reference returns. Classified `support` in `tools/run-tests.sh`: not a harness, nothing
runs per session; the unit tests read the committed fixtures.

| script | writes |
|---|---|
| `make_h5ebsd_fixtures.py <out>` | `ebsd-*.h5` / `.h5oina` (six h5ebsd files: kikuchipy, EDAX, two Bruker, two Oxford) and `ebsd-h5ebsd.truth.json` |
| `make_h5oina_map_fixtures.py <out>` | `ebsd-oxford-map*.h5oina` (four planted map-only H5OINA files, #513: no reference reads an H5OINA map, so the test states the map; the same map with processed or only unprocessed patterns, and `ebsd-oxford-eds.h5oina`, an EDS scan alone, #514; h5py and NumPy only) |
| `make_hspy_4d_fixture.py <out>` | `sem/hyperspy-4d-unnamed.hspy` (a 4D HyperSpy file whose experiment is "__unnamed__"; refused without that name) |
| `make_h5oina_lzf_fixture.py <ebsd-oxford.h5oina> <out>` | `ebsd-oxford-lzf.h5oina` (#524: ebsd-oxford.h5oina with every dataset LZF-compressed by h5py, as AZtec writes patterns; read as the uncompressed file) |
| `make_orix_map_fixtures.py <out>` | `ebsd-orix-map*.h5` (orix 0.15.0's own map files, written by `orix.io.save`: a map, one with two rotations a point, one cut from it) and `ebsd-orix-map.truth.json` (`orix.io.load`), #514 |
| `make_h5ebsd_without_patterns.py <fixtures>` | `ebsd-bruker-nopatterns-h5ebsd.h5`, `ebsd-edax-nopatterns-h5ebsd.h5`: the committed Bruker and EDAX files without their patterns (in place, from the fixtures folder), #514 |
| `make_edax_fixtures.py <out> [sdss_ferrite_austenite.ang]` | `ebsd-edax-binary*.up1/.up2`, `ebsd-sdss-ferrite-austenite.ang`, `ebsd-tsl*.ang` and `ebsd-edax.truth.json` (kikuchipy 0.13.1 `edax_binary`, orix 0.15.0 `ang`) |

Run with the SEM parity environment (`tools/parity/sem`): `python -I -B make_h5ebsd_fixtures.py out` or `make_edax_fixtures.py out`, then copy the files into
`macTEMTests/Fixtures/`. A changed fixture or truth is a fixture move: its own commit with the reason.
