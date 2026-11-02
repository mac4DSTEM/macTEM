# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). App versions are tagged with a `v`
(`v1.0.0`); release-please writes each new entry above the older ones from the merged pull requests' titles.

## Unreleased

- **Runs on macOS 26** (was macOS 27) on Apple silicon. MacEMUI 0.3.2. CI builds and runs the unit tests, on Xcode 26.6.
- Exports no longer carry internal milestone ids: the `validation` and `lineage` text in PNG metadata, FFT CSVs and the line profile and measurement CSVs names what each number is checked against (numpy, scikit-image, ImagoKit's parity tests), without "V1-…" or "until V1-2".

## [1.2.0](https://github.com/mac4DSTEM/macTEM/compare/v1.1.1...v1.2.0) (2026-11-02)


### Features

* EELS keyboard regions, hovered pixel spectrum and profile labels ([#82](https://github.com/mac4DSTEM/macTEM/issues/82)) ([36aadd5](https://github.com/mac4DSTEM/macTEM/commit/36aadd518e6a7559ba4e00e5f9293d05ba1f629d))
* EELS Maps status line while maps are computed ([#78](https://github.com/mac4DSTEM/macTEM/issues/78)) ([3b3812d](https://github.com/mac4DSTEM/macTEM/commit/3b3812da73e01b22767b65f6503c9372bfeff7ae))
* EELS MLLS fit uses the reference spectra ([#90](https://github.com/mac4DSTEM/macTEM/issues/90)) ([903f3b9](https://github.com/mac4DSTEM/macTEM/commit/903f3b9608bedaf156adb7da65bf6924b4eb78ab))
* EELS results footer opens the fit notes, as the EDS room ([#81](https://github.com/mac4DSTEM/macTEM/issues/81)) ([124d663](https://github.com/mac4DSTEM/macTEM/commit/124d6632e3abe7d8ed520a2c2f9f64791e137810))
* EELS room keyboard regions, the hovered pixel's spectrum and profile labels ([36aadd5](https://github.com/mac4DSTEM/macTEM/commit/36aadd518e6a7559ba4e00e5f9293d05ba1f629d))
* EELS single spectrum and stage state on the section titles ([#77](https://github.com/mac4DSTEM/macTEM/issues/77)) ([521675d](https://github.com/mac4DSTEM/macTEM/commit/521675d1c7c32721f5df3bc998d80669d3b47139))
* EELS Spectrum MSA export, method JSON SHA-256, Info tilts and beam source ([#79](https://github.com/mac4DSTEM/macTEM/issues/79)) ([e2bd1f6](https://github.com/mac4DSTEM/macTEM/commit/e2bd1f6b7db8adacabd5b369c2981b69206229b1))


### Bug Fixes

* EELS profile lists only the shown maps; the hovered spectrum shows in light mode ([#84](https://github.com/mac4DSTEM/macTEM/issues/84)) ([d49acb1](https://github.com/mac4DSTEM/macTEM/commit/d49acb13514b2d23d2f1c61807dbdf9dcdc3923a))
* EELS results table shows at% and wt% without clipping ([#88](https://github.com/mac4DSTEM/macTEM/issues/88)) ([7383d0f](https://github.com/mac4DSTEM/macTEM/commit/7383d0f07414496d848cd790e9238d486d8f69c4))
* EELS ZLP shift tile contrast and the empty tooltip on the colour mix ([#91](https://github.com/mac4DSTEM/macTEM/issues/91)) ([1d43ad8](https://github.com/mac4DSTEM/macTEM/commit/1d43ad8cd2f329ae134456feae78a4569f4e3e30))
* Open Files shows the scan size of an EELS spectrum image ([#89](https://github.com/mac4DSTEM/macTEM/issues/89)) ([a701ded](https://github.com/mac4DSTEM/macTEM/commit/a701ded5083d0fb39410a1030c6dd6124488a980))
* the EELS room opens a single spectrum ([#85](https://github.com/mac4DSTEM/macTEM/issues/85)) ([77d81fc](https://github.com/mac4DSTEM/macTEM/commit/77d81fca95de9f0522cb655fac69b603e4d1bda5))

## [1.1.1](https://github.com/mac4DSTEM/macTEM/compare/v1.1.0...v1.1.1) (2026-11-02)


### Bug Fixes

* the app version comes from the release tag ([#75](https://github.com/mac4DSTEM/macTEM/issues/75)) ([5994de9](https://github.com/mac4DSTEM/macTEM/commit/5994de9bbe6fb5f0a5399ecd9c352db2667423c6))

## [1.1.0](https://github.com/mac4DSTEM/macTEM/compare/v1.0.0...v1.1.0) (2026-11-01)


### Features

* EELS results carry sigma on at% and wt%, the fit quality and an MLLS Fit to ([#61](https://github.com/mac4DSTEM/macTEM/issues/61)) ([e6ff757](https://github.com/mac4DSTEM/macTEM/commit/e6ff757a908c9e297474adba6672d0698e69b688))
* EELS room deconvolution stage, MLLS fit model and Fit only role ([#58](https://github.com/mac4DSTEM/macTEM/issues/58)) ([cd78122](https://github.com/mac4DSTEM/macTEM/commit/cd7812245e4e8bfab5d527c914da0493fc102778))
* EELS wt% maps and a display filter ([#67](https://github.com/mac4DSTEM/macTEM/issues/67)) ([0e736f3](https://github.com/mac4DSTEM/macTEM/commit/0e736f3723808b9f1b40b247c9d4e26b19fc1c10))
* Find Spots ranks by local contrast and shows it in the spot row ([#38](https://github.com/mac4DSTEM/macTEM/issues/38)) ([b1b1b3b](https://github.com/mac4DSTEM/macTEM/commit/b1b1b3b74b8b663e11134ba6621890160bafc274))
* particles take Otsu's threshold, remove objects below the minimum area and report the areal density ([#37](https://github.com/mac4DSTEM/macTEM/issues/37)) ([59f211f](https://github.com/mac4DSTEM/macTEM/commit/59f211f41c329d2eaa5329ad8c0e2d02fd3b9df5))
* results no longer carry an unvalidated badge ([#63](https://github.com/mac4DSTEM/macTEM/issues/63)) ([12c2b34](https://github.com/mac4DSTEM/macTEM/commit/12c2b34dad28676b9ff9a2005c4623bfd130dc61))
* the busy line shows elapsed time, and an ETA where the work reports progress ([#45](https://github.com/mac4DSTEM/macTEM/issues/45)) ([02bfc77](https://github.com/mac4DSTEM/macTEM/commit/02bfc77f567c1d7ab7d4276dbae3c65276e64790))
* the EDX room comes from MacEMUI ([#22](https://github.com/mac4DSTEM/macTEM/issues/22)) ([e1165e7](https://github.com/mac4DSTEM/macTEM/commit/e1165e7117544c8d570a8cda59ea6faa38e2c997))
* the EELS room no longer labels results as unvalidated ([#65](https://github.com/mac4DSTEM/macTEM/issues/65)) ([3fc255c](https://github.com/mac4DSTEM/macTEM/commit/3fc255c2041954c8f948f2c22a46aa3bc0e14093))
* the Particles object table is a window, the pointer names the object under it, and the section sits above Measure ([#42](https://github.com/mac4DSTEM/macTEM/issues/42)) ([242ff56](https://github.com/mac4DSTEM/macTEM/commit/242ff56b15f0a0851be077504b909ce4e96b6fe8))
* the Results room lists the EDS composition of the file ([#41](https://github.com/mac4DSTEM/macTEM/issues/41)) ([849c3ba](https://github.com/mac4DSTEM/macTEM/commit/849c3baa8fe00ee909e37eb72ebe9643e9f4e147))
* the Results room lists the EELS thickness and fitted edges of the file ([#50](https://github.com/mac4DSTEM/macTEM/issues/50)) ([113ccf5](https://github.com/mac4DSTEM/macTEM/commit/113ccf56c58179cac8bcaea5296f2cb8a91eff4d))


### Bug Fixes

* a lone spectrum file highlights only its own room in the sidebar ([#47](https://github.com/mac4DSTEM/macTEM/issues/47)) ([369d626](https://github.com/mac4DSTEM/macTEM/commit/369d6263228e592cd36f8d8cca56786b261b114f))
* a re-read with other pixels drops the particle report; ImagoKit 0.8.0 ([#26](https://github.com/mac4DSTEM/macTEM/issues/26)) ([add48f4](https://github.com/mac4DSTEM/macTEM/commit/add48f426b54c55390bf7d59793e1e198a04c7e6))
* a session re-save keeps another writer's lineage keys and refuses a rewritten or deleted sidecar ([#33](https://github.com/mac4DSTEM/macTEM/issues/33)) ([795ac30](https://github.com/mac4DSTEM/macTEM/commit/795ac30554aa01a56a50b8eb6e82e9c2402cbfe3))
* a single .msa spectrum opens from Finder, the Open panel and a drop ([#34](https://github.com/mac4DSTEM/macTEM/issues/34)) ([d7605fc](https://github.com/mac4DSTEM/macTEM/commit/d7605fcd8abae4fe6ed4c5c8b803bc01d12fa2bd))
* exports carry no milestone ids in their validation and lineage text ([#16](https://github.com/mac4DSTEM/macTEM/issues/16)) ([44edfdb](https://github.com/mac4DSTEM/macTEM/commit/44edfdb358f9a891fe99b0e7bae6e1ad57564029))
* macTEM texts drop the unvalidated wording ([cc778be](https://github.com/mac4DSTEM/macTEM/commit/cc778be64931eada4e5c4c37a5d31f51ad89d1fb))
* Particles numbers use the locale decimal mark ([#48](https://github.com/mac4DSTEM/macTEM/issues/48)) ([2f7d726](https://github.com/mac4DSTEM/macTEM/commit/2f7d726dfaa30a587e9ff4a89ff4e48c2de0a653))
* refuse a save after a re-read with other pixels, offer Save Anyway ([#27](https://github.com/mac4DSTEM/macTEM/issues/27)) ([2f07578](https://github.com/mac4DSTEM/macTEM/commit/2f0757843986332d55b1a378be6cfaab96b2075e))
* the busy line names the running operation, not the last status sentence ([#49](https://github.com/mac4DSTEM/macTEM/issues/49)) ([49c63aa](https://github.com/mac4DSTEM/macTEM/commit/49c63aa266956b318e78d04eddcb70b216f31d31))
* the Save to Session title follows a grant stored or dropped while the file is open ([#35](https://github.com/mac4DSTEM/macTEM/issues/35)) ([fd19a40](https://github.com/mac4DSTEM/macTEM/commit/fd19a4008aba3364f0d6c5fe407cebcbb3108fe2))
* turn Metal fast math off before the first compute kernel ([#28](https://github.com/mac4DSTEM/macTEM/issues/28)) ([3bffd96](https://github.com/mac4DSTEM/macTEM/commit/3bffd96616f740fd91350ce66c914814aa63d6f8))

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
