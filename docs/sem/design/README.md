# The SEM rooms of macEM: design

2026-11-06. Phase 0 of the SEM program (Paul's spec of 2026-11-06 19:34). One document per room, in the style of the
shared designs (`design-dna`, `control-placement`, `workspace-alignment`, `microscopist-task-map`, the EELS room
design) and matching how macTEM's rooms are built today (`WorkspaceArea`, `RoomAvailability`, `WorkspaceView`,
`WorkspaceInspector`, the EDS chassis of MacEMUI). No code in this folder: a room PR carries its doc as the check for
each drive, and the review step compares the room's screenshots with the doc.

The suite's standards win on a conflict: the design DNA (what the apps feel like) and the control placement
standard (where every control sits), both in the suite's `process/` folder. A room that departs from a rule says so in one
sentence in its PR description. Open questions were decided here and logged in `docs/decisions.md`; nothing waits for
Paul.

## The rooms

| Doc | Room in the sidebar | Program phase | What it does |
|---|---|---|---|
| [`sem-image-room.md`](sem-image-room.md) | Image (the TEM Image room, extended) | 1 | a Tescan, Zeiss or Thermo SEM TIFF with its metadata, databar, detector and beam conditions; measure, particles, FFT as today |
| [`ebsd-patterns-room.md`](ebsd-patterns-room.md) | Patterns (new) | 1 | the EBSD/TKD dataset: the scan map with a virtual BSE image, the live pattern pane, pattern browsing |
| [`pattern-processing.md`](pattern-processing.md) | Patterns (its pipeline sections) | 2 | static and dynamic background, binning, normalisation, FFT filters, the projection centre incl. TKD geometry |
| [`indexing-room.md`](indexing-room.md) | Indexing (new) | 4 | Hough and dictionary indexing against master patterns, refinement of orientation and projection centre |
| [`simulation-overlay.md`](simulation-overlay.md) | Indexing (a layer of its pattern pane) and Patterns | 6 | the kinematic Kikuchi overlay and the geometrical simulation on the experimental pattern |
| [`orientation-maps-room.md`](orientation-maps-room.md) | Maps (new) | 3, 5 | IPF, phase, KAM, GOS, GND, grains with statistics, pole figures and the ODF |
| [`sem-eds-room.md`](sem-eds-room.md) | EDS (the shared EDS room, extended) | 7 | SEM-EDS spectra and spectrum images, quantification with exspy parity |
| [`export-and-reports.md`](export-and-reports.md) | Results (extended) and each room's Export section | 8 | ang and ctf writers, maps and figures with scale bars, the session report |

Eight documents, three new rooms. SEM imaging, SEM-EDS and export live in rooms that exist, because the job is the
same job on a different file (design DNA 2: add a room only when a need fits none). Pattern processing and the
simulation overlay are documented apart from their rooms because each is one phase's PR set and one gate; in the
window they are sections and layers of the Patterns and Indexing rooms.

## The sidebar after the SEM rooms

`WorkspaceArea` lists the rooms in the order of the work; `shortcutDigit` is derived from that order, so inserting a
room moves the digits after it. The order becomes

`Image ⌘1 · FFT ⌘2 · EDS ⌘3 · EELS ⌘4 · Diffraction ⌘5 · Patterns ⌘6 · Indexing ⌘7 · Maps ⌘8 · Results ⌘9`

Results moves from ⌘6 to ⌘9 (decision D1 below). Nine rooms is the ceiling of one-digit shortcuts; the SEM program
adds no tenth. The rooms list is always fully in view (`WorkspaceSidebar`), so `LayoutPolicy.sidebarRoomsListHeight`
grows by three rows.

**The file decides the room** (`RoomAvailability`): `RoomHoldings` gains `ebsd` (a pattern dataset open or opening) and
`semImages` (every open image is an SEM micrograph). With an EBSD file open, Patterns, Indexing and Maps are enabled;
Image, FFT and Diffraction are disabled with "No file open holds an image" unless a micrograph is open too (a file
browser session holds both); EELS says "No file open holds an EELS spectrum image". With an SEM micrograph open,
Diffraction is disabled with "The open images are SEM micrographs, not diffraction patterns". A room keeps its data
when the user switches rooms: the EBSD session is the window's (`AppState.ebsd`, a `TEMSession` owner like `eels`).

