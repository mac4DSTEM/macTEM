# The Patterns room: the EBSD/TKD dataset, seen

2026-11-06. Phase 1 of the SEM program; the first of the three new rooms and the one the phase 1 gate drives. Sidebar
`Patterns` (⌘6, symbol `square.grid.3x3.square`), subtitle "EBSD and TKD patterns: the scan, virtual images and the
live pattern". The processing pipeline it grows in phase 2 is `pattern-processing.md`.

## 1. Purpose and the microscopist's tasks

The microscopist has a folder from the EBSD acquisition and wants to see it before anything is indexed: what the scan
covers, whether the patterns are usable, where the grains are. Tasks (microscopist task map A1–A3, F19 for 4D-STEM,
the same questions for a pattern dataset):

- *Know what I recorded*: scan shape and step, pattern shape, binning, detector, kV, tilt, working distance, the
  projection centre the vendor stored and its convention, phases the file names.
- *See the scan*: a virtual image of the scan from the patterns themselves (the virtual BSE), and the vendor's maps
  when the file carries them (image quality, band contrast, mean intensity).
- *Browse the patterns*: hover across the map and watch the pattern follow, pin one, step with the arrow keys, compare
  a few; see where the pattern is bad (vacuum, edge, charging).
- *Sift a dataset*: open several files, see which is worth indexing.

The room shows the file as it is; a number on screen is the file's own or a sum of its pixels (virtual images), nothing
processed until the Processing stages run (phase 2).

## 2. What opens here

`RoomHoldings.ebsd` becomes true when a file of one of these types is opened: kikuchipy h5ebsd (`.h5`, `/Scan 1/EBSD/`),
Oxford h5oina (`.h5oina`), Bruker h5 (`.h5`, `/Scan 0/EBSD/`), EDAX `.up1`/`.up2` with their `.ang`, Oxford `.ebsp`
with `.ctf`, NORDIF `Pattern.dat` with `Setting.txt`, EMsoft `.h5`. The reader is `TEMCore/EBSD/PatternDatasetOpening`
over FormatoKit's HDF5 layer, by extension then by the file's root groups; a `.h5` that is none of these is refused with
"No EBSD scan in this HDF5 file: expected /Scan 1/EBSD, /1/EBSD or an h5oina root". A directory drop with `Setting.txt`
opens the NORDIF set. An `.ang` or `.ctf` alone (vendor-indexed, no patterns) opens in Maps, not here; the Patterns row
says "No file open holds patterns".

The read is off the main actor (`AppState.read`); the dataset stays on disk and patterns are read on demand through an
LRU cache sized by the pattern bytes (`PatternDataset`), so a 4 GB scan opens in the time its header and the first
virtual image take. The virtual BSE of the whole scan is the first picture: it is computed on open as one pass over the
file with the progress in the centre display and Stop; the map draws tile by tile as the pass advances (DNA 10: first
look instant, work cancellable). Pattern (0, 0) is in the live pane before the pass ends.

## 3. Layout

```
┌──────────────────────────────────────┬──────────────────────────┐
│ Scan map (main pane)                 │ Live pattern pane        │
│ virtual BSE, 1 px per scan point     │ the pattern under the    │
│ scan marker ⌖ at the pinned position │ pointer, else the pinned │
│ regions; scale bar in the footer     │ one; detector grid when  │
│                                      │ Virtual images is open   │
├──────────────────────────────────────┴──────────────────────────┤
│ Bottom pane  tabs: Virtual images · Patterns · Metadata         │
│  Virtual images: the tiles (BSE, each detector tile, IQ, mean)  │
│  Patterns: the pinned patterns side by side (up to 6)           │
│  Metadata: the file's EBSD header as a table                    │
└─────────────────────────────────────────────────────────────────┘
```

- **Scan map**: the virtual BSE image, one pixel per scan point, drawn with `MetalImageView` in one `ZoomableContainer`;
  the scale bar from the step size (`ImageScaleBar`); the scan marker is a crosshair with a grab handle, drawn in the same
  transformed container as the picture (mac4DSTEM's `RealSpacePointerPolicy`: at 1× a click or drag anywhere scrubs the
  position; zoomed in a drag pans and the marker moves by its handle). Regions (`Tools`) are drawn here; every tile in the
  bottom pane shows the outline.
