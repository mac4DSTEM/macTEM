# tiff-reader-parity

macTEM's TIFF reader (`ImageOpening.openNow`, compiled from `tools/lib/sources.manifest` group `tiff`) against
RosettaSciIO `049e7d70` with tifffile 2026.9.20 (both pinned: `tools/lib/references-lock.txt`,
`tools/lib/fetch-rsciio.sh`). A `scientific` gate (`tools/run-tests.sh scientific`); the pre-registration is
archive: roadmap-registrations-2026-10-15.md V1-3b (the re-registration block governs). Run `tools/parity/tiff-reader-parity/run.sh`, redirect it to a log,
and read the exit code on its own line.

The comparison is exact: every pixel equals the reference's value cast to float32, each axis's scale and origin have
the same float64 bits, units are the same string, and `notes` are the same strings in the same order. A file macTEM
must refuse has to throw the named error (`multiPage`, `compressed`, `tiled`, `unequalChannels`, `sampleFormat`).
`origin = -offset/scale` in pixels, `+0.0` for a zero offset (never `-0.0`). An axis is `null` (uncalibrated) when
the reference gives it no unit.

## Cases

1. **Planted** (`make_fixture.py`, tifffile): 40 × 24, x scale != y scale, values that only the right sign and width
   decode to. `reference.py` first requires the reference to reproduce every planted truth (pixels by sha256, axes,
   notes, the refusal's cause from the file's own structure); a disagreement exits 1 there — it is a reference
   check, not a pass.
   - ImageJ (uint8, uint16, float32; µm, anisotropic; and uint16 without calibration), plain int16, int32 and
     big-endian uint16, Digital Micrograph tags (int32 nm, float32 µm, nonzero offsets).
   - Velox/Ceta (tag 34683 on an 8-bit RGB render): agreeing tags, agreeing within the rounding band (pixel size
     2.1016264901077918e-09 m, 0.01/scale non-integer; the owner's 630 kx pair 224125360 against 224125354.07),
     65450 off by 10 % and (separately) 65451 off by 10 % (both axes null, disagreement named), a count a hair inside
     the bound (x high side, y low side: calibrated), exactly one count past it and a hair past it (uncalibrated),
     65450 alone (agreeing: calibrated) and 65451 alone (off: uncalibrated), no private tags, a grey uint16, and one
     unequal pixel (refused). A Velox XML without PixelSize beside ImageJ calibration opens as the ImageJ reading,
     no notes.
   - ImageJ: `unit = micron` with spaces (RosettaSciIO/tifffile trim: calibrated); `unit=micron` with no
     XResolution/YResolution (the tags renamed away: RosettaSciIO opens it uncalibrated, never 1 µm/px); stacks in
     ONE IFD (next-IFD offset 0) with `images=3`, `slices=2`, `frames=2`, `frames=2 channels=2`, and tifffile's
     default `channels=3` (all refused `multiPage`; RosettaSciIO sees a stack).
   - FEI SEM, anisotropic, tag 34682 INI text: `[Scan]` PixelWidth != PixelHeight; `[IRBeam]` HFW/VFW with `[Image]`
     ResolutionX/Y and no `[Scan]`; `PixelWidth = 1e-9` with spaces. Truth: PixelWidth (HFW/ResolutionX) on x = width,
     `"reference": "registration"`; `reference.py` also asserts RosettaSciIO's reading is that SWAPPED.
   - Digital Micrograph scale 0 (tag 65009 = 0.0): x uncalibrated (registration; RosettaSciIO keeps scale 0, asserted),
     y still calibrated.
   - A corrupt header: ImageWidth = ImageLength = 0xFFFFFFFF on a 16-bit grey file (refused `truncated`).
   - Plain RGB R=G=B (opens, labelled) and with one unequal pixel (refused); two pages, LZW, tiled, WhiteIsZero and
     uint32 (refused).
2. **RosettaSciIO's own files** (sha256 against `registry.txt`): ImageJ float32 µm and no-scale, DM-saved int32 µm,
   the ImageJ and DM stacks (refused, multi-page), FEI Helios E-beam 16- and 8-bit (`Scan/PixelWidth`, m) and the
   navcam files without an IRBeam block (uncalibrated).
3. **The owner's two Ceta TIFFs** (`References/example_files/`, gitignored; `diagnostic: true`): skipped with a printed
   line when absent.

`"reference": "registration"` marks the Velox/Ceta convention, which no published reader reads: the rule is
written in `reference.py` from the tags — scale from `/Metadata/BinaryResult/PixelSize/X,Y` (`unit` attribute), origin
0 (`Offset` is not read); cross-checked against tags 65450 (x) / 65451 (y) only when 65452 == 3 and both units are `m`, on each axis whose tag
is present (neither present: no check): per axis agree iff
`abs(perCm - 0.01/scale) <= 0.5 + float32_half_ulp(perCm)`, `float32_half_ulp(v) = numpy.spacing(numpy.float32(v)) / 2`.
Why: Velox stores the per-cm count after a float32 rounding, as a RATIONAL n/1 (the owner's 630 kx file: 224125360
against the implied 224125354.07, where the float32 step is 16); a plain integer rounding (0.5) is refuted by that
file. Any checked axis disagreeing opens both axes
uncalibrated with `uncalibrated: the Velox XML and the resolution tags disagree`, otherwise `scale unvalidated (one
acquisition)`; an R=G=B RGB file adds `8-bit render, not counts` first. Tags 65450/65451 are TIFF RATIONALs (an
integer over 1) in the owner's files, not floats.

## What RosettaSciIO does (and does not) read

- ImageJ: scale from X/YResolution (`den/num`) **only when the description has a `unit`**, and the unit is kept **only
  for `micron`** (→ µm). Another unit (`nm`) keeps the scale and drops the unit: the harness reads such an axis as
  uncalibrated and plants only µm. Offset is always 0.
- Digital Micrograph: tags 65003/65004 units, 65009/65010 scale, 65006/65007 *offset in axis units* (RosettaSciIO's
  writer and its test file agree); in its DM test file the offsets are 139.66 and 128.19 µm = 828 and 760 pixels of
  0.1687 µm on a 68-pixel image — whether DM's tag is that offset or an origin is unchecked.
- FEI: `Scan/PixelWidth`/`PixelHeight` (m). Its `_order_axes_by_name` puts `PixelWidth` on the height axis (and the
  IRBeam `HFW/ResolutionX` fallback likewise): invisible on the isotropic `Scan` files, wrong on anisotropic ones.
  macTEM's documented DEVIATION puts PixelWidth on x (width); every FEI case (planted and RosettaSciIO's) is therefore
  `"reference": "registration"` with the axes computed from `tifffile.fei_metadata`, and `reference.py` asserts
  RosettaSciIO's reading equals them swapped (failing loudly if it stops swapping, or if the file is isotropic).
  The real anisotropic navcam file stays `diagnostic`.
- Digital Micrograph scale 0: RosettaSciIO returns scale 0.0 with the unit; the registration reads that axis as
  uncalibrated (a scale that is not finite and > 0 is never a pixel size).
- Plain TIFFs and `XResolution` alone: uncalibrated (only `force_read_resolution` reads them).

## Negative controls

Seven (`MACTEM_PARITY_MUTATE`, in `main.swift`): transpose → shape, swap-calibration → scale, units → units, pixel →
pixels, origin-sign → origin, accept-unequal-rgb → `rgb-unequal-plain refusal`, drop-notes → notes. Each counts as
caught only when the harness exits 1 and the check it targets is among the failures.
