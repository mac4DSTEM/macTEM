# SEM-EDS in the EDS room

2026-11-06. Phase 7 of the SEM program. Not a new room: the EDS room (⌘3) is MacEMUI's shared room (`ShellEDXModel`,
`ShellSpectroscopy`) over SpectroKit, the same in both apps. What the program adds, in the macTEM repo only, is the
opening of SEM-EDS files (single spectra and spectrum images from Bruker, Oxford, EDAX and Thermo exports, and
HyperSpy/exspy `.hspy`), the SEM words and conditions (kV, take-off angle, tilt, detector, live time), and the
quantification of bulk SEM spectra with parity against exspy. The kits are untouched (Paul's rule): every number the
room needs that SpectroKit lacks is computed in `TEMCore/EDX/` with its parity test, and is listed as a SpectroKit ask
in `docs/parity.md` for after the program.

## 1. Purpose and the microscopist's tasks

- *Which elements* (task 15): peaks in the spectrum, lines identified, maps when it is a spectrum image; Auto ID as
  today.
- *How much of each* (task 16) for a bulk SEM sample: line intensities with background windows (exspy's
  `get_lines_intensity` with `background_windows`), k-ratios against a standard, ZAF or φ(ρz) quantification
  (exspy's `quantification` with `method="CL"`, `"zeta"` and `"cross_section"` for thin films; for bulk, the
  Cliff-Lorimer path with the kit's absorption correction, named as such and badged `validation: none` until a bulk
  standard is measured; a full ZAF is a SpectroKit ask, decision D7).
- *Across an interface* (task 17): the line tool and the Profile tab, as the EDS room has them.
- *Thin-film standards*: the demo TM002 is a thin film on Si, so exspy's tutorial numbers (line intensities, the
  Cliff-Lorimer table with exspy's k-factors) are the north-star figure (NS-7) and the room reproduces them with the
  existing Cliff-Lorimer path.

## 2. What opens here

Beside the Velox and GMS spectrum images: Bruker `.bcf` (rosettasciio's reader ported: the spectrum image and its SEM
image, the conditions), Oxford `.h5oina` with an EDS group (the same HDF5 layer as the EBSD reader), EDAX `.spd`/`.spc`
with `.ipr`, EMSA `.msa` (already), HyperSpy `.hspy` with an `EDS_SEM` signal (the demo spectrum's native format; the
metadata tree gives beam energy, tilt, azimuth and elevation angles, live time, elements). `RoomHoldings.eds` as today;
the Info tab says `SEM` or `TEM` from the file's signal type or detector geometry and the EDS room's conditions rows take
the SEM values (take-off angle from elevation and tilt as exspy computes it, with the formula in the tooltip).

## 3. Layout

The EDS room's, unchanged: the maps block (a spectrum image) or the spectrum alone (a single spectrum, as the demo),
the spectrum with the results table beside it, the lower-pane tabs `Spectrum · Profile · Table`. One addition in the
spectrum: the **background windows** of every picked line are shaded when `Lines › Background windows` is on, with the
line's integration window in the element's colour and its two background windows hatched, as exspy's
`plot(background_windows=…)` draws them; a window's edge is draggable on the spectrum (direct manipulation).

## 4. Inspector

The EDS room's sections (`Maps · Tools · Elements · Lines · Quantification · Fitting · Export`) with these rows added:

- **Elements**: unchanged (periodic table, Auto ID). The SEM lines at 10 kV: Auto ID's energy cutoff follows the beam
  energy (no K lines above the overvoltage; the caption says `10 kV: lines above 8 keV excluded`).
- **Lines** (the line-window section, whatever its name is in the EDS room today; the one word is kept): `Background
  windows` switch; `Window width` field (× FWHM, exspy's `line_width` default 2 and 2); per line the windows as a
  value row (`Mn Kα · 5,78–6,02 · bg 5,48–5,60 · 6,14–6,26 keV`) with a `Reset` on the row's context menu.
- **Quantification**: `Method` pop-up gains `Cliff-Lorimer (bulk, absorption)`; the existing `k-factors` sheet
  accepts exspy's k-factor list (typed or from a CSV) so NS-7's table is reproduced with the same k; `Take-off angle`
  value row with its source; `Thickness` field (thin films; the demo's 100 nm) and `Density`.
- **Export**: unchanged; `Method JSON…` names the method exspy would call and its parameters.

## 5. Behaviour spec

- Opening the demo `.hspy` shows the spectrum with its elements picked (the file's `Sample.elements`), the conditions
  in Info, `Quantify` enabled once k-factors are typed or loaded (help "Type k-factors or pick a method that needs
  none"); line intensities with background windows are live in the results table before Quantify (they are counts,
  not a composition).
- `Background windows` on draws the shaded windows; dragging an edge recomputes that line's intensity live and marks
  Quantify stale.
- A spectrum image (`.bcf`) behaves as a Velox one: maps, regions, the HAADF tile is the SEM image the file carries
  (SE or BSE, named).
- A line that the overvoltage excludes is listed in the periodic table as disabled with the reason.

## 6. Demo data

Help › Open Demo Data › SEM-EDS Spectrum (`--demo-sem-eds`): the demo SEM-EDS spectrum (exspy's TM002, a `.hspy`
converted to `.msa` with its metadata in the header if `.hspy` reading is later than phase 7's first PR; the format
shipped is named in `docs/data-sources.md`) opens in EDS with C, Al, Mn, Cu, Zr, Si picked and the background windows
on.

## 7. Acceptance

- NS-7: the line intensities of Al Kα, Mn Kα, Cu Kα, Zr Lα with exspy's default windows equal exspy's
  `get_lines_intensity` within its tolerance; the Cliff-Lorimer composition with exspy's k-factors equals the exspy
  tutorial table within north-star.md's tolerance; the take-off angle equals exspy's `take_off_angle()` to 0,01°.
- Readers exact: the `.hspy` metadata tree and the `.bcf` fixture's spectrum image, conditions and SE image equal
  rosettasciio's.
- Screenshot: the demo spectrum with the background windows shaded and the results table filled.

## 8. Journeys

`SEMEDSJourney.swift`: (1) launch `--demo-sem-eds`, `edx.room`, the spectrum exists, the results table lists `Mn`
with an intensity; screenshot; (2) `Background windows` on, the shaded windows exist (`edx.spectrum.windows`); (3)
load the k-factor CSV from the fixtures, `Quantify`, the table shows wt% for five elements; screenshot (NS-7 gate); (4)
Info reads `SEM · 10 kV · take-off 35°`.
