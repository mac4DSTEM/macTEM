# The simulation overlay: Kikuchi bands on the experimental pattern

2026-11-06. Phase 6 of the SEM program. Not a room: a layer of the Indexing room's live pattern pane (and of the
Patterns room's, once a solution exists), a `Simulation` section in the Indexing inspector, and the master pattern's own
picture in the Indexing bottom pane's `Dictionary` tab. Decision D3: nine rooms is the ceiling of the digit shortcuts,
and the overlay is a check on the indexing, which is the job the Indexing room has.

## 1. Purpose and the microscopist's tasks

- *Compare with simulation* (task 11): does the solution's geometrical Kikuchi pattern lie on the bands I see? Which
  band is which `{hkl}`, where are the zone axes?
- *Read the master pattern*: what the dynamical master pattern (EMsoft) looks like, in Lambert and stereographic
  projection, which hemisphere, at which kV; what the simulated pattern for a given orientation and PC looks like, next
  to the experimental one.
- *Check the geometry*: a wrong PC or tilt shows as a systematic shift of the simulated bands; the overlay makes the
  Refine step visible.

Ported with parity: kikuchipy's `KikuchiPatternSimulator.on_detector` (geometrical simulation: band lines and zone
axes from a `ReciprocalLatticeVector` list with structure factors from diffsims), the `as_collections` geometry
(line coordinates in detector pixels), `EBSDMasterPattern.get_patterns` (the dynamical simulation of one pattern from
the master pattern by Lambert projection), `plot_spherical`-style projection of the master pattern.

## 2. Where it is drawn

In the live pattern pane's transformed container, over the pattern, in the accent colour, scaled with the zoom:

- band lines (the full Kikuchi band as its centre line, or as the pair of edge lines when `Band width` is on), labelled
  `{111}` at the pane's edge where the line leaves it;
- zone axes as small circles labelled `[101]`;
- the PC glyph `⊕` (shared with Processing's Geometry);
- the simulated dynamical pattern as a half-transparent layer when `Overlay · Dynamical` is picked (the pattern from the
  master pattern at the solution and PC), with a `Blend` slider.

The layer is a SwiftUI `Canvas` the size of the pane mapped through the shader's transform (`MarkGeometry`, the Image
room's marks pattern), redrawn only when the solution, PC or zoom changes; the hovered pattern's texture update does not
redraw the canvas (it is keyed on the solution, not the pattern).

## 3. Inspector: Simulation (Indexing room, after Refine, before Export; closed by default)

| Row | Control |
|---|---|
| Overlay | segmented full width `Off · Geometrical · Dynamical` |
| Bands | field: `hkl` families to draw, by `d` cutoff (`Min d` field, Å) or `Families` pop-up listing the phase's families with checkboxes |
| Band width | switch: draw the two edge lines at the Bragg angle for the beam energy |
| Zone axes | switch; `Label` switch |
| Blend | slider (Dynamical only) |
| Master pattern | value row: the one Dictionary opened (`Ni · 20 kV · EMsoft`), `Open…` is Dictionary's |
| Hemisphere | segmented `Upper · Lower` (for the picture in the Dictionary tab; the simulation uses both) |
| Projection | segmented `Lambert · Stereographic` (the picture) |

The `Dictionary` tab of the bottom pane shows the master pattern in the chosen projection and hemisphere (a picture
with the Display popover), and beside it the simulated pattern for the pinned point's solution with the NCC against the
experimental one in its footer; a click on the master pattern reads the direction under the pointer in the status
line (`[u v w]` and the polar angles).

## 4. Behaviour spec

- The overlay exists only for a point with a solution (indexed, or the vendor's from the file); on a point without one
  the pane shows the pattern alone and the status line reads `not indexed`.
- Hovering the map moves the overlay with the solution at the hovered point, so a grain boundary is seen as the bands
  jumping; the geometrical simulation of one point is sub-millisecond, the dynamical one a few ms (one Lambert
  interpolation per pixel on the GPU or Accelerate), both debounced to the display refresh.
- The PC drag (indexing-room.md §6) previews with this overlay.
- A band family picked in `Families` highlights that family's lines; a click on a line in the pane reads its `{hkl}`
  and its θ in the status line.
- Export: `Pattern with overlay…` (PNG, the pane as drawn, the labels in the figure) joins the Indexing Export section;
  the lines as CSV (`Overlay CSV…`: hkl, x1, y1, x2, y2 in detector px) for a figure made elsewhere.

## 5. Demo data

The demo Ni dataset indexed (Hough), the Ni master pattern at 20 kV, `Overlay · Geometrical`, `{111} {200} {220}
{311}` families by `Min d 1,0 Å`, zone axes labelled: the pinned point (0, 0) reproduces kikuchipy's geometrical
simulation figure (NS-6).

## 6. Acceptance

- NS-6: the line coordinates for the demo pattern (0, 0) at its Hough solution and the file's PC match kikuchipy's
  `as_collections` output within 0,5 px (or north-star.md's tolerance); the zone-axis positions likewise; the
  dynamical simulation matches `get_patterns` within kikuchipy's float32 tolerance.
- Screenshot: the pattern pane at (0, 0) with the geometrical overlay and labels, zoomed 2× to show the lines on the
  bands.

## 7. Journeys

`SimulationOverlayJourney.swift`: (1) launch `--demo-ebsd-indexed` (the demo with its Hough result restored from the
sidecar, so the journey does not index), `Overlay · Geometrical`, `indexing.pattern.overlay` exists with at least four
labelled lines (accessibility children named `{111}` …); screenshot; (2) hover a second grain, the labels change; (3)
`Overlay · Dynamical`, the `Blend` slider appears, the Dictionary tab's simulated pattern shows an NCC above 0,3; (4)
`Export › Pattern with overlay…` writes a PNG.
