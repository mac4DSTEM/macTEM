# SEM micrographs in the Image room

2026-11-06. Phase 1 of the SEM program. Not a new room: an SEM micrograph is a calibrated image, and the Image room
(⌘1) already measures, marks, finds particles and feeds the FFT room. What the program adds is the reading of the SEM
vendors' TIFFs with their metadata, the databar, the detector and beam conditions in Info, and the SEM words on screen.

## 1. Purpose and the microscopist's tasks

- *Know what I recorded* (task 1): HV, working distance, detector (SE, BSE, InLens, ETD, T1…), spot or beam current,
  magnification, dwell, scan size, stage tilt and rotation, vacuum mode, the date; the pixel size the vendor wrote.
- *Look and measure* (task 7): the scale bar from the vendor's pixel size, distances, angles, profiles; the databar
  excluded from the picture and from every number.
- *Count and size objects* (task 24): particles on a BSE image, as today on a TEM image.
- *Sift a session* (task 2): open a folder of SEM TIFFs, step through them in Open Files, see the conditions at a glance.

## 2. What opens here

`.tif`/`.tiff` from Tescan (the TIFF's `ImageDescription` ini block and the trailing `.hdr` when present), Zeiss
(`CZ_SEM` tag 34118, the key list), Thermo/FEI (`FEI_HELIOS`/`FEI_TITAN` tag 34682, the `[User] [System] [Beam] [EBeam]
[Scan] [Stage] [Vacuum] [Image] [Detectors]` ini). The read is FormatoKit's TIFF reader as today (`TIFFImageReader`);
the SEM metadata is a `TEMCore/Data/SEMMetadata` seam that parses the vendor block the file carries into one
`AcquisitionMetadata` with named fields and the file's own units, exact (unit tests against the fixtures' known
values). A TIFF with none of the three tags is a plain image, as today. The pixel size comes first from the vendor block
(Thermo `PixelWidth`, Zeiss `Image Pixel Size`, Tescan `PixelSizeX`), then from the TIFF resolution tags, then none
("Not calibrated: the scale bar counts pixels", the existing warning).

`RoomHoldings.semImages` is true when every open image carries an SEM block: Diffraction is then disabled with "The open
images are SEM micrographs, not diffraction patterns" (`RoomAvailability.reason`, decision D2).

## 3. Layout

The Image room's, unchanged: the picture in `ImagePane` with the scale bar in its footer, the inspector, the bottom
Output pane. One addition in the picture: the **databar** is cropped out of the picture by default when the vendor block
states its height (Thermo `[Image] ResolutionY` vs the TIFF height; Zeiss and Tescan from their own fields), and the
room's numbers (histogram, measurements, particles, FFT, exports) use the cropped image. The crop is a `Display` row,
`Databar · Hide · Show` (shown, it is drawn below the picture outside the zoom container, as a footer strip, never
inside a measurement). The status line reads `x 412 · y 96 · 18 304` (pixels of the cropped image) as today.

## 4. Inspector: Settings

Image-room order, as today: `Calibration · Display · Particles · Measure · Lineage`.

- **Calibration**: `Horizontal (x)`, `Vertical (y)`, `Source` (`The file (Thermo PixelWidth)` names the vendor field),
  the existing warnings.
- **Display**: the shared Display pattern plus `Databar · Hide · Show` (two segments, full width; only when the file
  has one).
- **Particles**, **Measure**, **Lineage**: unchanged.

No SEM section in Settings: conditions are information, not settings (control placement §1).

## 5. Inspector: Info

`ImageRoomAcquisition` gains the SEM block, under the existing `Image` and `File` groups, as `Acquisition`, one value row
each, the file's words and units, in this order: `Instrument`, `Detector`, `HV`, `Beam current` or `Spot`, `Working
distance`, `Magnification`, `Dwell`, `Pixel size`, `Scan size`, `Stage tilt`, `Stage rotation`, `Vacuum`, `Date`; then
`Vendor fields` as a disclosure with every key the block carries, raw. A field the file lacks is left out, not shown
empty. Copy on the group gives TSV.

## 6. Behaviour spec

- Opening a Thermo, Zeiss or Tescan TIFF shows the picture with the databar hidden, a calibrated scale bar, Info filled;
  the Output pane logs `Read Thermo metadata: 47 fields` once.
- `Databar · Show` reveals it as a strip under the picture, aligned to the picture's width at any zoom; measurements
  cannot start on it.
- The window title is the file name; the centre display reads `name.tif · Image · 2048 × 1536` (cropped size).
- An 8-bit image with a 16-bit vendor block variant (Thermo saves both) reads the pixel data as stored and names the
  bit depth in Info.
- Multi-page SEM TIFFs (a Zeiss series) use the existing stack frame row and ← →.

## 7. Demo data on open

Help › Open Demo Data › SEM Micrograph (`--demo-sem-image`): the demo SEM micrograph (a public Thermo or Zeiss TIFF with
a databar, `docs/data-sources.md`) opens in Image, databar hidden, scale bar from the vendor pixel size, Info filled.

## 8. Acceptance

- Readers exact: every field of the three fixtures equals the value a reference reader gives (rosettasciio's `tiff`
  plugin for Zeiss, Thermo and Tescan metadata; `tools/parity` emits the reference JSON).
- The pixel size and the databar height equal the reference; a 10 µm distance measured on the demo micrograph equals
  the same in Fiji within one pixel.
- Screenshot: the demo micrograph in the Image room, Info tab open on `Acquisition`.

## 9. Journeys

`SEMImageJourney.swift`: (1) launch `--demo-sem-image`, the picture is in view, the scale bar reads a µm value, Info ›
Acquisition lists `HV` and `Detector`; screenshot. (2) `Databar · Show` adds the strip, `Hide` removes it, the status
line's y never exceeds the cropped height. (3) a distance measured across the picture reads in µm.