Indexing and Maps are entered before anything is indexed: Indexing is where the verb is, and Maps shows vendor-indexed
orientations from a file that carries them (an .ang, .ctf, h5oina with indexed data) without a run. A room with
nothing to show yet shows its empty state with the one verb that fills it (DNA, *States*).

## Common shape of every SEM room

Every room is the macTEM chassis: sidebar · centre · inspector · infobar with the process area (Output). Inside the
centre the three new rooms share one arrangement, the browser arrangement of mac4DSTEM's Imaging room:

```
┌─────────────┬──────────────────────────────┬───────────────┬───────────────┐
│ Sidebar     │ Main pane (the map)          │ Live pattern  │ Inspector     │
│ rooms       │ the scan as a map with the   │ pane (open by │ Settings·Info │
│ open files  │ scan marker and regions      │ default)      │ sections in   │
│             │                              │               │ the standard  │
│             ├──────────────────────────────┴───────────────┤ order         │
│             │ Bottom pane: results (table · profile ·      │               │
│             │ pole figure · histogram), tabs per room      │               │
├─────────────┴──────────────────────────────────────────────┴───────────────┤
│ Infobar: status line (readout) · run · glance · pane toggles   Output pane │
└────────────────────────────────────────────────────────────────────────────┘
```

- **Main pane**: the map of the scan (virtual BSE in Patterns, the indexed map in Indexing, the chosen map in Maps);
  the anchor where regions and the scan marker are drawn; one `ZoomableContainer`; a scale bar in its `PaneFooter`.
- **Live pattern pane**: the pattern at the scan position under the pointer while it hovers the map, the pinned
  position otherwise; open by default; the toggle is in the infobar's pane toggles (⌃⌘P) and the View menu; it carries
  the overlays of its room (the projection centre, the Kikuchi bands, the indexed solution) in one transformed
  container so the overlays stay pixel-accurate at any zoom, as mac4DSTEM's `ImagePanes` does.
- **Bottom pane**: results beside the data, never in the inspector (control placement §1): tabs per room, selection
  drives the map and the pattern together; `PaneSplit` with a stored fraction.
- **Inspector**: the standard orders. Patterns and Indexing are image rooms (`Calibration · Display · <stages> ·
  Export`), Maps is a map room (`Maps · Tools · <pipeline> · Export`). Sections are one word, the same word in both
  apps.
- **Toolbar**: the room's one verb (`Process`, `Index`, `Segment`), Stop in its place, ⌘↩; the centre display names the
  file · room · size, then the running stage with its bar and ETA.
- **Status line**: `row 42 · col 17 · BSE 1 203 · φ₁ 12,3° Φ 44,0° φ₂ 271,5° · Ni · CI 0,82`: the hovered position
  first, every map's value at that position after it, in one line (control placement §7). No chip on a tile.
- **Keys**: ⌘1–9 rooms; ⌘↩ verb; ⌘. stop; ← → ↑ ↓ step the scan position by one pixel while the map has focus, ⇧ by
  ten; Space pins and unpins the pattern; ⌃⌘0–4 tools; ⌘+ ⌘− ⌘0 zoom.

## Shared components to reuse from macTEM and MacEMUI

Reused as they are, named so a room PR links the existing type instead of a twin:

