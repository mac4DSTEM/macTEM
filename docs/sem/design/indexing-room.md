# The Indexing room: orientations from patterns

2026-11-06. Phase 4 of the SEM program (it waits on the orientation core of phase 3, which has no room). Sidebar
`Indexing` (⌘7, symbol `scope`), subtitle "Hough and dictionary indexing, projection-centre refinement". The verb is
`Index`. The simulation overlay on its pattern pane is `simulation-overlay.md` (phase 6).

## 1. Purpose and the microscopist's tasks

- *Index the scan* (task 12's twin for a map): which orientation and which phase at every scan point, with a confidence;
  Hough indexing (pyEBSDindex: band detection, triplet voting, `EBSDIndexer`) for speed, dictionary indexing (kikuchipy:
  master pattern → dictionary of simulated patterns → normalised cross-correlation) for noisy or binned patterns.
- *Refine*: the orientation and the projection centre at every point or on the mean pattern (kikuchipy's
  `refine_orientation`, `refine_projection_center`, `refine_orientation_projection_center`), so the dictionary result
  reaches the Hough result's angular precision.
- *Judge the result*: the indexed map next to the pattern at any point with the solution's bands drawn over it; the
  confidence and the orientation-similarity map (kikuchipy's `orientation_similarity_map`); where it failed and why.
- *Compare*: Hough vs dictionary vs the vendor's indexing from the file, as maps and as a disorientation histogram.

## 2. What is here

The room needs an EBSD dataset open (`RoomHoldings.ebsd`); it reads the processed patterns from the sidecar when
Processing ran, raw otherwise (the inspector says which). Phases come from the file (Patterns › Calibration) or are
added here from DiffractoKit's `CrystalPresets` and CIF import (the Diffraction room's `Crystal` section, reused). A
master pattern (EMsoft HDF5, kikuchipy's `.h5`) is opened from the `Dictionary` section; the demo Ni master pattern ships.
Dictionary indexing takes every phase on, each against its own dictionary from its own master pattern, and each point
takes the phase whose best match scores highest, as kikuchipy's `merge_crystal_maps` merges the phases' maps (D-SEM-98).

## 3. Layout

```
┌──────────────────────────────┬───────────────────────────────┐
│ Indexed map (main pane)      │ Live pattern pane             │
│ IPF-Z of the current result, │ the hovered/pinned pattern    │
│ or CI, phase, OSM; scan      │ with the solution's Kikuchi   │
│ marker; regions              │ bands and PC drawn over it    │
├──────────────────────────────┴───────────────────────────────┤
│ Bottom pane (no tabs, D-SEM-92)                              │
│  Results: one row per scan point in view (row, col, phase,   │
│   φ₁ Φ φ₂, CI/NCC, fit, bands); selection pins the pattern   │
│  beside Bands (Hough) or Best match (Dictionary)             │
│  Compare in their place while Display › Compare is on:       │
│   maps A and B on one zoom, disorientation histogram A vs B  │
└──────────────────────────────────────────────────────────────┘
```

- **Indexed map**: the result picked in `Display › Map` (`IPF-Z · IPF-X · IPF-Y · Phase · CI · OSM · Fit`), one pixel
  per scan point, the IPF colour key as the legend in the pane's footer beside the scale bar (`OrientationColorKey`);
  before `Index` runs it is the Patterns room's virtual BSE dimmed, with the empty-state sentence "Index to see the
  orientations" (the one verb that fills it). Regions pick where to index (`Apply to · Scan · Region`).
- **Live pattern pane**: as in Patterns (hover follows, pin, Space, arrows); overlays in its transformed container: the
  solution's bands (the geometrical simulation, `simulation-overlay.md`), the PC glyph (draggable here during
  refinement, see §6), the detected Hough bands as thin lines when `Display › Show detected bands` is on.
- **Bottom pane**: `Results` (a `Table`, ⌘C TSV, sorted by column, the selected row pins the pattern; footer: method ·
  phases · PC · validation badge), `Compare` (two results side by side as maps sharing the transform, the
  disorientation angle histogram between them, its median and the fraction over 2°; it takes the bottom pane in place of
  the tables while `Display › Compare` is on, D-SEM-97), `Dictionary` (the master pattern as a
  picture, the simulated pattern for the pinned point's solution, the NCC score; with several phases its header names
  the point's phase, D-SEM-98), `Log` (pyEBSDindex's band-detection
  readout for the pinned pattern: ρ, θ, intensity, width of every band).
- **Scan navigator**: the main map stays the scan: Compare draws its two maps and its histogram in the bottom pane
  (D-SEM-97), so no navigator is needed beside the pattern pane.
- **Status line**: `row 12 · col 40 · Ni · φ₁ 12,3° Φ 44,0° φ₂ 271,5° · CI 0,82 · bands 9 of 9`.
- **Toolbar**: `Index` (⌘↩), Stop in its place; centre display `Hough · 2 341 of 4 125 · 0:08` or `Dictionary · 1 of 3
  chunks · NCC`. A second verb would be `Refine`; it is the same verb with `Method · Refine` picked (DNA 3: one verb;
  refinement is a stage that follows indexing in the same pipeline, so the verb runs the stale stages in order:
  Index → Refine).

## 4. Inspector: Settings

Image-room order: `Calibration · Display · Phases · Method · Hough · Dictionary · Refine · Export`.

**Calibration** (open): value rows: `Patterns · Processed (5 stages)` or `Raw`, `PC · (0,4210, 0,7794, 0,5049) ·
Bruker · Refined` (source named), `Sample tilt`, `Geometry · EBSD`. A link row `Edit in Patterns` is a plain button
(the PC is a Patterns setting; refinement writes it back with source `Refined in Indexing`).

**Display** (open): `Map` segmented would be seven (`IPF-Z · IPF-X · IPF-Y · Phase · CI · OSM · Fit`): a pop-up
`Map`; `Colour key` pop-up `IPF · Euler · Phase colours` with the legend; `Show detected bands` switch; `Show solution`
switch (the overlay); the Display pattern (colormap, histogram, gamma, scale bar) for the scalar maps.

**Phases** (open): the list of phases with name, space group, cell; `Add from file… · Add preset…` width set (the
Diffraction room's `Crystal` controls reused); a phase row has a colour swatch and a switch (indexed or not).

**Method** (open): segmented full width `Hough · Dictionary`; caption `Dictionary needs a master pattern`.

**Hough** (open when Method is Hough): pyEBSDindex's `EBSDIndexer` parameters: `Bands` field (n bands to detect, 9),
`ρ mask` field (fraction), `θ step` field (°), `Band width` field (px), `Vote tolerance` field (°), `Backend` segmented
`CPU · Metal` (the kit's one API; Metal checked against CPU at float32 tolerance). `Vendor PC` caption names the PC
pyEBSDindex sees after conversion (EDAX convention, converted internally).

**Dictionary** (open when Method is Dictionary): for each phase on, a `<phase> master` row with a pop-up of opened ones
and its value row `Ni · 20 kV · Lambert · 1001 × 1001` (D-SEM-98: until one is picked, a phase takes the latest opened of
its space group, one of its name first), then `Open…`; `Angular resolution` field (°, 2 by default; the dictionary size is the
caption: `Dictionary: 100 347 patterns at 2°`); `Metric` segmented `NCC · NDP`; `Keep` field (n best, 1); `Signal
mask` pop-up `None · Circular · From file`; `Chunk` value row (patterns per chunk, chosen by memory).

**Refine** (closed): `Refine` segmented `Orientation · PC · Both`; `Method` pop-up `Nelder–Mead · Powell · Least
squares`; `Trust region` fields (° and PC fractions); `Apply to` segmented `Every point · Mean pattern · Pinned
point`; the PC result as value rows after a run (`PC · (…) · ± (…)`).

**Export** (closed): `Results ang… · Results ctf…` width set (`export-and-reports.md`), `Map…`, `Method JSON…`; `Scale
bar · Colour key` switches.

## 5. Inspector: Info

The dataset's (Patterns › Info) plus `Indexing`: method, phases, PC and its source, the run's time and point count,
the kit versions the numbers come from (pyEBSDindex, kikuchipy, orix pins from `docs/parity.md`).

## 6. Behaviour spec

- **States**: *not indexed*: map dimmed BSE, `Index` enabled when a phase exists, help "Index 4 125 patterns with Hough
  (Ni)"; no phase: `Index` disabled with "Add a phase first". *running*: progress in the centre display, the map fills
  row by row (the result is published per chunk), Stop keeps the indexed prefix and hatches the rest. *indexed*: map,
  results, pattern overlay. *refused*: "Master pattern is for Fe, the phase is Ni" under the Dictionary rows and in
  Output.
- **Hover and pin**: as Patterns; hovering the map updates the pattern pane and the overlay (the solution at that point),
  so the user watches the fit hold or break across a boundary.
- **PC drag**: while `Refine › Apply to · Pinned point` is picked, the PC glyph in the pattern pane is draggable
  (direct manipulation); release previews the simulated bands at the new PC on the pinned pattern and writes the three
  numbers into Geometry as `Typed`; `Index` with `Refine · PC` commits a fit from there.
- **Compare**: `Display › Compare` is a switch; while it is on, the bottom pane shows `A` against `B`, two of the
  results the session holds (the last Hough run, the last Dictionary run, the file's vendor indexing when it lies on
  the scan's grid; Refined joins once the room refines). A pane holds no controls, so the two choices are
  `Display › A · B` pop-ups, shown while Compare is on. The histogram is the disorientation angle per point (orix
  `Orientation.angle_with` with each side's point group, the same number as `Misorientation.angle` for one group) on
  1° bins; the footer gives the median and the fraction over 2° (D-SEM-97).
- **Stale**: a Processing change in Patterns stales Indexing (`●` on `Method`), the map dims, `Index` says "Patterns
  changed: index again"; a Phases change stales too; a Display change never does.
- **Memory**: a dictionary at 1° on a 1001 × 1001 master pattern is ~ 800 000 patterns; the caption names the size and
  the kit chunks by the memory cap; the window never allocates the full dictionary at once.

## 7. Demo data on open

The demo Ni dataset, processed (Patterns' defaults), with the Ni phase from the file and the shipped Ni 20 kV master
pattern; `Method · Hough` with pyEBSDindex's defaults (9 bands). `Index` reproduces NS-3; switching to `Dictionary`
at 2° with `Refine · Orientation` reproduces NS-4.

## 8. Acceptance

- NS-3: the Hough-indexed IPF-Z map equals pyEBSDindex's on the demo scan (orientation per point within the tolerance
  north-star.md states, after symmetry reduction) and the OSM map kikuchipy's; the IPF colours are orix's
  `IPFColorKeyTSL` colours per point within 1/255.
- NS-4: the dictionary-indexed IPF-Z map with the refined PC equals kikuchipy's tutorial result (the refined PC within
  its stated tolerance, the NCC scores within kikuchipy's).
- NS-6 (phase 6): the overlay matches, `simulation-overlay.md`.
- Hough indexing of the demo scan takes under ten seconds on the CPU path on an M1 (budget, nightly).

## 9. Journeys

`IndexingJourney.swift`: (1) launch `--demo-ebsd`, `Index` is enabled with the Ni phase named in its help; (2) click
`Index`, wait on `indexing.map` to show the IPF-Z (the empty sentence is gone), hover the map, the status line reads
three Euler angles and `CI`; screenshot (NS-3 gate); (3) select a Results row, the pattern pane header reads that row
and the overlay is drawn (`indexing.pattern.overlay` exists); (4) `Method · Dictionary`, the caption names the
dictionary size, `Index`, the map fills; `Display › Compare` shows Hough against the file's indexing with a median
under 1° (0.44°; Hough against the 4° dictionary reads 2.4°, the dictionary's grid), then `B · Dictionary`;
screenshot (NS-4 gate); (5) `Export › Results ang…` writes a file the unit tests read back.
