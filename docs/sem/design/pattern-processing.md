# Pattern processing: the Processing sections of the Patterns room

2026-11-06. Phase 2 of the SEM program. The Patterns room (`ebsd-patterns-room.md`) grows a pipeline: background
removal, binning, normalisation, FFT filters, and the projection centre with its convention and the TKD geometry.
It is one room because processing is a stage of seeing the patterns, as the EELS room's Processing section is of
seeing the spectrum; the verb `Process` runs the stale stages in order (`EELSSession.stages` is the pattern).

## 1. Purpose and the microscopist's tasks

- *Check data quality* (task 3): remove the static background (the detector's shading) and the dynamic one (the
  pattern's own low-frequency intensity) so the bands show; see the before and after on one pattern.
- *Prepare for indexing* (task 20's EBSD twin): bin to speed indexing, normalise intensities, filter with an FFT
  window, crop the detector; a clean pattern set for the Indexing room.
- *Know the geometry* (task 5's twin): the projection centre (PC) in a named convention, the detector and sample
  tilts, TKD's negative tilt and the transmission geometry; the same PC in any of the four conventions.

Every stage is a kikuchipy function ported with a parity test: `remove_static_background`, `remove_dynamic_background`
(Gaussian and spatial), `rescale_intensity`, `normalize_intensity`, `fft_filter` with `Window`, `downsample`, `crop`,
`average_neighbour_patterns`, `adaptive_histogram_equalization`; the PC conversions are kikuchipy's `EBSDDetector`
convention table. Tolerances are kikuchipy's own test tolerances (`docs/parity.md`).

## 2. Layout

The Patterns room's; two additions:

- The **live pattern pane** shows the raw or the processed pattern. The choice is a `Display` row of the inspector,
  `Pattern · Raw · Processed` (a pane header holds words only, control placement §1), and the pane's sentence says
  which (`Pattern · row 12 · col 40 · processed`). Default `Processed` once a stage ran.
- The **bottom pane** gains a `Processing` tab: the pinned pattern before and after, side by side, and under them the
  pattern's intensity histogram raw and processed (the `IntensityHistogram` pattern), so a stage's effect is checked on
  one pattern before the whole scan is processed (NS-1's second half).

Processing a whole scan writes a processed copy next to the file in the session sidecar
(`<file>.mactem.h5`, the existing sidecar, a `processed` dataset chunked by pattern) so Indexing reads processed
patterns without recomputing; the sidecar's size is named in Output ("Processed patterns: 15,4 MB in name.mactem.h5").
Stop keeps the processed prefix and marks the stage stale.

## 3. Inspector sections

Inserted between `Virtual images` and `Export`, in dependency order, one section per stage; the stage's state is on its
title row (`●` stale, `✓` current, `—` not run, the EELS room's glyphs); a refused stage shows the kit's sentence under
its rows and in Output.

**Geometry** (open; above the stages because the PC is a setting of the detector, not a stage): the projection centre
and the tilts, editable.

| Row | Control |
|---|---|
| Convention | pop-up `Bruker · EDAX · Oxford · EMsoft` (six would be a pop-up anyway; four is for the titles' length) |
| PC x · PC y · PC z | three number fields in one row, in the chosen convention; typing converts and stores the kit's internal (Bruker) values |
| Sample tilt | field, `°`; `70` default for EBSD |
| Detector tilt | field, `°` |
| Geometry | segmented full width `EBSD · TKD`; TKD sets sample tilt `−20°` (typed values win), names the transmission geometry in the caption `TKD: beam passes the foil; the pattern is formed below it` and flips the kit's `tilt` sign as kikuchipy's `EBSDDetector` does |
| Source | value row: `The file (Bruker)` / `Typed` / `Refined in Indexing` |
| Reset to the file's | one full-width button, disabled with "The file states no projection centre" |

The PC is drawn on the pattern pane as a glyph (`⊕`) in the pane's transformed container; it is not draggable here
(refinement is Indexing's job). The four conventions agree on the demo file's PC within the kit's tolerance, tested.

**Static background** (open): `Source` pop-up `The file's · The scan's mean · A file…`; `Operation` segmented `Subtract ·
Divide`; `Run` is the room's verb, not a button here. Caption: `The demo dataset carries its static background`.

**Dynamic background** (closed): `Filter` segmented `Gaussian · Spatial`; `Operation` segmented `Subtract · Divide`;
`Std` field (px), `Truncate` field.

**Intensity** (closed): `Rescale` switch with `Low · High` percentile fields; `Normalise` switch with `Mean · Std`
fields; `Equalise` switch (adaptive histogram equalisation, kernel field).

**FFT filter** (closed): `Window` pop-up `Gaussian · Hanning · Hamming · Tukey · Rectangle · Custom…`; `Shape` row `w ×
h` px; `Pass` segmented `Low · High`; the window is drawn in the Processing tab over the pattern's FFT while this section
is open.

**Size** (closed): `Bin` segmented `1 · 2 · 4 · 8`; `Crop` row `top · bottom · left · right` px fields; `Average
neighbours` switch with `Window` pop-up `3 × 3 · 5 × 5 · Gaussian`.

**Apply to** (a row at the top of Static background, once): segmented `Scan · Region`, with the region named in the
caption when `Region`. Regions and the Tools section arrive with this phase (Tools under Display).

As built (D-SEM-82): the FFT filter's `Pass` is `Low · High · Band` with cutoff and width fields (kikuchipy's lowpass and
highpass), not a window pop-up; `Average neighbours` is its own section after Size, run by Process over the scan.

The dependency order is Static → Dynamic → Intensity → FFT filter → Size → Average neighbours → NLPAR; a change in one stales it and every later
stage; the title glyphs say so and `Process`'s help names the first stale stage (`Run the stages that are not current,
starting with Dynamic background`).

## 4. The verb

`Process` (⌘↩) in the toolbar, Stop in its place; the centre display reads `Dynamic background · 2 341 of 4 125 ·
0:12`; the infobar's run readout carries the bar. While running, the map dims and the pattern pane keeps showing (the
processed pattern updates as its position is reached). ⌘. stops.

## 5. Behaviour spec

- On open nothing has run: every stage `—`, the pattern pane shows raw, the Processing tab shows the pinned pattern twice
  with "Processed: nothing yet".
- Changing a stage's row previews it on the pinned pattern in the Processing tab at once (one pattern is cheap: the
  preview is the kit on one pattern, on the main actor's behalf off it, debounced 100 ms) and marks the stage stale for
  the scan; `Process` commits it to the scan.
- The virtual images are of the raw patterns (they are the file's sums) unless `Virtual images › Source` says
  `Processed`; the row appears with this phase.
- A refused stage (a static background whose shape is not the pattern's: "Static background is 480 × 480, the patterns
  are 60 × 60") shows the sentence under its rows, in Output, and `Process` skips it and the later stages.
- Export gains `Processed patterns…` (kikuchipy h5ebsd, the sidecar's dataset copied out) and `Method JSON…` (every
  stage's parameters in kikuchipy's names, so a user reproduces the run in Python).

## 6. Demo data

The demo Ni dataset with its static background: `Static background · The file's · Subtract`, `Dynamic background ·
Gaussian · Subtract · Std 8` are the defaults kikuchipy's tutorial uses, so `Process` on open reproduces NS-1's
processed pattern (0, 0).

## 7. Acceptance

- NS-1 (second half): pattern (0, 0) after static and dynamic background removal matches kikuchipy's within tolerance;
  the Processing tab's before and after is the gate screenshot.
- Every stage's parity test passes at kikuchipy's tolerance on the demo scan; the PC conversion round-trips the four
  conventions to float32 precision; the TKD geometry reproduces kikuchipy's `EBSDDetector(tilt=-20)` PC.
- Processing the whole demo scan takes under five seconds on an M1 (performance budget, measured in the nightly).

## 8. Journeys

`PatternProcessingJourney.swift`: (1) launch `--demo-ebsd`, open the Processing tab, the before and after are equal
("nothing yet"); (2) `Process`, the stage titles turn `✓`, the processed pattern differs from the raw (the histogram's
mean moved), screenshot (NS-1 gate); (3) change `Std` to 12, the Dynamic background title shows `●`, the preview
changes, `Process` clears it; (4) `Geometry · TKD` sets the sample tilt to −20 and the caption; (5) `Export ›
Method JSON…` writes a file naming every stage.
