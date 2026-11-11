# tools/parity/sem

The SEM program's parity harness: the pinned Python stack (kikuchipy, orix, diffsims, HyperSpy, exspy, RosettaSciIO,
pyEBSDindex) emits a reference bundle for every ported function; `macTEMTests` compares the Swift port against the
bundle within the tolerance the bundle states; CI is red on drift on either side. No SEM function ships without a
bundle and a test against it.

```
requirements.lock     the stack, every package pinned (pip freeze on CPython 3.14)
setup.sh              builds References/sem-venv from the lock (prints the interpreter)
data-manifest.txt     the downloaded datasets: path, sha256, URL ("manual" for Zenodo)
fetch-data.sh         fetches them into References/sem-data/ and verifies
fixtures/             small committed inputs with SHA256SUMS (docs/data-sources.md lists each one's licence)
make_fixtures.py      writes the planted fixtures (the .ctf, kikuchipy's dummy H5OINA and Bruker files)
emit.py               the cases: one function per bundle, --out DIR
check.py              the drift gate: emit afresh, compare with references/ within tolerance
references/           the committed bundles, <milestone>/<case>/manifest.json + <array>.bin
lib/refbundle.py      the bundle format (schema 1) and the comparison
lib/refbundle_selftest.py  the comparison checked on its own (CI runs it before the emit)
drift-gate.sh         setup, fetch, check (not run.sh: that name is the Swift-harness entry point the inventory checks)
```

## A bundle

`manifest.json` names the reference package, version and function, the stack it ran on, its inputs with sha256,
`values` (exact JSON: shapes, axes, metadata, fingerprints of arrays too large to commit), `scalars` and `arrays`,
each with `rtol` and `atol` (0/0 is exact; otherwise numpy's `assert_allclose` rule, |a - b| <= atol + rtol * |b|,
the reference as b). Arrays are raw little-endian C-order files; dtype one of uint8, uint16, int32, int64,
float32, float64. The Swift loader is `macTEMTests/SEMParityReference.swift`. An array of rotations may also carry
`symmetry` (an orix point group name), `rotation` (`quaternion` or `euler_bunge_radians`) and
`angle_tolerance_degrees`: `check.py` then compares it point by point by the misorientation angle under that group, so
a re-emit that hands another symmetry twin of the same orientation agrees (#434); the Swift loader ignores the keys.

## Writing a port's test

```swift
let ref = try SEMParityReference.load("m1/vbse-kikuchipy-h5ebsd")
let url = try XCTUnwrap(ref.inputURL())                  // the fixture the bundle was emitted from
let images = try VirtualBSE.gridImages(of: url, grid: (5, 5))   // the Swift port
SEMAssertParity(images.values, try ref.array("grid_images"), shape: images.shape)
```

A case whose input is a downloaded dataset (`sem-data/…`) skips with `XCTSkip` when the file is absent; the committed
small fixtures cover every function, so the skip never hides a port.

## Changing a reference

A number moves only when the stack pin, a fixture or `emit.py` changes on purpose. Then: `setup.sh`, `fetch-data.sh`,
`python -I -B emit.py --out references --require-data`, read the diff, commit the bundle with the reason in the
message (a `fix:` PR when a shipped number changes; `docs/parity.md` and the release notes say so). `check.py`
stays red until that commit.

## CI

`.github/workflows/sem-parity.yml` (Linux, on changes under this folder) rebuilds the stack, runs
`lib/refbundle_selftest.py`, fetches the data, regenerates the planted fixtures (must not change the tree), emits every
bundle and runs `check.py --require-data`.
The unit job of `ci.yml` runs `SEMParityHarnessTests` on every PR: every bundle loads intact, fixtures match
`SHA256SUMS`, the comparison accepts within tolerance and refuses beyond it, and every case is named in
`docs/sem/north-star.md`.
