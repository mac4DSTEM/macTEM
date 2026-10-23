# dm4-reader-parity

macTEM's DM3/DM4 reader (`ImageOpening.openNow`, compiled from `tools/lib/sources.manifest` group `dm`) against
ncempy, pinned in `tools/lib/references-lock.txt`. A `scientific` gate (`tools/run-tests.sh scientific`); the
pre-registration is archive: roadmap-registrations-2026-10-15.md V1-1. Run `tools/parity/dm4-reader-parity/run.sh`, redirect it to a log, and read the exit
code on its own line.

The comparison is exact: every pixel equals ncempy's value cast to float32, each axis's scale has the same float32
bits, the origins are equal and the units are the same string. A file macTEM must refuse has to throw the named
error.

## Cases

1. **Planted fixtures** (`make_fixture.py`), whose truth is written beside each file. ncempy has to reproduce that
   truth before its reading of any case counts.
   - `macTEMTests/Fixtures/planted-2d.dm4` (committed): a thumbnail, then a 40 × 24 int16 image with unique
     values and different, signed, non-integer origins on its two axes.
   - One 3 × 2 fixture for each of the eight pixel types the reader decodes, written to the scratch directory at
     every run. Each holds values that only the right sign and width decode to: a negative value in each signed
     type, a value above the signed maximum in each unsigned type, a value outside the next narrower type's
     range, and a non-integer in each float type. `reference.py` refuses a fixture that lacks them. RosettaSciIO's
     per-type GMS files hold only 1 to 4, which cannot tell these decodings apart.
   **Format fixtures** (archive: roadmap-registrations-2026-10-15.md V1-1b, `make_fixture.py --types`): `planted-si.dm4` (one 6 x 3 object, both axes in nm,
   `Meta Data.Format` "Spectrum image": refused as `noImage`), `planted-si-then-image.dm4` (that object, then a 3 x 2
   image tagged "Image": opens ImageList.3) and `planted-diffraction.dm4` ("Diffraction image": opens). `reference.py`
   checks that ncempy 1.16 reads the same tag from each object before the cases are written.
2. **GMS-written files** from RosettaSciIO at its pinned commit (`tools/lib/fetch-rsciio.sh`). The sha256 of
   `registry.txt` is pinned, and every file's sha256 has to match that registry. Five files must be refused: a
   line scan, a stack, a CL spectrum image (nm × µm) and two complex images.

Seven negative controls (`MACTEM_PARITY_MUTATE`, in `main.swift`) break the reader on purpose; `ignore-format` opens the
refused files by the object rule without its Format clause, so `planted-si` reads. Each one counts as
caught only when the harness exits 1 and the check it targets is among the failures.

## ncempy and a missing Origin

ncempy 1.16 (`ncempy/io/dm.py`, the file whose sha256 `reference.py` pins) keeps one `_origin_temp` for the whole
file:
- it is set to 0 once (line 202);
- it is overwritten by each `Dimension.N.Origin` tag (lines 890–891);
- it is appended to `origin` at each `Dimension.N.Units` tag (lines 810–813).

So a Dimension group with no Origin tag takes the last Origin ncempy read, which may come from another axis or from
the thumbnail. Scale works the same way (`_scale_temp`, line 889). macTEM reads a missing Origin as 0. In a file
whose dimension 1 has Origin 7 and whose dimension 2 has none, ncempy reports 7 for both, while macTEM reports 7
and 0. Every planted Dimension group therefore carries Origin, Scale and Units, which is the layout GMS writes.
