# P2-02: FFT filters, adaptive histogram equalisation and neighbour averaging (figure F4)

- **Repo:** macTEM, workstream Processing (TEMCore numerics)
- **Plan:** phase 2, M2, figure F4; catalogue section 2
- **Prerequisite:** none (runs now)
- **Size:** about 5 h

## Scope
In `Sources/TEMCore/SEM/`: kikuchipy's `filters.window.Window` (gaussian, lowpass, highpass, modified Hann, custom kernels with their parameters), `filters.fft_barnes` (Barnes et al. 2016: padding, the real FFT, crop), `EBSD.fft_filter` in frequency and spatial modes; `EBSD.adaptive_histogram_equalization` (scikit-image's CLAHE: kernel size, clip limit, nbins; port `skimage.exposure.equalize_adapthist` step for step, float64); `EBSD.average_neighbour_patterns` (window shapes, weights, the edge rule). FFT through Accelerate vDSP in TEMCore (ImagoKit's FFT may be called, not changed). The Patterns room gains them in P2-01's Processing list once both are in (a follow-up step of whichever lands second).

## Done when
F4 reproduced: pattern (0,0) of nickel_ebsd_large after the Gaussian highpass + lowpass `fft_filter` of kikuchipy's docs example equals the reference within rtol 1e-5; CLAHE exact on uint8; averaging rtol 1e-5 on the 3 x 3 Gaussian window; rows in `docs/parity.md`.

## Gates (every brief)
- Branch from `main`, one PR, conventional-commit title, `Fixes macEMSuite/macEM#<n>`, auto-merge on green. Never stack on another open branch; a brief whose prerequisite is not merged waits for it.
- A test that fails before and passes after. Numerics compare against a `tools/parity/sem` bundle (add the case to `emit.py`, commit the bundle) within the upstream tolerance stated in `docs/parity.md`; the before/after table goes in the PR body. Numeric PRs in the SEM program auto-merge within tolerance.
- `tools/run-tests.sh unit` green on CI; the inventory rules (UI contract rule 4: numeric frames from `LayoutPolicy`; member imports in tests). TEMCore nonisolated, heavy work through `@concurrent`, no SwiftUI below the app. Float64 CPU path on Accelerate is the reference; a Metal float32 path only where size pays, checked against CPU.
- Code only in macTEM: no change to the kits, MacEMUI or mac4DSTEM; a kit API that is missing is ported into TEMCore with its source named.
- UI work loads the `swiftui-macos` skill, reads the room's design doc and `process/control-placement.md`; a change to what the app draws adds an XCUITest journey step and says "unverified on screen" until a drive saw it.
- Decisions appended to `docs/decisions.md` (take the next free number at merge time); leftover work becomes an issue. No placeholders, no stubs, no "later" comments. Licence of every ported file checked against `docs/sem/catalogue.md` and named in `NOTICE`.
- At the end of a phase, the thread holding its last figure posts the figures beside the references (for review only; nothing waits).
