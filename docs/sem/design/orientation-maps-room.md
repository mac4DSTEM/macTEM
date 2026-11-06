# The Maps room: orientation maps, grains and texture

2026-11-06. Phases 3 (the orientation core, which has no room of its own and lands here as maps and pole figures) and 5
of the SEM program. Sidebar `Maps` (⌘8, symbol `map`), subtitle "IPF, phase and KAM maps, grains and their statistics,
pole figures and the ODF". The verb is `Segment`. A map room in the control placement sense: the EDS chassis.

## 1. Purpose and the microscopist's tasks

- *Read the microstructure* (task 22's twin): IPF maps along any sample direction, the phase map, the confidence and
  fit maps, image quality underneath; where the grains are, how big, how misoriented.
- *Local misorientation*: KAM (kernel average misorientation, orix `Misorientation` on the neighbour kernel), GOS
  (grain orientation spread), GND density (the Nye-tensor estimate from the orientation gradient, with its assumptions
  named), grain-boundary maps by angle class (2–5°, 5–15°, > 15°, Σ3 and other CSL twins).
- *Grains*: segmentation by a misorientation threshold with a minimum size (the flood fill orix's examples use, and
  DefDAP's for reference), the grain table (id, phase, area, equivalent diameter, mean orientation, GOS, neighbours),
  the size histogram, the mean grain size by area and by number, with the region tools to pick a subset.
- *Texture*: pole figures for picked `{hkl}` in the sample frame (orix `PoleFigure`-style, from `Vector3d` projections),
  inverse pole figures with the colour key as a legend, the ODF (orix's `ODF`-style kernel density on the fundamental
  zone, as sections), the texture index.
- *Compare*: the vendor's indexing from the file, next to ours (Indexing's Compare tab is the home; here a map is a map).

Every number is orix's with a parity test: `Orientation`, `Rotation`, `Quaternion`, `Symmetry` (the 32 point groups),
`Misorientation.angle`, `Orientation.get_distance_matrix`, `Vector3d`, `IPFColorKeyTSL`, the stereographic projection,
the KAM kernel; grain segmentation is checked against orix's example and DefDAP's `Map.findGrains` on the same data (the
numbers must agree for the same threshold and neighbour rule; `docs/parity.md` names which is the reference). GND is
Pantleon's formulation as DefDAP computes it, with its reference in the Info tab.

## 2. What is here

An indexed result: from Indexing (this session), from the file (vendor indexing in h5oina, Bruker h5, `.ang`, `.ctf`;
an `.ang`/`.ctf` alone opens straight here, `RoomHoldings.orientations`), or from a kikuchipy h5ebsd that carries
`xmap`. `Maps › Source` pop-up picks which result when several exist.

## 3. Layout

```
┌──────────────────────────────┬───────────────────────────────┐
│ Maps block (main pane)       │ Live pattern pane (open by    │
│ the anchor map (IPF-Z) with  │ default): the pattern at the  │
│ the grain boundaries, and    │ hovered point, the solution   │
│ the tiles the Maps control   │ overlay if a solution exists; │
│ picks, one shared transform  │ or the vendor's, no pattern:  │
│                              │ the orientation as a unit     │
│                              │ cell drawing                  │
├──────────────────────────────┴───────────────────────────────┤
│ Bottom pane  tabs: Grains · Pole figures · ODF · Histogram   │
│  Grains: Table, one row per grain; selection outlines it     │
│  Pole figures: {hkl} stereograms of the scan or the region   │
│  ODF: sections φ₂ = const, the texture index in the footer   │
│  Histogram: grain size, KAM, misorientation angle            │
└──────────────────────────────────────────────────────────────┘
```

- **Maps block**: the EDS chassis (`EDXRoom`'s maps block, `MapRaster`, tiles with a title row, the colour bar or the
  colour key as the legend, the display chip, hatching for unindexed points with the count in the footer). The anchor
  tile (regions drawn here) is the `Anchor` the Maps control names, IPF-Z by default; grain boundaries draw over every
  tile as thin lines coloured by angle class once `Segment` ran; the scan marker as in Patterns. One `ZoomableContainer`
  over the block (all tiles follow).
- **Live pattern pane**: open by default, the pattern at the hovered point with the solution overlay
  (simulation-overlay.md) when patterns are open; for a vendor-indexed file without patterns the pane draws the
  orientation as the unit cell in the sample frame (a wireframe cube or hexagonal prism rotated by the orientation,
  the standard EBSD teaching picture) with the IPF colour swatch and the Euler angles underneath; the toggle hides it.
- **Bottom pane**: `Grains` (`Table`: id, phase, area µm², diameter µm, points, φ₁ Φ φ₂, GOS, neighbours, boundary
  classes; ⌘C TSV; selection outlines the grain on every tile and pins the pattern to its centroid), `Pole figures`
  (one stereogram per picked `{hkl}`, points or contoured, the sample axes labelled X Y Z or RD TD ND by the Settings
  choice, the region's subset when one is selected), `ODF` (φ₂ sections at the symmetry's step, shared colour bar, the
  texture index and the max in the footer), `Histogram` (the picked quantity with its bins; grain size by number and by
  area as two bars).
- **Status line**: `row 12 · col 40 · Ni · φ₁ 12,3° Φ 44,0° φ₂ 271,5° · KAM 0,41° · grain 17 · CI 0,82`.
- **Toolbar**: `Segment` (⌘↩): the grain segmentation and everything that depends on it (GOS, grain table, size
  statistics, boundaries), Stop in its place. Maps that need no grains (IPF, phase, KAM, CI) compute on open or on a
  setting change, live, as the EDS room's net-count maps do; they are quick (one pass over the scan).

## 4. Inspector: Settings

Map-room order: `Maps · Tools · Phases · Orientation · Misorientation · Grains · Texture · Export`.

**Maps** (open): `Source` pop-up (`Hough · Dictionary · Refined · File (Oxford)`); `Anchor` pop-up (`IPF-Z · IPF-X ·
IPF-Y · Phase · IQ`); tiles as checkboxes in a list under one caption `Shown` : `IPF-Z · IPF-X · IPF-Y · Phase · CI ·
Fit · IQ · KAM · GOS · GND · Boundaries · Grain ID` (a list, control placement §3); `Filter` switch (the display-only
3 × 3 median for KAM and GND, rule 11, `filtered` tag on the tile); `Legend` segmented `Key · Bar` is derived, not a
control: an IPF tile carries the colour key, a scalar tile the colour bar.

**Tools** (open): `arrow · ▭ · ◯ · ⬠ · ╱` (⌃⌘0–4), regions in the Results area's regions table as EDS; a region limits
the Grains table, the pole figures, the histogram and the statistics to its points.

**Phases** (closed): the phase list with colours (shared with Indexing); `Point group` value row per phase (the
symmetry orix uses, named).

**Orientation** (open): `Reference frame` segmented `X Y Z · RD TD ND`; `IPF direction` is the `Anchor`'s (`Z`) with a
`Custom…` row `u v w` fields; `Colour key` pop-up `TSL · Euler · Axis-angle`; `Convention` pop-up for the Euler angles
(`Bunge ZXZ`, read-only caption: orix's, the file's convention converted on read, named in Info).

**Misorientation** (open): `KAM kernel` segmented `1st · 2nd · 3rd` neighbours; `KAM max` field (°, points above are
excluded, 5 by default); `GND` switch with `Burgers vector` value row (from the phase) and `Step` value row; `Boundary
classes` as three fields `2 · 5 · 15` (°) and a `Twins Σ3` switch with `Brandon tolerance` field.

**Grains** (open): `Threshold` field (°, 5 by default); `Min size` field (points, 10); `Neighbours` segmented `4 · 8`;
`Phase boundaries` switch (a grain never spans a phase); `Fill unindexed` switch (points under the CI cutoff join the
grain around them; off by default: refuse rather than guess, the hatching stays). The verb runs it.

**Texture** (closed): `Pole figures` pop-up of `{hkl}` families with checkboxes (`{100} {110} {111}` default for cubic);
`Projection` segmented `Stereographic · Equal area`; `Contour` switch with `Half width` field (°); `ODF half width`
field (°), `Sections` segmented `φ₂ · φ₁ · Φ`.

**Export** (closed): `Maps… · Figure…` width set; `Grains CSV… · Pole figures…` width set; `ang… · ctf…` width set
(the writers, export-and-reports.md); `Scale bar · Colour key · Boundaries · Regions` switches.

## 5. Inspector: Info

The result's provenance: source, method, phases and point groups, the Euler convention and the conversion applied, the
PC, the kernel and threshold used by the maps shown, the orix pin and the reference for each method (`Misorientation`:
orix; KAM: the kernel definition; GND: Pantleon 2008; grain segmentation: the flood-fill rule; IPF colours: TSL key as
orix implements it), one row each with its reference, the EELS room's `Methods` tag pattern.

## 6. Behaviour spec

- **States**: *no result*: "Index first" with the Indexing verb's name, or the file's indexing when it has one; *maps
  live*: IPF, phase, CI, KAM on open; `Segment` enabled with help "Segment 4 125 points into grains at 5°"; *segmented*:
  grains, boundaries, table, statistics; *stale*: a Grains or Misorientation change stales `Segment` (● on the title),
  the dependent tiles dim; *refused*: "Point group unknown for phase 2: no misorientation" under Phases.
- **Hover**: the pattern pane follows; the status line carries every shown map's value; hovering a grain highlights
  its row in the Grains table (scrolls it into view) and its boundary.
- **Select**: a click on the map at 1× pins and selects the grain under it; the pole figures mark the grain's points in
  the accent; ⌘-click adds grains to the selection; Esc clears.
- **Regions**: drawn on the anchor; the pole figures, histogram and statistics switch to the region (`Pole figures ·
  Region 1 · 312 points`); the Grains table filters to grains with their centroid inside.
- **Unindexed**: points with CI under `Maps › CI cutoff` (a field in Maps, 0,1 default) hatch on every tile with the
  count in the footer and the status line reads `not indexed`.
- **1000 × 1000 performance budget** (phase 9): IPF and phase maps draw under 0,5 s; KAM under 2 s; segmentation under
  5 s with progress; the maps block scrolls and zooms at 60 fps (the tiles are Metal textures; the boundaries one
  `Canvas` keyed on the segmentation, redrawn on zoom only).

## 7. Demo data on open

The demo Ni dataset indexed by Hough (restored from the sidecar by `--demo-ebsd-indexed`, or after `Index` in a drive):
IPF-Z anchor with the TSL key, Phase and KAM tiles, Grains at 5°/10 points, `{100} {110} {111}` pole figures. The
sdss_ferrite_austenite `.ang` from orix is the second demo (`SEM Orientation Map` in the demo menu, `--demo-ang`): it
opens straight into Maps with two phases and no patterns, the pane showing the unit cell.

## 8. Acceptance

- NS-3 (shared with Indexing): the IPF-Z map's colours equal orix's `IPFColorKeyTSL` for the Hough result within 1/255.
- NS-5: the KAM map (1st neighbours, 5° max), the grain map at 5°/10 points and the grain-size statistics (count, mean
  diameter by number and by area, the histogram's bins) equal orix's tutorial numbers on the demo Ni dataset within
  north-star.md's tolerance; the pole figures' point positions equal orix's `Vector3d` stereographic projection within
  float32.
- The two-phase `.ang` shows the phase map with both phases named and coloured as orix reads them.
- Screenshot: the room on the indexed demo data, IPF-Z anchor with boundaries, Grains tab open with a grain selected.

## 9. Journeys

`MapsJourney.swift`: (1) launch `--demo-ebsd-indexed`, `maps.room`, the IPF-Z tile and the colour key exist; hover, the
status line reads `KAM`; (2) `Segment`, the Grains table fills, select the first row, the boundary outline exists on the
anchor (`maps.grain.outline`), screenshot (NS-5 gate); (3) `Pole figures` tab shows three stereograms; a region drawn on
the anchor changes the tab's header to `Region 1`; (4) `Export › Grains CSV…` writes a file with one row per grain; (5)
`--demo-ang`: the `.ang` opens in Maps with two phases and the unit-cell pane.
