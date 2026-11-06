# sem-readers

The fixtures and truth of the SEM program's file readers (`Sources/TEMCore/SEM/`), written by kikuchipy's own readers and
dummy-file writers so a reader is tested against what the Python reference returns. Classified `support` in
`tools/run-tests.sh`: not a harness, nothing runs per session; the unit tests read the committed fixtures.

| script | writes |
|---|---|
| `make_h5ebsd_fixtures.py <out>` | `ebsd-*.h5` / `.h5oina` (six h5ebsd files: kikuchipy, EDAX, two Bruker, two Oxford) and `ebsd-h5ebsd.truth.json` |

Run with the SEM parity environment (`tools/parity/sem`, kikuchipy 0.13.1): `python -I -B make_h5ebsd_fixtures.py out`, then copy
the files into `macTEMTests/Fixtures/`. A changed fixture or truth is a fixture move: its own commit with the reason.
