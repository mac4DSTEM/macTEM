# The SEM program's north star

Two published studies with public raw data and figures. Every milestone reproduces one more of their figures; the
program is done when all of them match and the app does each end to end from the welcome window on shipped demo
data. The numbers below come from the pinned Python stack (`tools/parity/sem/requirements.lock`: kikuchipy 0.13.1,
orix 0.15.0, HyperSpy 2.5.0, exspy 0.3.2, RosettaSciIO 0.15.0, pyEBSDindex 0.3.10.1 on CPython 3.14.6) run on the
data `docs/data-sources.md` names; the reference bundles under `tools/parity/sem/references/` hold them in full, each
array with its tolerance, and `tools/parity/sem/check.py` keeps them from drifting. A figure "matches" when every
array behind it passes its bundle's tolerance in `macTEMTests`.

## Study 1, EBSD: Ånes et al. 2020, recrystallised nickel

Ånes, H. W., Hjelen, J., Sørensen, B. E., van Helvoort, A. T. J. & Marthinsen, K. (2020). *Processing and indexing of
electron backscatter patterns using open-source software*, IOP Conf. Ser.: Mater. Sci. Eng. 891, 012002. Data: the
authors' Ni gain series (Zenodo 10.5281/zenodo.7497682, CC BY 4.0), of which kikuchipy's `nickel_ebsd_large`
(55 x 75 patterns of 60 x 60 px, 1.5 µm step, 20 kV, NORDIF UF-1100) is the cut the kikuchipy tutorials draw their
figures from. The figures are the paper's and the kikuchipy user guide's (pattern processing, virtual BSE imaging,
Hough indexing, dictionary indexing, orientation refinement) on that cut.

Scan facts (bundle `m1/read-nickel-ebsd-large`): navigation 55 rows x 75 columns, detector 60 x 60 px, uint8,
binning 8, sample tilt 70°, projection centre of pattern (0, 0) in the Bruker convention
(0.42772, 0.21212, 0.50027), static background in the file, crystal map of one phase (ni, 4125 points, properties
`scores` and `z`). Pattern (0, 0): min 24, max 240, mean 147.5917. Whole-scan mean intensity per pattern (the
navigator map): 117.048 to 148.615, mean 145.4218.

### Figure 1 (milestone 1): virtual BSE image and the first processed pattern

Kikuchipy user guide, *Virtual backscatter electron imaging*, and *Pattern processing*, on `nickel_ebsd_large`.

