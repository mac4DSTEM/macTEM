# Export and reports: writers, figures and the session report

2026-11-06. Phase 8 of the SEM program. Not a room: each room's `Export` section (control placement §4), the Results
room (⌘9) extended with the EBSD session's products, and one new sheet, the **report**. Every export is also a File ›
Export menu item.

## 1. Purpose and the microscopist's tasks

- *Figures and tables* (task 27): a map with its scale bar, colour key or bar, boundaries and regions as drawn, at a
  chosen size and format (PNG, PDF, SVG for the vector overlays); the pattern with its overlay; pole figures and the
  ODF; the grain table and the statistics as CSV; the spectrum and its table.
- *Share and archive* (task 30): the indexed result as `.ang` (EDAX/TSL) and `.ctf` (Oxford HKL) so MTEX, OIM, AZtec
  and DefDAP read it; the orientations with phase, CI, fit, IQ per point; the processed patterns as kikuchipy h5ebsd;
  the method as JSON in the Python packages' names.
- *Say how I got it* (task 28): a session report: what was opened, every stage and its parameters, every figure the
  session exported, the references of the methods, the kit and reference versions, as one Markdown (and PDF) file next
  to the data, with the figures embedded.

The writers are ported from orix (`io.plugins.ang`, `ctf`) and kikuchipy (`h5ebsd` writer) with round-trip parity
tests: write, read back with the Python package in `tools/parity`, compare exact for indices and metadata, within
float32 for angles.

## 2. The Export section of each SEM room

| Room | Buttons (width sets, plain, disabled with the reason) | Switches under them |
|---|---|---|
| Patterns | `Virtual images… · Pattern PNG…` / `Processed patterns… · Method JSON…` / `Metadata JSON…` | `Scale bar` |
| Indexing | `Results ang… · Results ctf…` / `Map… · Figure…` / `Pattern with overlay… · Overlay CSV…` / `Method JSON…` | `Scale bar · Colour key · Show solution` |
| Maps | `Maps… · Figure…` / `Grains CSV… · Pole figures…` / `ang… · ctf…` / `Method JSON…` | `Scale bar · Colour key · Boundaries · Regions` |
| EDS | as today | as today |
| Image | as today | as today |

`Figure…` opens the one figure sheet (mac4DSTEM's `ExportSheet` pattern, `FigureExportSection`): size in px or mm at a
DPI, format `PNG · PDF · SVG`, the tiles to include as checkboxes (the shown ones picked), the legend placement
`Right · Below · None`, the scale bar's length (auto or typed), a title line, and a preview at the sheet's left. The
sheet remembers its choices per room in `SceneStorage`.

`ang…` writes the TSL header (orix's writer: the phases with their symmetry and lattice, the grid, the step, `x y`
columns in µm, Euler angles in radians, IQ, CI, phase index, detector signal, fit) from the picked `Maps › Source`;
`ctf…` writes the HKL Channel 5 header (Euler in degrees, Bands, Error, MAD, BC, BS); a result without a column (no IQ
for a vendor map without it) writes the writer's documented placeholder value and says so in Output.

## 3. The Results room

The Results room lists the window's products as today (measurements, particles, FFT, diffraction, EDS, EELS). The EBSD
session adds its rows: the virtual images, the processing run, each indexing result, the grain segmentation, the pole
figures, each exported figure, with the time, the parameters' one-line summary and the file written. Selecting a row
shows its summary at the right; the row's context menu has `Show in Finder` and `Export again…`. The one full-width
button at the bottom of its inspector is `Report…`.

## 4. The report

`Report…` (Results room, also File › Export › Session Report…) opens a sheet: `Include` checkboxes (`Opened files ·
Calibration · Processing · Indexing · Maps and grains · Texture · Spectra · Figures · Methods and references ·
Versions`), `Format` segmented `Markdown · PDF`, `Figures` segmented `Embed · Link`, a title field, a preview of the
outline, `Export…`. The report is one file (`<dataset> report.md` with a `figures/` folder, or one PDF) with:

1. title, date, app version, the user's name from the Mac (optional switch);
2. per opened file: path, format, size, the Calibration rows, the Acquisition rows;
3. per stage run: the section's rows as a table, the time, the Output lines it logged;
4. the results: the indexing summary (points, indexed fraction, mean CI, PC), the grain statistics, the composition
   table; each with its validation badge;
5. the figures exported in the session, embedded at their exported size with their captions (room, source, settings);
6. methods and references: one paragraph per method used, the reference as the Info tab names it (the EELS room's
   `EELSLiterature` pattern, an `EBSDLiterature` for the SEM methods), the Python package and version the parity tests
   compared against;
7. versions: macEM, the kits, the parity references, the date of the reference run.

The report never contains a number that is not on screen or in an export; it is assembled from the session's lineage
(the Results rows) and the method JSONs, not recomputed.

## 5. Behaviour spec

- Every export button is disabled with its reason until its product exists ("Grains need Segment first"); the File
  menu items mirror the state.
- An export writes next to the data by default with the file's name and a suffix (`name results.ang`, `name IPF-Z.png`,
  the EELS room's suffix pattern), through the save panel; the Output pane logs the path; the Results room gets a row.
- `Figure…`'s preview is the export at reduced size; what is drawn is what is written (the overlays, legend and scale
  bar are rendered by the same code path at the export's scale, not screenshots).
- The `ang`/`ctf` writers refuse a result with more than one phase whose symmetries the format cannot name, with the
  sentence.
- The report opens in the default Markdown or PDF app after writing (a switch in the sheet, on by default).

## 6. Acceptance

- Round trips: the demo Ni Hough result written as `.ang` and `.ctf` reads back in orix with equal orientations (within
  float32 after symmetry reduction), phase, CI and IQ exact; the processed patterns written as h5ebsd read back in
  kikuchipy equal byte for byte.
- Figures: the IPF-Z figure of the demo at 1200 px with the key and scale bar is pixel-identical between two exports
  and matches the screen's tile within colour-management tolerance; the SVG overlay opens in Inkscape with the lines
  as paths.
- The report of the gate drive (open demo → process → index → segment → export two figures) contains every section
  with its numbers equal to the screen's, and is the phase 8 gate artefact posted next to the reference values.

## 7. Journeys

`ExportJourney.swift`: (1) launch `--demo-ebsd-indexed`, Indexing › `Export › Results ang…` writes a file in the
journey's temp folder (the save panel is bypassed by the `--export-to` launch option, as the existing export journeys
do), the unit test reads it back; (2) Maps › `Figure…`, the sheet's preview exists, `Export…` writes a PNG whose size
is the typed one; screenshot of the sheet; (3) Results › `Report…`, `Markdown`, `Export…`, the file contains the
headings `Processing`, `Indexing`, `Methods and references`; (4) each disabled export button's help names its reason
on a fresh `--demo-ebsd` launch.
