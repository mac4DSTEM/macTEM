# SEM program plan

macTEM grows into macEM: EBSD, TKD, ECCI, SEM imaging and SEM-EDS at mac4DSTEM's depth or deeper, scientifically
correct, in mac4DSTEM's UI. This page is the plan of record: phases, milestones tied to the north-star figures,
workstreams, gates and rules. It changes with every merge that moves the program; `docs/status.md` and `ROADMAP.md`
say what is live. Written 2026-11-06 (phase 0). Program owner: the nightly review; decisions are logged in
`docs/decisions.md` and never asked.

Companion pages: `catalogue.md` (what we port, from where, under which licence), `north-star.md` (the two studies,
their figures, numbers and tolerances), `../data-sources.md` (every dataset with source, licence and DOI),
`design/` (one design per room), `briefs/` (one brief per task, the queue).

## Boundaries

- Code only in this repo. The kits, MacEMUI and mac4DSTEM do not change; what the kits lack (HDF5 EBSD layouts,
  rotations, indexing, grains) is written in `Sources/TEMCore/SEM/` over FormatoKit's HDF5 layer and ImagoKit's
  images, with the `package` access the rest of TEMCore uses. A kit move is a later program.
- Rename, bundle IDs, the store and the website stay untouched; the 2.0.0 rename gets a release-notes draft in
  phase 9, not an execution.
- Nothing merges untested: unit tests on GitHub-hosted macOS runners, parity tests against `tools/parity/sem`,
  XCUITest journeys and screenshots on the Mac runner, queued while it is offline.

## North star

Two public studies (chosen 2026-11-06, `north-star.md` has the figures and numbers):

- **EBSD**: kikuchipy's `nickel_ebsd_large` (Aanes et al. 2020, IOP Conf. Ser.: Mater. Sci. Eng. 891 012002;
  data CC BY 4.0, Zenodo concept DOI 10.5281/zenodo.7497682): 55 x 75 patterns of 60 x 60 px of recrystallised Ni,
  NORDIF UF-1100, with its static background and the EMsoft Ni 20 kV master pattern (Zenodo 7498645).
- **SEM-EDS**: exspy's `EDS_SEM_TM002` (BAM EDS-TM002 layer standard, Zeiss Nvision40, Oxford X-Max 80; ships in
  exspy under GPL-3.0): the exspy EDS tutorial's line intensities, background windows and quantification.

Done means every north-star figure matches within its stated tolerance and the app reaches each one from the welcome
window's "Try Demo Data" with the shipped demo data.

## Milestones and figures

Each milestone reproduces one more figure; release-please tags the minor when its PRs are in.

| Milestone | Tag | Figure reproduced (north-star.md) | Rooms live | Phase |
|---|---|---|---|---|
| M1 | 1.4.0 | F1 virtual BSE image (5 x 5 grid, RGB) of nickel_ebsd_large; F2 pattern (0,0) after static and dynamic background removal | Patterns (browse, virtual images, backgrounds); SEM TIFFs in Image | 1, start of 2 |
| M2 | 1.5.0 | F3 image quality map; F4 FFT-filtered pattern; F5 moving-screen PC on si_in | Patterns complete | 2 |
| M3 | 1.6.0 | F6 orientation round trips and IPF colour key against orix; F7 misorientation angle distribution of the Ti orientations | Maps (colour key, pole figures on loaded maps) | 3 |
| M4 | 1.7.0 | F8 Hough-indexed IPF-Z map of Ni (pyEBSDindex); F9 dictionary-indexed map with the Ni master pattern; F10 refined PC and orientations | Indexing | 4 |
| M5 | 1.8.0 | F11 grain map with sizes; F12 KAM and GOS maps; F13 pole figures and ODF sections | Maps complete | 5 |
| M6 | 1.9.0 | F14 kinematic Kikuchi overlay on the indexed pattern; F15 master pattern projected to the detector | Simulation overlay in Indexing | 6 |
| M7 | 1.10.0 | F16 TM002 line intensities with background windows; F17 TM002 quantification | EDS (SEM) | 7 |
| M8 | 1.11.0 | F18 `.ang` and `.ctf` round trips; session report with every figure | Export | 8 |
| M9 | 1.12.0 | every figure again from "Try Demo Data"; screenshots; 2.0.0 release-notes draft | all | 9 |

## Phases and gates

