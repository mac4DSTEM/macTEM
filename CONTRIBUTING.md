# Contributing

Thanks for looking. macTEM is a measuring instrument as much as an application: a wrong number that looks plausible is
worse than a crash, so the conventions below are mostly about making correctness checkable by someone other than the
author.

## Reporting a problem

Open an issue. A scientific bug report is much more useful with:

- **The file type and its shape**: DM3/DM4, TIFF, MRC, Velox `.emd`, a spectrum image; its size and pixel type.
- **What the app reported**: the calibration it read, the `validation` text of the result, and any refusal it gave.
  These are on screen and in every export for exactly this reason.
- **macOS version and Mac model.** Apple silicon only.
- **What the Python reference produced**, if you have it (ncempy, RosettaSciIO, NumPy, scikit-image, HyperSpy/exSpy).
  A discrepancy with numbers attached is the most useful report this project can receive.

Please do not attach datasets to issues. Describe them, or link to a published one.

## Building and testing

You need Xcode 27 or Xcode 26.6 (the Command Line Tools alone cannot build it) on an Apple silicon Mac with macOS 26 or
later.

```sh
xcodebuild -project macTEM.xcodeproj -scheme macTEM -destination 'platform=macOS' build
tools/run-tests.sh unit         # the unit tests: run these before you open a pull request
tools/run-tests.sh core         # TEMCore and TEMSession build alone, with no warning (the layering check)
tools/run-tests.sh inventory    # repository checks (notices, large files, harness list, UI identifiers)
```

Everything under `tools/` finds its own toolchain through `tools/lib/developer-dir.sh`: an explicit `DEVELOPER_DIR`
wins, then `xcode-select`, then any Xcode in `/Applications`.

## Where code goes

The Xcode project uses synchronized folder groups, so placement is wiring: a file under `macTEM/` joins the app target.
Views describe the interface only; compute lives in `Sources/TEMCore`, session state in `Sources/TEMSession`, and
neither imports SwiftUI or anything above it. More in [`docs/architecture.md`](docs/architecture.md).

The numerics are the suite's kits ([FormatoKit](https://github.com/mac4DSTEM/FormatoKit),
[DiffractoKit](https://github.com/mac4DSTEM/DiffractoKit), [ImagoKit](https://github.com/mac4DSTEM/ImagoKit),
[SpectroKit](https://github.com/mac4DSTEM/SpectroKit)). A wrong number in a reader, a fit or a transform is fixed in
the kit's repository and reaches the app when `Package.swift` moves to the kit's new tag.

## The rules that matter

- **Tests move with the code.** A change comes with a test that fails before it and passes after it.
- **Numbers match the Python reference** within the tolerance that package's own tests use for the function, never
  widened to hide a bug. Readers, I/O and metadata are tested exact.
- **One focused change per commit**, with a clear message, and CI green.
- A result not yet compared with a dataset of known truth says `validation: none` until it has been.

## Licence

By contributing you agree that your contribution is licensed under the GNU General Public License v3.0 or later, as the
project is. See `LICENSE` and `NOTICE`.
