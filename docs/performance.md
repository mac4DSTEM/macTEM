# Performance (UI-driven, 2026-10-21)

`tools/run-tests.sh ui PerformanceJourney` (not in the default `ui` run). `macTEMUITests/PerformanceJourney.swift`: five iterations per
action, each a fresh launch of the real app (Debug, kits `-O`) on the generated demo documents; the measured span runs from the click to the
element that shows the result. Machine: MacBook Pro, Apple M5 Pro (Mac17,9), macOS 27.0.1. Commit: 6f9d0c5 plus the signposts. Medians of five;
the range is under 3 % everywhere except the memory peak of the EDX action (240 to 245 MB).

| Action (demo document) | Wall clock (driver) | In the app (signpost) | Peak memory | CPU time |
|---|---|---|---|---|
| Open the demo image (launch to the file listed; 512 x 512) | 1.88 s | none (the demo is built in memory, not read from a file) | 184 MB | 0.66 s |
| FFT: click a spot, read d, then Find Spots (512 x 512) | 5.62 s | spot 2.4 ms, finder 17 ms (the transform runs before the window) | 269 MB | 2.38 s |
| EDX: Quantify to the composition table (spectrum image, pooled fit) | 2.88 s | 693 ms (spectrum, windows, fit) | 239 MB | 8.99 s |
| EELS: launch, room, a pixel's t/λ (16 x 16 x 1024) | 6.42 s (includes the launch) | map 102 ms | 170 MB | 1.16 s |
| Particles: Show Objects to the count (512 x 512, five discs) | 4.91 s | 15 ms | 264 MB | 1.27 s |
| Stack: Next to frame 2 shown (24 frames of 128 x 128) | 3.76 s | frame read 0.4 ms | 195 MB | 1.15 s |

Signposts are the median of five intervals inside the app (`Signposts` in `TEMCore`: `fft.spectrum`, `fft.spot`, `fft.find`, `edx.refresh`, `eels.map`,
`particles.analyse`, `stack.frame`, `open.image`), read by `XCTOSSignpostMetric` beside the clock. The demo documents are small and planted; the
real-data numbers (a 2048 x 2048 image, a full EDX cube) come with the owner's files.

## How to read these

The clock includes XCUITest's own cost: each `waitFor` / `waitValue` is an accessibility query of the window, and a click is a synthesized
event. The stack step reads one small frame from disk and costs 3.8 s, so about 3 s of every clock figure above is the driver, not the app (the signposts show it: the frame read takes 0.4 ms). Treat
the table as a regression guard (the same action should stay within a few percent run to run, as it does here), and as an upper bound
per action; it does not rank the actions against each other. CPU time is the app's own and does show real work: the EDX fit is the one action
that uses several cores (8.9 s of CPU in 2.9 s of wall clock).

The signpost column is the app's own compute time and is what to compare between commits; the clock column is the user-visible total with the driver's cost in it. A signpost that is not listed for an action ran before the measured window (the FFT transform runs when the room opens).
