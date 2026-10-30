# Architecture

What the app is made of, how the layers depend on each other, where a new file goes, and how the code shared with
mac4DSTEM is held.

## Layers and the dependency rule

```text
SwiftUI views (macTEM/UI/)     present state, send user intent                      app target
macTEM/App/ (AppState, …)      own the window, compose the owners, dispatch           app target
Sources/TEMSession             the owners of session state: the open files, each      package
                               image, its presentation and marks, the sidecar,
                               lineage and results — no SwiftUI, no AppState
Sources/TEMCore                readers, the calibrated image, the rooms' compute      package
                               over the kits, writers — no SwiftUI, no AppState,
                               no Session
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

The versions are exact tags in `Package.swift`, the one place that states them.

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
| Opening an EDS spectrum image (the room itself is MacEMUI's) | `Sources/TEMCore/EDX/` |
| The EELS room's compute: SpectroKit called with the room's choices (stages, windows, fits, regions, exports) | `Sources/TEMCore/EELS/` |
| Session owners (`@Observable`), no SwiftUI | `Sources/TEMSession/` |
| Unit tests; committed fixtures (≤ 1 MiB) in `Fixtures/` | `macTEMTests/` |
| Reference harnesses, gates, their libraries | `tools/<name>/` — classified in `tools/run-tests.sh` |
| Docs | `docs/` |
| Pinned references, fetched or provisioned | `References/` (gitignored; `tools/lib/python.sh`, `tools/lib/fetch-rsciio.sh`, `tools/lib/fetch-formatokit.sh`, `tools/lib/fetch-diffractokit.sh`, `tools/lib/fetch-imagokit.sh`) |
| Redistributed binaries and their licences | FormatoKit's three frameworks in `Contents/Frameworks` (`FormatoLibHDF5`, `FormatoLibSZ`, `FormatoLibAEC`; none committed here) and `Licenses/`, named and hashed in `NOTICE` |

The app's folder is a synchronized group: placement is wiring. Fixtures land flat in the test bundle's resources, so
two fixtures may not share a name.

## The kits, and what came from mac4DSTEM

**The kits are imported at exact tags, never copied** (`Package.swift` is the truth for versions; the Xcode project and `Package.resolved` follow):

| Kit | What the app takes |
|---|---|
| FormatoKit | the DM3/DM4, Velox EMD, MRC and TIFF readings and metadata, the HDF5 layer and libhdf5 as three frameworks in `Contents/Frameworks`, the PNG text chunks, the thumbnail maker; the sidecar's HDF5 root attributes |
| DiffractoKit | cells, symmetry, CIF import, kinematic lists, the reference crystals (`CrystalPresets`), ring calibration and fit, indexing |
| SpectroKit | the EDS and EELS numbers: the spectrum image and its Velox / GMS opening (over FormatoKit), line windows and net-count maps, Auto ID, the pooled Cliff-Lorimer fit with computed k and absorption, the EELS alignment, thickness and edge fits, the results CSV and method JSON; its NIST EPQ tables and the EELS generalised oscillator strengths ride in resource bundles in `Contents/Resources` |
| ImagoKit | the calibrated axis (`AxisCalibration`), the unit and scale-bar numbers, the CSV writers (profile, tidy results, FFT), distance and angle, the display mapping, the 2D FFT, spectrum and radial profile, spot spacing, masked inverse FFT, HRTEM filters, the region / bin / unit / shape rules, the histogram, the line-profile numbers, objects and their moments |
| MacEMUI | the window skeleton, toolbar, sidebar and inspector, the controls, the scale bar and histogram, the Metal image view and engine, and the EDS room (`ShellEDXModel`, `ShellSpectroscopy`) shared with mac4DSTEM |

TEMCore keeps thin seams over the kits: `CalibratedImage+Micrograph` (the kit's `Micrograph`), `KitImages`,
`MRCImageReader`, `TIFFImageReader`, `VeloxImageReader`, `Compute/LineProfile` (the kit's `LineProfile` with the app's two refusals), `ImagePoint+PixelPoint`, `ProfileCSV`, `ResultsCSV` and `FFTExport` (the app's titles and validation sentences over the kit's CSV writers) and `UnitDisplay` (how a unit and a number are shown). A harness cannot compile a kit into TEMCore's one
module, so `tools/lib/fetch-formatokit.sh`, `fetch-diffractokit.sh` and `fetch-imagokit.sh` pin `References/<Kit>` to `Package.resolved`, and
`tools/lib/sources.manifest` builds the kits' modules under TEMCore's flags. Where a file names both TEMCore's `DiffractionPattern` and the kit's,
`import struct DiffractoGeometry.DiffractionPattern` picks the kit's. No other name is shared: the app's twins are gone (2026-10-21).

**What came from mac4DSTEM** is the app entry point, the scripts and the CI workflow, adapted; each says so in its first lines. The shared
window shell, controls, inspector kit and Metal image view are the MacEMUI package, imported, never copied.

## The UI contract

mac4DSTEM's, unchanged (its `docs/architecture.md`, "The UI contract"):

1. **SwiftUI only.** `MetalImageView` is the one platform bridge; no `import AppKit` in `UI/` (gated).
2. **No AppKit shell.** `HSplitView`, `VSplitView`, `NSSplitView`, `NSSplitViewController` are banned (gated).
3. **No bar or wash in the chrome**; the science panes are exempt (gated).
4. **`LayoutPolicy` is the whole number budget**: a numeric `.frame` outside it is science drawing geometry only —
   the panes and overlays (gated).
5. **No pane focus model; no UI selection stored beside the navigation seam** — the sidebar's selection is a binding
   onto `WorkspaceNavigation`.
6. **Three full-height columns, one job each**: the sidebar (navigation), the centre (the science, the 34-pt infobar
   that is the column's divider, the process area), the inspector (Settings · Info). The file, the room and the room's
   verb live in the toolbar. Below the 915-pt floor a panel closes before a science pane shrinks past its minimum.

## Requirements, build, test

- macOS 26 or later on Apple silicon (`MACOSX_DEPLOYMENT_TARGET = 26.0`, `.macOS(.v26)`, lowered from 27 on 2026-10-28);
  Xcode 27 (Swift 6.4) on the dev Mac, Xcode 26.6 (Swift 6.3) on CI. An API newer than macOS 26.0 sits behind `if #available`.
  `ARCHS = arm64`.