| Phase | Scope | Exit gate |
|---|---|---|
| 0 | survey, catalogue, north star, parity environment, room designs, briefs, this plan | `plan.md` complete; `tools/parity/sem` emits the M1 references; summary in the project chat |
| 1 | data in and seen: EBSD/TKD formats (h5oina, Bruker h5, EDAX up1/up2 + ang, Oxford ctf and ebsp, kikuchipy h5ebsd, NORDIF), SEM TIFFs with metadata (Thermo, Zeiss, Tescan), the Patterns room with live navigation and virtual BSE images | F1 and F2 reproduced and posted beside the reference (for review; nothing waits, D-SEM-26) |
| 2 | pattern processing: static and dynamic background, binning, normalisation, FFT filters, IQ, PC conventions incl. TKD geometry | F3 to F5 posted |
| 3 | orientation core: rotations, symmetry, misorientation, IPF keys, pole figures, parity against orix | F6, F7 posted |
| 4 | indexing: Hough (pyEBSDindex), dictionary with master patterns, refinement of orientation and PC | F8 to F10 posted |
| 5 | maps and grains: IPF, phase, KAM, GOS, GND, grains with statistics, ODF | F11 to F13 posted |
| 6 | simulation: kinematic overlay, master-pattern reading and projection, geometrical simulation | F14, F15 posted |
| 7 | SEM-EDS: the EDS room on SEM files; quantification parity with exspy | F16, F17 posted |
| 8 | export and reports: ang/ctf writers, maps and figures with scale bars, session report | F18 posted |
| 9 | polish: every room against its design, keyboard and accessibility, 1000 x 1000 map budget, screenshots, 2.0.0 notes | final report in the project chat |

Every gate posts its figures next to the reference values for review; nothing waits for an answer or an objection
window (Paul, 2026-11-06 22:32: "finish macEM fully"; D-SEM-26). Work starts as soon as its prerequisites are on
`main`, in the waves of `briefs/README.md`.

## Workstreams

Parallel threads, one branch and PR each, from `main`, auto-merge on green. A room waits on its design doc; indexing
waits on the orientation core; everything else runs at once.

| Workstream | Phase 1 briefs | Depends on |
|---|---|---|
| Formats | P1-01 h5ebsd family (kikuchipy, Bruker, EDAX, Oxford h5oina), P1-02 EDAX binary + ang, P1-03 Oxford ebsp + ctf, P1-04 NORDIF | parity references (`tools/parity/sem`) |
| SEM images | P1-05 vendor TIFF metadata and databar | RosettaSciIO test files |
| Patterns room | P1-06 pattern browser (navigator, map, live pattern pane), P1-07 virtual BSE images | design `ebsd-patterns-room.md`; P1-01 |
| Processing | P1-08 static and dynamic background in TEMCore (M1's F2) | parity references |
| Demo data | P1-09 shipped demo EBSD set and "Try Demo Data" door | `data-sources.md` |
| Review | nightly review of the day's merges, figures against Python, issues filed, plan reordered | |

Phase 2 to 9 briefs are written at each gate from the catalogue's rows for that phase, in the same format.

## Rooms

Sidebar order: Image ⌘1, FFT ⌘2, EDS ⌘3, EELS ⌘4, Diffraction ⌘5, Patterns ⌘6, Indexing ⌘7, Maps ⌘8, Results ⌘9.
No Simulation room: the Kikuchi overlay is a layer of the Indexing room's live pattern pane, and the master pattern
is viewed in the Maps room's bottom pane (design README, decision D-SEM-5). SEM images open in the Image room; SEM-EDS
files open in the EDS room. Every room: navigator, main pane, live pattern pane open by default, inspector right,
bottom pane for results, following `design/README.md` and the suite's control-placement rules.

## Rules of the program

- **Parity first.** `tools/parity/sem` holds the pinned Python environment and emits reference arrays for every ported
  function; a Swift test compares within the tolerance the upstream package's own tests use, never stricter; CI fails on
  drift. No function ships without its parity test and its row in `docs/parity.md`.
- **Design before rooms.** A room PR cites its design doc; a departure is one sentence in the PR body.
- **Look at the screen.** Every room PR adds an XCUITest journey and screenshots under `release-assets/sem/`; the
  review step compares them with the design and files fixes before the next task.
- **Nightly review.** Once a day: open the app on demo data, exercise every room, compare with the Python figures,
  read the day's diffs, file issues, reorder this plan, post one summary. What the nightly found is fixed before new
  features.
- **Small releasable PRs.** Conventional-commit titles, auto-merge on green including numeric PRs within tolerance,
  the before/after table in the PR body. `docs/status.md` and `ROADMAP.md` move with each merge.
- **Demo data ships with the app**, public and licensed, listed in `data-sources.md`, reachable from "Try Demo Data".
- **Licence check per port**, GPL-compatible only (`catalogue.md`). Commercial tools are feature targets from public
  documentation, never code.
- **No placeholders.** Port the reference algorithm correctly first, then optimise on Accelerate or Metal behind the
  same parity test.
- **Post in the project chat** only at gates and nightly summaries, one short message each.

## Final report

At the end of phase 9: every figure, our value beside the reference, every deviation explained, open issues ranked.
