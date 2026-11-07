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
| `emsoft_ebsd_master_pattern_ni_mc_mp_20kv_uint8_gzip_opts9.h5` (fixture, 0.9 MB); shipped in the app as `DemoData/ni_mc_mp_20kv_uint8_gzip_opts9.h5` | The same EMsoft Ni 20 kV master pattern as the next row, 401 x 401 px Lambert and stereographic, both hemispheres, reduced to uint8 with gzip by kikuchipy's own script (`kikuchipy.data.nickel_ebsd_master_pattern_small`); the master pattern of figure F15 and of the app's demo (md5 `807c8306a0d02b46effbcb12bd44cd02`, kikuchipy's registry) | kikuchipy 0.13.1 package data (`kikuchipy/data/emsoft_ebsd_master_pattern/`) | CC BY 4.0 (data), GPL-3.0 (package) | As the next row; EMsoft: Callahan, P. G. & De Graef, M. (2013), *Dynamical electron backscatter diffraction patterns. Part I*, Microsc. Microanal. 19, 1255, doi:10.1017/S1431927613001840 |
| `ebsd_master_pattern/ni_mc_mp_20kv.h5` (manual) | EMsoft Ni master pattern at 20 kV in float32 at full resolution, for dictionary indexing (phase 4) where the uint8 copy above is not enough | Zenodo record 7498645 (kikuchipy's registry; md5 `8b69c071a036ad3488d465093b67fe4d`) | CC BY 4.0 | Ånes, H. W. (2023). *EBSD master pattern of nickel at 20 kV*, doi:10.5281/zenodo.7498645 |
| `exspy_EDS_SEM_TM002.hspy` / `.msa` (fixture, 31 KB); shipped in the app as `DemoData/EDS_SEM_TM002.hspy` (macTEM#127) | One SEM-EDS spectrum, 1024 channels at 10 eV from -0.1 keV, of the BAM EDS-TM002 thin-film standard (C, Al, Mn, Cu, Zr on Si), Zeiss Nvision40 at 10 kV, Oxford X-Max 80, 20 s live time (`exspy.data.EDS_SEM_TM002`); the `.msa` twin is HyperSpy's EMSA export of the same signal | exspy 0.3.2 package data (`exspy/data/EDS_SEM_TM002.hspy`), original `1D_EDS_SEM_Spectrum.msa` of the HyperSpy demos | GPL-3.0 (exspy) | exspy: doi:10.5281/zenodo.10700224; HyperSpy: de la Peña, F. et al., doi:10.5281/zenodo.592838. Sample: BAM EDS-TM002 (www.webshop.bam.de) |

## Datasets (downloaded)

| Dataset | What | Source | Licence | DOI / citation |
| --- | --- | --- | --- | --- |
| `silicon_ebsd_moving_screen/si_in.h5` (0.5 MB) | One 480 x 480 EBSD pattern of single-crystal Si, NORDIF UF-420, normal screen position (`kikuchipy.data.si_ebsd_moving_screen(0)`); the moving-screen projection-centre test of phase 2 | github.com/pyxem/kikuchipy-data `bcab8f7a` | CC BY 4.0 | Ånes, H. W. et al. (2022), Zenodo doi:10.5281/zenodo.7491388 (`ebsd_si_wafer`); Hjelen, J. et al. (1991), *Electron diffraction in the SEM*, Micron Microsc. Acta 22, 137 |
| `silicon_ebsd_moving_screen/si_out5mm.h5` (0.5 MB) | The same Si crystal and beam position with the detector 5 mm further out (`kikuchipy.data.si_ebsd_moving_screen(5)`); the second pattern of figure F5, drawn by `detector_figure.py` | github.com/pyxem/kikuchipy-data `bcab8f7a` | CC BY 4.0 | as si_in.h5 |
| `orix/sdss_ferrite_austenite.ang` (0.65 MB) | EDAX .ang orientation map, 100 x 117 points at 1.5 µm, two phases (austenite 5657 points, ferrite 6043) of a super duplex stainless steel, with dot product and image quality (`orix.data.sdss_ferrite_austenite`) | github.com/pyxem/orix-data `main`, served from raw.githubusercontent.com | CC BY 4.0 (orix-data) | orix: Johnstone, D. N. et al. (2020), *Density-based clustering of crystal (mis)orientations and the orix Python library*, J. Appl. Cryst. 53, 1293, doi:10.1107/S1600576720011103; data doi:10.5281/zenodo.3625780 |
| `orix/Ti_orientations.ctf` (29.6 MB, fetched by `fetch-data.sh`) | The whole Ti map: 193 167 points, 381 x 507 at 0.25 µm, MTEX export (13 columns, Bunge angles in degrees, point group 622); figure F7 (`m3/ti-neighbour-misorientations-full`) | github.com/pyxem/orix-data `main`, served from raw.githubusercontent.com | CC BY 4.0 (orix-data) | Krakow, R. et al. (2017), *On three-dimensional misorientation spaces*, Proc. R. Soc. A 473, 20170274, doi:10.1098/rspa.2017.0274; orix: Johnstone, D. N. et al. (2020), J. Appl. Cryst. 53, 1293 |
| `orix/Ti_orientations.ctf`, first 2000 rows (committed: `macTEMTests/Fixtures/sem/oxford/ti_orientations_head.ctf`; its Bunge angles in `tools/parity/sem/fixtures/orientation_inputs.json`) | Ti orientations exported from MTEX (Bunge angles in degrees, point group 622), the orix orientation tutorials' map (`orix.data.ti_orientations`) | github.com/pyxem/orix-data `main`, served from raw.githubusercontent.com | CC BY 4.0 (orix-data) | orix: Johnstone, D. N. et al. (2020), J. Appl. Cryst. 53, 1293, doi:10.1107/S1600576720011103 |
| `orix/Ti_orientations.ctf`, rows 0-89, columns 0-119 (committed: `tools/parity/sem/fixtures/grain_inputs.json`, Bunge angles in degrees as written) | the input of the grain bundle `m5/grains-ti` (P5-01); the whole map is figures F11 and F12 (`m5/grains-ti-full`, fetched) | github.com/pyxem/orix-data `main`, served from raw.githubusercontent.com | CC BY 4.0 (orix-data) | orix: Johnstone, D. N. et al. (2020), J. Appl. Cryst. 53, 1293, doi:10.1107/S1600576720011103 |
| `orix/Ti_orientations.ctf`, rows 0-89, columns 0-119, and the whole `orix/sdss_ferrite_austenite.ang` (committed: `tools/parity/sem/fixtures/slip_inputs.json`, the files' Bunge angles as written and the sdss phase ids) | the input of the slip-analysis bundles `m5/slip-ti` and `m5/slip-sdss` (P5-03) | as above | CC BY 4.0 (orix-data) | as above |

## Fixtures (committed)

| Fixture | What | Source | Licence |
| --- | --- | --- | --- |
| `kikuchipy_h5ebsd_patterns.h5` | 3 x 3 patterns of 60 x 60 px cut from the Ni dataset above, kikuchipy h5ebsd with static background, PCs and crystal map (`kikuchipy.data.nickel_ebsd_small`) | kikuchipy 0.13.1 package data | CC BY 4.0 (data), GPL-3.0 (package) |
| `detector_geometry_cases.json` | The inputs of the detector-geometry and moving-screen bundles (figure F5): detector shapes, projection centres, angles, and the zone-axis points kikuchipy's tutorial and tests mark on `si_ebsd_moving_screen` | kikuchipy 0.13.1 tests and tutorial (points); chosen for the SEM program (the rest) | GPL-3.0 |
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
| `emsoft_ebsd_master_pattern_ni_mc_mp_20kv_uint8_gzip_opts9.h5` | The Ni 20 kV master pattern, see above | kikuchipy 0.13.1 package data | CC BY 4.0 (data), GPL-3.0 (package) |
| `emsoft_ebsd_master_pattern_dummy.h5` | A 13 x 13 float32 EMsoft EBSD master pattern file of 11 energies (10 to 20 kV), Lambert and stereographic, both hemispheres, of kikuchipy's Al2Cu test phase (`master_patterns.h5`) | kikuchipy 0.13.1 package data | GPL-3.0 |
| `planted_emsoft_tkd_master_pattern.h5`, `planted_emsoft_ecp_master_pattern.h5` | The same 13 x 13 x 11-energy layout as EMsoft TKD and ECP master pattern files, written as kikuchipy's test fixtures write them (`kikuchipy/conftest.py`); kikuchipy ships no TKD or ECP file | this repo (`make_fixtures.py`) | GPL-3.0 |

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