| Part | Reference | Bundle | Arrays and tolerance |
| --- | --- | --- | --- |
| 5 x 5 detector grid, one virtual BSE image per tile (sum of the tile's pixels per pattern; tile (r, c) covers rows 12r..12r+12, columns 12c..12c+12, half-open) | `kikuchipy.imaging.VirtualBSEImager.get_images_from_grid` | `m1/vbse-nickel-ebsd-large` | `grid_images` float32 [5, 5, 55, 75], exact (integer sums; range 6055 to 31664); `tile_bounds` in values |
| RGB virtual BSE image from tiles (2, 1), (2, 2), (2, 3), each channel min-max rescaled to 0..255 | `VirtualBSEImager.get_rgb_image(normalize=True)` | same | `rgb_image` uint8 [55, 75, 3], atol 1 count (rounding); channel means 115.27, 122.92, 129.50; pixel (0, 0) = (156, 199, 177) |
| One explicit rectangular ROI (left 10, top 20, right 50, bottom 40 px) | `EBSD.get_virtual_bse_intensity` | same | `roi_image` float64 [55, 75], exact |
| Mean intensity per pattern (navigator) | `EBSD.data.mean(axis=(-2, -1))` | same | `mean_intensity_map` float64 [55, 75], rtol 1e-7 |
| Pattern (0, 0) after static background subtraction (the file's background, `operation="subtract"`) | `EBSD.remove_static_background` | `m2/background-nickel-ebsd-large` | `after_static_first` uint8 [60, 60], atol 1; the whole scan's sha256 in values |
| Pattern (0, 0) after static then dynamic background (Gaussian std = 60/8 = 7.5 px in the frequency domain, truncate 4) | `EBSD.remove_dynamic_background` | same | `after_static_and_dynamic_first` uint8 [60, 60], atol 1 (min 0, max 255, mean 119.6214); a 3 x 3 corner of the scan as `after_static_and_dynamic_corner` |

The same arrays on the committed 3 x 3 cut (`m1/vbse-kikuchipy-h5ebsd`, `m2/background-kikuchipy-h5ebsd`) run in
every unit test run without a download: a port passes there first. Milestone 1 also lands the readers:

| Format | Bundle | What is exact |
| --- | --- | --- |
| kikuchipy h5ebsd (3 x 3 and the full scan) | `m1/read-kikuchipy-h5ebsd`, `m1/read-nickel-ebsd-large` | shapes, axes (1.5 µm), detector, PC per pattern, static background, patterns (sha256 of the whole array, first and last pattern as files), per-pattern min/max (exact) and mean (rtol 1e-7), mean pattern, crystal map head (Euler, rtol 1e-7) |
| NORDIF `Pattern.dat` + `Setting.txt` | `m1/read-nordif` | the same, with the SEM metadata of Setting.txt (Hitachi SU-6600, 20 kV, 200 x, WD 24.7 mm) |
| Oxford binary `.ebsp` | `m1/read-oxford-binary` | the same |
| Oxford H5OINA | `m1/read-oxford-h5oina` | the same, PC per pattern, static background, crystal map |
| Bruker Esprit h5ebsd | `m1/read-bruker-h5ebsd` | the same |
| EDAX `.up1` (9 patterns uint8) and `.up2` (10 patterns uint16, hex grid, x step 1.5708 µm) | `m1/read-edax-up1`, `m1/read-edax-up2` | the same |
| EDAX h5ebsd | `m1/read-edax-h5ebsd` | the same, crystal map, WD 24.7 mm and 200 x |
| EMsoft EBSD (one 640 x 480 simulated pattern) | `m1/read-emsoft-ebsd` | the same, PC (0.4688, 0.4583, 0.625), 20 kV |
| EDAX `.ang` orientation map (duplex steel, 100 x 117 at 1.5 µm) | `m1/read-ang-sdss-ferrite-austenite` | size 11700, phases austenite (5657 points) and ferrite (6043), `phase_id` exact, Euler/x/y/dp/iq heads rtol 1e-7, Euler sha256 |
| Oxford `.ctf` (planted 4 x 5, one not-indexed point) | `m1/read-ctf-planted-oxford` | the same, properties bands, error, MAD, BC, BS |
| Zeiss SmartSEM TIFF | `m1/read-sem-tiff-zeiss` | pixels exact (512 x 384 uint8, mean 149.59065), pixel size 1.1649976e-8 m, 5 kV, "50.00 K X", WD 3.9 mm, stage (x 62.9961, y 65.3168, z 44.678, rotation 245.8, tilt 0), date 2018-09-25 08:20:42, author LIBERATO |
| Thermo/FEI Helios TIFF | `m1/read-sem-tiff-fei-helios` | pixels exact (512 x 471 uint8, mean 3.06674), pixel size 3.3724e-6 m, 5 kV, 6.25 nA, dwell 1e-5 s, WD 4.03466 mm, stage, date 2016-06-13 17:06:40 |

### Figure 2 (milestone 2): pattern processing

Kikuchipy *Pattern processing*: the static and dynamic background figures above on the whole scan (the sha256 in
`m2/background-nickel-ebsd-large` is the exact claim), then binning, normalisation to zero mean and unit variance,
the FFT filters, and the moving-screen projection-centre estimate on `si_in.h5` (bundles to be emitted with the
phase, same stack).

### Figure 3 (milestone 3): orientation maths

orix: rotations, quaternions, the m-3m symmetry of Ni, misorientation and IPF colour keys on the file's crystal map.
Reference `orix.plot.IPFColorKeyTSL` colours of the 4125 orientations and the pairwise misorientation of the first
16 points, rtol 1e-7 (bundles with the phase).

The orientation core underneath it (P3-01), on inputs that need no download (`fixtures/orientation_inputs.json`):

| What | Reference | Bundle | Tolerance |
| --- | --- | --- | --- |
| Every conversion of Rowenhorst et al. (2015) (Euler, matrix, axis-angle, Rodrigues and Rodrigues-Frank, homochoric, cubochoric), composition, inverse, angles, vector action (proper and improper), outer products, `unique` on 64 rotations with seven special ones | `orix.quaternion.Rotation`, `_conversions` | `m3/rotation-conversions` | atol 1e-7; indices exact; +∞ two-fold Rodrigues-Frank lengths equal |
| The 38 point-group objects (32 groups with their axis settings) and the aliases 2, m, 32: elements in orix's order, improper flags, proper subgroup, Laue group and its proper subgroup, system, Euler region, subgroups, inverse-pole-figure sector, fundamental zone | `orix.quaternion.symmetry` | `m3/point-groups` | elements and normals 1e-10; names and flags exact |
| The orientation fundamental zone of each group and the misorientation zone of each pair (G, G) | `OrientationRegion.from_symmetry` | `m3/orientation-regions` | normals 1e-10 |
| The first 2000 Ti orientations of orix-data (622) and 100 seeded m-3m orientations (the Ni symmetry): reduced orientations, neighbour angles, disorientations of neighbours, orientation and misorientation distance matrices | `Orientation.reduce`, `angle_with`, `-`, `get_distance_matrix` | `m3/ti-disorientations` | atol 1e-7 |

### Figure 4 (milestone 4): the indexed map

The paper's Figure 3 and the kikuchipy *Hough indexing* and *Dictionary indexing* tutorials: the IPF-Z map of the
scan indexed with pyEBSDindex (Hough, Ni, PC from the file's mean), with the dictionary method against the Ni 20 kV
master pattern (`ni_mc_mp_20kv.h5`, manual fetch), and after orientation and PC refinement. Reference values: the
indexed Euler angles, the normalised cross-correlation scores and the orientation-similarity map. Tolerance: the
tutorials state none; the misorientation between our map and the reference is held under 1° per point for 99 % of
points, and the score arrays within rtol 1e-5 (the pattern matching runs in float32).

### Figure 5 (milestone 5): maps and grains

orix on the indexed map: KAM, GOS, grain segmentation at 5°, grain size statistics, ODF. Reference arrays from orix
on the same map, rtol 1e-7 for angles, exact for grain ids after relabelling by size.

Slip analysis and dislocation content (P5-03), DefDAP 1.3.1 on inputs that need no download
(`fixtures/slip_inputs.json`: a 90 x 120 corner of orix-data's Ti map and the whole sdss map):

| What | Reference | Bundle | Tolerance |
| --- | --- | --- | --- |
| hcp Ti (`hexagonal_withca`, 24 systems in 10 plane groups): slip-system vectors, DefDAP quaternions, Nye tensor and GND density (DefDAP as shipped and with separate x and y derivatives, D-SEM-38), grains at 10° (13), their average orientations, Schmid factors for a load along x, slip-trace angles and inclinations, and the same per orientation for every 37th point under loads along x and y | `defdap.ebsd.Map.calc_nye`, `find_grains`; `Grain.calc_average_ori`, `calc_average_schmid_factors`, `calc_slip_traces`; `crystal.SlipSystem.load` | `m5/slip-ti` | Schmid factors and angles atol 1e-6; GND and Nye rtol 1e-5 (atol 1e6 m⁻²); vectors and quaternions 1e-12; grain averages 1e-10; indices exact |
| The duplex steel: fcc austenite (`cubic_fcc`, 12 systems) and bcc ferrite (`cubic_bcc`, 48 rows in 30 plane groups), the same quantities, 102 grains | as above | `m5/slip-sdss` | as above |

### Figure 6 (milestone 6): geometrical simulation

Kikuchipy *Geometrical EBSD simulations*: Kikuchi bands and zone axes of the indexed orientation drawn on the
experimental pattern (0, 0); band and zone-axis detector coordinates rtol 1e-7.

## Study 2, SEM-EDS: the BAM EDS-TM002 standard in exspy

exspy's bundled SEM-EDS spectrum of the BAM EDS-TM002 thin-film standard (C, Al, Mn, Cu and Zr, about 6 µm, on
Si), Zeiss Nvision40 at 10 kV, Oxford X-Max 80, elevation 37°, 20.0 s live time, 130 eV resolution at Mn Kα; the
figures are the exspy EDS tutorial's: the spectrum with its lines marked, the line windows with background windows,
the line-intensity table. Reader bundle `m1/read-eds-msa-tm002`: 1024 channels, 10 eV from -0.1 keV, 1 000 279
counts in total, every count exact.

### Figure 7 (milestone 7): line intensities with background windows

Bundle `m7/eds-lines-tm002`, `exspy.signals.EDSSEMSpectrum.get_lines_intensity`, integration windows 2.0 x FWHM,
background windows `estimate_background_windows(line_width=[5.0, 2.0])`:

| Line | Energy keV | Integration window keV | Raw counts | Background-subtracted |
| --- | --- | --- | --- | --- |
| Al Kα | 1.4865 | 1.4099 to 1.5631 | 84163 | 69287.29 |
| C Kα | 0.2774 | 0.2240 to 0.3308 | 89063 | 77683.00 |
| Cu Lα | 0.9295 | 0.8626 to 0.9964 | 96117 | 83885.31 |
| Mn Lα | 0.6332 | 0.5720 to 0.6943 | 96700 | 85734.00 |
| Zr Lα | 2.0423 | 1.9571 to 2.1275 | 99075 | 82215.86 |

Tolerance rtol 1e-7 on the intensities and the window edges. Quantification (Cliff-Lorimer with k-factors, as the
tutorial does it) follows in the same milestone once the k-factors it uses are recorded with their source.

### Figure 8 (milestone 8): export

The `.ang` and `.ctf` writers round-trip the indexed map through orix (exact after the writers' decimal places),
and the exported figures carry scale bars.

## Tolerances, the rule

Readers, indices and metadata are exact. A reduction in float64 matches at rtol 1e-7 (numpy's `assert_allclose`
default). A result the reference rounds to uint8 matches within one count. A float32 pattern-matching score matches
at rtol 1e-5. Never stricter than the reference package's own tests; where a tutorial states no tolerance, the one
here is written next to the figure and in the bundle.
