# macTEM

TEM images, EDS and EELS spectrum images and electron diffraction, analysed natively on the Mac.

macTEM is the companion to [mac4DSTEM](https://github.com/mac4DSTEM/mac4DSTEM). Both are free, open source and built for
Apple silicon.

## Download

Get the signed and notarised DMG from the [latest release](https://github.com/mac4DSTEM/macTEM/releases/latest). It needs
macOS 27 or later on an Apple silicon Mac.

## What it does

Open a DigitalMicrograph (.dm3, .dm4), Velox (.emd), TIFF or MRC file and work through the rooms in the sidebar:

- **Image**: calibration, colormap, contrast and gamma; distances, angles, line profiles and particles; image stacks.
  Your marks are saved in a session file next to the image.
- **FFT**: the transform of the image or a region, spots and their d-spacings, the radial profile, a masked inverse,
  and ABSF and Wiener filters.
- **EDS**: Velox and GMS spectrum images. Pick elements from the periodic table or let Auto ID suggest them, then get
  net, wt%, at% and thickness maps, regions, and the Cliff-Lorimer composition.
- **EELS**: Dual-EELS spectrum images. Align the zero-loss peak, map t/λ, pick edges from the periodic table, and fit
  their intensities and at%.
- **Diffraction**: calibrate on a ring of a standard, then index rings and spots and read their d-spacings.
- **Results**: every measurement of a file in one table, exported as CSV.

## Where the numbers come from

Every number is computed by the suite's Swift kits, each checked against the Python package it ports, within that
package's own tolerance: [FormatoKit](https://github.com/mac4DSTEM/FormatoKit) (file readers),
[ImagoKit](https://github.com/mac4DSTEM/ImagoKit) (FFT and image maths),
[DiffractoKit](https://github.com/mac4DSTEM/DiffractoKit) (crystallography) and
[SpectroKit](https://github.com/mac4DSTEM/SpectroKit) (EDS and EELS). A result that has not yet been compared with a
dataset of known truth says `validation: none` next to it.

## Building it yourself

You need Xcode 27. Open `macTEM.xcodeproj`, pick the `macTEM` scheme and press ⌘R. The first build fetches the kits at
the exact tags in `Package.swift`. The tests run with `tools/run-tests.sh unit`. How the code is organised is in
[`docs/architecture.md`](docs/architecture.md).

## Problems and ideas

Please open an issue. Bug reports with the file type and what you expected help most.

## Licence

GPL-3.0-or-later ([`LICENSE`](LICENSE)). Third-party notices are in [`NOTICE`](NOTICE).