- Build: open `macTEM.xcodeproj`, scheme `macTEM`, ⌘R; or `xcodebuild -project macTEM.xcodeproj -scheme macTEM -destination 'platform=macOS' build`.
- Gates: `tools/run-tests.sh unit | core | scientific | inventory`; the `scientific` array in that script is the
  harness roster. A harness compiles TEMCore sources from `tools/lib/sources.manifest` with TEMCore's own Swift
  settings (`MACTEM_CORE_FLAGS`, held equal to `Package.swift` by `inventory`) and compares against a reference
  pinned in `tools/lib/references-lock.txt` (Python, provisioned into `References/python-venv`) or fetched at a
  commit (`tools/lib/fetch-rsciio.sh`).
- Signing: local builds are signed ad hoc with no team; Hardened Runtime is off in Debug and on in Release, as in
  mac4DSTEM. The sandbox grants only user-selected files.

## Known limitations

- Reads 2D images from DM3/DM4, TIFF, one-image MRC and Velox `.emd`; a stack opens at "frame 1 of N" and steps through its frames with ← and →.
- The kits compile at `-Onone` in a Debug build (a versioned dependency carries no `-O`): one DiffractoKit ring fit takes 2.0 s there and 0.04 s at `-O`, so the
  fit tests are the slow part of a unit run, and a room that runs the fit from a Debug build waits seconds.
- A 2D object larger than 1 GiB is refused, not streamed. Pixel types decoded: int8/16/32, uint8/16/32, float32/64; complex, packed-complex FFT, RGB and bool
  are refused by name. Pixels become Float32 (integers above 2^24 and float64 values round). Only little-endian DM files are read.
- The image is drawn at its pixel aspect; when the axes differ the Info tab says so and the horizontal scale bar uses x.
- No non-Metal fallback: MacEMUI's `MetalEngine` stops the app without a Metal device or when its shaders cannot be built.
