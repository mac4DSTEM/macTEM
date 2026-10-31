# sidecar-parity

macTEM's session sidecar (archive: roadmap-registrations-2026-10-15.md V1-2 slice A, ADR 020): `SessionSidecarFile` (create,
replace and read the four root attributes through FormatoHDF5's `HDF5RootAttributes`; the refusals; the name rule) and `SessionLineage` (the lineage, the source identity
and the restore verdict), TEMCore, through Package.swift's `SidecarParity` target (FormatoKit's FormatoHDF5 as Package.resolved pins it; built by
`tools/lib/harness.sh`) against **h5py 3.16.0**
(pinned: `tools/lib/references-lock.txt`, `tools/lib/python.sh`). A `scientific` gate (`tools/run-tests.sh scientific`); the
pre-registration is archive: roadmap-registrations-2026-10-15.md V1-2, the block "Completed at pickup (2026-10-13 night)": P1 a written record re-reads equal,
P2 a newer minimum reader is refused by name before anything is read further, P3 a file that cannot be opened is an error and
never "no file", P4 the restore verdict. Run `tools/parity/sidecar-parity/run.sh`, redirect it to a log, and read the exit code on
its own line.

Pass lines: `sidecar-parity: all passed — N cases, M checks against h5py 3.16.0`, then
`sidecar-parity: negative controls: 105 of 105 caught by their checks`. About an hour (2026-10-14, this Mac, with the other lanes running): every control compiles the sources
again and runs the whole gate.

