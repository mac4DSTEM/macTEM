# velox-image-parity

macTEM's Velox `.emd` image reader (`ImageOpening.openNow` → `VeloxImageReader`, TEMCore, over SpectroKit 0.2.0's
`VeloxEMDReader`; both compiled into one module from `tools/lib/sources.manifest` groups `velox` and `metadata`) against
the registered object rule written again, independently, from the raw JSON, h5py 3.16.0, and RosettaSciIO `049e7d70`
(`rsciio.emd.file_reader(select_type="images")`; pinned: `tools/lib/references-lock.txt`, `tools/lib/fetch-rsciio.sh`;
SpectroKit's source: `tools/lib/fetch-spectrokit.sh`). A `scientific` gate (`tools/run-tests.sh scientific`); the
pre-registration is archive: roadmap-registrations-2026-10-15.md V1-3a (the 2026-10-13 amendment and the 2026-10-12 re-registration govern), and V1-4a "the
panel", the `.emd` sentence, for the metadata. Run `tools/parity/velox-image-parity/run.sh`, redirect it to a log, and read the exit
code on its own line.

Pass lines: `velox-image-parity: all passed — …`, then `velox-image-parity: negative controls: 14 of 14 caught by their
checks` and `velox-image-parity: .emd metadata negative controls: 3 of 3 caught by their checks`.
`run.sh --make-fixture` rewrites the unit tests' planted files (below).

## Three readings that must agree

`reference.py` reads every Velox file three ways and writes the expected reading of each (`manifest.json`, one `.f32` per
frame). Before any reading counts it checks that the files are the pinned ones (sha256 against `rsciio/tests/registry.txt`),
that the planted files are the ones `make_fixture.py` wrote, and that all three reproduce every planted truth and each other;
a disagreement exits 1 there, loudly, as a reference check and never a pass.

- **rule** — an entry of `Data/Image` (a group with a rank-3 `Data` and a `Metadata`, in h5py's key order) is a *candidate*
  when its `BinaryResult.DetectorIndex` resolves in the `Detectors` table to a `DetectorType` other than
  `AnalyticalDetector` and its stored type is an integer of 1–8 bytes or a float of 4 or 8 bytes (not compound). The first
  candidate whose `BinaryResult.Detector` is `HAADF` opens, else the first candidate; none: `noImage`; not Velox (no
  `Version`, a format other than `Velox`, not HDF5): `notVelox`; an image over 2^28 pixels: `unreadable`. Calibration as
  stored: scale = `PixelSize.width` / `.height`, unit = `PixelUnitX` / `PixelUnitY`, origin = −`Offset` / `PixelSize` in exact
  rational arithmetic (nil when the size is absent or not positive), voltage = `Optics.AccelerationVoltage`. Written in
  `reference.py` from the raw JSON, not from the reader.
- **h5py** — the raw frames (frame 0, frame 1 and the last) as float32, and the raw strings.
- **RosettaSciIO** — frame 0 as float32, and each axis's scale and offset converted back to the file's own unit with pint
  (RosettaSciIO puts X's unit on both axes, so a file with different X and Y units is read as RosettaSciIO would). Parity, not
  truth: the planted files carry truth by construction.

## What is compared (P1, P2)

For every file the rule opens: the pixels of frame 0 and of every frame named, bit for bit against h5py's float32 (and
RosettaSciIO's); each axis's scale, bit for bit against the stored decimal and within 1e-12 relative of RosettaSciIO's; its
origin within 1e-9 px of the rule's and of RosettaSciIO's, and its sign; the unit strings equal to the raw `PixelUnitX` /
`PixelUnitY`; the voltage equal to the raw field; the opened entry (`source`, and `openedEntry`) equal to the rule's; the
notes; `ImageOpening.openNow` equal to `VeloxImageReader.read`; a frame outside the stack refused as `unreadable`.

- **P2 (a)** every non-Velox, spectrum-only, compound-only and maps-only file throws its named refusal, and no file the rule
  opens is refused. **(b)** every entry's candidacy equals the rule's, and no Analytical entry and no compound image opens.
  **(c)** `frame 1 of N` is in the notes iff N > 1. **(d)** one frame of a 1024 × 1024 × 64 `uint16` stack, one frame per chunk,
  written at run time (134 MB), opens with peak resident growth under 25 % of the stack. The measurement is `ru_maxrss` before
  and after the open in a child process of the harness (`--measure`), which first opens a small file so the library is loaded;
  `fei_example_tem_stack` (chunked across frames) is measured the same way and reported, not claimed. Beyond the registration:
  an image over 2^28 pixels is refused as `unreadable` without being allocated, and a process told of no libhdf5 (a child run
  with `FORMATO_HDF5_PATH` and `DYLD_FALLBACK_LIBRARY_PATH` pointing nowhere, in an empty directory) names the refusal
  `library`.
- **The registered predictions** (12 of the 13 zip files open, 6 as `frame 1 of N`, `Test SI 16x16` opens its HAADF though
  last, `example_velox_EELS_EDS` its 16 × 20 DF-S image, `FFTComplexEven/Odd` the 128 × 128 HAADF, `fei_example_complex_fft`
  and the 14 non-Velox files refused, the Ceta trio at its TIFF's scale and origin 1024.0) are each printed `HELD` or
  `REFUTED` with the evidence; all but the Ceta one (a diagnostic) fail the gate when refuted.
- **The `.emd` metadata** (V1-4a), `AcquisitionMetadata.read(path:)`: high tension (V → kV), detector, instrument, start date
  and dwell (µs, only for a `ScanningDetector` entry) equal the rule's reading of the raw JSON; the high tension also equals
  RosettaSciIO's `Optics.AccelerationVoltage` mapping (`FeiEMDReader._get_mapping`), the date its `General.date` and `.time`;
  the date shown in `Pacific/Auckland` equals the instant there (so the zone conversion is checked whatever this Mac's clock
  says); the four fields macTEM does not read yet (SpectroKit 0.2.0 exposes them) are `unread`, never "not recorded"; a refused file reads empty.
  Two differences from RosettaSciIO are printed, not checked, because they are its own derivations: its `General.title` is
  the Operations group's camera or DPC name (`Ceta` for `BM-Ceta`, `B-D` for a DPC entry), not `BinaryResult.Detector`; and
  for a file without `AcquisitionStartDatetime` it dates the image from a `CustomProperties` timestamp, which SpectroKit 0.2.0
  does not expose. On the owner's three Ceta files each field both the `.emd` and its paired TIFF read is compared (diagnostic).

## Cases

1. **Planted files** (`make_fixture.py`; Velox-shaped, each under 1 MiB, written at every run): a HAADF not first in key order
   beside two float32 EDX maps without `DetectorIndex` and a DF4 image before it; no HAADF (DF2 and BF) with an EDX map whose
   index names an `AnalyticalDetector` first; maps only; compound only; anisotropic non-square pixels with `Offset` ≠ 0 in
   `m`, in `1/m`, and with different X and Y units; a stack of three frames that differ at every pixel; two frames of `int16`
   with negative values (a camera image, so its `Scan.DwellTime` is not a dwell); `int32` beyond 2^24; one file per other stored
   type; no calibration at all; a zero pixel width; an image over 2^28 pixels; a Berkeley (NCEM) EMD; a text file named `.emd`.
   The truth of each is written by hand in `make_fixture.py`: the entry, every pixel, each axis's scale, unit and origin, the
   voltage, the notes, the refusal.
2. **RosettaSciIO `049e7d70`'s test data** (`References/rosettasciio`): the 4 Velox zips (13 files, 27 image stacks), the loose
   `FFTComplexEven`, `FFTComplexOdd`, `fei_example_complex_fft`, `fei_example_dpc_titles` and `fei_example_tem_stack`, and its
   14 non-Velox `.emd` and `.h5` files for refusal.
3. **The owner's three Ceta `.emd`** (`References/example_files/`, gitignored): a diagnostic, never gated; each skips with a
   printed line when absent.

`reference.py` counts the candidate entries of the public Velox files and the owner's Ceta files and prints whether each
carries `PixelSize`, `Offset` and the same `PixelUnitX` and `PixelUnitY`: when it does (the run says), the adapter's
DEVIATION (the y unit from `PixelUnitY`, where RosettaSciIO reads X's) is inert on the real data, and the planted
different-units file is what exercises it.

Added after Gate B (2026-10-13), each catching transformations that passed every earlier check: `two-haadf` (the first
exact HAADF opens; "haadf" and "HAADF-2" do not count), `detector-gap` (a table with indices 1, 2, 5: an index is a key),
`index-absent`, `sizes-not-positive` (−2.5e-10 and inf), `x-unit-only`, `unit-nm`, `entries-differ` (each entry its own
size, unit, offset, voltage), `frac-date` (a start second of .75 is truncated) and `camera-index-mismatch` (Velox 4's
`1854 Camera Ceta.emd` in miniature: the detector is the one `BinaryResult.Detector` names, so its scan dwell is no dwell).

## Negative controls

Seventeen source mutants: each compiles the harness against an edited COPY of `VeloxImageReader.swift` (the app's seam), or of FormatoKit's `FormatoEMD/VeloxImageSelection.swift` / `FormatoEMD/AcquisitionMetadataVelox.swift` (through `MACTEM_KIT_OVERRIDE`), in the scratch directory, never the file in `Sources/`. An edit must apply exactly once
(a changed line fails the mutation loudly, to be re-aimed) and the build must succeed. A mutant is caught only when the
harness exits exactly 1 and its log holds a failure of every check named for it; a crash by signal is never a catch.

| mutation | the check it must fail |
|---|---|
| transpose | `planted-aniso-m shape` |
| frame index ignored | `planted-frames frame 2 pixels` |
| PixelSize width and height swapped | `planted-aniso-m x scale`, `y scale` |
| Offset x and y swapped | `planted-aniso-m x origin`, `y origin` |
| offset sign | `planted-aniso-m x origin sign`, `y origin sign` |
| origin = −Offset (not divided by the size) | `planted-aniso-m x origin`, `y origin` |
| y unit from `PixelUnitX` | `planted-aniso-mixed y units` |
| `int16` read unsigned | `planted-int16-negative pixels` |
| first candidate over HAADF | `planted-haadf-last object` |
| Analytical entries not excluded | `planted-no-haadf object` |
| non-Velox as empty | `planted-berkeley refusal` |
| the whole stack read | `memory stack growth` |
| frame label dropped | `planted-frames frame label` |
| voltage in kV, not V | `planted-aniso-m voltage` |
| `.emd` metadata: high tension left in volts | `planted-aniso-m metadata highTension` |
| `.emd` metadata: dwell of a camera image | `planted-int16-negative metadata dwell` |
| `.emd` metadata: the date's zone conversion dropped | `planted-aniso-m metadata zone` |

The whole-stack mutant clamps the frame it takes from the stack: an index out of range would trap, which is a crash, not a
catch.

## The reference's Python

RosettaSciIO's Velox image path imports `pint` (unit conversion; `rsciio.utils._units`) and `python-dateutil`, and tests that
`sparse` is importable before it reads an EDS spectrum image whatever `select_type` says. With `select_type="images"` it never
imports it, so `reference.py` puts a stub `sparse` module in `sys.modules` that raises on any use: a read that did reach
`sparse` would fail loudly, and numba and llvmlite stay out of the lock. `dask` and `pyyaml` are not reached.

## Unit tests

`macTEMTests/VeloxImageReaderTests.swift` opens seven small planted files (`macTEMTests/Fixtures/velox-*.emd`, each under 64 KiB,
written by `make_fixture.py --unit`, byte-for-byte reproducible, with `velox.truth.json` carrying their sha256) through
`ImageOpening.openNow` inside the XCTest host. One test proves the host finds the libhdf5 the app embeds
(`Contents/Frameworks`) with no override: it asserts the one libhdf5 the process has loaded is that file. It cannot run
outside the app host; hide the dylib to break it.
