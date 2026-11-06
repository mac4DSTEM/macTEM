# Data sources

Every public dataset the SEM program reads, with its source, licence and DOI. Two kinds:

- **Fixtures** are committed under `tools/parity/sem/fixtures/` (each under 1 MB; `SHA256SUMS` beside them is checked
  by CI and by `SEMParityHarnessTests`). They are the inputs of the committed reference bundles.
- **Datasets** are downloaded by `tools/parity/sem/fetch-data.sh` into `References/sem-data/` (gitignored) from
  `tools/parity/sem/data-manifest.txt`, which holds each file's URL and sha256. Zenodo-hosted files are marked
  `manual` in the manifest: the cloud runners cannot reach Zenodo, so they are fetched on the Mac.

The licence rule (program spec, 2026-11-06): GPL-compatible only. macTEM is GPL-3.0-only; CC BY 4.0 data and GPL-3
test files are compatible, and each entry below says which it is. Demo data shipped with the app is listed in the
"Shipped with the app" section once a build carries it.

## North-star datasets

| Dataset | What | Source | Licence | DOI / citation |
| --- | --- | --- | --- | --- |
| `nickel_ebsd_large/patterns_v2.h5` (15.4 MB); shipped in the app as `DemoData/nickel_ebsd_large/patterns_v2.h5` (macTEM#127) | 55 x 75 EBSD patterns of 60 x 60 px (uint8), recrystallised Ni, NORDIF UF-1100 on a Hitachi SU-6600 at 20 kV, 1.5 µm step; kikuchipy h5ebsd with static background, per-pattern projection centres and the indexed crystal map (`kikuchipy.data.nickel_ebsd_large`) | github.com/pyxem/kikuchipy-data at commit `bcab8f7a`, served from raw.githubusercontent.com | CC BY 4.0 | Ånes, H. W., Hjelen, J., Sørensen, B. E., van Helvoort, A. T. J. & Marthinsen, K. (2019). *Electron backscatter patterns from Nickel acquired with varying camera gain*. Zenodo, concept DOI 10.5281/zenodo.7497682 (version record 7498632). Paper: Ånes et al. (2020), *Processing and indexing of electron backscatter patterns using open-source software*, IOP Conf. Ser.: Mater. Sci. Eng. 891, 012002, doi:10.1088/1757-899X/891/1/012002 |
| `ebsd_master_pattern/ni_mc_mp_20kv.h5` (manual) | EMsoft Ni master pattern at 20 kV, for dictionary indexing and geometrical simulation (phases 4 and 6) | Zenodo record 7498645 (kikuchipy's registry; md5 `8b69c071a036ad3488d465093b67fe4d`) | CC BY 4.0 | Ånes, H. W. (2023). *EBSD master pattern of nickel at 20 kV*, doi:10.5281/zenodo.7498645 |
| `exspy_EDS_SEM_TM002.hspy` / `.msa` (fixture, 31 KB); shipped in the app as `DemoData/EDS_SEM_TM002.hspy` (macTEM#127) | One SEM-EDS spectrum, 1024 channels at 10 eV from -0.1 keV, of the BAM EDS-TM002 thin-film standard (C, Al, Mn, Cu, Zr on Si), Zeiss Nvision40 at 10 kV, Oxford X-Max 80, 20 s live time (`exspy.data.EDS_SEM_TM002`); the `.msa` twin is HyperSpy's EMSA export of the same signal | exspy 0.3.2 package data (`exspy/data/EDS_SEM_TM002.hspy`), original `1D_EDS_SEM_Spectrum.msa` of the HyperSpy demos | GPL-3.0 (exspy) | exspy: doi:10.5281/zenodo.10700224; HyperSpy: de la Peña, F. et al., doi:10.5281/zenodo.592838. Sample: BAM EDS-TM002 (www.webshop.bam.de) |

## Datasets (downloaded)

| Dataset | What | Source | Licence | DOI / citation |
| --- | --- | --- | --- | --- |
| `silicon_ebsd_moving_screen/si_in.h5` (0.5 MB) | One 480 x 480 EBSD pattern of single-crystal Si, NORDIF UF-420, normal screen position (`kikuchipy.data.si_ebsd_moving_screen(0)`); the moving-screen projection-centre test of phase 2 | github.com/pyxem/kikuchipy-data `bcab8f7a` | CC BY 4.0 | Ånes, H. W. et al. (2022), Zenodo doi:10.5281/zenodo.7491388 (`ebsd_si_wafer`); Hjelen, J. et al. (1991), *Electron diffraction in the SEM*, Micron Microsc. Acta 22, 137 |
| `orix/sdss_ferrite_austenite.ang` (0.65 MB) | EDAX .ang orientation map, 100 x 117 points at 1.5 µm, two phases (austenite 5657 points, ferrite 6043) of a super duplex stainless steel, with dot product and image quality (`orix.data.sdss_ferrite_austenite`) | github.com/pyxem/orix-data `main`, served from raw.githubusercontent.com | CC BY 4.0 (orix-data) | orix: Johnstone, D. N. et al. (2020), *Density-based clustering of crystal (mis)orientations and the orix Python library*, J. Appl. Cryst. 53, 1293, doi:10.1107/S1600576720011103; data doi:10.5281/zenodo.3625780 |

## Fixtures (committed)

| Fixture | What | Source | Licence |
| --- | --- | --- | --- |
| `kikuchipy_h5ebsd_patterns.h5` | 3 x 3 patterns of 60 x 60 px cut from the Ni dataset above, kikuchipy h5ebsd with static background, PCs and crystal map (`kikuchipy.data.nickel_ebsd_small`) | kikuchipy 0.13.1 package data | CC BY 4.0 (data), GPL-3.0 (package) |
| `nordif/Pattern.dat`, `nordif/Setting.txt` | The same 3 x 3 scan as a NORDIF binary with its settings file | kikuchipy 0.13.1 package data | GPL-3.0 |
| `oxford_binary_patterns.ebsp` | The same 3 x 3 scan as an Oxford Instruments binary (version 1 `.ebsp`) | kikuchipy 0.13.1 package data | GPL-3.0 |
| `edax_binary.up1`, `edax_binary.up2` | EDAX TSL binaries: 9 patterns uint8 (up1, square grid) and 10 patterns uint16 (up2, hexagonal grid) | kikuchipy 0.13.1 package data | GPL-3.0 |
| `edax_h5ebsd_patterns.h5` | The 3 x 3 scan as an EDAX h5ebsd file with its indexed map | kikuchipy 0.13.1 package data | GPL-3.0 |
| `emsoft_ebsd_EBSD_TEST_Ni.h5` | One 640 x 480 simulated Ni pattern as EMsoft's EBSD HDF5 output (`EMEBSD`), with PC and orientation | kikuchipy 0.13.1 package data | GPL-3.0 |
| `oxford_h5oina_patterns.h5oina`, `bruker_h5ebsd_patterns.h5` | The 3 x 3 scan as an Oxford AZtec H5OINA (format 7.0) and a Bruker Esprit h5ebsd, written by kikuchipy's dummy-file writers (`tools/parity/sem/make_fixtures.py`) | kikuchipy 0.13.1 `kikuchipy.data._dummy_files` | GPL-3.0 |
| `planted_oxford.ctf` + `.truth.json` | A hand-written Oxford Channel 5 text file, 4 x 5 points, fcc and bcc iron, one not-indexed point. No public `.ctf` of a known licence was found on 2026-11-06 and orix 0.15.0 has no `.ctf` writer | this repo (`make_fixtures.py`) | GPL-3.0 |
| `rsciio_Zeiss_SEM_512pix.tif` | A 512 x 384 Zeiss SmartSEM TIFF (ULTRA 55, 5 kV, CZ_SEM tag: pixel size 11.65 nm, WD 3.9 mm, stage) | RosettaSciIO 0.15.0 test data `tiff_Zeiss_SEM.zip` | GPL-3.0 |
| `rsciio_FEI_Helios_Ebeam_8bits.tif` | A 512 x 471 Thermo/FEI Helios NanoLab 660 TIFF (5 kV, FEI_HELIOS tag: pixel size 3.3724 µm, dwell 10 µs, stage) | RosettaSciIO 0.15.0 test data `tiff_FEI_Helios.zip` | GPL-3.0 |
| `exspy_EDS_SEM_TM002.hspy`, `.msa` | The north-star SEM-EDS spectrum, see above | exspy 0.3.2 package data | GPL-3.0 |

## Gaps on 2026-11-06

- No public **Tescan** SEM image with its metadata header was found; RosettaSciIO has no Tescan test file. The
  Tescan reader waits for a licensed example (an issue is filed when the reader is scheduled).
- No public **Oxford .ctf** map; the planted file above covers the reader until one is found.
- **TKD** patterns: none public with a stated licence yet; the TKD geometry of phase 2 is checked against kikuchipy
  on the Ni data with the detector tilted as a TKD setup would be (a geometry test, not a TKD dataset).

## Shipped with the app

Since macTEM#127 (2026-11-06), reachable from "Try Demo Data":

| Bundle path | Dataset | Size | Licence |
| --- | --- | --- | --- |
| `DemoData/nickel_ebsd_large/patterns_v2.h5` | kikuchipy `nickel_ebsd_large`, the EBSD north star | 15.4 MB | CC BY 4.0 |
| `DemoData/EDS_SEM_TM002.hspy` | exspy `EDS_SEM_TM002`, the SEM-EDS north star | 31 KB | GPL-3.0 |
