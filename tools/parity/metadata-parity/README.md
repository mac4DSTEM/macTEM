# metadata-parity

macTEM's acquisition-metadata readers (`AcquisitionMetadata.tiff(data:)`, `.mrc(data:)`, `.dm(numbers:strings:)` — slice
S-a — and `.read(path:)`, the entry point that describes a FILE — slice S-b; TEMCore, through Package.swift's `MetadataParity` target, built by `tools/lib/harness.sh`) against ncempy 1.16,
RosettaSciIO `049e7d70`, tifffile 2026.9.20 and mrcfile 1.5.4 (pinned: `tools/lib/references-lock.txt`,
`tools/lib/fetch-rsciio.sh`). A `scientific` gate (`tools/run-tests.sh scientific`): P1, P2, and
slice S-b (the DM wiring and tag 65027) for `read(path:)`. `make_fixture.py` writes the S-b DM4 plants with
`dm4_writer.py` beside it (mac4DSTEM's writer, kept as copied). Run
`tools/parity/metadata-parity/run.sh`, redirect it to a log, and read the exit code on its own line.

Pass lines: `metadata-parity: all passed — …; owner Ceta TIFFs gated: N of 6 (machine-local, gitignored)` and
`metadata-parity: negative controls: 33 of 33 caught by their checks`.

## What is compared

Every case, every one of the nine fields (high tension kV, magnification, camera length mm, detector, dwell µs, exposure s,
acquired, instrument, mode):

- **nil exactly where the reference says "not recorded"** (P2): never 0, never `""`;
- a value: text equal exactly, a number to 1e-9 relative;
- the `note` equal exactly (nil when the reference has none) and the second stored copy `otherCopy` likewise.

Notes, exact texts, joined with `; ` in this order: `local time, zone not stored` (a Velox, DM or FEI SEM date),
`clock of the writer, zone not stored` (an MRC date), `mm (assumed)` (a DM camera length), `month-first order assumed` (a
DM date whose first two fields are both ≤ 12; a FEI SEM date is month-first by format and never carries it),
`unvalidated: the mode is not checked` (an MRC camera length), `unvalidated: no published reader reads it` (a value whose
path no pinned reference maps: most Velox values, the FEI SEM detector, an MRC mode and exposure).

A case marked `nilOrThrows` (a file that is not what it says) passes when the function throws or returns every field nil;
a file the harness itself cannot read is a failure, never a refusal.

**The owner's six Ceta TIFFs gate where they are provisioned** (`References/example_files/`, gitignored): they are the only
real Velox data. Where they are absent each prints a `skip` line and the summary says `0 of 6`. That part of P1 is
machine-local — a public reader cannot reproduce it — and must not be quoted as reproducible.

## Slice S-b: `read(path:)` end to end

`manifest.json` gains `reads`; every check of a read case is named `read:<case> …`. `read(path:)` never throws: a container
it cannot read for its metadata reads empty.

- **C1, the object the open shows** (DM). `ImageOpening.primaryImageObject(in: DM4Experiment.list(path:)).index` is
  `shown`, the ImageList number the reference expects, and so is the one in `ImageOpening.openNow(path:).source`; where the
  open shows none (the stack builder's 3-D object, a `[170, 1]` line scan) the first is nil and the open refuses
  (`C1 primary object`, `C1 openNow`, `C1 openNow refuses`). For the real files `shown` is reference.py's `n`; for the
  plants it is hand-written, and reference.py restates the registered object rule on ncempy's tags
  (`primary_object`) and requires it to agree. This is the only comparison of the object `read(path:)` describes with the one
  the open shows that the harness can make from outside: `read(path:)` is a black box, so the object it describes is
  observed through its reading (C3), the decoy plants being the files where a wrong object shows.
- **C2, the maps**. The walker's `imageTagNumbers` / `imageTagStrings` of the object equal the manifest's, EXACTLY, keys and
  values both ways (numbers bit for bit): for the 12 real objects (11 two-dimensional, the stack builder's 3-D one)
  ncempy 1.16's `allTags` maps after the two NAMED steps of `reference.py` `c2_maps`, for a plant the maps it declared (which
  reference.py first requires ncempy's parse of the same file to confirm). The tag stream of a DM-saved TIFF (`tagTree`) is
  checked the same way (`C2 tag stream`). Exact on purpose: a divergence on a new file must go red and be named, not absorbed.
  - Step (i), the labels: ncempy decodes a label byte by byte as Latin-1; the walker decodes it as UTF-8 when valid and as
    Latin-1 otherwise (mac4DSTEM `5b696589`). Each ncempy key is re-decoded the same way. REGISTERED as "UTF-8 from the
    Latin-1 bytes" (the walker of `be10cce0` made U+FFFD of the lone `0xB5` of "(µA)", on 10 of the 12 objects and the
    tag-65027 block, and the registration predicted that mismatch); the re-sync brought the upstream fix, so the step
    **changes no key of any real file** (the run prints 0) and is gated on a planted UTF-8 label
    (`planted-dm4-utf8-label`) and by two walker mutations.
  - Step (ii), the array artifacts: ncempy adds `X.arraySize`, `X.arrayOffset`, `X.arrayType` numbers for every array of
    1000 bytes or more. The ImageTags of the 12 real objects and of the block hold none (the run prints 0 dropped).
  - Divergences that exist on planted bytes only and are NOT gated: ncempy keeps U+0000 in a uint16 string (the walker drops
    every zero unit; planted-file step (iii), in reference.py's planted loop, strips it from ncempy's side and requires NULs
    only where the plant wrote them), reads a short array of another type as text, reads type 11 as uint64 and desyncs on a
    DM4 type-18 string; the walker reads type 11 as Int64.
- **C3, the reading**. `read(path:)` equals the expectation, every field, note and second copy: for the real DM files
  reference.py's ncempy maps + RosettaSciIO (the S-a expectation), for the plants hand-written truth, for tag 65027 ncempy's
  reading of the same bytes written to a temp file. The stack builder's 3-D file shows no image: `read(path:)` is required to
  read empty (`nothing described`) and the object's own tags go through the walker's `list` and `dm(numbers:strings:)`.
- **C4, planted DM4 files** (`dm4_writer.py`): `planted-dm4-two-objects` (a thumbnail, a spectrum-image decoy at 300 kV in the
  STEM mode ahead of the 200 kV image the open shows), `planted-dm4-date-nul` / `-date-no-nul` (a uint16 date with and
  without its trailing NUL unit), `planted-dm4-creation-only` (tags only under `source.Tags at creation.`),
  `planted-dm4-no-tags`, `planted-dm4-no-primary-object` (a thumbnail and a `[170, 1]` line scan stating 200 kV: nothing is
  described), `planted-dm4-utf8-label` (a UTF-8 µ in a label) and `planted-dm4-eleven-objects` (the shown object first,
  `ImageList.10` and `.11` carrying keys of their own, which makes `ImageList.1` against `.10.` catchable here). The writer
  writes DM4 only, which amends the registration's "planted DM3": the 9 real `.dm3` files gate the DM3 branch.
- **C5, tag 65027**. `rsciio-dm-tiff-65027` (RosettaSciIO's `test_loading_image_saved_with_DM.tif`) and
  `rsciio-dm-tiff-65027-stack` (an empty tree, 0 tags in 512 bytes), replacing the `rsciio-dm-tiff-known-gap` tripwire. The
  expectation is ncempy's reading of the block, `PREDICTED_65027` in reference.py holds the hand-written prediction registered
  before the code (200 kV, 51×, no camera length, "BM-UltraScan", 0.5 s, 2015-07-20 18:48:25, "FEI Tecnai", "TEM · IMAGING")
  and the run requires the reference to agree (86 numbers and 46 strings in the block). Plants: `planted-tiff-65027-dm` (the
  STEM maps `planted-dm-actual-ne-indicated` also uses), `planted-tiff-velox-and-dm` and `planted-tiff-fei-and-dm` (a Velox /
  FEI SEM tag beside a 120 kV block: the order is FEI SEM, Velox, DM), `planted-tiff-velox-tag-not-text-and-dm` (tag 34683 that
  is a SHORT beside a block: the tag's existence is the Velox convention), `-type-undefined` (the same stream as TIFF type 7:
  only a BYTE block is read), `-garbage` and `-truncated` (the walker refuses: empty, no throw), and two TIFFs written byte by
  byte (tifffile writes only consistent files) whose 65027 entry counts more bytes than the file holds: `-overruns-by-one` (a
  complete 120 kV stream, count one byte too large: a reader that clamped the count would show 120 kV) and `-overruns-far` (the
  review's reproducer: 100 bytes, count 5000 at offset 26). Both read empty, and both are **isolated**: the harness runs
  each in a child process of itself (`harness --child <out-dir> <case>`), so a reader that TRAPS on one (a slice of the file out
  of range exits by signal) fails the check `read:<case> survives` and the run exits 1, instead of dying without a verdict.
  `reference.py` reads the entry back from the bytes (`entry_extent`; tifffile drops such an entry with a warning, so it cannot
  say the plant overruns) and requires the declared geometry. Policy, restated in `tiff_block`: none of 34680, 34682, 34683,
  type 1, and the block wholly inside the file.
- **C6, the extension dispatch**. `read(path:)` on every TIFF and MRC case of slice S-a (75 on a machine with the owner's
  files), which must equal the S-a expectation (a case marked `nilOrThrows` must read empty), and four renamed copies
  (`planted-ext-tiff`, `-upper-TIF`, `-upper-MRC`, `-upper-DM4`).

## The expectations: where each comes from

`reference.py` builds them from the pinned references and states each place the registered rules differ as a named
override or policy (module docstring). It never re-implements the Swift reader's code, but the policies (i)–(m) below are
macTEM's own rules restated in Python, because no pinned reference reads those paths: they are checked against truth
written by hand in the plants, not against an independent reader. Before any reading counts the reference has to
reproduce every PLANTED truth that `make_fixture.py` wrote; a disagreement exits 1 there.

| Format | Reference | Read how |
|---|---|---|
| DM | ncempy 1.16 `fileDM(…).allTags` (the sha256 of `ncempy/io/dm.py` pinned) for the tag maps; RosettaSciIO `rsciio/digitalmicrograph/_api.py` `ImageObject.get_mapping()` applied to them | the `{numbers, strings}` maps the Swift function takes (keys relative to `ImageList.N.ImageTags.`): a scalar number or boolean is a number, a string a string, arrays are not carried. RosettaSciIO's own parser is run on the same object and its mapped values must equal the ones from ncempy's tags. |
| FEI SEM TIFF (tag 34682 / 34680) | RosettaSciIO `rsciio.tiff.file_reader` (tifffile's `read_fei_metadata` inside it), its `mapping_fei` applied to its `original_metadata` | `Beam.HV` V → kV, `Scan.Dwelltime` s → µs, `User.Date` + `User.Time` (dateutil), `System.SystemType`; the detector `Detectors.Name` is mapped by no reference (labelled unvalidated). tifffile's INI semantics are the reference as they stand: a repeated key takes its last line, an empty one included; a repeated section replaces the earlier one. |
| Velox TIFF (tag 34683) | tifffile 2026.9.20 for the text, `xml.etree` for the XML, `xml.parsers.expat` for the document guard (m); RosettaSciIO `rsciio/emd/_emd_velox.py:938-945` for the two conversions | `Optics/AccelerationVoltage` / 1e3, `Optics/CameraLength` × 1e3 — the two lambdas are EXTRACTED from that file by `ast` and run as written; every other field has no published reader and is labelled unvalidated |
| MRC | mrcfile 1.5.4 `indexed_extended_header` (its FEI1 / FEI2 dtype; the byte order follows the machine stamp) | record 0 and the four bitmasks; the date on the OLE epoch 1899-12-30 (override (h), executable evidence below) |
| DM tag stream in a TIFF (tag 65027, S-b) | ncempy 1.16 `allTags` of the tag's bytes written to a temp file (`block_reading`), RosettaSciIO's mapping as for DM | the maps of the bare stream (keys without prefix) through the DM rules. macTEM's own policy, restated in `tiff_block`: none of 34680, 34682, 34683, and TIFF type 1; a stream ncempy cannot parse reads nothing |

### Registered paths and rules as applied

- **High tension**: DM `Microscope Info.Voltage` (V), FEI SEM `[Beam] HV` (V), Velox `Optics/AccelerationVoltage` (V), MRC
  `HT` (V) → kV.
- **Magnification**: the indicated one, never the actual (g): DM `Indicated Magnification` (not recorded in TEM +
  DIFFRACTION, where it holds the camera length), Velox `Optics/NominalMagnification`, MRC `Magnification`; FEI SEM none.
- **Camera length** only where the mode makes it real (c): DM STEM (`Illumination Mode` starts "STEM") from `STEM Camera
  Length`, or TEM + DIFFRACTION from `Indicated Magnification`, both "mm (assumed)" (d); Velox when `ProjectorMode` is
  Diffraction or `OperatingMode` is STEM (case-insensitive, policy (j)); MRC as stored when its bit is set (m → mm), noted
  that the mode is not checked; FEI SEM none.
- **Detector**: DM `Acquisition.Device.Name`, FEI SEM `[Detectors] Name`, Velox `BinaryResult/Detector`, MRC the first written,
  non-empty of `STEM Detector name`, `Camera name`, `Detector commercial name` (the last FEI2 only).
- **Dwell** (µs): DM `DigiScan.Sample Time` (µs), FEI SEM `[Scan] Dwelltime` (s), MRC `Dwell time` (s); Velox TIFF none — the
  dwell path of a Velox STEM TIFF is unobserved (no such file exists), so it stays "not recorded" whatever
  `ScanSettings/FrameTime` holds.
- **Exposure** (s): DM `Acquisition.Parameters.Detector.exposure (s)` with `DataBar.Exposure Time (s)` as the second copy (f);
  Velox the `ExposureTime` of the `Detectors/*` element whose `DetectorName` is `BinaryResult/Detector` (policy (i)); MRC the
  FEI `Integration time` (unvalidated, override (l)); FEI SEM none.
- **Acquired** (e): `YYYY-MM-DD HH:MM:SS` in the file's own clock; a date without a time, or a time without a date, is not
  recorded (DM, FEI SEM). DM `DataBar.Acquisition Date` + `Time`, FEI SEM `[User] Date` (MM/DD/YYYY) + `Time` (12-hour),
  Velox `AcquisitionStartDatetime` with `AcquisitionDatetime` as the second copy when it differs at the second and is not
  before 1990 (policy (k)), MRC `Timestamp` (OLE days, override (h)).
- **Instrument**: DM the first of `Session Info.Microscope`, `Microscope Info.Name`, `Microscope Info.Microscope` that is neither
  empty nor the text `[]`, only where the file has a `Microscope Info` group (RosettaSciIO's `_get_microscope_name`, `_api.py:820-837`,
  gate `:963`), FEI SEM `[System] SystemType`, Velox `Instrument/InstrumentModel`, MRC `Microscope type`. **Mode**: DM
  `Illumination Mode` and `Imaging Mode` joined by " · ", Velox `Optics/OperatingMode` as stored, MRC `Instrument mode` — the
  stored int32 as decimal text, "unvalidated" (override (l); compared to mrcfile's field at offset 244, no enum is decoded), FEI
  SEM none.
- (a) absent, empty or unparseable is nil; (b) a strictly positive quantity stored as 0, negative or non-finite is nil — in
  every format after the unit conversion (the DM dwell, which converts nothing in the Swift, is the one named exception); MRC: a field whose bitmask bit is unset is nil whatever its bytes hold.

### MRC bitmask positions

Bit *i* of Bitmask *k* says whether the *i*-th field after that bitmask was written; the 48-byte `Unused range` counts 6 bits.
`reference.py` derives the positions from mrcfile's dtype and requires them to equal the ones the plant typed, and requires
bitmasks 1–3 to span exactly 32 bits each and bitmask 4 17 fields (`check_layout`). The record's byte order follows the machine
stamp (mrcfile `get_ext_header_dtype`); the bitmasks are always little-endian.

What the real records add (`bit_evidence`; `reference.py` prints it and writes it to `expected.txt`). The check is one-sided: it
can only see a field that is non-blank under an unset bit, so it pins the derivation rule and only some of the reader's bits.

- The rule: over all 257 real records (1 in `HAADFscan.mrc`, 256 in `4DSTEMscan.mrc`) the derived assignment has no field
  non-blank under an unset bit, and each wrong one — an `Unused range` of 0–5 or 7–9 bits, or every bit shifted by 1–3 either
  way — leaves at least one (`reference.py` exits 1 if one does not).
- Reader bits a real record pins against a shift of that bit alone: `HT` (all six shifts), `Timestamp` and `Camera length`
  (+1 to +3; both sit at bit 0), `Dwell time` (−3 to +1), `STEM Detector name` (−3 to −1 and +3), `Detector commercial name`
  (all but −1), `Instrument mode` (−1 only).
- Reader bits no real record pins, which rest on the rule and the 32-bits-per-mask arithmetic alone: `Magnification` (its bit is
  clear on both files), `Microscope type`, `Camera name`, `Integration time` (never non-blank, or in one record only). The
  planted files set each of these bits with its neighbours clear (`planted-fei2-seconds-truncated` and
  `planted-fei2-unset-bits` separate the `Timestamp` / `Microscope type` pair), so a reader with a moved bit reads nothing and
  fails; measured by mutation for `Integration time` (below), by construction for the others.

The OLE epoch (override (h)) is checked on the records that carry both a `Timestamp` and the int64 `Acquisition time stamp`
(unix microseconds, UTC; `check_epoch_evidence`): on all 256 records of `4DSTEMscan.mrc` the OLE date minus the UTC stamp is
+3600 s, inside 14 h and a whole number of quarter hours, and the epochs 1900-01-01 and 1904-01-01 both fail that test.
`HAADFscan.mrc` has no int64 stamp (its Bitmask 4 is 0): it reads 2022-12-05 12:13:07, the second the 4D file's UTC stamp
gives for the same day, and its zone is unverified. The two files disagree by an hour, which is why the MRC note says "clock
of the writer" and not "local time".

## Overrides of RosettaSciIO and macTEM policies (each named in `reference.py`)

- (b) a 0 or negative `Voltage`, `Indicated Magnification`, `Sample Time`, … RosettaSciIO would map; the registered value is nil.
- (c) RosettaSciIO maps `STEM Camera Length` in SEM and any other non-"TEM" mode (junk 0 / 1 in `test-MonarcCL_mono-image`);
  and not in TEM imaging (the stale 255 of `test_dm_image_um_unit`: both agree here). The registered rule shows it only in
  STEM. RosettaSciIO's Velox EMD mapping (`_emd_velox.py:942-945`) has no mode gate either; the Swift gate is a DEVIATION
  named in FormatoKit's `FormatoTIFF/AcquisitionMetadataTIFF.swift` (`.app`). An MRC camera length has no gate: it is shown as stored and says so.
- **Instrument** (DM) is not an override: the expectation is RosettaSciIO's own `get_mapping` value (`_get_microscope_name`, `:820-837`;
  the mapping `:1004-1011`, inside `if "Microscope Info" in image_tags_dict.keys()` `:963`), and on every real object the harness
  fails if the registered instrument differs from it. The one exception is (a): RosettaSciIO returns a whitespace-only text as
  written (a truthy string), the registered rule treats it as empty and reads the next location, so the same mapping is applied
  to the tags with every string trimmed (`planted-dm-instrument-session-blank`; no real file has such a name, none is printed).
- (a) FEI SEM `Dwelltime` is mapped by RosettaSciIO without a function, so a text like `notafloat` would pass through; it goes
  through `float()` here.
- (e) the date and the time are RosettaSciIO's two isoformat strings joined; the order note comes from the date text. RosettaSciIO
  maps the date alone when no time reads; the registered rule shows nothing (`planted-dm-date-no-time`,
  `planted-fei-sem-date-no-time`, `planted-fei-sem-time-no-date`).
- (h) the MRC `Timestamp` is days since **1899-12-30** (OLE automation date): the registration's choice, which overrides mrcfile's
  comment "days after 1/1/1900" (`dtypes.py:108`; mrcfile never converts the field). Evidence above.
- (i) a Velox exposure comes from the `Detectors/*` element that names the image's detector, never another's — no pinned reader
  reads the TIFF path (`planted-velox-exposure-decoy`, `planted-velox-exposure-named`).
- (j) `ProjectorMode` / `OperatingMode` open the camera-length gate without regard to case; the registration states no case, no
  pinned reader reads `ProjectorMode` (`planted-velox-mode-case-*`).
- (k) a second Velox start stamp from before 1990 is an unset field, not a copy: the Velox XML schema postdates 1990, and the
  sentinel form is inferred from same-schema EMD files (no Velox STEM TIFF exists here); a stamp from 1990 on is kept
  (`planted-velox-second-stamp-*`).
- (l) an MRC mode is the stored `Instrument mode` int32 as text and an MRC exposure the `Integration time`, both "unvalidated": mrcfile
  lays the fields out, no published reader reads them.
- (m) a Velox document is read only if it passes the guard: a tag of at most 4 MiB, element depth at most 64, at most 1 MiB of
  character data, no entity declaration, well-formed; a string value over 256 characters is not recorded; a refused document
  reads empty (`planted-velox-hostile-*`, `planted-velox-value-*`). The real Ceta tags are about 14 KB and 6 deep.

## DEVIATIONS

- **dask**: `rsciio/digitalmicrograph/_api.py` imports `memmap_distributed` from `rsciio/utils/file.py`, whose only job is
  dask, which is not in the lock; `get_mapping` never calls it. The module `rsciio.utils.file` is replaced in `sys.modules` by
  an empty stand-in carrying `memmap_distributed = None` before `_api` is imported. `get_mapping` and the helpers it calls are
  RosettaSciIO's own, unmodified (the sha256 of `_api.py`, `tiff/_api.py` and `emd/_emd_velox.py` is pinned in
  `reference.py`). The AST-extraction route the brief names was not needed.
- **The join** RosettaSciIO leaves to HyperSpy (not in the lock): `apply_mapping` walks each mapping path through the tag
  tree with HyperSpy's key normalisation (spaces → `_`, other non-word characters dropped, applied to both sides, a collision
  fails) and calls the mapping's function. A function that raises yields no value.

## Cases

**Planted** (`make_fixture.py` prints the count; the truth is written by hand from the rules, the MRC files by its own
`struct.pack`, the TIFFs by tifffile):

- Velox TIFF: diffraction (camera length real, FrameTime present, dwell nil), imaging (camera length stored but not in effect),
  STEM (camera length real, FrameTime), two differing start datetimes (`otherCopy`), an empty document, garbage (zero HT,
  unparseable magnification, empty camera length, negative exposure, bad date, blank model), padded values; the exposure of the
  named detector with a decoy `ImagingDetector` (and the named detector listed second); the camera-length gate with the mode in
  mixed case; a second start stamp at the epoch on a UTC+1 clock, in year 1, on the last second of 1989 (nil) and on the first
  of 1990 (kept); a detector and instrument name of 300 characters (not recorded) and of 200 (read); hostile documents — 2000
  nested elements, seven nested entity declarations (10 MB when expanded), a small internal / external / unparsed entity
  declaration, 2 MiB of text, a 5 MiB comment (no text, so only the size bound refuses it) — each beside real fields and each
  reading empty.
- TIFFs with no acquisition tags: plain, ImageJ, Digital Micrograph calibration tags (a DM-saved TIFF's whole ImageTags tree is
  in tag 65027: the `reads` cases of slice S-b); tag 34683 that is not XML (`nilOrThrows`).
- FEI SEM INI: full (a different `[EBeam] HV` beside `[Beam] HV`, 25 µs, US date, 12-hour time), `HV=` empty (tag 34680),
  `HV=notafloat`, `HV=0` with `Dwelltime=0`, 12:05:09 AM, 12:30:00 PM, a garbage file; a repeated `HV` whose later copy is empty
  (not recorded: tifffile's last line wins) and one whose later copy is 6000; a repeated `[Beam]` section; the date `05/06/2022`
  (May 6, no order note) and `13/06/2022`; a date without a time and a time without a date.
- MRC: FEI2 imaging (all bits set, Instrument mode 1, Integration time 0.5), FEI2 STEM (magnification 0.0 and Integration time
  0.0 with their bits set, an empty microscope type, the STEM detector name over the camera name, dwell, OLE date), FEI2 with ten
  non-zero fields whose bit is UNSET, FEI2 with bits set on zero and negative values (an Instrument mode of 0 is a value; empty
  names fall through to the commercial name, a padded name), FEI2 whose HT, camera length and dwell are positive and finite but
  convert to 0 or inf, a big-endian-stamp FEI2 (mrcfile's mixed-endian layout), FEI1, the seconds of 12:00:07.75 and 23:59:59.99
  (truncated, not rounded), no extended header, `exttyp` CCP4, a truncated record, a non-MRC, a record whose own size says 768, an
  extended header of 500 bytes (the last three `nilOrThrows`), and an FEI1 whose Bitmask 4 says a field past the record.
- DM tag maps: TEM imaging with `STEM Camera Length` 255, SEM with 1.0, TEM diffraction (`7/9/2014`, camera length from
  `Indicated Magnification`), STEM with Actual ≠ Indicated, two exposure copies that differ and that agree to 2e-7, zeros and
  empty strings, a garbage date with a padded name, a date without a time, a day-first date, a stack-builder object whose tags are
  only under `source.Tags at creation.`, eight for the instrument chain (`Session Info.Microscope` first; empty, `[]` and
  whitespace-only values passed over; `Microscope Info.Microscope` third; nothing usable; a session name without a `Microscope
  Info` group; a stack-builder object with both names under the copy), an object with no tags.

**RosettaSciIO's own files** (sha256 against `registry.txt`): 12 DM objects (`test_STEM_image`, `test_diffraction_pattern`,
`…_tags_removed`, `multi_signal`, `test-MonarcCL_mono-image`, `test_dm_image_um_unit`, the four `Fei HAADF-*_location`, the
tag-less `test-1.dm4`, which stands for the other 2 × 2 files, and the 3-D object of `test_stackbuilder_imagestack.dm3`, the
one real file with `source.Tags at creation.`: the stack-builder fallback is gated on it as well as on its two planted twins),
the 5 Helios TIFFs of `tiff_FEI_Helios.zip` (extracted into the run's scratch directory), `HAADFscan.mrc` and
`4DSTEMscan.mrc` (record 0). The four `Fei HAADF` files carry day-first dates (`27.08.2016`, `27/08/2016`) and one a
`08:55:59 p.m.` clock: the reference (dateutil) reads them, so the Swift date reading has to (a first field above 12 is a day:
no order note). Not in the gate (the harness takes exactly one non-thumbnail object of the stated dimension per file): the
1D spectra, the 3-D spectrum-image cubes, the two 2D spectrum images `test-MonarcCL_spectrum-SI.dm4` /
`test-MonoCL_spectrum-SI.dm4` and `test_fft_packed_complex8.dm4`.

**The owner's Ceta TIFFs** (`References/example_files/`, gitignored): the only real Velox data; each gates where provisioned,
and is skipped with a printed line where it is not. Their XML has what the planted XML lacks (namespace declarations, attributes,
nine detectors, a CustomPropertyGroup).

**The DM-saved TIFFs** (S-b, C5): `tiff/test_loading_image_saved_with_DM.tif` and `…_DM_stack.tif`, tag 65027 only (neither has
34680, 34682 or 34683; `reference.py` requires it). The S-a case `rsciio-dm-tiff-known-gap`, which expected nothing recorded as a
tripwire while 65027 was unread, is gone; its two files are the `reads` cases `rsciio-dm-tiff-65027` and
`rsciio-dm-tiff-65027-stack`.

## Negative controls

Twenty-one. Fifteen are `MACTEM_PARITY_MUTATE` names in `main.swift`; six edit a COPY of one of the app's source files
(`AcquisitionMetadata+Read.swift`, `ImageOpening.swift`) and build the harness again (below). FormatoKit's files (the tag walker,
the TIFF reader) are not mutated here: FormatoKit's own tests hold them. Each counts as caught only when the harness exits 1 and EVERY check it targets (`run.sh` lists
them, `|`-separated) is among the failures. A crash of the harness is never a catch (a signal is not an exit 1, and its log has no
tally); a mutant that makes the reader TRAP is caught only through an isolated case (above), where the trap is the harness's own
failed check. An input rewrite reproduces the bug through the real code (a twin file written by
`make_fixture.py` or `reference.py`, or replacement tag maps); an output rewrite is applied to the returned reading; a WIRING
mutation mirrors a defect of `read(path:)` that the harness cannot inject from outside (the same calls `read(path:)` makes, with
the defect), so it shows the checks are sensitive to it, and the source mutations then show the real code is.

| Mutation | How | Check that must fail |
|---|---|---|
| `kv-unscaled` | input: Velox twin with `AccelerationVoltage` × 1e3, so the real / 1e3 leaves volts as kV | `planted-velox-diffraction highTensionKV` |
| `mm-unscaled` | input: Velox twin with `CameraLength` / 1e3, so the real × 1e3 leaves metres as mm | `planted-velox-diffraction cameraLengthMM` |
| `nil-as-zero` | output: every numeric field left nil becomes a reading of 0 | `planted-fei-sem-hv-empty highTensionKV` |
| `stem-cl-in-tem` | output: a nil DM camera length with a positive `STEM Camera Length` tag gets that tag (an input rewrite would also move the mode) | `dm-test_dm_image_um_unit-dm3-IL2 cameraLengthMM` |
| `dm-date-swapped` | input: the date text `9/7/2014` for `7/9/2014` (the real month-first parse is the day-first reading of the original) | `planted-dm-tem-diffraction acquired` |
| `mrc-bitmask-ignored` | input: twin with all four bitmasks set (every field read) | `planted-fei2-unset-bits highTensionKV` |
| `mrc-big-endian` | input: twin with the 8 bytes of the HT double reversed (what a big-endian read of the little-endian record returns) | `planted-fei2-stem highTensionKV` |
| `actual-for-indicated` | input: the Indicated Magnification tag holding the Actual value | `planted-dm-actual-ne-indicated magnification` |
| `frametime-as-dwell` | output: `dwellUS` = stored FrameTime × 1e6 | `planted-velox-stem dwellUS` |
| `dm-wrong-object` | wiring: the first object that is not the thumbnail, not the object rule's (registered M1) | `read:planted-dm4-two-objects C1 primary object` and `… highTensionKV` |
| `dm-prefix-kept` | wiring: every map key keeps `ImageList.N.ImageTags.` (registered M2) | `read:dm-test_STEM_image-dm3-IL2 highTensionKV` and `… C2 numbers` |
| `dm-strings-lost` | wiring: the strings map is empty (M3) | `read:dm-test_STEM_image-dm3-IL2 mode`, `… acquired`, `… C2 strings` |
| `dm-creation-dropped` | wiring: no key under `source.Tags at creation.` (M4) | `read:dm-test_stackbuilder_imagestack-dm3-IL2 highTensionKV` and `… C2 numbers` |
| `tiff-65027-skipped` | input: `rsciio-dm-tiff-65027` with the tag renamed 65028 (M5) | `read:rsciio-dm-tiff-65027 highTensionKV` |
| `tiff-dm-before-velox` | input: `planted-tiff-velox-and-dm` with its Velox tag removed, so the real reader meets only the 120 kV block (M6) | `read:planted-tiff-velox-and-dm highTensionKV` |

**Source mutations of slice S-b** — built and run by `run.sh` itself, each against an edited COPY (the edit must apply exactly
once, or the gate fails loudly and the mutation is re-aimed). They reproduce the registered M1 and M3 (in
`AcquisitionMetadata+Read.swift`) and the mutations of the wiring itself. The walker's (M2, M4, M7, M8) and the TIFF reader's
(M5, M6) source mutations were dropped here with the switch to SwiftPM: that code is FormatoKit's.

| Edit | Check that must fail |
|---|---|
| `ImageOpening.swift`: `openNow` shows the first object that is not the thumbnail | `read:planted-dm4-two-objects C1 openNow` |
| `AcquisitionMetadata+Read.swift`: the first object that is not the thumbnail (registered M1, in the code) | `read:planted-dm4-two-objects highTensionKV` and `read:planted-dm4-no-primary-object highTensionKV` |
| `AcquisitionMetadata+Read.swift`: `strings: [:]` handed to the DM rules | `read:dm-test_STEM_image-dm3-IL2 mode` and `… acquired` |
| `AcquisitionMetadata+Read.swift`: `.mrc` not dispatched | `read:rsciio-4dstemscan highTensionKV` and `read:planted-fei2-stem highTensionKV` (C6) |
| `AcquisitionMetadata+Read.swift`: the extension not lower-cased | `read:planted-ext-upper-TIF`, `-upper-MRC`, `-upper-DM4` `highTensionKV` (C6) |
| `AcquisitionMetadata+Read.swift`: `.tiff` not dispatched | `read:planted-ext-tiff highTensionKV` (C6) |

**Source mutations of slice S-a** — the controls above rewrite inputs and outputs; these edit the reader. Each was measured by hand on
2026-10-12 against copies of the `metadata` sources (copy `Sources/TEMCore/Data`, make the edit, compile with `main.swift`, run
the harness on the unchanged `reference.py` output). Every one exits 1 (or traps) and names the case that catches it:

| Edit to the reader | Case that fails |
|---|---|
| MRC: the mode's bit 25 → 24; its offset 244 → 245; its value + 1 | `planted-fei2-imaging mode` (and `-stem`, `-bigendian`, `-fei1`) |
| MRC: the Integration time's bit 16 → 17 | `planted-fei2-imaging exposureS` |
| MRC: the seconds rounded, not truncated | `planted-fei2-seconds-truncated acquired`, `planted-fei2-midnight acquired` (24:00:00) |
| MRC: the record's own size (`Metadata size`) not tested | `planted-fei2-wrong-record-size` (a reading from a record that says 768) |
| MRC: the extended header's length not tested against the record | `planted-fei2-nsymbt-short` |
| MRC: the field-extent test in `isRecorded` deleted | a trap (exit 133) in `planted-fei1-commercial-bit`, and in that case alone |
| MRC: rule (b) tested before the unit conversion | `planted-fei2-converted-to-zero highTensionKV` |
| MRC: the date note "local time"; the camera length or the mode without its note | `acquired note`; `cameraLengthMM note`; `mode note` on every FEI plant |
| Velox: the exposure of any detector, not the named one | `planted-velox-exposure-decoy exposureS`, `planted-velox-exposure-named exposureS` |
| Velox: `Diffraction` / `STEM` matched in exact case | `planted-velox-mode-case-projector cameraLengthMM`, `planted-velox-mode-case-operating cameraLengthMM` |
| Velox: no floor on the second stamp; the floor at 1989; at 1991 | `planted-velox-second-stamp-epoch-local` and `-year-1` (`otherCopy`); `-1989`; `-1990-kept` |
| Velox guard: the size bound; the depth bound; the text bound; the internal-entity test; the unparsed-entity test; the 256-character bound | `planted-velox-hostile-huge`; `-deep`; `-text`; `-entity-internal`; `-entity-unparsed`; `planted-velox-value-300` |
| FEI SEM: an empty value skipped; the first copy of a repeated key wins; a repeated section merged | `planted-fei-sem-repeated-key-empty highTensionKV`; `-repeated-key-later` and `-empty`; `planted-fei-sem-repeated-section` |
| FEI SEM: a date read without its time; an order note on every date | `planted-fei-sem-date-no-time acquired`; `acquired note` on the FEI plants |

`planted-velox-hostile-laughs` is also refused by the text bound once its entities expand, so it cannot tell the entity test from
the text bound; the small `-entity-internal` and `-entity-unparsed` plants can.

## Not covered

- A Velox STEM TIFF: none exists here, so its dwell path is unobserved (stays "not recorded", unvalidated) and the unset form of
  the second start stamp is inferred from EMD files, not seen in a TIFF.
- The owner's `.emd` files hold the same numbers as their TIFFs (a second copy, not an independent measurement).
- The MRC `Instrument mode` enum and the `Projection mode` (no pinned reference decodes them): the mode is the stored number, and an MRC
  camera length is not gated on it.
- The zone of an MRC date: `HAADFscan.mrc` carries no UTC stamp.
- The MRC reader bits that no real record pins (above): `Magnification`, `Microscope type`, `Camera name`, `Integration time`,
  and `Instrument mode` and `STEM Detector name` partly. The planted files pin them.
- A DM-saved TIFF other than the two RosettaSciIO files: the 65027 plants are written by this harness's DM4 writer.
- A real file whose labels hold valid non-ASCII UTF-8, or an array of 1000 bytes or more among the ImageTags: steps (i) and (ii)
  of C2 are gated on a plant and, for (ii), on no file at all (the run prints 0 dropped on every real object); a Velox STEM TIFF
  with a DM block is not a case.
- The object rule against a real file with a spectrum image or mixed units ahead of the image: the plants carry it
  (`planted-dm4-two-objects`); of the 12 real objects the only one the rule skips is the 3-D stack.
- A planted Velox XML with the real file's namespace declarations and attributes: the Ceta files carry those, and gate where
  provisioned.
