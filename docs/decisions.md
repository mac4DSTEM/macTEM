# Decisions

Engineering decisions of the SEM program, logged instead of asked (program rule, 2026-11-06). One line of context,
the decision, the reason. Numbered D-SEM-n; the room designs keep their own D1-D8 in `sem/design/README.md`.

| # | Date | Decision | Reason |
|---|---|---|---|
| D-SEM-1 | 2026-11-06 | SEM code lives in `Sources/TEMCore/SEM/` (readers, patterns, rotations, indexing, maps) and `Sources/TEMSession/` owners, over FormatoKit's HDF5 layer and ImagoKit's images; no kit changes | the program's boundary; a kit move is a later program once the API has settled |
| D-SEM-2 | 2026-11-06 | North star: kikuchipy `nickel_ebsd_large` (EBSD) and exspy `EDS_SEM_TM002` (SEM-EDS) | both public, licensed (CC BY 4.0, GPL-3.0), small enough to ship as demo data, with published figures and Python code that emits every reference number |
| D-SEM-3 | 2026-11-06 | The parity Python environment is `tools/parity/sem` on CPython 3.13 with a full lock, separate from the existing 3.14 TEM lock | kikuchipy 0.13.1 and pyebsdindex 0.3.10.1 have no 3.14 wheels yet; one stack per program keeps each lock reproducible |
| D-SEM-4 | 2026-11-06 | pyebsdindex is ported although it is not GPL: it is a US NRL public-domain work with a worldwide grant; `NOTICE` acknowledges NRL and marks the port as a modified derivative | the licence asks exactly that; it is the only open Hough indexer with tests |
| D-SEM-5 | 2026-11-06 | Rooms: Patterns ⌘6, Indexing ⌘7, Maps ⌘8, Results moves to ⌘9; no Simulation room | nine rooms is the ceiling of the ⌘1-9 keys; the simulation is a layer of the Indexing room's pattern pane. Room design decisions D1-D8: `sem/design/README.md` |
| D-SEM-6 | 2026-11-06 | Briefs live in `docs/sem/briefs/` in the repo (and are copied to the project's shared folder) | the program runs from the repo; the shared folder is not versioned |
| D-SEM-7 | 2026-11-06 | SEM-EDS quantification ships what exspy ships (line intensities, k-factor quantification with supplied factors); no ZAF | there is no GPL Python ZAF reference with tests; DTSA-II is Java and public domain and can become a later reference |
| D-SEM-8 | 2026-11-06 | Grains, KAM, GOS and GND take DefDAP (Apache-2.0) as the reference, orix for everything orientation | orix has no grain segmentation; DefDAP's is tested and its licence is compatible |
| D-SEM-9 | 2026-11-06 | Hex-grid EBSD maps are refused with a sentence in phase 1 | kikuchipy refuses them; square-grid conversion is a phase 5 issue |
| D-SEM-10 | 2026-11-06 | Zenodo-only datasets (si_wafer, ni_gain, master patterns) are fetched on the Mac; the cloud sandbox reaches PyPI and raw.githubusercontent.com only | measured 2026-11-06: zenodo.org is refused by the sandbox proxy |
| D-SEM-11 | 2026-11-06 | Phase 1 orders the formats kikuchipy h5ebsd first (the north-star file), then Oxford h5oina, Bruker and EDAX h5ebsd, EDAX binary, Oxford binary, NORDIF, ctf and ang maps | the first figure needs the first; the others follow by how common they are in labs |
