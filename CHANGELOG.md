# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). App versions are tagged with a `v`
(`v1.0.0`); release-please writes each new entry above the older ones from the merged pull requests' titles.

## Unreleased

- **Runs on macOS 26** (was macOS 27) on Apple silicon. MacEMUI 0.3.2. CI builds and runs the unit tests, on Xcode 26.6.
- Exports no longer carry internal milestone ids: the `validation` and `lineage` text in PNG metadata, FFT CSVs and the line profile and measurement CSVs names what each number is checked against (numpy, scikit-image, ImagoKit's parity tests), without "V1-…" or "until V1-2".

## v1.0.0 — 2026-10-23

First release. macTEM analyses TEM images, EDS and EELS spectrum images and diffraction patterns on Apple silicon
Macs (macOS 27 at this release). The numbers come from the suite's kits (FormatoKit 0.11.0, DiffractoKit 0.10.0,
ImagoKit 0.7.0, SpectroKit 0.12.0) and the window from MacEMUI 0.3.0; anything not yet checked against known truth says
`validation: none`.

### Added

- **Opening files.** DigitalMicrograph (.dm3, .dm4), Velox (.emd), TIFF and MRC. The file's content decides the room,
  not its extension: an image opens in the Image room, a spectrum image in the EDS or EELS room (a Velox file with a
  HAADF image and a spectrum cube fills both), a single `.msa` spectrum in the EDS room. A room with no data for the
  open files is disabled in the sidebar with a one-line reason.
- **Rooms** in the order the work goes: Prepare, Image, FFT, EDS, EELS, Diffraction and Results (⌘1 to ⌘7).
- **Image room.** Calibration from the file, colormap, contrast window and gamma; zoom (⌘+, ⌘−, ⌘0) with the pixel
  under the pointer in the status line; distances, angles and line profiles measured on the file's pixels; marks saved
  in a session file next to the image.
- **Image stacks.** A multi-page TIFF or ImageJ stack opens frame by frame, read on demand (a 100-frame series shows a
  frame in about 2 MB of memory). ← and → step through the frames, Home and End go to the ends, and "Same contrast for
  every frame" holds the contrast window so brightness drift shows.
- **Particles.** Bright or dark objects found by a threshold in the image's own units, with optional smoothing, 4 or 8
  connectivity and a minimum area; each object outlined with its moments ellipse, a sortable table and a CSV export.
- **FFT room.** The transform of the image or a region with a window (Hann, Hamming, Blackman, Tukey), spots and their
  d-spacings, Find Spots with an editable threshold, distance and count, the radial profile, a masked inverse, and
  Gaussian, band-pass, ABSF and Wiener filters.
- **EDS room.** Velox and GMS spectrum images. Elements from the periodic table or from Auto ID (the published
  AutoEMX/NIST identification loop); net-count, wt%, at% and thickness maps; the pooled Cliff-Lorimer fit with
  computed or typed k-factors and the absorption correction when the file gives the detector geometry and a thickness
  is typed; zeta-factor and cross-section methods. Quantify is the toolbar's verb (⌘↩).
- **EELS room.** Dual-EELS spectrum images with their low loss and core loss. Run aligns the zero-loss peak, maps t/λ
  and fits the chosen edges; the periodic table offers 383 K, L and M edges of 95 elements (the generalised oscillator
  strengths of Segger, Guzzinati and Kohl, bundled; see NOTICE). Background and signal windows can be dragged on the
  spectrum; each edge's intensity carries its 1σ, and an edge at or under 3σ reads "below detection".
- **Regions** in the EDS and EELS rooms: rectangles, ellipses, polygons and lines, each numbered and coloured, with
  their spectra overlaid, a table row per region and line profiles across the maps.
- **Diffraction room.** Any image read as a pattern: a centre (image centre, typed, or a fitted ring's), a scale from a
  ring calibrated against Au, Al or Si (or the file's reciprocal axis, or a typed Δq), fitted rings and clicked spots
  indexed against a standard or an opened CIF, and a readout table and CSV.
- **Results room.** Every measurement of a file in one table, exported as CSV.
- **Exports.** PNG figures with the scale bar, CSV tables, and a method JSON for the spectroscopy rooms.