| Need | Reuse | Where |
|---|---|---|
| window shell, sidebar, inspector frame, infobar, process area, run readout | `WorkspaceColumn`, `WorkspaceSidebarFrame`, `WorkspaceRoomsSection`, `WorkspaceInspectorFrame`, `InfobarRunReadout`, `InfobarGlance`, `PanelNavigation` | MacEMUI ShellLayout |
| the one verb | `PrimaryActionButton`, `RoomPrimaryAction`, `BusyOperation` | ShellLayout, `macTEM/UI/RoomPrimaryAction.swift` |
| the picture, zoom and pan, scale bar, histogram | `MetalImageView`, `ZoomableContainer` / `ZoomPan`, `PaneFooter`, `ImageScaleBar`, `DisplayControls`, `IntensityHistogram` | ShellMetal, ShellControls, TEMCore |
| inspector rows and sections | `InspectorSection`, `InspectorRow`, `InspectorValueRow`, `InspectorWarning`, `InspectorNote`, `InspectorScrollColumn` | ShellInspector |
| the maps block, tiles, colour mix, regions, display popover, display filter | the EDS chassis: `EDXRoom`'s maps block, `MapRaster`, `MapColoring`, `MapAppearance`, the regions table of the Results area | ShellEDXModel, ShellSpectroscopy; `EELSRoom.swift` shows the reuse |
| region tools and the regions list | the EDS `Tools` segmented control and regions table (`arrow · ▭ · ◯ · ⬠ · ╱`) | ShellSpectroscopy |
| the room's compute seam | the EELS pattern: a `TEMCore/<Room>/` folder calling the kit with the room's choices, a `TEMSession` owner (`EELSSession`) with stages, `isComputing`, `progress`, `stop()` | `Sources/TEMCore/EELS`, `Sources/TEMSession` |
| opening a file, the read off the main actor, the item list | `AppState.open(urls:)`, `ImageOpening`, `OpenItems`, `FileInventory` | `macTEM/App`, TEMCore |
| metadata in the Info tab | `AcquisitionMetadata`, `ImageRoomAcquisition` | TEMCore, `macTEM/UI` |
| measure, marks, particles, lineage on an image | the Image room's sections and `ImageRoomTools` | `macTEM/UI/ImageRoom*.swift` |
| exports | `EELSExportKind` pattern, `ResultsCSV`, `FFTExport`, `EDXFigureContent` for a figure of tiles | TEMCore, ShellEDXModel |
| demo data | `DemoDocument` and `DemoDocuments` (Help › Open Demo Data, `--demo-<name>` launch options, the same path for the menu and the journeys) | `macTEM/App/DemoData.swift`, TEMSession |
| the periodic table and the EDS pipeline | the shared EDS room (`ShellEDXModel`, `ShellSpectroscopy`), SpectroKit | MacEMUI, SpectroKit |
| journeys and screenshots | `Journey` (launch with demo arguments, `step` attaches a screenshot, waits never sleep, identifiers never labels), `tools/lib/ui-screenshots.sh` | `macTEMUITests/Support` |

New in the program, built once and shared by the three rooms (all in the macTEM repo; the kits, MacEMUI and
mac4DSTEM are untouched, Paul's rule):

- `TEMCore/EBSD/`: the readers' seams, the pattern dataset model (`PatternDataset`: scan shape, pattern shape, step,
  the pattern at (row, col) read on demand through a cache, the static background, detector geometry), the processing
  pipeline, orientations and symmetry, Hough and dictionary indexing, maps and grains. Every function has a parity test
  against `tools/parity` references (kikuchipy, pyEBSDindex, orix) at the tolerance stated in `docs/parity.md`.
- `TEMSession/EBSDSession`: the window's EBSD owner: the dataset, the processing stages with their state (current ·
  stale · refused), the indexing result, the maps, the grains, regions, the selected and hovered scan positions.
- `macTEM/UI/ScanMapPane`, `LivePatternPane`, `ScanNavigator` (the thumbnail with the marker, drawn beside a pane that
  is not a map of scan positions, as mac4DSTEM's `ScanNavigatorPlacement`), `PoleFigurePane`, `GrainTable`.
- `macTEM/UI/OrientationColorKey`: the IPF colour key legend as a view, the one legend for maps, tables and exports.

## Demo data

One EBSD dataset and one SEM-EDS spectrum ship in the app and are the data of every journey and screenshot. They are
the north-star data the parity thread chose and licenses (`docs/data-sources.md`, `docs/sem/north-star.md`):

- **the demo Ni dataset**: kikuchipy's `nickel_ebsd_large` (`patterns_v2.h5`, kikuchipy h5ebsd): a 55 × 75 scan of
  60 × 60 uint8 patterns, 15.4 MB, CC BY 4.0, Aanes et al. 2019 (Zenodo concept DOI 10.5281/zenodo.7497682), NORDIF
  UF-1100, recrystallised Ni; with its static background and the Ni master pattern at 20 kV;
- **the demo SEM-EDS spectrum**: exspy's `EDS_SEM_TM002`, the BAM EDS-TM002 thin-film standard (C, Al, Mn, Cu, Zr on
  Si), Zeiss Nvision40 at 10 kV, Oxford X-Max 80, one 1024-channel spectrum at 10 eV per channel, 31 KB;