Updated 2026-10-14 for the Gate B review of slice A (the refuter's plants and the fixes that review led to): the removal cascade
and the refused add, a newer schema, the minimum reader judged first, the name limit in UTF-16 units, a link to nothing, dates
to the nearest millisecond, the writer's own limits, and the library check, each with a control that breaks it.

**Memory cap** (suite rule, 2026-10-15): run under a 24 GB memory cap, one at a time, nothing else heavy running. Measured peak 18.3 GB resident over 8 processes (the negative controls' parallel mutant builds and the h5py read-backs; 2026-10-15, killed at 16 GB); the main run fits 8 GB. The negative controls move to the nightly set.

## Two directions, two independent libraries

h5py ships its own HDF5, so neither side reads what the other wrote with its own code.

- **Swift writes, h5py reads** (`main.swift --write`, then `reference.py readback`). The harness builds four planted sessions
  with the sidecar code, writes each with `SessionSidecarFile.write` to the name `sidecarURL(forSource:)` gives, and records
  the exact strings it handed the writer. h5py then reads every root attribute: it must be a **scalar fixed-length, null-padded
  UTF-8 string as long as the text** (ADR 021: `attrs.get_id(name).shape == ()`, not variable-length, `H5Tget_strpad` NULLPAD,
  `H5Tget_cset` UTF-8, `get_size()` the text's UTF-8 bytes, one for an empty text), **byte-equal** to what Swift wrote, and the root must hold those four attributes and nothing else. Python's `json` parses the two texts: the source
  identity equals the plan (the fingerprint is `hashlib.sha256` over the planted pixels, the name is NFC); the lineage's
  `version`, `next_id`, node ids and kinds, parameters, results, inputs, and `removed` equal the plan; **every coordinate and
  measurement, as `float(text)`, is bit-equal (`struct.pack('>d')`) to the planted double**, which the plan states as its IEEE-754
  bit pattern, never as decimal text; every `recorded` is a JSON **integer** equal to the planted millisecond count (and no
  number anywhere in the lineage has a decimal point or an exponent). Both texts must also be Python's canonical form
  (`sort_keys`, `separators=(",", ":")`, `ensure_ascii=False`), which checks Swift's key order, escaping of control characters and
  quotes, and the absence of escaped "/" and non-ASCII. The directory beside the sidecars must hold nothing else (no stray
  scratch file from the atomic write).
- **While Swift builds those lineages** (`swift rules <session>`): an `add` whose input names a removed node, or a node that is
  not there, is refused with `danglingInput` (the step, and the id it would have minted), changes nothing and spends no id (the
  next add is the id the plan says); a `replace` of a removed node is refused and changes nothing.
- **The writer is offered strings directly** (`raw_writes`, `swift writer <id>`, `h5py raw <id> …`): a NUL in either string,
  a string of 4 MiB + 1 (each refused by name, and no file or scratch file is left), a string of exactly 4 MiB (written, and
  h5py reads all of it back), and a **replace over a sidecar h5py wrote** (which h5py then reads: the four attributes and
  nothing else, the 40 extra attributes of the old file gone, every byte the new text).
- **h5py writes, Swift reads or refuses** (`main.swift`, the planted sidecars). Each file is read by `SessionSidecarFile.read`,
  and, where the file layer hands the strings back, decoded by `SessionLineage.decode` and `SessionSourceIdentity.decode`. A
  file Swift refuses to read is also offered to `SessionSidecarFile.write`, which must refuse it by the same name and leave
  the bytes unchanged.

## The plan (`reference.py plant`)

`reference.py` writes `manifest.json` (the plan and the truth), the pixel sets (`pixels/*.f32`) and the sidecars h5py writes
(`planted/*.mactem.h5`). A **reference check** runs first and exits 1 if h5py does not read each plant as the plan says (a
fixed-length string is fixed-length, the "invalid UTF-8" is invalid, the truncated file does not open in h5py either, the
planted doubles round-trip through `repr`), so a planted file can never pass as something it is not.

- **Swift-written sessions** (P1), nine: `marks` (`SCAN.DM4`: distance, angle and profile marks whose coordinates are 0.1, 1e-300,
  -0.0, 16777217.5, the least subnormal, the largest double and others; a mark added and deleted; an export citing the profile,
  after which the profile is removed and kept with a `removed` date; a mark replaced in place; names with "Å", "µ", "°" and
  "·"; a reciprocal-space unit "1/nm", a slash written as it is; a source identity whose byte size is over 2^32), `unicode`
  (an NFD source name, a note with a quote, a backslash, a newline, a tab, "/", NUL and other control characters, U+2028,
  U+FEFF, an astral character, and non-ASCII keys; an object name with a "/" in the identity), `many` (200 nodes, with 800 random doubles between 1e-300 and 1e300 in size), `empty` (no marks; pixels with ±0, a subnormal, ±inf and a
  NaN with a payload), `kept` (a cited mark removed and kept with its first `removed` date through a second removal; the refused
  add and the refused replace above), `cascade` (the same, then the last citer deleted: it goes, then the removed node only it
  cited, then the one only that one cited), `dates` (a `Date` with a fraction of a millisecond recorded to the **nearest**
  millisecond, before and after 1970; four exact ties, 62.5 and 312.5 ms either side of zero, which go away from zero where
  half-to-even would not; a date of +∞, -∞ and NaN, which the registered clamp records as ±9e15 and 0), `chain` (a chain of
  250 nodes each citing the one before, all but the last removed and kept, a live node added, the last of the chain
  deleted: 249 removed nodes go in one cascade, leaving the live node, `next_id` 252) and `longname` (a source named with 245
  × "µ": a sidecar name of 255 UTF-16 units and 500 bytes, written to the real file system).
- **Sidecars h5py writes** (P2, P3, the guards): valid ones (byte-for-byte read, decoded equal, re-encoded byte-equal to
  Python's canonical text; an NFD file name read as NFC; a newer writer whose minimum reader is 1, which is **read, and never
  written over** (`newerSchema`, with the bytes unchanged; also schema 3 with an attribute this build has never heard of); the
  newest object-header format; 40 more attributes beside the four in the newest format with creation order tracked; missing or
  empty strings); a newer minimum reader (refused by name), the same with an **invalid** source and a fixed-length lineage
  planted behind it (the refusal must still be the minimum-reader one: refused before the rest is read), the same with an
  identity spelled "v2" (a file that needs a newer reader is a newer file, not a garbled one; beside a minimum reader of 1 it is
  garbled), and a newer reader and writer; foreign files (no identity: bare, a lookalike with the other three attributes, an HDF5
  file of datasets); a missing minimum reader; garbled markers; a lineage of 5 MiB, of exactly 4 MiB (read) and of 4 MiB + 1
  (refused), a source of 5 MiB and one over its own 64 KiB cap; invalid UTF-8 in the source and in the lineage; a fixed-length
  string, an array, an integer and a **null dataspace** (no element) where a scalar string belongs; bytes that are not HDF5, an
  empty file, a truncated sidecar, a mode-000 file, a path with no file and a **link to nothing** (all `cannotOpen`; a write over
  the link is refused too, and leaves the link and creates nothing where it points); and the lineage's
  own guards, each refused by `SessionLineage.decode` with its named refusal: a cycle (two nodes, itself, a longer one; a diamond
  is accepted), a missing input, repeated ids, `next_id` over 1 000 000 (and 0; 1 000 000 itself is accepted, and then no id
  can be minted), an id not below `next_id`, malformed ids, 2001 nodes (2000 accepted), not JSON, the wrong shape, a missing
  `next_id`, a string where the version belongs; an **unknown version** read as a read-only lineage with no nodes (never
  rewritten, never extended, not refused); an unknown kind kept; an `external` input kept and written back as read; absent
  collections empty and unknown keys ignored; an id with a sign ("s+1"); and the identity's guards (not JSON, a zero width, a
  negative size, an upper-case fingerprint, a missing field).
- **The name rule** (`urls`): `SCAN.DM4` gives `SCAN.DM4.mactem.h5` verbatim (and `scan.dm4`, `SCAN.TIF`, `a.tif`, `x.emd`,
  names with spaces, dots, a leading dot, "Å" and "µ" in NFC and NFD), beside the source; a source that already ends in
  `.mactem.h5` (any case) is refused; a URL that is not a file and the root are refused. **The length limit is 255 UTF-16 code
  units of the sidecar's name**, not 255 bytes (ADR 020 D1, amended 2026-10-14; measured on APFS 2026-10-13): for ASCII, "µ", "日", an emoji and "Å", a name of
  exactly 255 units is accepted (the "µ" name is 500 bytes, the "日" name 745) and one of 256 is refused with `units 256` (an
  emoji is two units; Foundation hands "Å" to the file system decomposed, two units, so the units counted are the NFD name's).
  `reference.py plant` checks the same names against the scratch volume itself (accepted at 255, `ENAMETOOLONG` at 256), and
  fails the gate's reference check if the volume answers otherwise: the rule was measured on APFS.
- **The verdict** (P4): planted identities built from the planted pixels. The object or the shape differs: refuse (the
  sentence names both objects and both shapes; a shape differing with the same bytes is its own case); the pixels differ:
  adopt, flagged (also when the name differs: the louder fact wins); only the name differs: adopt, with the stored name; the
  same image, whatever the byte size or the Unicode form of the name: adopt; a normalised copy (`2a + 5` against `a`, the same
  picture once scaled onto [0, 1]) is another image.
- **The fingerprint** against `hashlib.sha256` over numpy's float32 little-endian bytes of the same planted pixels, for every
  pixel set (cross-checked in Python over the uint32 words packed by `struct`).

The independent lineage: the `simulate` function of `reference.py` re-implements the registered rules (ids from `next_id`, never
reused and not spent by a refused add; replace in place, never of a removed node; a deleted mark leaves no node; a cited node
is kept with `removed` and goes with its last citer, and every removed node only it cited goes too), so the nodes Swift must
write are derived, not copied from the Swift code. The cascade is stated twice there: as the walk over the edges from the live
nodes that the plan uses (which is fast enough for the 250-node chain), and as the slow rule it reads as (delete a removed
node nothing cites, again and again), which every plan of up to 200 operations must also agree with. The plan's own dates are
checked on exact fractions: the recorded value an operation states must be what rounding to the nearest millisecond, a tie away
from zero, gives for the date it plants.

## ADR 021 (slice B, step 1): what was added

- **The writer's form** (P1), held by h5py in the checks `h5py <session> <attribute> type | strpad | charset | size | bytes`
  (five properties of each of the four attributes of each Swift-written session), and the file's **format** by
  `h5py <session> superblock` (version 2 or later) and `h5py <session> object headers` (an "OHDR" signature is present): the
  writer sets the library-version bounds (V18, LATEST) itself (Gate B 2026-10-14, finding 2).
- **The variable-length plants** (P2): each of the four attributes planted variable-length by h5py (`vl-identity`,
  `vl-min-reader`, `vl-source`, `vl-lineage`), all four at once, an invalid-UTF-8 one, a newer minimum reader with a
  variable-length rest, and the archived hang file (`tools/parity/sidecar-parity/fixtures/hangcase-flip.mactem.h5`, pinned
  by its SHA-256), each refused **by name** (`variableLengthString` with the attribute) on a read and on a write over it, which
  leaves the bytes as they were. Every read of these runs in a child process with a 10 s deadline (`fuzz.swift`), so a reader
  that parsed the damaged heap times out and fails `swift reads hangcase-flip` instead of stalling the gate.
- **The fuzz** (P3, `fuzz.swift`; the files and schedule are `reference.py`'s `FUZZ`): three sidecars Swift writes (a marks
  session of 1,678 bytes; a lineage text of about 58 KB; one of 2,000 nodes, about 315 KB, which h5py plants in dense storage because the writer refuses it, ADR 023 a), mutated at the bytes the
  registration names (every byte of the small file, every 61st of the second, every 997th of the third; xor 0xFF, bit 0, set to
  zero as registered; 16 truncations of each), each mutated file read by the Swift reader in its own process with a 10 s
  deadline. Pass: 0 hangs, 0 crashes (a signal), 0 unnamed outcomes, and 0 silent changes on the two files whose text is within
  the checksummed object header; the third file's silent changes are counted, not gated. **This fuzz does not repair
  checksums**: it is the registered plain-corruption fuzz. The structure-aware fuzz that recomputes HDF5's checksums and found
  the dense-storage hang and crash is archive: sidecar-dense-hang-2026-10-14/ and is not part of this gate.
- **Controls of the fuzz driver** (`--fuzz-selftest`): against a stub reader that hangs, crashes, changes silently or answers
  unnamed, the driver must fail its own check for each, and report nothing against a stub that only refuses by name.

## Slice B, the core: the marks (`marks.swift`, `marks_reference.py`)

`SessionMarks`, `SessionRestore` and `SessionSave` (TEMCore) against h5py and closed forms. The owner (`ImageMeasurements`, TEMSession) is gated by the
app-hosted unit run, not here. The truth is `marks_reference.py`, independent of the Swift code:

- **Swift writes, h5py reads** (5 sessions: anisotropic nm axes, mixed nm and µm, uncalibrated, x only, and a 33 554 432-pixel image
  with awkward doubles 1e-300, 5e-324, -0.0, 16777217.5). Swift builds each lineage with `SessionMarks.parameters` and `.results`
  and saves it through `SessionSave.request` and `.write` (so every node has passed the restore's own checks). h5py reads every node
  (`h5py mk <session> <node> fields | links | recorded | parameters keys | parameters <key> | results keys | results <key>`): the exact
  key sets, every coordinate `float(text)` bit-equal to the planted double, the width, the object, the frame, each result within 1e-12
  relative of the closed form (a distance is the square root of an exact sum of squares, a 200-bit integer square root and one rounding;
  an angle is `atan2(|cross|, dot)` of the exact vectors scaled by the axes when both are calibrated in one unit; `length` and `unit`
  only for one shared unit; `plane`; `samples`), `scale_x`, `scale_y` bit-equal to the planted axes, `unit_x`, `unit_y`, and the source
  identity and both texts in Python's canonical form.
- **P1, a restore equals the save**: Swift reads those files, restores them (`swift marks nodes | kept | verdict | note | readonly | kinds |
  widths | points <session>`: ids, kinds, points bit for bit, widths, the verdict, the calibration note), and saves the restore again with
  no edit: the lineage and the source are the same bytes (`swift marks resave`, `swift marks lineage text`).
- **P2 and P3 on 82 sidecars h5py writes**: restored (three kinds in node order with the others kept and not drawn; the image's edges and
  zero-length marks; awkward doubles; extra keys; an empty and a read-only lineage), the calibration note for six cases of opened axes
  against the recorded scales, the verdict through the restore (another object or shape refused whole as `otherImage`; other pixels
  flagged; only the name noted; the byte size never deciding; the verdict judged before a bad node), and each refusal by name, naming the
  node and what is wrong with it: a missing key (every key of each kind), 17 coordinates outside the grammar `-?digits(.digits)?(e[+-]?digits)?`
  (hex, ".5", "+1", "1.", "1e", "1e999", nan, inf, spaces, an Arabic digit, "1,5"), a point outside by the inclusive bounds on each side of
  each axis (and on the third point of an angle), a width that is not plain digits 1 to 25 (eleven forms), the first bad node of two,
  and no source, no lineage, a malformed identity or lineage. `swift marks restores | refuses <case>` and, for the same lineage, the save's
  checks (`swift marks save <case>`: the same refusal, or the same bytes).
- **The save's changed-on-disk rule** on real files (`swift marks save-disk <scenario>`; h5py reads each accepted save's file, `h5py mk save`):
  a first save, a rewrite that expects what it read, a stale expectation, a file never read (both `changedOnDisk`, the file untouched), a
  chosen replace, a foreign HDF5 file left alone even when replacing was chosen, a read-only lineage, a mark the reader would refuse.
- **Controls 58 to 95** (`marks-*`, 38, the last two of them ADR 023 a's): source mutants of `SessionMarks.swift` (x and y swapped, the vertex, the width, a removed node drawn,
  the bounds at 0 and at W on each axis, the grammar, "03", the width bound, another object drawn, each refusal skipped or naming the wrong
  node, the calibration note skipped and its scales swapped, the plane, the unit for mixed units, the verdict skipped, a partial restore, the
  save's checks skipped, the changed-on-disk check skipped, a read-only save, the frame, the samples) and three of the file layer's
  not-permitted refusal. Where a mutant makes the writer refuse its own marks (a bound at 0), the check that fails is the write's
  (`swift marks writes aniso`), not h5py's: the control names what actually fails.
- **Not here**: the owner's rules (clamps, R3, the full lineage, adopt-only-into-an-empty-owner) are `ImageMeasurementsSessionTests`.

## Check names

A failure prints `  FAIL  <check>: <detail>`, the check being the text between `  FAIL  ` and `: `: `h5py <session> …` (h5py's
reading of a Swift file: `file name`, `opens`, `attributes`, `<attribute> type`, `<attribute> bytes`, `markers`, `source json`,
`source canonical`, `lineage integers`, `lineage canonical`, `lineage next_id`, `lineage node ids`, and per node `fields`,
`coordinates`, `recorded`, `removed`; a lineage of more than ten nodes has them aggregated), `h5py raw <id> …` (h5py's reading
of what the writer was offered directly), `swift reads <case>`, `swift decodes <case>`, `swift identity <case>`, `swift
refuses to overwrite <case>`, `swift writes <session>`, `swift rules <session>`, `fuzz <file> hangs | crashes | silent changes | unnamed outcomes`, `swift writer <id>`, `swift reads its own
<session>`, `swift names <session>`, `url <name>`, `fingerprint <set>`, `verdict <case>`, `libhdf5 is the named copy`.

## Negative controls

The source mutants, the library check, and five controls of the fuzz driver (four misbehaving stubs it must fail on and one it must pass). Each mutant builds the harness (tools/lib/harness.sh) against an edited COPY of one
source file (`SessionSidecarFile.swift` or `SessionLineage.swift`) in the scratch directory, never the file in `Sources/`, and
runs the whole gate (Swift writes, h5py reads, the harness checks). An edit must apply exactly once (a changed line fails the
mutation loudly, to be re-aimed, never dropped) and the build must succeed. A mutant is caught only when the harness exits
exactly 1 and its log holds a failure of every check named for it, the name being the text at the START of a `  FAIL  ` line
(a name found anywhere else in a line is not a catch); a crash by signal is never a catch.

Since the FormatoKit 0.5.0 switch (2026-10-20) the file layer is FormatoKit's `HDF5RootAttributes`, not a macTEM file. The 22
controls that edited it (the null dataspace, the NUL on write, the variable-length, padding, string-class, writer-form,
library-bounds, not-permitted and dense-storage ones: rows 31, 32, 42-44 and 46-53 below, and the dense and not-permitted controls
further down) were dropped when the harness moved to SwiftPM: that code is FormatoKit's and its tests hold it. The plants and checks
they aimed at stay, and still run on the unmutated build. The count before: 105 of 105 caught (2026-10-21, one full run under a
40 GB memory cap; `dense-header-read-with-meta-size`, now dropped, was the one that needed it).

Controls 1-14: the nine registered mutations (1-9) and five of the same kind (10-14). Re-aimed 2026-10-14: control 5 (the
cascade after a delete is now `sweepOrphans()`) and control 13 (the writer's check is now `requireReplaceable`).
Controls 15-40: the guards and rules the plan reaches that the fourteen left open (the Gate B refuter's plants and the fixes
of that review). Control 41: the library check.

| # | mutation | the checks it must fail |
|---|---|---|
| 1 | minimum-reader check skipped | `swift reads newer-min-reader`, `swift reads newer-min-reader-invalid-rest` |
| 2 | a foreign file read as a sidecar (no identity read as "1") | `swift reads foreign-lookalike`, `swift reads foreign-bare` |
| 3 | (retired 2026-10-14, ADR 023 d': equivalent, no file reaches the check) the 4 MiB cap removed from the read | none |
| 4 | a cycle accepted | `swift decodes lineage-cycle`, `lineage-self-cycle`, `lineage-long-cycle` |
| 5 | ids reused after a delete (`next_id` recomputed from the nodes left) | `h5py marks lineage next_id`, `h5py marks lineage node ids` |
| 6 | dates in seconds | `h5py marks s1 recorded`, `s2 recorded`, `h5py many recorded` |
| 7 | the name lower-cased | `url SCAN.DM4`, `h5py marks file name` |
| 8 | the fingerprint over the display canvas (a normalised copy hashed) | `fingerprint six`, `fingerprint ramp-a`, `h5py marks source json` |
| 9 | shape and fingerprint swapped in the verdict | `verdict shape differs`, `verdict pixels differ` |
| 10 | an unknown lineage version refused as malformed | `swift decodes lineage-unknown-version` |
| 11 | the bound on `next_id` removed | `swift decodes lineage-next-id-over` |
| 12 | the 2000-node cap removed from the guards | `swift decodes lineage-2001-nodes` |
| 13 | the writer replaces whatever is there (header check skipped) | `swift refuses to overwrite foreign-bare`, `foreign-lookalike`, `newer-min-reader` |
| 14 | a file name stored as given, not under NFC | `h5py unicode source json`, `swift identity valid-nfd-name` |
| 15 | P2's order: the source and lineage read before the minimum reader is judged | `swift reads newer-min-reader-invalid-rest` |
| 16 | the identity's spelling judged before the minimum reader ("v2" under minimum reader 2 is garbled, not newer) | `swift reads newer-min-reader-v2-identity`, `swift refuses to overwrite newer-min-reader-v2-identity` |
| 17 | a write over a sidecar of a newer schema is allowed | `swift refuses to overwrite valid-newer-writer-same-min-reader`, `newer-schema-with-future-attribute` |
| 18 | the name limit counted in UTF-8 bytes | `url 255 units (µ)`, `(日)`, `(emoji)`, `url 256 units (µ)` |
| 19 | the name limit counted in characters | `url 256 units (emoji)`, `url 256 units (Å)` |
| 20 | the name limit counted on the composed name ("Å" as one unit) | `url 256 units (Å)` |
| 21 | a link to nothing at the sidecar's path is replaced (existence asked by `fileExists`) | `swift refuses to overwrite dangling-link` |
| 22 | an add citing a removed node is accepted | `swift rules kept`, `swift rules cascade`, `h5py kept lineage node ids` |
| 23 | an add is not checked against its inputs at all | `swift rules kept`, `swift rules cascade` |
| 24 | a slash written escaped in the lineage ("1\/nm") | `h5py marks lineage canonical`, `h5py unicode lineage canonical` |
| 25 | a slash written escaped in the identity | `h5py unicode source canonical` |
| 26 | a date rounded half-to-even | `h5py dates s4 recorded`, `s5`, `s6`, `s7` |
| 27 | a date truncated toward zero | `h5py dates s1 recorded`, `s3`, `s4` |
| 28 | a date floored | `h5py dates s1 recorded`, `s4` |
| 29 | the lower clamp of a date moved to -9e18 (a date of -∞) | `h5py dates s9 recorded` |
| 30 | the upper clamp moved to 9e18 (a date of +∞) | `h5py dates s8 recorded` |
| 31 | a null-dataspace attribute read as "" | `swift reads null-dataspace-source` |
| 32 | a NUL accepted in a written string | `swift writer nul-lineage`, `nul-source` |
| 33 | the 4 MiB cap removed from the write | `swift writer cap-plus-one-lineage`, `cap-plus-one-source` |
| 34 | a write over a valid sidecar does nothing | `h5py raw replace-valid attributes`, `mactem_source`, `mactem_lineage` |
| 35 | the cascade after a delete not run | `h5py cascade lineage node ids`, `h5py chain lineage node ids` |
| 36 | the cascade one level deep only | `h5py cascade lineage node ids`, `h5py chain lineage node ids` |
| 37 | a second removal overwrites the first `removed` date | `h5py kept s2 removed` |
| 38 | a removed node edited by a replace | `swift rules kept`, `h5py kept s2 fields` |
| 39 | the digit check of an id dropped ("s+1") | `swift decodes lineage-bad-id-plus` |
| 40 | the identity's 64 KiB cap removed | `swift identity source-over-64kib` |
| 41 | (the harness) the named libhdf5 does not load and the bare name is found instead | `libhdf5 is the named copy` |
| 42 | the variable-length check removed (the damaged string is read) | `swift reads vl-identity`, `vl-min-reader`, `vl-source`, `vl-lineage`, `hangcase-flip` (the last by timing out in its child) |
| 43 | the variable-length check after the read | `swift reads hangcase-flip`, `swift refuses to overwrite hangcase-flip` (timed out) |
| 44 | a variable-length string refused as malformed, not by name | the five reads above, `swift refuses to overwrite vl-identity`, `hangcase-flip` |
| 45 | (retired, as 3) the cap at `<` | none |
| 46 | the padding check removed (text, NUL, text read as the first text) | `swift reads nul-then-text-lineage`, `nul-then-text-source`, `nul-first-lineage`, `nul-then-text-identity` |
| 47 | the whole storage taken as the text, padding and all | `swift reads padded-lineage`, `padded-markers`, `valid-empty-strings`, `all-nul-lineage` |
| 48 | the string class not checked (an integer read as text) | `swift reads integer-source` |
| 49 | the writer back to a variable-length string (slice A's) — re-aimed: the harness's own read-back of what it wrote refuses it first | `swift writes marks`, `swift writes unicode`, `h5py marks file` |
| 50 | the writer's padding NULLTERM | `h5py marks mactem_source strpad`, `mactem_lineage strpad`, `mactem_session_schema strpad` |
| 51 | the writer one byte longer (a trailing NUL) | `h5py marks mactem_source size`, `mactem_lineage size`, `mactem_session_schema size`, `mactem_lineage bytes` |
| 52 | the writer's character set ASCII | `h5py marks mactem_source charset`, `mactem_lineage charset`, `h5py unicode mactem_lineage charset` |
| 53 | the library-version bounds (earliest, V18) (the pair (earliest, earliest) is itself refused by HDF5 2.x) | `h5py marks superblock`, `h5py marks object headers`, `swift writes fuzz-315k` |
| 54-57 | (the harness) the fuzz driver against a stub reader that hangs, crashes, changes silently, answers unnamed | `fuzz selftest hangs`, `crashes`, `silent changes`, `unnamed outcomes` |

Control 41 is not a source mutant: the named copy is made unloadable and the committed one is offered under the dynamic
loader's fallback path, so the binding's fall-back to the bare `libhdf5.dylib` loads it. Everything else would pass on that
library (it is the same one); only the check that the loaded copy is the named one fails.

## ADR 023 a (slice B, step 2, part a): the writer's 60,000-byte cap

- **Raw writes** (`swift writer total-cap-*`): the four attributes' text at the cap exactly (a lineage of 60,000 minus the other
  three attributes' bytes) is written, one byte over is refused by name (`sidecarTooLarge`) and nothing is written, and the same
  over by the sum only (a source and a lineage each far under it). Nine sizes from empty to within 100 bytes of the cap
  (`size-N`) are written and h5py checks each one **compact**: the attribute message is present in the object header and
  `meta_size.attr` has no heap and no index (`h5py raw size-N compact`).
- **The marks' save** (`swift marks save-disk at-budget | over-budget`): a mark session whose lineage text lands at the budget is
  saved, one node more is refused as `sidecarTooLarge` and the file is untouched.
- **Controls 96 to 100**: the cap removed, at `<`, on the lineage only (`SessionSidecarFile.swift`), and the save request's check
  removed or at `<` (`SessionMarks.swift`).
- **What the cap moved**: the node cap of 2,000 (`lineage-2000-nodes`, the decode) stays the decoder's; a session of 2,000 nodes
  cannot be written any more, so `many` is 200 nodes, `chain` 250 (the cascade's 2,000-node time is `SessionLineageTests`'), and
  the fuzz's third file is planted by h5py.

## ADR 023 d' (slice B, step 2, part d'): the reader's header-only refusal of dense storage

- **The dense plants** (`dense=True` cases, each proved dense by h5py's `meta_size.attr` heap and index): lineages of 65,600 B and
  100 KB, and of 4 MiB, 4 MiB + 1 and 5 MiB (and the source at 5 MiB), 40 more attributes with and without creation order tracked, a
  dense file that is also foreign / of a newer minimum reader / variable-length in its identity; each is refused
  `denseAttributeStorage` on a read and on the replace check, the file untouched. The decode checks of the three texts too big for a
  compact file (2,000 and 2,001 nodes, a 70,000-byte identity) run on the text kept beside the sidecar. Compact twins read:
  `valid-compact-attributes-tracked-order` (8 attributes), and `foreign-no-attributes` is `foreign`, not dense.
- **The structure-aware fuzz** (`dense_fuzz.py`, run with `--fuzz`): three h5py dense sidecars (65,600 B, 70,000 B and 100,000 B
  lineages); for every byte of each FRHP, BTHD and BTLF block six byte operations and every 2-, 4- and 8-byte window at the sheet's values,
  the block's lookup3 checksum recomputed (the second opinion's 648 FRHP windows are a subset, counted); 12,708 / 12,705 / 12,706
  mutations, each read by the Swift reader in a child process with a 10 s deadline. Pass: 0 hangs, 0 crashes, 0 unnamed, 0 reads that
  succeed (every read a named refusal; the registered outcome is `denseAttributeStorage` for all). The compact fuzz of step 1 is
  unchanged except that its third file (h5py-planted, 315 KB) is now a dense file read as that refusal.
- **Measured, not gated**: four forged headers (a compact sidecar with creation order tracked, its attribute-info message pointed at the
  superblock, the root header, the end of the file, beyond it; checksum recomputed): all four `refused hdf5` by the library
  (no heap behind the pointer). Not covered: a dense file with a valid attribute message added to its root header passes d′
  and its fuzz crashes or hangs libhdf5 (Gate B 2026-10-14, ADR 023 Implemented (4)).
- **Retired**: controls 3 and 45 (the reader's 4 MiB cap removed / at `<`): no file reaches that check since dense storage is refused
  first. New controls: the check skipped, after the first attribute, in the read only, the message bit inverted, the attribute-info
  condition dropped / negated, and the header read together with `META_SIZE` (caught by `--fuzz-dense`, the second opinion's windows).
- `SIDECAR_PARITY_FUZZ=1 run.sh --only '^$'` runs the gate and the fuzz alone.

## Notes

- **The scratch directory**: everything is written under `mktemp -d` and removed on exit; no tracked file is written. About
  25 MB: the 5 MiB lineage and source plants and the 4 MiB pair are the bulk. `reference.py plant` also makes and removes a
  few empty files there to measure the file system's name limit.
- **libhdf5** is FormatoKit's `FormatoLibHDF5` framework, which the harness links (tools/lib/harness.sh puts it beside the
  executable), named by `FORMATO_HDF5_PATH`, which FormatoKit's loader reads first, so the process holds one HDF5 image. The
  loader falls back to other paths when that one does not load, so the harness checks which library it got (`libhdf5 is the
  named copy`); control 41 offers FormatoKit's plain vendored dylibs, copied and re-signed ad hoc, as that fallback.
- **A mode-000 file** needs a user that cannot read it; where `reference.py` can read it anyway (a privileged user) it says so
  and drops that case.
- **The date plants** (`dates`): a tie can be planted only where the millisecond count is exact in binary, which a date near
  2026 is not (a Double of seconds there has a step of 1.2e-7 s), so the four ties are in 1970 (62.5 and 312.5 ms, 1/16 and
  5/16 s). The ±∞ and NaN dates have their truth in the source's own documented clamp (±9e15, NaN is 0), not in an
  independent reference.
- **What is not checked here**: the UI (slice B), mac4DSTEM's ADR 047 vocabulary beyond ADR 020, and Metal. The publish race
  (the target replaced or created between the check and the rename) and what a replace drops (mode, extended attributes,
  link-ness) are the unit tests' (`SessionSidecarFile.WriteSeams` puts a test exactly between the check and the publish); the
  time a cascade takes is the unit test's too (`testRemovingTheEndOfAChainOfTwoThousandRemovedNodesIsOnePass`: here the
  250-node chain proves the cascade complete, with no timer). A sidecar damaged inside (a flipped byte in the global heap's
  object size makes HDF5's own read spin, in this library and h5py's alike) could once not be planted, the read never returning; since ADR 021 the archived hang file is one of the cases and is refused by name. The unit
  tests (`macTEMTests/SessionSidecarFileTests.swift`, `SessionLineageTests.swift`) pin the layers' own rules without Python; this
  harness is where they meet h5py.
