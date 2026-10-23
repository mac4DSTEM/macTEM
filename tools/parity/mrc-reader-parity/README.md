# mrc-reader-parity

macTEM's MRC reader (`MRCImageReader`, compiled from `tools/lib/sources.manifest` group `mrc`) against mrcfile 1.5.4
(pinned: `tools/lib/references-lock.txt`) and RosettaSciIO `049e7d70`'s `tests/data/mrc` files (`tools/lib/fetch-rsciio.sh`,
sha256 against `rsciio/tests/registry.txt`). A `scientific` gate; the pre-registration is archive: roadmap-registrations-2026-10-15.md V1-3c-i. Run
`tools/parity/mrc-reader-parity/run.sh`, redirect it to a log, and read the exit code on its own line.

The comparison is exact: every pixel equals mrcfile's value cast to float32, bit for bit; each axis's scale is
`Double(float32 voxel size)` -- the same 64 bits as `float(voxel_size.x)`, with origin `0.0` and unit `Å`; `notes` are the
same strings. A file macTEM must refuse has to throw the named case (`stack`, `mode`, `byteOrder`, `notMRC`,
`axisOrder`, `truncated`). When either scale is not finite and > 0, both axes are `null` with the note
`uncalibrated: the cell length is not positive`.

## The reference

mrcfile reads `MrcFile.data`, `voxel_size` (= `header.cella / (mx, my, mz)`, float32, in Å, nothing converted) and the
header; it reads mode 0 as signed int8, byte order from the machine stamp only, and skips the extended header by NSYMBT.
Its shapes: nz = 1 with ispg 0 is `(ny, nx)`, with ispg 1 it is `(1, ny, nx)` (the harness reshapes and asserts both);
the header origin is never interpreted (macTEM does not read it either). `reference.py` opens STRICT
(`permissive=False`) every file that must open and PERMISSIVE only to read the header of a defective file (nx, ny <= 0).
Its numpy 2.5 `dtype` deprecation warning is silenced.

Before any reading counts, `reference.py` requires mrcfile to reproduce every planted truth (dtype of the mode, shape,
pixels by sha256 of the float32 bytes, scales, notes, header words): a disagreement exits 1 there -- a reference check,
never a pass.

**Refusals.** mrcfile does not name refusals and reads several refused files without complaint (mode 4, mapc/mapr/maps
!= 1 2 3, nz > 1, nx = 0), so `reference.py` derives the cause from the header bytes (`refusal_cause`, first that
applies): `notMRC` (< 1024 bytes, or no "MAP " at 208), `byteOrder` (stamp not 44 44 / 44 41 / 11 11), `notMRC` (nx or
ny <= 0), `mode` (not 0, 1, 2, 6, 12), `stack` (nz > 1), `axisOrder` (mapc, mapr, maps != 1, 2, 3), `truncated` (NSYMBT
< 0 or the file shorter than 1024 + NSYMBT + nx*ny*bytes). It then confirms the cause with mrcfile where mrcfile has an
opinion (strict open raises; mode 4 reads as complex64; a stack's shape is `(nz, ny, nx)`; `validate()` rejects the
axis order). Every planted refusal has exactly one defect, so the order matters only for real files.

## Deviations from RosettaSciIO `rsciio/mrc` (not run: it needs dask)

- **Unit and scale**: RosettaSciIO converts to nanometres (scale `Xlen/MX/10`, unit `nm`, offset `XORIGIN/10`); macTEM
  keeps the file's Å (scale `cella.x/mx`, unit `Å`) and does not read the origin, whose meaning (a phase origin in
  pixels or a map origin in Å) is unchecked.
- **Mode 0**: RosettaSciIO reads uint8; the MRC2014 specification and mrcfile read int8. macTEM follows the specification.
- **Machine stamp**: RosettaSciIO ignores it (default `<`); macTEM honours `44 44`, `44 41` and `11 11` and refuses others.
- **Refusals**: RosettaSciIO squeezes singleton axes and has no mode-aware refusal; macTEM refuses nz > 1, modes 3, 4, 101,
  and unknown ones. It also takes a FEI header (NEXT/1024 == 128) as scale = pixel size (m) x 1e9; macTEM does not.

## Cases

1. **Planted** (`make_fixture.py`: its own `struct.pack` writer of the 1024-byte header, not mrcfile's):
   - Modes 0 (all 256 int8 values), 1 (negatives down to -32768), 2 (float32 extremes), 6 (above 32767), 12 (float16
     extremes, subnormal); big-endian mode 1 (stamp 11 11); stamp 44 41; a 1024-byte non-zero extended header; nz = 1
     with ispg 1.
   - Calibration: 40 x 24 with cella.x/mx != cella.y/my; mx, my not equal to nx, ny; negative cella (x and y),
     zero, NaN, and mx = 0 (each uncalibrated with the note).
   - Refusals: nz = 3 (ispg 0 and ispg 1), modes 3, 4, 5 and 101, stamp 00 00, no "MAP ", a 700-byte file, nx = 0,
     ny = -4, mapc/mapr/maps = 2 1 3, 1 3 2 and 0 0 0, truncated data, NSYMBT past the end, NSYMBT < 0.
2. **RosettaSciIO's files**: HAADFscan (16 x 16 uint16 behind NSYMBT 909312: calibrated), the DE singles
   (`20241021_00405_final`, `Virt 0/1 sum`, `Ext 1`) and `ROI_Random_Scan_Sum` (cella is negative: uncalibrated); the
   stacks `4DSTEMscan`, `Custom_movie`, `20241021_00405_movie` and `ROI_Random_Scan_movie` (refused `stack`).

## Negative controls

Seven (`MACTEM_PARITY_MUTATE`, in `main.swift`): transpose -> shape, mode0-unsigned -> pixels, ignore-stamp -> `mode1-bigendian read` (a little-endian reading of a big-endian header refuses the file),
ignore-nsymbt -> pixels, scale-from-my -> scale, drop-nonpositive -> notes, accept-stack -> `stack-nz3 refusal`. Each
counts as caught only when the harness exits 1 and the check it targets is among the failures.
