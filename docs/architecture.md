# Architecture

What the app is made of, how the layers depend on each other, where a new file goes, and how the code shared with
mac4DSTEM is held.

## Layers and the dependency rule

```text
SwiftUI views (macTEM/UI/)     present state, send user intent                      app target
macTEM/App/ (AppState, …)      own the window, compose the owners, dispatch           app target
Sources/TEMSession             the owners of session state: the open files, each      package
                               image, its presentation and marks, the sidecar,
                               lineage and results, the SEM rooms' sessions — no
                               SwiftUI, no AppState
Sources/TEMCore                readers, the calibrated image, the rooms' compute      package
                               over the kits, writers; the SEM program's own
                               ports and their two Metal paths (SEM/) — no
                               SwiftUI, no AppState, no Session
FormatoKit                     the suite's file-format library: the DM3/DM4, Velox    package dependency
                               EMD, MRC and TIFF readers, the HDF5 layer, the
                               libhdf5 it ships
DiffractoKit                   crystallography and diffraction: cells, symmetry,      package dependency
                               CIF import, kinematic lists, ring calibration and
                               fit, indexing
ImagoKit                       image analysis: FFT, spectrum display, profiles,       package dependency
                               filters, objects
SpectroKit                     EDS and EELS: spectrum images, line and edge windows,  package dependency
                               maps, Auto ID, quantification, the EELS pipeline
MacEMUI                        the window shell, controls, the Metal image view and   package dependency
                               the shared EDS room
```

`Package.swift` takes each kit by version range (`from:`); `Package.resolved` holds the versions built.

Each layer knows nothing above it, and that is a module boundary: `Package.swift` builds `Sources/TEMCore` and
`Sources/TEMSession` as SwiftPM targets, the app target links them as package products, and `swift build`
(`tools/run-tests.sh core`) fails the moment either reaches upward. Their sources live outside the app's
synchronized folder, so every file compiles exactly once with no exception list (mac4DSTEM keeps Core/ inside its
app folder and excludes it file by file; that list has drifted). Declarations use `package` access; the app and
test targets set `SWIFT_PACKAGE_NAME` to the package's identity, derived from the checkout folder so a renamed clone
still builds. `inventory` also greps that nothing in `Sources/` imports SwiftUI, AppKit, Cocoa or MetalKit (which
brings AppKit in).

Swift 6 language mode everywhere. The app and its tests default to MainActor isolation; TEMCore is nonisolated by
default; TEMSession defaults to MainActor because it holds the `@Observable` owners views read. Heavy work runs in
`@concurrent` functions (`AppState.read`, which calls TEMCore's synchronous readers), so the main actor only
publishes results. TEMCore and TEMSession compile at `-O` in Debug too, as mac4DSTEM's do; a versioned kit dependency cannot be given `-O`, so the kits
build `-Onone` in Debug (see "Known limitations").

## Data flow: file → screen

1. **Open.** ⌘O, the sidebar or the welcome door bump `AppState.openImageRequest`; `ContentView` presents the
   open panel; Finder's Open With arrives through `.onOpenURL`. Both reach `AppState.open(urls:)`
   (`App/AppState+Open.swift`).
2. **Read, off the main actor.** `AppState.read` holds the sandbox scope only while the file is read, then calls
   `ImageOpening.openNow` (`TEMCore/Data/ImageOpening.swift`): the reader by extension, then the object rule (the
   first object that is not the thumbnail, has exactly two dimensions larger than one, and whose axes do not carry
   two different units). DM3/DM4, TIFF, MRC and Velox `.emd` are all FormatoKit's readings behind TEMCore's thin seams (`TIFFImageReader`, `MRCImageReader`,
   `VeloxImageReader` over one frame and one hyperslab, `KitImages`); the libhdf5 the `.emd` reader loads is FormatoKit's FormatoLibHDF5 framework in `Contents/Frameworks`; the result is a `CalibratedImage`
   (`TEMCore/Data/CalibratedImage.swift`): Float32 pixels, row-major, and each axis's origin, scale and unit exactly
   as the file states them.
3. **Normalise for display.** `FloatImage.normalized()` maps the finite range to [0, 1] and non-finite pixels to the
   masked sentinel; `MetalImageView.contentVersion` hashes the result; `IntensityHistogram` counts the RAW pixels for
   the Display section. All run in the same off-main read, with `AcquisitionMetadata.read(path:)`.
4. **Publish.** `ImageSession.finishOpen` publishes only the latest open's result (a slower, earlier read is
   dropped, and its failure is not reported over the newer image); `ImagePresentation.show` takes the canvas pixels.
   An open in flight is drawn over the image already shown, which stays if it fails.