- **the demo SEM micrograph**: one Tescan, Zeiss or Thermo TIFF with a databar and full metadata from a public source
  the parity thread records in `docs/data-sources.md` (decision D5).

The welcome window's Help › Open Demo Data menu gains `EBSD Pattern Dataset` (opens in Patterns), `SEM Micrograph`
(Image) and `SEM-EDS Spectrum` (EDS). A journey launches with `--demo-ebsd`, `--demo-sem-image`, `--demo-sem-eds`.

The north-star figures, in milestone order (north-star.md owns the numbers and tolerances):

| Figure | What | Reference | Room |
|---|---|---|---|
| NS-1 | virtual BSE image from a 5 × 5 detector grid, RGB from three tiles; pattern (0, 0) before and after static and dynamic background removal | kikuchipy | Patterns |
| NS-2 | image-quality and mean-intensity maps | kikuchipy | Patterns |
| NS-3 | Hough-indexed IPF-Z map and the orientation similarity map | pyEBSDindex, kikuchipy | Indexing, Maps |
| NS-4 | dictionary-indexed IPF-Z map with the Ni 20 kV master pattern and the refined projection centre | kikuchipy | Indexing |
| NS-5 | KAM map, grain map and grain-size statistics | orix | Maps |
| NS-6 | geometrical Kikuchi simulation over an experimental pattern | kikuchipy | Indexing |
| NS-7 | SEM-EDS line intensities with background windows, and the quantification table | exspy | EDS |

## Reference bundles

The parity harness (`tools/parity/sem`, north-star.md) emits one reference bundle per figure; a room's acceptance
test reads the bundle by name. The figures above map to the bundles so:

| Figure | Bundle(s) | Holds |
|---|---|---|
| NS-1 | `m1/read-nickel-ebsd-large`, `m1/vbse-nickel-ebsd-large`, `m2/background-nickel-ebsd-large` | scan facts (55 × 75, 60 × 60 px, PC per pattern, static background, one-phase crystal map); the grid images, the RGB mix, the ROI, the mean-intensity map; pattern (0, 0) after static and dynamic background |
| NS-2 | `m1/vbse-nickel-ebsd-large` | the mean-intensity map (image quality joins the m2 bundle) |
| NS-3 to NS-6 | the m3 to m6 bundles north-star.md lists | indexing, refinement, grains, overlay |
| NS-7 | `m7/eds-lines-tm002` | Al Kα, C Kα, Cu Lα, Mn Lα, Zr Lα intensities with background windows |
| readers | one reader bundle per format (h5oina, Bruker h5, EDAX, Oxford, NORDIF, EMsoft, kikuchipy) | exact scan facts and the first pattern |

## Acceptance

Each room's doc ends with its acceptance in terms of the north-star figures (`docs/sem/north-star.md`, written by the
parity thread; figure numbers NS-n are its). A room is done when

1. its journeys pass on the hosted runner and the self-hosted Mac, with screenshots in `release-assets/sem/<room>/`;
2. the review step finds no difference between the screenshots and this doc's layout and control placement, or has
   filed the differences as issues before the next task;
3. the figure its phase owns matches the reference within the tolerance north-star.md states, computed in the app from
   the demo data end to end from the welcome window;