- **Live pattern pane**: open by default, 38 % of the centre width, `PaneSplit` stored per window. Shows the raw pattern
  at the hovered scan position while the pointer is over the map, the pinned one when it is not; the header sentence says
  which: `Pattern · row 12 · col 40 · hovering` / `· pinned`. Its own `ZoomableContainer`, its own Display popover from
  its scale bar (a pattern is in pixels or, once the geometry is known, in degrees across). Overlays live in the pane's
  transformed container: the detector-grid tiles while the Virtual images tab is open, the projection centre glyph once
  Calibration knows one. The pattern draws on every hover, so the pane's update is the hovered index only, never a
  layout change (performance: the Metal view takes the new texture; nothing above it re-renders).
- **Bottom pane**: `Virtual images` (the tiles the room has computed; the BSE anchor is also the map), `Patterns` (the
  pinned patterns side by side, each with its row · col and a Remove ×, max six; ⌘P pins the current one), `Metadata`
  (the EBSD header as a two-column table: key, value, the file's own words). Selection in `Virtual images` makes that
  tile the map; selection in `Patterns` moves the marker.
- **Status line**: `row 12 · col 40 · BSE 1 203 · IQ 0,71 · mean 118` (control placement §7): every virtual image's
  value at the hovered position, the map's first.
- **Toolbar**: no verb in phase 1 (the room shows; nothing runs but the open). Phase 2 adds `Process` (pattern-
  processing.md). The centre display: `patterns_v2.h5 · Patterns · 55 × 75 of 60 × 60`.
- **Scan navigator**: none here, the map is the scan. It appears in Indexing and Maps beside a pane that is not a map of
  scan positions (mac4DSTEM's `ScanNavigatorPlacement`).

## 4. Inspector: Settings

Image-room order (control placement §2): `Calibration · Display · Virtual images · Export`; phase 2 inserts
`Processing` sections before Export.

**Calibration** (open): the geometry the file states, as value rows, with its source; a warning when a value is missing.

| Row | Value | Note |
|---|---|---|
| Step | `1,5 µm × 1,5 µm` | from the file |
| Scan | `55 × 75` | rows × columns |
| Pattern | `60 × 60 px · binned 8×` | |
| Detector | `NORDIF UF-1100` | |
| Beam | `20 kV` | |
| Sample tilt | `70°` | `TKD: −20°` when the file says so |
| Detector tilt | `0°` | |
| Projection centre | `(0,4210, 0,7794, 0,5049) · Bruker` | the convention named; `None in the file` otherwise |
| Convention | pop-up `Bruker · EDAX · Oxford · EMsoft` | read-only readout of the file's; the choice is phase 2's (pattern-processing.md §3) |
| Phases | `Ni (Fm-3m, 3,524 Å)` | one value row per phase |

**Display** (open): the one Display pattern (`DisplayControls`): `Colormap`, the histogram with handles and `Reset
Range`, `Gamma`, `Show Scale Bar`. It applies to the map; the pattern pane's own is its scale-bar popover, so the two
pictures keep their own contrast (a pattern is 8-bit and dark at the edges; a BSE image is a sum).

**Virtual images** (open): what the tiles are made of.

- `Grid` segmented, full width: `1 · 3 × 3 · 5 × 5 · 7 × 7` (the detector cut into that many tiles; `1` is the whole-
  pattern sum, the BSE).
- `Tile` is picked by clicking a cell of the grid drawn over the pattern pane, not in the inspector (direct manipulation
  of the data it sits on, §1 *break when*); the picked cells are listed as `r1c1 · r3c5 …` in a caption under the control.
- `Colour mix`: three cells as R, G, B make the colour-mix tile (NS-1); the mix is the anchor of the bottom pane once it
  exists.
- `Vendor maps` switch: `Show the file's maps` (image quality, band contrast, mean intensity, when the file has them).
- `Image quality` and `Mean intensity` are computed tiles (`Compute IQ · Mean` width set, each disabled with "Needs the
  patterns read once" until the open pass ends); NS-2.

**Export** (closed): `Virtual images… · Pattern PNG…` width set; `Scale bar` switch; `Metadata JSON…` full width. The
figure sheet is export-and-reports.md's.

## 5. Inspector: Info

What the file is: path, format and version (`kikuchipy h5ebsd 1.0`), size, the acquisition block the format carries
(date, microscope, magnification, working distance, exposure, frame rate, gain), the phase list with cell parameters
and space group, the file's own projection centre. The Metadata tab of the bottom pane is the same table in full; Info
is the summary (one screen).

## 6. Behaviour spec

- **States**: *empty* (nothing open): one sentence, `Open Dataset…` (⌘O) and `Open Demo Data`. *opening*: the header
  read, then the virtual BSE pass in the centre display with its bar and Stop; the map draws tile by tile; the pattern
  pane shows (0, 0) as soon as the header is read. *opened*: map, pattern, tiles. *refused*: the reader's sentence in
  the canvas (`ContentUnavailableView`) with `Try Again`, and in Output.
- **Hover**: the pattern pane follows the pointer; leaving the map returns it to the pinned position; the status line
  carries the readout. ⌥ while hovering holds the hovered pattern as a ghost (50 %) over the pinned one for comparison
  until ⌥ is released (the EDS room's ⌥ pixel-spectrum move).
- **Pin**: click or drag on the map at 1× moves the marker (scrub); Space pins the hovered position; ← → ↑ ↓ step by
  one, ⇧ by ten; Home/End go to the first and last column of the row. ⌘P adds the pinned pattern to the Patterns tab.
- **Zoom**: wheel and pinch zoom about the pointer, double-click fits, ⌘+ ⌘− ⌘0, continuous; the map and the tiles share
  one transform; the pattern pane has its own.
- **Regions**: `arrow · ▭ · ◯ · ⬠ · ╱` (⌃⌘0–4) in Tools, drawn on the map; a region's mean pattern replaces the pinned
  one in the pattern pane while the region is selected (`Pattern · Region 1 · mean of 312`); ⌫ deletes, Esc returns to
  the arrow. Tools is a section of this room only once regions have a consumer: phase 2 (processing on a region) adds
  it, under Display.
- **Large scans**: the virtual BSE pass reads the file once in scan order in 64 MB chunks; the map shows progress by
  drawing; Stop keeps what was drawn and marks the rest hatched (unavailable, with a count in the tile's footer).
  Patterns are cached by scan index; hovering past the cache reads the pattern synchronously off the main actor and the
  pane keeps the last pattern until the new one arrives (never a blank).
- **Several files**: each open dataset is an item in Open Files; selecting one makes it the room's document; the pinned
  position and regions are per item.

## 7. Demo data on open

Help › Open Demo Data › EBSD Pattern Dataset (`--demo-ebsd`): the demo Ni dataset opens in Patterns. The map is the
virtual BSE of the 55 × 75 scan; the pattern pane shows pattern (0, 0); Calibration reads step 1,5 µm, 60 × 60 px,
20 kV, 70°, the projection centre and convention the file carries; Virtual images is at `1`; the bottom pane shows the
BSE tile. The reference numbers are NS-1's.

## 8. Acceptance

- NS-1: the virtual BSE (`Grid 1`) and the 5 × 5 grid with the three-cell colour mix match kikuchipy's
  `VirtualBSEImager` output on the demo Ni dataset within north-star.md's tolerance, computed in the app from the
  welcome window. Pattern (0, 0) raw equals the file's bytes exactly (readers are exact).
- NS-2: the image-quality and mean-intensity tiles match kikuchipy's within tolerance.
- The gate screenshot: the room on the demo data at the default window size, live pane open, bottom pane open on
  Virtual images with the colour mix selected.
- Every format in §2 opens its fixture and shows the first pattern and the calibration rows; a wrong file is refused
  with the sentence above (unit tests, exact).

## 9. Journeys

`PatternsJourney.swift`:

1. `testTheDemoDatasetOpensInPatterns`: launch `--demo-ebsd` → `patterns.room` → the map (`patterns.map`) and the
   pattern pane (`patterns.pattern`) exist → hover the map at (0,3, 0,4) → the status line reads `row` and `col` and a
   BSE value → screenshot.
2. `testHoverPinAndStep`: hover, Space pins, → steps the column by one, the pattern header reads `pinned` and the new
   column; ⌘P adds to the Patterns tab; the tab shows one pattern.
3. `testVirtualImageGrid`: pick `5 × 5`, click three cells on the pattern pane, the colour mix tile appears in the bottom
   pane and becomes the map on selection; screenshot (the NS-1 shot for the gate).
4. `testTheCalibrationRowsAreTheFiles`: every Calibration row shows the demo file's values as text.
5. `PatternsRealFileJourney` (self-hosted Mac, skips without `$MACEM_DATA`): open an h5oina from the data folder, see
   the map and the pattern.

Screenshots go to `release-assets/sem/patterns/` by the review step.