5. **Show.** `ImagePane` letterboxes the image at its pixel aspect, draws it through MacEMUI's `MetalImageView` (the one
   SwiftUI↔Metal bridge) inside one `scaleEffect`/`offset` container (`ZoomPan`), and puts the scale bar in a
   `PaneFooter` outside that container. The bar measures the screen horizontal, so it uses the x axis's sampling
   (`ImageScaleBar`), and counts pixels when x is not calibrated — a unit and a finite, positive scale
   (`AxisCalibration.isCalibrated`), the one definition the inspector shares. The contrast window and gamma reach only the
   shader (`DisplayWindow`); the marks are drawn in one pane-sized `Canvas` mapped through the shader's own
   transform (`MarkGeometry`), and their numbers come from the file's pixels, never the canvas.

EBSD patterns, orientation maps and SEM-EDS files take their own path into their rooms ("The SEM program", below).

## Project structure and where files go

| Putting in… | goes under… |
|---|---|
| App entry, `AppState` and its orchestration extensions, window-level state, menus | `macTEM/App/` |
| SwiftUI views, the inspector kit, the canvas, overlays | `macTEM/UI/` |
| Readers, the image and calibration model, writers | `Sources/TEMCore/Data/` |
| The histogram, the line-profile seam, the signposts (the FFT and its display rules are ImagoKit's) | `Sources/TEMCore/Compute/` |
| The FFT room's preprocessing over ImagoKit | `Sources/TEMCore/FFT/` |
| The particle pass over ImagoKit | `Sources/TEMCore/Particles/` |
| The Diffraction room's pure core (the standards, calling DiffractoKit directly) | `Sources/TEMCore/Diffraction/` |
| Opening an EDS spectrum image (the room itself is MacEMUI's); exspy's SEM-EDS line intensities (`SEMEDSLines`, `XrayLineDatabase`) | `Sources/TEMCore/EDX/` |
| The EELS room's compute: SpectroKit called with the room's choices (stages, windows, fits, regions, exports) | `Sources/TEMCore/EELS/` |
| The seam between the app's `ImagePoint` and ImagoKit's `PixelPoint` | `Sources/TEMCore/Analysis/` |
| The SEM program's ports: EBSD and TKD readers, pattern processing, orientations, indexing, maps, grains, texture, Kikuchi simulation, the SEM-EDS map readers, the session report ("The SEM program") | `Sources/TEMCore/SEM/` and its subfolders |
| Session owners (`@Observable`), no SwiftUI, the SEM rooms' `EBSDSession`, `IndexingSession` and `OrientationMapSession` among them | `Sources/TEMSession/` |
| Unit tests; committed fixtures (≤ 1 MiB) in `Fixtures/` | `macTEMTests/` |
| Reference harnesses, the SEM reference bundles, their fixtures and scripts | `tools/parity/<name>/`, each folder in one array of `tools/run-tests.sh`; the gate and release scripts in `tools/`, their libraries in `tools/lib/` |
| Docs | `docs/` |
| Pinned references, fetched or provisioned | `References/` (gitignored; `tools/lib/python.sh`, `tools/lib/fetch-rsciio.sh`, `tools/lib/fetch-py4dstem-scattering.sh`; the SEM stack `References/sem-venv` from `tools/parity/sem/setup.sh`, its datasets `References/sem-data` from `tools/parity/sem/fetch-data.sh`) |
| Redistributed binaries and their licences | FormatoKit's three frameworks in `Contents/Frameworks` (`FormatoLibHDF5`, `FormatoLibSZ`, `FormatoLibAEC`; none committed here) and `Licenses/`, named and hashed in `NOTICE` |

The app's folder is a synchronized group: placement is wiring. Fixtures land flat in the test bundle's resources, so
two fixtures may not share a name.

## The kits, and what came from mac4DSTEM

**The kits are imported by version range, never copied** (`Package.swift` states the ranges, `Package.resolved` the versions built):

| Kit | What the app takes |
|---|---|
| FormatoKit | the DM3/DM4, Velox EMD, MRC and TIFF readings and metadata, the HDF5 layer and libhdf5 as three frameworks in `Contents/Frameworks`, the PNG text chunks, the thumbnail maker; the sidecar's HDF5 root attributes |
| DiffractoKit | cells, symmetry, CIF import, kinematic lists, the reference crystals (`CrystalPresets`), ring calibration and fit, indexing |
| SpectroKit | the EDS and EELS numbers: the spectrum image and its Velox / GMS opening (over FormatoKit), line windows and net-count maps, Auto ID, the pooled Cliff-Lorimer fit with computed k and absorption, the EELS alignment, thickness and edge fits, the results CSV and method JSON; its NIST EPQ tables and the EELS generalised oscillator strengths ride in resource bundles in `Contents/Resources` |
| ImagoKit | the calibrated axis (`AxisCalibration`), the unit and scale-bar numbers, the CSV writers (profile, tidy results, FFT), distance and angle, the display mapping, the 2D FFT, spectrum and radial profile, spot spacing, masked inverse FFT, HRTEM filters, the region / bin / unit / shape rules, the histogram, the line-profile numbers, objects and their moments |
| MacEMUI | the window skeleton, toolbar, sidebar and inspector, the controls, the scale bar and histogram, the Metal image view and engine, and the EDS room (`ShellEDXModel`, `ShellSpectroscopy`) shared with mac4DSTEM |

TEMCore keeps thin seams over the kits: `CalibratedImage+Micrograph` (the kit's `Micrograph`), `KitImages`,
`MRCImageReader`, `TIFFImageReader`, `VeloxImageReader`, `Compute/LineProfile` (the kit's `LineProfile` with the app's two refusals), `ImagePoint+PixelPoint`, `ProfileCSV`, `ResultsCSV` and `FFTExport` (the app's titles and validation sentences over the kit's CSV writers) and `UnitDisplay` (how a unit and a number are shown). A harness is an executable target in
`Package.swift` over TEMCore, so it links the kits `Package.resolved` pins. Where a file names both TEMCore's `DiffractionPattern` and the kit's,
`import struct DiffractoGeometry.DiffractionPattern` picks the kit's. No other name is shared: the app's twins are gone (2026-10-21).

**What came from mac4DSTEM** is the app entry point, the scripts and the CI workflow, adapted; each says so in its first lines. The shared
window shell, controls, inspector kit and Metal image view are the MacEMUI package, imported, never copied.

## The SEM program

EBSD, TKD, SEM images and SEM-EDS (`docs/sem/plan.md`). Its numbers follow the pinned Python SEM stack
(`tools/parity/sem/requirements.lock`), ported here rather than taken from a kit: decision D-SEM-1 (`docs/decisions.md`) keeps the
SEM code in `Sources/TEMCore/SEM/` and the `Sources/TEMSession/` owners, over FormatoKit's HDF5 layer and ImagoKit's images,
with no kit change; a kit move is a later program, once the API has settled. Each file names the module it ports in its
first lines; `docs/parity.md` lists every function with its reference, test and tolerance, `docs/sem/catalogue.md` what is
ported from where, and `NOTICE` the licences.

| Under `Sources/TEMCore/` | holds | `docs/parity.md` section |
|---|---|---|
| `SEM/` (its own files) | the EBSD and TKD pattern readers (`EBSDH5Reader` for h5ebsd, `EDAXBinaryReader`, `OxfordBinaryReader`) and their doors (`EBSDOpening`, `EDAXOpening`, `OxfordOpening`), the map readers `ANGReader` and `CTFReader`, `EBSDDataset` and `EBSDPatternAccess`, the Patterns room's pure part and its virtual BSE images (`EBSDBrowsing`, `VirtualBSEImaging`), the pattern processing (`PatternPipeline`, `PatternProcessing`, `PatternFilters`, `PatternWindow`, `AdaptiveHistogramEqualization`, `NeighbourAveraging`, `NLPAR`), `PatternQuality`, the detector geometry (`EBSDDetectorProjection`, `PCCalibrationMovingScreen`), the SEM TIFF record (`SEMImageMetadata`) and HyperSpy's `.hspy` spectrum (`HyperSpySpectrumFile`) | Readers; SEM images (TIFF); Pattern processing; Pattern filters; Pattern quality; Detector geometry; Patterns room |
| `SEM/NORDIF/` | a NORDIF acquisition: `Setting.txt`, `Pattern.dat`, its bitmaps and calibration patterns, and the door that opens them as one dataset | Readers |
| `SEM/Orientation/` | orix's rotations, point groups, orientations and misorientations, vectors and projections, Miller indices, fundamental sectors, colour keys and cubochoric sampling; the crystal lattice the texture and simulation code share | Orientation maths |
| `SEM/CrystalMap/` | orix's `CrystalMap` and `PhaseList`, one type for every map reader and indexing result; the neighbour misorientation; the Maps room's pictures (`OrientationMaps`) and analysis (`MapAnalysis`) | Crystal map |
| `SEM/Grains/` | DefDAP's grain boundaries, grains, KAM, GROD and GOS | Grains, KAM and GOS |
| `SEM/Deformation/` | DefDAP's quaternions and crystal symmetries, slip systems, Schmid factors and slip traces, the Nye tensor and GND density | Slip analysis and GND density |
| `SEM/Texture/` | orix's pole density function and pole figures; the ODF by kernel density estimation (Hielscher and Schaeben 2008) | Pole figures, inverse pole figures and the ODF |
| `SEM/Indexing/` | Hough indexing (PyEBSDIndex), dictionary indexing with its Metal path, refinement (kikuchipy, with SciPy's Nelder-Mead), the orientation similarity map, the merge of dictionary maps, the comparison of two runs, and the Indexing room's plans and results | Hough indexing; Dictionary indexing; Refinement; Crystal map (`IndexingComparison`) |
| `SEM/MasterPattern/` | EMsoft's master pattern files (kikuchipy's reader) and their projection onto a detector, with its Metal path | Master patterns and their projection |
| `SEM/Simulation/` | kikuchipy's geometrical Kikuchi simulation and kinematical master pattern on diffsims' reflectors: the pattern panes' overlay | Kikuchi simulation |
| `SEM/Export/` | the `.ang` writer (orix's) and the `.ctf` writer (the layout orix's reader reads) | Crystal map writers |
| `SEM/EDS/` | the SEM-EDS map readers of Bruker, EDAX and JEOL (RosettaSciIO's) and their door (`SEMEDSOpening`); they hand the EDS room a `CSRSpectrumImage` of their own (D-SEM-76) | SEM-EDS map readers |
| `SEM/Report/` | the SEM session's rows (`SEMSessionRow`), the files the rooms wrote, the methods the report cites, and the session report set as Markdown or PDF from numbers the rooms computed | none: no numbers of its own |
| `EDX/` (`SEMEDSLines`, `XrayLineDatabase`) | exspy's SEM-EDS line intensities and window quantification, on exspy's element database | SEM-EDS (exspy's window path) |

**The owners and the rooms.** TEMSession holds one owner per SEM room, the room's only state, which its views read:
`EBSDSession` (with `EBSDSession+Overlay`) is the Patterns room's: the open EBSD or TKD dataset, the pinned and hovered
positions, the pattern on screen, the navigation map, the processing pipeline and the simulation overlay. `IndexingSession`
(with `+Compare`, `+Overlay` and `IndexingRun`) is the Indexing room's, on the Patterns room's dataset: the phases, the method
(Hough or Dictionary) and its settings, the master patterns, the last run of each method, Compare and the overlay.
`OrientationMapSession` is the Maps room's: the map shown (an `.ang` or `.ctf` opened on its own, the dataset's crystal map,
or an Indexing run sent by `Open in Maps`, D-SEM-99), its layer, pictures, colour keys and analysis. `AppState` composes them
as `ebsd`, `indexing` and `maps`, each with a view-state type in `macTEM/App/` (`PatternsRoomState`, `IndexingRoomState`,
`MapsRoomState`) that holds only what the centre and the inspector share, and wires them in `init`: every dataset the
Patterns room binds starts the Indexing room over on it and gives the Maps room its crystal map (`ebsd.onBind`), and closing
it ends the Indexing room's work and drops the dataset's maps from the Maps room (a map opened on its own stays).
`SEMSessionRecord` keeps every file the rooms wrote and every line they logged; `SEMSessionLedger` sets the Results room's
SEM rows from the rooms and that record, and the session report is set from those rows (D-SEM-103, D-SEM-104). An SEM
image stays in the Image room, which reads the vendor's record (`SEMImageMetadata`) beside FormatoKit's and cuts the
databar off (`SEMImageSettings` shows it as a strip when asked); an SEM `.hspy` spectrum gets exspy's rows in the EDS room
from `SEMEDSState`.

**How a file reaches an SEM room.** `FileRouting.inventory(path:)` (`Sources/TEMCore/Data/`) asks the SEM doors before
FormatoKit's sniff decides, since the sniff knows none of these formats (an h5ebsd file it knows only as HDF5):

- SEM-EDS files go by extension (`SEMEDSOpening`): a Bruker `.bcf`, an EDAX `.spd`/`.lsd` or a JEOL `.pts`/`.asw` is an EDS
  spectrum image and a `.spx`/`.spc`/`.eds` one spectrum, both for the EDS room (`EDXOpening.open`); a JEOL `.img`/`.map`
  is an image for the Image room (`ImageOpening`). A HyperSpy `.hspy` whose header `HyperSpySpectrumFile` reads is one
  spectrum for the EDS room.
- The vendors' EBSD files (`EBSDOpening.isVendorFile`: EDAX `.up1`/`.up2`/`.ang`, Oxford `.ebsp`/`.ctf`, and a `.dat` with a
  NORDIF `Setting.txt` beside it): a pattern file, or a map with the pattern file of its name beside it, is a pattern
  dataset for the Patterns room; an `.ang` or `.ctf` alone (`EBSDOpening.isLoneMap`) is an orientation map for the Maps room.
- An HDF5 file, or a `.h5oina` or `.h5ebsd` the sniff does not know, that `EBSDH5Reader.sniff` recognises is an h5ebsd
  pattern dataset.

`AppState.open(urls:)` then opens the batch's first pattern dataset in `EBSDSession` and its first lone map in
`OrientationMapSession`, and lands in the richest room: Patterns, then Maps, EDS, EELS, Image (`FileInventory.Landing`). A
dataset's own crystal map reaches the Maps room through the Patterns room, an Indexing run through `Open in Maps`.

**Metal in TEMCore.** Two numeric ports carry a float32 Metal path beside their float64 CPU reference (D16); they are the
only files in `Sources/` and `macTEM/` that import Metal (the drawing is MacEMUI's):

- `SEM/Indexing/DictionaryIndexingMetal.swift`: the score matrix of dictionary indexing. Its CPU reference is
  `DictionaryIndexing.matchCPU`; the automatic backend takes the GPU from 10⁹ products (`workThreshold`); it is held to
  the CPU within 1e-5 by `SEMDictionaryIndexingParityTests` (D-SEM-72).
- `SEM/MasterPattern/MasterPatternProjectionMetal.swift`: many patterns projected from one master pattern (a dictionary).
  Its CPU reference is `MasterPatternProjection.project`; `patternsFloat32` takes the GPU from 10⁶ pattern pixels
  (`metalWorkThreshold`); it is held to the CPU within 1e-3 on the -1 to 1 scale by `MasterPatternParityTests` (D-SEM-34).

Both compile their kernel from source at first use with safe (not fast) math, and ship no `.metal` file, so the app's
shader library stays the shell's; they are the two rows of `tools/kit-boundary.allow` that let TEMCore import Metal.

**Reference bundles and their CI.** `tools/parity/sem` (the `references` array of `tools/run-tests.sh`) holds the pinned
stack (`requirements.lock`, built into `References/sem-venv` by `setup.sh`), the downloaded datasets (`data-manifest.txt`,
fetched into `References/sem-data` by `fetch-data.sh`), small committed fixtures, and `emit.py`, which writes one bundle
per ported function into `references/<milestone>/<case>/` (`manifest.json` with the tolerances, and raw arrays). The unit
job of `ci.yml` holds each port to its bundle on every PR (`macTEMTests/SEMParityReference.swift` loads one, the parity
tests compare), and `SEMParityHarnessTests` checks that every bundle loads intact, its fixtures match `SHA256SUMS` and its
case is named in `docs/sem/north-star.md`. `.github/workflows/sem-parity.yml` holds the bundles to the stack: on a Linux
runner, on a change under `tools/parity/sem`, it rebuilds the stack, fetches the data, regenerates the planted fixtures
(the tree must not change) and runs `check.py --require-data`. `tools/parity/sem-readers` (the `support` array) writes
the reader fixtures and their truth with the references' own readers. The harness's rules are in
`tools/parity/sem/README.md`.

## The UI contract

mac4DSTEM's, unchanged (its `docs/architecture.md`, "The UI contract"):

1. **SwiftUI only.** `MetalImageView` is the one platform bridge; no `import AppKit` in `UI/` (gated).
2. **No AppKit shell.** `HSplitView`, `VSplitView`, `NSSplitView`, `NSSplitViewController` are banned (gated).
3. **No bar or wash in the chrome**; the science panes are exempt, and a line marked `// science` (a label plate drawn on
   the data) (gated).
4. **`LayoutPolicy` is the whole number budget**: a numeric `.frame` outside it is science drawing geometry only —
   the panes and overlays (gated).
5. **No pane focus model; no UI selection stored beside the navigation seam** — the sidebar's selection is a binding
   onto `WorkspaceNavigation`.
6. **Three full-height columns, one job each**: the sidebar (navigation), the centre (the science, the 34-pt infobar
   that is the column's divider, the process area), the inspector (Settings · Info). The file, the room and the room's
   verb live in the toolbar. Below the 915-pt floor a panel closes before a science pane shrinks past its minimum.

## Numbers and dates: the screen and the files

The interface is English and is not translated (the project's only language is `en`). What follows the reader's Mac is
how a number and a time are written, and that depends on where they go (#302).

- **On screen: the reader's locale.** A number a person reads goes through `Num` (`macTEM/UI/NumberFormat.swift`),
  which writes through `UnitDisplay` (`Sources/TEMCore/Data/UnitDisplay.swift`): printf's digits, so the screen shows
  the last digit the CSV writes, with the locale's decimal mark, no grouping separator and no exponent. The EELS room's
  `EELSRoomFormat` (`Sources/TEMCore/EELS/EELSRoomChassis.swift`) writes the reader's mark without grouping as well.
  These helpers take a `locale` that defaults to `.autoupdatingCurrent`: right for a view, wrong for a file. A count in
  a sentence ("4,125 of 4,125 indexed") and a clock time are the reader's too.
- **In every file the app writes: `en_US_POSIX`.** A decimal point, no grouping, and dates that do not depend on the
  Mac's region, so a figure, a table and a report made on a German Mac read as those made on an American one, and a
  script reads either. A writer never calls a display helper at its default. It passes `ExportSnapshot.labelLocale`
  (`macTEM/App/ExportSnapshot.swift`, the app's constant for `en_US_POSIX`; TEMCore and TEMSession cannot see it and
  name the locale themselves) to a helper that takes a `locale`, or it uses a format that has none: `String(format:)`
  without a locale argument writes a point whatever the process locale is, and so do `JSONEncoder`,
  `JSONSerialization` and a Swift number's `description`. A helper made only for a file never defaults to the reader's
  locale: `EELSRoomFormat.fitQuality` takes a `locale` with no default, and the Maps figure labels default to
  `labelLocale`. A room's words that a file quotes have a `locale` form beside the reader's one:
  `IndexingRefineSettings.words(locale:)`, `IndexingMasterPattern.summary(locale:)` (over its `energyWords(locale:)`)
  and `DictionaryIndexingPlan.energyWords(locale:)`.

Which of the two each writer uses:

| File | Written by | Its numbers and dates |
|---|---|---|
| Image PNG | `ImageExport` (`Sources/TEMCore/Data/ImageExport.swift`), from `ExportSnapshot` | Mark labels: `MarkFormat.value(…, locale: labelLocale)`. Scale bar: ImagoKit's `ScaleBarMath` writes the number, `UnitDisplay.label` the unit. Description chunk: JSON built by hand, numbers by `description`. |
| Line profile, results, radial profile and spots CSV | `Sources/TEMCore/Data/ProfileCSV.swift`, `ResultsCSV.swift` and `FFTExport.swift`, over ImagoKit's CSV writers | `%.17g` (`CSVText.number`). The results CSV's `session:` line: `ExportSnapshot.sessionHeader` (`macTEM/App/ResultsExportSnapshot.swift`), ISO 8601 with the zone's offset. The spots CSV's note: `FFTRoomFormat.accuracyNote(…, locale: labelLocale)` (`macTEM/App/FFTExportSnapshot.swift`). |
| Maps and Texture PNG | `MapsFigure` (`macTEM/App/MapsRoomState.swift`) | `scaleBarLabel`, `rangeLabel` and `mrdLabel`, whose `locale` defaults to `labelLocale`. |
| EELS maps PNG | `macTEM/UI/EELSRoom.swift` | Each tile's `EELSMapTile.detailText(locale: labelLocale)`. |
| Grains and histogram CSV | `MapsRoomFormat.grainsCSV` and `histogramCSV` (`macTEM/App/MapsRoomState.swift`) | `String(format:)`, `%.6g`. |
| Indexing results CSV, `.ang`, `.ctf` | `IndexingResult.csv` (`Sources/TEMCore/SEM/Indexing/IndexingResult.swift`), `ANGWriter` and `CTFWriter` (`Sources/TEMCore/SEM/Export/`) | `String(format:)`. |
| Kikuchi overlay CSV | `KikuchiOverlay.csv` (`Sources/TEMCore/SEM/Simulation/KikuchiOverlay.swift`) | A number's `description`. |
| Method and metadata JSON | `methodJSON` of `IndexingPlan`, `DictionaryIndexingPlan`, `PatternPipeline` and `EELSCompute`; `EBSDBrowsing.metadataJSON` | `JSONEncoder` or `JSONSerialization`. The dictionary record's `energy` words: `DictionaryIndexingPlan.energyWords(locale:)` in `en_US_POSIX`; `energyKeV` beside them is the number. |
| EELS CSV and MSA | `EELSExports` (`Sources/TEMCore/EELS/EELSExports.swift`) | `%.9g`; the `.msa` is FormatoKit's `MSAWriter`. The results CSV's thickness, fit quality and deconvolution lines are made in `en_US_POSIX` (`EELSSession.resultsCSV`, `EELSDeconvolveCompute.recordLine`). |
| Diffraction CSV | `DiffractionExport` (`Sources/TEMCore/Diffraction/DiffractionExport.swift`) | `%.9g`. |
| Particles CSV | `ParticleFormat.csv` (`Sources/TEMCore/Particles/ParticleCompute.swift`) | `String(format:)`. |
| EDX CSV and MSA | MacEMUI's `ShellEDXModel` | `String(format:)` in the CSVs; the `.msa` is FormatoKit's `MSAWriter` (`EDXExports.msa`). |
| Session report, Markdown and PDF | `SEMSessionReport` (`Sources/TEMCore/SEM/Report/SEMSessionReport.swift`), from `ExportPanels.exportSessionReport` | Rows: `SEMSessionLedger.rows(of:locale:)` with `labelLocale`, which reaches the Refine words and the dictionary's master and energy words (`SEMSessionLedger.refineField` and `dictionaryFields`). Dates: `SEMSessionReport.Clock`, a `DateFormatter` in `en_US_POSIX` on the Gregorian calendar ("2026-11-07 16:42"). |
| Session sidecar | `SessionSidecarFile` and `SessionLineage` (`Sources/TEMCore/Data/`) | `JSONEncoder`: integers, times as milliseconds. |

A test holds each writer that passes a locale: the file's string is the `en_US_POSIX` one, and the same value in `de_DE`
reads differently, so the literal separates the two on any Mac (`ExportSnapshotTests`, `MapsFigureLabelTests`,
`SEMSessionLedgerTests`, `EELSFitTextTests`, `ResultsWiringTests`, `IndexingFileWordsTests`; `FFTExportSnapshotTests`
with `NumberFormatTests` for the spots CSV's note). `ProfileCSVTests` holds `String(format:)` under a German C locale. A
new writer comes with its own.

The session report quotes two things as the room wrote them at the time, in the reader's locale: the Output lines, and
the settings a room recorded with an exported file.

## Requirements, build, test

- macOS 26 or later on Apple silicon (`MACOSX_DEPLOYMENT_TARGET = 26.0`, `.macOS(.v26)`, lowered from 27 on 2026-10-28);
  Xcode 27 (Swift 6.4) on the dev Mac, Xcode 26.6 (Swift 6.3) on CI. An API newer than macOS 26.0 sits behind `if #available`.
  `ARCHS = arm64`.
- Build: open `macTEM.xcodeproj`, scheme `macTEM`, ⌘R; or `xcodebuild -project macTEM.xcodeproj -scheme macTEM -destination 'platform=macOS' build`.
- Gates: `tools/run-tests.sh unit | core | scientific | inventory`; the `scientific` array in that script is the
  harness roster. A harness is an executable target in `Package.swift` (`parityHarness`, TEMCore's own Swift
  settings, held equal by `inventory`), built by `tools/lib/harness.sh`, and compares against a reference
  pinned in `tools/lib/references-lock.txt` (Python, provisioned into `References/python-venv`) or fetched at a
  commit (`tools/lib/fetch-rsciio.sh`). Every folder under `tools/parity/` sits in one array of that script; the
  `references` array holds `sem`, whose pinned Python stack emits the committed SEM bundles the unit lane's parity tests
  compare against, and `.github/workflows/sem-parity.yml` checks on Linux that the stack still emits them ("The SEM
  program").
- Signing: local builds are signed ad hoc with no team; Hardened Runtime is off in Debug and on in Release, as in
  mac4DSTEM. The sandbox grants only user-selected files.

## Known limitations

- Reads 2D images from DM3/DM4, TIFF (with the Thermo/FEI, Zeiss and Tescan SEM records), one-image MRC, Velox `.emd` and
  JEOL `.img`/`.map`; a stack opens at "frame 1 of N" and steps through its frames with ← and →. Reads spectrum images and
  single spectra from Velox `.emd`, GMS `.dm4`, `.msa`, HyperSpy `.hspy`, Bruker `.bcf`/`.spx`, EDAX `.spd`/`.lsd`/`.spc`
  and JEOL `.pts`/`.eds`/`.asw`; EBSD and TKD patterns from h5ebsd (kikuchipy, Bruker, EDAX, Oxford H5OINA), EDAX
  `.up1`/`.up2`, Oxford `.ebsp` and NORDIF `Pattern.dat`; orientation maps from `.ang` and `.ctf`. A hexagonal EBSD grid is
  refused (D-SEM-9).
- The kits compile at `-Onone` in a Debug build (a versioned dependency carries no `-O`): one DiffractoKit ring fit takes 2.0 s there and 0.04 s at `-O`, so the
  fit tests are the slow part of a unit run, and a room that runs the fit from a Debug build waits seconds.
- A 2D object larger than 1 GiB is refused, not streamed. Pixel types decoded: int8/16/32, uint8/16/32, float32/64; complex, packed-complex FFT, RGB and bool
  are refused by name. Pixels become Float32 (integers above 2^24 and float64 values round). Only little-endian DM files are read.
- The image is drawn at its pixel aspect; when the axes differ the Info tab says so and the horizontal scale bar uses x.
- No non-Metal fallback: MacEMUI's `MetalEngine` stops the app without a Metal device or when its shaders cannot be built.
  TEMCore's two SEM Metal paths are compute, each beside its float64 CPU reference ("The SEM program").
