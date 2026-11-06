# sem-readers

The fixtures and truth of the SEM program's file readers (`Sources/TEMCore/SEM/`), written by the Python references' own readers
so a reader is tested against what the reference returns. Classified `support` in `tools/run-tests.sh`: not a harness, nothing
runs per session; the unit tests read the committed fixtures.

| script | writes |
|---|---|
| `make_edax_fixtures.py <out> [sdss_ferrite_austenite.ang]` | `ebsd-edax-binary*.up1/.up2`, `ebsd-sdss-ferrite-austenite.ang`, `ebsd-tsl*.ang` and `ebsd-edax.truth.json` (kikuchipy 0.13.1 `edax_binary`, orix 0.15.0 `ang`) |

Run with the SEM parity environment (`tools/parity/sem`): `python -I -B make_edax_fixtures.py out`, then copy the files into
`macTEMTests/Fixtures/`. A changed fixture or truth is a fixture move: its own commit with the reason.
