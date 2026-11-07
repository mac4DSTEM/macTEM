# SEM briefs: the queue

One brief per task of the SEM program, in the order a thread picks them up. Start a thread by file name. Phase 1
to 8 briefs are here; phase 9 (polish) is written when the rooms are in.

Order: formats (P1-01 to P1-04) and SEM images (P1-05) run at once; P1-06 waits for P1-01 and the room design;
P1-07 waits for P1-06; P1-08 runs at once; P1-09 waits for P1-01.

- [P1-01-formats-h5ebsd](P1-01-formats-h5ebsd.md)
- [P1-02-formats-edax-binary-ang](P1-02-formats-edax-binary-ang.md)
- [P1-03-formats-oxford-ebsp-ctf](P1-03-formats-oxford-ebsp-ctf.md)
- [P1-04-formats-nordif](P1-04-formats-nordif.md)
- [P1-05-sem-image-tiff-metadata](P1-05-sem-image-tiff-metadata.md)
- [P1-06-patterns-room-browser](P1-06-patterns-room-browser.md)
- [P1-07-virtual-bse-images](P1-07-virtual-bse-images.md)
- [P1-08-background-removal-core](P1-08-background-removal-core.md)
- [P1-09-demo-data-door](P1-09-demo-data-door.md)

Gates post their figures beside the references in the project chat for review only; nothing waits for an answer (Paul, 2026-11-06 22:32, decision D-SEM-26).

## Phases 2 to 8

A wave starts when its prerequisites are on `main`; within a wave every brief runs in parallel, one thread each.

Wave A, start now:
- [P2-02-fft-filters-clahe-averaging](P2-02-fft-filters-clahe-averaging.md)
- [P2-03-image-quality-adp-maps](P2-03-image-quality-adp-maps.md)
- [P2-04-detector-geometry-pc-tkd](P2-04-detector-geometry-pc-tkd.md)
- [P2-05-nlpar-denoising](P2-05-nlpar-denoising.md)
- [P3-01-rotations-symmetry](P3-01-rotations-symmetry.md)
- [P6-01-master-pattern-projection](P6-01-master-pattern-projection.md)
- [P7-01-sem-eds-quantification](P7-01-sem-eds-quantification.md)
- [P7-02-sem-eds-map-readers](P7-02-sem-eds-map-readers.md)

Wave B, once #144 (Patterns room) merges:
- [P2-01-patterns-processing-pane](P2-01-patterns-processing-pane.md)

Wave C, once P3-01 merges:
- [P3-02-vectors-projections-ipf-keys](P3-02-vectors-projections-ipf-keys.md)
- [P3-03-crystal-map-model](P3-03-crystal-map-model.md)
- [P3-05-orientation-sampling](P3-05-orientation-sampling.md)
- [P5-03-gnd-schmid-slip-traces](P5-03-gnd-schmid-slip-traces.md)

Wave D:
- [P3-04-maps-room-first-slice](P3-04-maps-room-first-slice.md) (after P3-02, P3-03)
- [P4-01-hough-indexing](P4-01-hough-indexing.md) (after P3-01, P2-04)
- [P5-01-grains-kam-gos](P5-01-grains-kam-gos.md) (after P3-03)
- [P5-02-pole-figures-odf](P5-02-pole-figures-odf.md) (after P3-02)
- [P6-02-kinematic-geometric-overlay](P6-02-kinematic-geometric-overlay.md) (after P3-02)
- [P8-01-ang-ctf-h5ebsd-writers](P8-01-ang-ctf-h5ebsd-writers.md) (after P3-03)

Wave E:
- [P4-02-dictionary-indexing](P4-02-dictionary-indexing.md) (after P3-05, P6-01)
- [P4-04-indexing-room](P4-04-indexing-room.md) (after P4-01)
- [P5-04-maps-room-complete](P5-04-maps-room-complete.md) (after P3-04)
- [P8-02-session-report](P8-02-session-report.md) (after P3-04)

Wave F:
- [P4-03-refinement-orientation-pc](P4-03-refinement-orientation-pc.md) (after P4-02)