4. Paul has driven it on a real dataset (the suite's UI rule): the nightly review posts the drive request with the
   room's first build.

## XCUITest journeys

Every room ships with journeys in `macTEMUITests/<Room>Journey.swift`, on the demo data, in the `Journey` pattern:
launch with the demo argument, enter the room by its sidebar identifier (`workspace.patterns`), wait on identifiers,
attach a screenshot per step. Identifiers follow the existing scheme: `<room>.room`, `<room>.map`, `<room>.pattern`,
`<room>.results`, `settings.<room>` for the inspector scope, `status.bar` for the readout. Each doc lists its journeys.

## Decisions

Decided here, 2026-11-06, without Paul (his rule for the program); `docs/decisions.md` points at this list. Each can be
reversed by a one-line PR to the doc it touches.

- **D1 Rooms and digits.** Three new rooms, `Patterns · Indexing · Maps`, inserted before Results; the order is
  `Image ⌘1 · FFT ⌘2 · EDS ⌘3 · EELS ⌘4 · Diffraction ⌘5 · Patterns ⌘6 · Indexing ⌘7 · Maps ⌘8 · Results ⌘9`. Results
  moves from ⌘6 to ⌘9 because `shortcutDigit` is derived from the list order and Results is last in the work. Nine is
  the ceiling: no tenth room in the program.
- **D2 SEM micrographs are Image-room documents.** No SEM Image room; the Image room reads the vendors' metadata and
  hides the databar; Diffraction is disabled for them with a reason. One job, one room.
- **D3 No Simulation room.** The kinematic and dynamical overlays are a layer of the Indexing room's pattern pane with a
  `Simulation` inspector section; the master pattern is a tab of its bottom pane. The overlay is a check on the
  indexing, and a tenth room has no key.
- **D4 The live pattern pane follows the pointer.** Open by default in all three rooms; the pattern under the pointer
  while it hovers the map, the pinned position otherwise; a click or drag at 1× scrubs, Space pins, arrows step, ⌥
  ghosts the hovered over the pinned. Toggle ⌃⌘P in the infobar's pane toggles and the View menu. This is mac4DSTEM's
  browser with hover added, the "live view: preview, then commit" pattern of the design DNA.
- **D5 Demo data.** The demo Ni dataset (kikuchipy `nickel_ebsd_large`, CC BY 4.0) with its static background and Ni
  20 kV master pattern, orix's `sdss_ferrite_austenite.ang`, exspy's `EDS_SEM_TM002`, and one public SEM TIFF with a
  databar; all listed in `docs/data-sources.md` by the parity thread, which owns the licence check. Launch options
  `--demo-ebsd`, `--demo-ebsd-indexed`, `--demo-ang`, `--demo-sem-image`, `--demo-sem-eds`.
- **D6 Processed patterns live in the session sidecar.** `Process` writes the processed scan into `<file>.mactem.h5`
  (the existing sidecar) as a chunked dataset; Indexing reads it; the Hough result is stored there too, so
  `--demo-ebsd-indexed` restores without indexing. Nothing is written into the user's data file.
- **D7 Bulk SEM-EDS quantification.** Phase 7 reproduces exspy's thin-film figure with the existing Cliff-Lorimer path
  and k-factors; a full ZAF or φ(ρz) for bulk is a SpectroKit ask recorded in `docs/parity.md`, not built in the app
  (the kits are frozen for the program). The bulk path shipped is named `Cliff-Lorimer (bulk, absorption)` and badged
  `validation: none` until a bulk standard is measured.
- **D8 One verb per room.** `Process` (Patterns), `Index` (Indexing; refinement is a stage the same verb runs after
  indexing when `Refine` is picked), `Segment` (Maps; the maps that need no grains are live). No second button.
- **D9 Two docs are not rooms.** `pattern-processing.md` and `simulation-overlay.md` describe sections and layers of the
  Patterns and Indexing rooms, kept apart because each is one phase's PR set and gate.
- **D10 Grain segmentation reference.** Grains are segmented by the flood fill over the misorientation threshold with a
  minimum size and the 4- or 8-neighbour rule; the parity reference is orix's example implementation, cross-checked
  against DefDAP's `findGrains` on the same data; `docs/parity.md` records which numbers each test holds.
