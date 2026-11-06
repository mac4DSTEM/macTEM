# SEM feature catalogue

What the open-source SEM stack does, by workflow, with the source we port from, its licence, the paper behind each
algorithm and the public data it is tested on. Written 2026-11-06 for the SEM program (`plan.md`); the catalogue is the
list every brief and parity test draws from. A function not in this table is not ported until it is added here with its
four columns.

Versions pinned for the parity environment (`tools/parity/sem`, PyPI on 2026-11-06): kikuchipy 0.13.1, orix 0.15.0,
diffsims 0.7.0, pyebsdindex 0.3.10.1, hyperspy 2.5.0, exspy 0.3.2, rosettasciio 0.15.0, DefDAP 1.3.1, numpy 2.5.4,
scipy 1.18.1, h5py 3.16.0, numba 0.68.1, CPython 3.14.

## Licences

| Package | Licence | Port? |
|---|---|---|
| kikuchipy | GPL-3.0-or-later | yes |
| orix | GPL-3.0-or-later | yes |
| diffsims | GPL-3.0-or-later | yes |
| pyebsdindex | US Naval Research Laboratory public-domain work (17 USC 105), worldwide royalty-free grant; derivative works must say they are derived and modified, and acknowledge NRL | yes; `NOTICE` carries the acknowledgment and the modification note |
| HyperSpy, exspy, RosettaSciIO | GPL-3.0-or-later | yes |
| DefDAP | Apache-2.0 (compatible with GPL-3.0; notices kept in `NOTICE`) | yes |
| EMsoft | BSD-2-Clause (compatible) | master patterns are read, EMsoft itself is not ported (Fortran, Monte Carlo) |
| MTEX | GPL-2.0-or-later (MATLAB) | algorithms by paper only; never code (MATLAB, and the app does not link it) |
| Avizo, AZtec, OIM Analysis, Esprit, Velox | commercial | feature targets from public manuals only, never code or data |

macTEM is GPL-3.0-only; every row above is compatible. Each port names its source file and version in the Swift file
header, and `docs/parity.md` names the function, its reference and its tolerance (the suite's rule).

## 1. Data in (phase 1)

| Capability | Reference | Paper / spec | Test data | Notes |
|---|---|---|---|---|
| Oxford h5oina EBSD (`.h5oina`) | `kikuchipy.io.plugins.oxford_h5ebsd` (read), `orix.io.plugins` (map) | Oxford Instruments H5OINA spec, GitHub `oinanoanalysis/h5oina` | kikuchipy dummy writer `_dummy_files/oxford_h5ebsd.py`; a real file from the h5oina spec repo | patterns, PC per pattern, indexing results, EDS layers in one file |
| Bruker h5ebsd (`.h5`) | `kikuchipy.io.plugins.bruker_h5ebsd` | Jackson et al. 2014, Integr. Mater. Manuf. Innov. 3, 4 (h5ebsd) | kikuchipy dummy writer `_dummy_files/bruker_h5ebsd.py` | PC in Bruker convention |
| EDAX h5ebsd (`.h5`, `.oh5`) | `kikuchipy.io.plugins.edax_h5ebsd` | Jackson et al. 2014 | `kikuchipy/data/edax_h5ebsd/patterns.h5` (in package, CC BY 4.0) | PC in EDAX convention |
| EDAX binary (`.up1`, `.up2`) with `.ang` | `kikuchipy.io.plugins.edax_binary`; `orix.io.plugins.ang` | EDAX UP1/UP2 layout as read by kikuchipy; `.ang` header spec (EDAX OIM) | `kikuchipy/data/edax_binary/edax_binary.up1`, `.up2` (in package); `orix-data/sdss_ferrite_austenite.ang` | hex grids refused with the kit's sentence (kikuchipy refuses them too) |
| Oxford binary (`.ebsp`) | `kikuchipy.io.plugins.oxford_binary`; DefDAP `OxfordBinaryLoader` | Oxford Instruments, as reverse-engineered by kikuchipy | `kikuchipy/data/oxford_binary/patterns.ebsp` (in package) | |
| Oxford `.ctf` map | `orix.io.plugins.ctf`; DefDAP `OxfordTextLoader` | Channel Text File spec (Oxford) | `orix-data/Ti_orientations.ctf` | orientation map only, no patterns |
| kikuchipy h5ebsd | `kikuchipy.io.plugins.kikuchipy_h5ebsd` | Jackson et al. 2014 + kikuchipy's extension | `kikuchipy/data/kikuchipy_h5ebsd/patterns.h5` (in package); `nickel_ebsd_large/patterns_v2.h5` (kikuchipy-data on GitHub) | the north-star EBSD file is this format |
| NORDIF (`Pattern.dat` + `Setting.txt`) | `kikuchipy.io.plugins.nordif`, `nordif_calibration_patterns` | NORDIF UF-1100 / UF-420 file layout as read by kikuchipy | `kikuchipy/data/nordif/` (in package); `si_wafer/Pattern.dat` (Zenodo 7491388) | calibration patterns as `.bmp` |
| EBSD directory of images | `kikuchipy.io.plugins.ebsd_directory` | | synthetic | optional; low priority |
| EMsoft EBSD (`.h5`) | `kikuchipy.io.plugins.emsoft_ebsd`; `orix.io.plugins.emsoft_h5ebsd` | Callahan & De Graef 2013, Microsc. Microanal. 19, 1255 | `orix-data/sdss_austenite.h5` | dictionary-indexed maps from EMsoft |
| EMsoft master pattern (`.h5`) | `kikuchipy.io.plugins.emsoft_ebsd_master_pattern`, `_tkd_`, `_ecp_` | Callahan & De Graef 2013 | `kikuchipy/data/emsoft_ebsd_master_pattern/ni_mc_mp_20kv_uint8_gzip_opts9.h5` (in package); Zenodo 7498645 (Ni 20 kV), 7498729 (Si), 7628365 (Al), steel phases | phase 6 |
| SEM image TIFF with vendor metadata: Thermo/FEI, Zeiss, Tescan | `rsciio.tiff` (`_api.py` parses the FEI `[User]/[Beam]/[Scan]` block, Zeiss `CZ_SEM` tag 34118, Tescan tag 50431) | tifffile tag numbers; vendor manuals | RosettaSciIO test files (`rsciio/tests/data/tiff/`: FEI, Zeiss, Tescan samples, GPL) | pixel size, HV, WD, detector, magnification, dwell, databar crop |
| Bruker Esprit `.bcf` (SEM-EDS map + image) | `rsciio.bruker` (`unbcf_fast`, SFS container) | RosettaSciIO's format notes | `rsciio/tests/data/bruker/` | phase 7 |
| EDAX `.spd` / `.spc` / `.ipr` | `rsciio.edax` | EDAX Genesis layout | `rsciio/tests/data/edax/` | phase 7 |
| JEOL `.asw` / `.pts` / `.eds` | `rsciio.jeol` | RosettaSciIO's format notes | `rsciio/tests/data/jeol/` | phase 7, after Bruker and EDAX |
| Ripple `.rpl`/`.raw`, `.msa` | `rsciio.ripple`, `rsciio.msa` (FormatoKit already reads `.msa`) | Lispix ripple spec; EMSA/MAS spec | RosettaSciIO tests | |
| HyperSpy `.hspy` (EDS signals) | `rsciio.hspy` | HyperSpy HDF5 layout | `exspy/data/EDS_SEM_TM002.hspy` (in package) | the north-star SEM-EDS spectrum is this format |

## 2. Pattern processing (phase 2)

| Capability | Reference | Paper | Test data | Tolerance (upstream test) |
|---|---|---|---|---|
| Static background subtract/divide | `kikuchipy.pattern._remove_static_background_*`; `EBSD.remove_static_background` | Wilkinson & Britton 2012 (review); kikuchipy docs | nickel_ebsd_small + its static background in the h5 | exact per dtype (uint8 rescale) |
| Dynamic background (Gaussian in frequency or spatial space) | `kikuchipy.pattern.remove_dynamic_background`, `get_dynamic_background` | kikuchipy docs; Barnes et al. 2016 FFT filtering | nickel_ebsd_small | `assert_allclose` rtol 1e-7 (float32 ~1e-5) |
| Rescale / normalise intensity, zero-mean, unit variance | `kikuchipy.pattern.rescale_intensity`, `normalize_intensity` | | | exact to float32 rounding |
| Binning / downsample | `EBSD.downsample`, `rebin`; `_bin2d` | | | exact |
| FFT filters (Barnes windows: lowpass, highpass, Gaussian, modified Hann) | `kikuchipy.filters.fft_barnes`, `filters.window.Window`, `EBSD.fft_filter` | Barnes et al. 2016, J. Microsc. 261, 125 | synthetic | rtol 1e-5 |
| Adaptive histogram equalisation | `EBSD.adaptive_histogram_equalization` (skimage CLAHE) | Zuiderveld 1994 | | exact |
| Neighbour pattern averaging | `EBSD.average_neighbour_patterns` | kikuchipy docs | | rtol 1e-5 |
| NLPAR denoising | `pyebsdindex.nlpar` | Brewick, Kalidindi, Rowenhorst 2019, Ultramicroscopy 200, 50 | nickel_ebsd_large | within pyebsdindex's own float32 tests |
| Image quality (IQ) | `kikuchipy.pattern.get_image_quality` | Lassen 1994 (thesis), Krieger Lassen 1998 | nickel_ebsd_small | rtol 1e-5 |
| Average neighbour dot product map | `EBSD.get_average_neighbour_dot_product_map` | Brewer, Field, Merriman 2009 | | rtol 1e-5 |
| Virtual BSE images (grid, RGB, ROI) | `kikuchipy.imaging.VirtualBSEImager` | Wright et al. 2015, Microsc. Microanal. 21, 1 (vBSE) | nickel_ebsd_large | exact sums |
| Detector geometry and PC conventions (Bruker, EDAX, Oxford, EMsoft v4/v5, TSL) | `kikuchipy.detectors.EBSDDetector`, `_convert_detector_coordinates` | Jackson, Pascal, De Graef 2019, Integr. Mater. Manuf. Innov. 8, 226 | detector tests | exact |
| Moving-screen PC estimate | `kikuchipy.detectors.PCCalibrationMovingScreen` | Hjelen et al. 1991, Textures Microstruct. 13, 1 | si_ebsd_moving_screen (GitHub) | rtol 1e-5 |
| TKD geometry (transmission, sample tilt and detector tilt, off-axis) | `EBSDDetector` with `sample_tilt`, `tilt`, `azimuthal`; `EMsoft TKD master` | Keller & Geiss 2012; Trimby 2012 | synthetic + EMsoft TKD master pattern | exact geometry |

## 3. Orientation core (phase 3)

| Capability | Reference | Paper | Test data | Tolerance |
|---|---|---|---|---|
| Rotations: quaternion, Euler (Bunge), axis-angle, matrix, Rodrigues, homochoric, cubochoric conversions | `orix.quaternion.Rotation`, `_conversions.py` | Rowenhorst et al. 2015, Modell. Simul. Mater. Sci. Eng. 23, 083501 | orix tests | `assert_allclose` atol 1e-7 |
| Symmetry: 32 point groups, Laue groups, proper subgroups | `orix.quaternion.symmetry` | Rowenhorst 2015; ITC vol. A | orix tests | exact set equality |
| Orientation, Misorientation, fundamental zone, disorientation angle | `orix.quaternion.Orientation`, `Misorientation`, `OrientationRegion` | Krakow et al. 2017, Proc. R. Soc. A 473, 20170274 | orix tests | atol 1e-7 |
| Orientation sampling (cubochoric, SO(3) grids) | `orix.sampling` | Rosca, Morawiec, De Graef 2014; Singh & De Graef 2016 | orix tests | exact counts, atol 1e-7 |
| Vectors, Miller indices, stereographic projection | `orix.vector`, `orix.projections` | | orix tests | atol 1e-7 |
| IPF colour keys (TSL style) | `orix.plot.IPFColorKeyTSL` | Nolze & Hielscher 2016, J. Appl. Cryst. 49, 1786 | orix tests | exact RGB to 1e-6 |
| Euler colours | DefDAP `calc_euler_colour` | | | exact |
| Crystal map (phase list, properties, slicing) | `orix.crystal_map.CrystalMap`, `Phase`, `PhaseList` | | orix tests + sdss files | exact |
| Structure, lattice, reciprocal vectors, structure factors | `diffsims.crystallography.ReciprocalLatticeVector`, `diffsims.structure_factor` (DiffractoKit already has cells, symmetry and kinematic lists; nothing is added to it) | Doyle & Turner 1968; Lobato & Van Dyck 2014 | diffsims tests | rtol 1e-6 |

## 4. Indexing (phase 4)

| Capability | Reference | Paper | Test data | Tolerance |
|---|---|---|---|---|
| Radon/Hough band detection, triplet voting | `pyebsdindex.ebsd_index`, `band_detect`, `tripletvote` | Krieger Lassen 1994; Wright & Adams 1992; Rowenhorst 2024 (pyebsdindex docs) | nickel_ebsd_large | bands within 1 px/1°, orientations within 1° of pyebsdindex, fraction indexed equal |
| Hough indexing through the wrapper (PC optimisation) | `EBSD.hough_indexing`, `hough_indexing_optimize_pc` | | nickel_ebsd_large | as above |
| Dictionary indexing (NCC, NDP metrics) | `kikuchipy.indexing.dictionary_indexing`, `similarity_metrics` | Chen et al. 2015, Microsc. Microanal. 21, 739; Marquardt et al. 2017 | nickel_ebsd_large + Ni 20 kV master pattern | best-match index exact on the north-star grid, score rtol 1e-4 |
| Orientation and PC refinement (Nelder-Mead, Powell, NLopt LN_NELDERMEAD) | `kikuchipy.indexing._refinement` | Singh, Ram, De Graef 2017; Winkelmann 2007 | nickel_ebsd_large | angle within 0.1° of kikuchipy, score rtol 1e-4 |
| Orientation similarity map, merge crystal maps | `kikuchipy.indexing._orientation_similarity_map`, `_merge_crystal_maps` | | | exact |

## 5. Maps and grains (phase 5)

| Capability | Reference | Paper | Test data | Tolerance |
|---|---|---|---|---|
| IPF-X/Y/Z, phase, Euler and property maps | `orix.plot.CrystalMapPlot`, `IPFColorKeyTSL` | Nolze & Hielscher 2016 | sdss_ferrite_austenite.ang | exact colours |
| Grain segmentation (misorientation threshold, flood fill, min size) | DefDAP `find_boundaries`, `find_grains` | Humphreys 2001, J. Mater. Sci. 36, 3833 | Ti_orientations.ctf; sdss | grain labels equal up to relabelling, sizes equal |
| KAM | DefDAP `calc_kam` | Wright, Nowell, Field 2011, Microsc. Microanal. 17, 316 | as above | atol 1e-6 rad |
| GOS, grain average orientation, grain reference orientation deviation | DefDAP `calc_grain_av_oris`, `calc_grain_mis_ori` | Wright 2011 | | atol 1e-6 |
| GND density (Nye tensor) | DefDAP `calc_nye` | Pantleon 2008, Scripta Mater. 58, 994; Wilkinson & Randman 2010 | | rtol 1e-5 |
| Boundary maps, phase boundaries, neighbour network | DefDAP `plot_boundary_map`, `build_neighbour_network` | | | exact |
| Pole figures, inverse pole figures, stereographic plots | `orix.plot.StereographicPlot`, `InversePoleFigurePlot`, `orix.vector.Vector3d.pole_density_function` | | orix tests | atol 1e-7 |
| ODF (kernel density on SO(3)) | `orix.quaternion.Orientation.get_distance_matrix`; `pole_density_function` (de la Vallée Poussin kernel) | Hielscher & Schaeben 2008, J. Appl. Cryst. 41, 1024 | ti_orientations | rtol 1e-4 |
| Schmid factors | DefDAP `calc_average_grain_schmid_factors` | | | atol 1e-6 |
| Band contrast, MAD, CI, IQ and fit as property maps (the values the vendor stores in `.ctf`, `.ang`, h5oina, h5ebsd) | `orix.crystal_map.CrystalMap.prop`, `CrystalMapPlot` (property maps); DefDAP `Map.band_contrast` | Wright & Nowell 2006, Microsc. Microanal. 12, 72 (IQ, CI, fit) | Ti_orientations.ctf (BC, BS, MAD), sdss (IQ, CI, fit) | exact (stored columns); band contrast from patterns is kikuchipy's IQ, section 2 |
| Slip-trace analysis (slip planes and traces per grain from the orientation and the crystal's slip systems, Schmid factor per system, trace angles in the map plane) | DefDAP `Grain.calc_slip_traces`, `Map.calc_average_grain_schmid_factors`, `defdap.crystal.SlipSystem` (slip-system files for fcc, bcc, hcp) | Schmid & Boas 1935; DefDAP docs (Atkinson, Orozco-Caballero, da Fonseca 2021, Materials & Design 211, 110140) | Ti_orientations.ctf (hcp), sdss (bcc, fcc) | trace angles within 1e-6 rad, Schmid factors atol 1e-6 |
| Strain from SEM image pairs (HRDIC: a reference and a deformed image, displacement field, strain components, maps and grain statistics on an EBSD map) | DefDAP `hrdic.Map` (reads DaVis, DICe output; the DIC itself runs in those tools), `calc_grain_av_strain`; the correlation step would be ImagoKit's cross-correlation (not yet ported) | Atkinson et al. 2021; Lunt et al. 2015, Acta Mater. 97, 34 | DefDAP's example DIC data (CC BY 4.0) | atol 1e-6 on the strain maps from imported displacements; new, to add once Paul picks a phase (D-SEM, catalogue addition 2026-11-06) |

## 6. Simulation (phase 6)

| Capability | Reference | Paper | Test data | Tolerance |
|---|---|---|---|---|
| Master pattern reading (Lambert and stereographic, both hemispheres, energies) | `kikuchipy.signals.EBSDMasterPattern` | Callahan & De Graef 2013 | Ni master pattern (in package, uint8) | exact |
| Pattern projection from a master pattern (Lambert interpolation) | `EBSDMasterPattern.get_patterns` | Callahan & De Graef 2013; Rosca 2010 (Lambert) | Ni | rtol 1e-5 |
| Kinematic master pattern | `kikuchipy.simulations.KikuchiPatternSimulator.calculate_master_pattern` | Winkelmann 2010 (kinematic approximation) | diffsims structures | rtol 1e-5 |
| Geometrical simulation on an experimental pattern (bands, zone axes) | `KikuchiPatternSimulator.on_detector`, `GeometricalKikuchiPatternSimulation` | | nickel_ebsd_small | line coordinates atol 1e-6 px |

## 7. SEM-EDS (phase 7)

| Capability | Reference | Paper | Test data | Tolerance |
|---|---|---|---|---|
| EDS SEM signal, calibration from a reference | `exspy.signals.EDSSEMSpectrum`, `get_calibration_from` | | EDS_SEM_TM002 (in package) | exact |
| Elements and lines database, line energies, weights | `exspy.misc.elements`, `exspy.utils.eds` | NIST X-ray transition energies | | exact |
| Line intensities with background windows | `EDSSpectrum.get_lines_intensity`, `estimate_background_windows`, `estimate_integration_windows` | HyperSpy EDS docs | EDS_SEM_TM002 | rtol 1e-7 |
| Quantification: Cliff-Lorimer, zeta factors, cross sections (TEM); SEM uses external k-factors | `EDSTEMSpectrum.quantification` (exspy has no SEM ZAF) | Cliff & Lorimer 1975; Watanabe & Williams 2006 | EDS_TEM_FePt_nanoparticles | rtol 1e-6 |
| Model fitting (Gaussians + background), fit with elements | `exspy.models.EDSSEMModel` | | EDS_SEM_TM002 | rtol 1e-4 |
| Decomposition (PCA, ICA) of EDS maps | `hyperspy` `decomposition`, `blind_source_separation` | | | rtol 1e-5 |
| Map readers | section 1 | | | |

SEM ZAF/phi-rho-z matrix correction has no GPL Python reference (DTSA-II is Java, public domain; CalcZAF is
closed). Quantification of SEM-EDS ships as exspy ships it: line intensities, k-factor quantification with
user-supplied factors, and a stated `validation: none` on anything beyond. Logged as decision D-SEM-7.

## 8. SEM imaging (phase 1, Image room)

| Capability | Reference | Test data |
|---|---|---|
| Open vendor TIFFs with pixel size, HV, WD, detector, dwell, databar | `rsciio.tiff` | RosettaSciIO tiff tests |
| Databar crop (Thermo/FEI, Zeiss, Tescan put the bar in the image) | `rsciio.tiff` (`_api.py` reads the image height from metadata) | same |
| Everything the Image room does today (marks, profiles, particles, FFT) | ImagoKit, already in the app | |
| Segmentation of SEM images (threshold, watershed, particle statistics: the Particles tool the Image room already has, applied to SEM micrographs with the vendor pixel size) | ImagoKit particles (scikit-image `threshold_otsu`, `watershed`, `regionprops`), already in the app | Zeiss and Thermo test TIFFs |
| ECCI images (channelling contrast micrographs: opened as SEM images with their metadata; the ECP master pattern reader of section 1 gives the channelling geometry; no ECCI simulation, see Out of scope) | `rsciio.tiff`; `kikuchipy.io.plugins.emsoft_ecp_master_pattern` | Zeiss test TIFF; EMsoft ECP master pattern |

## 9. Export and reports (phase 8)

| Capability | Reference | Test data |
|---|---|---|
| `.ang` writer | `orix.io.plugins.ang.file_writer` | round trip of sdss |
| `.ctf` writer | `orix.io.plugins.ctf` (reader only upstream; writer follows the Oxford spec, tested by reading back with orix) | round trip of Ti |
| kikuchipy h5ebsd writer | `kikuchipy.io.plugins.kikuchipy_h5ebsd.file_writer` | round trip |
| orix HDF5 crystal map | `orix.io.plugins.orix_hdf5` | round trip |
| Map and figure PNG/PDF with scale bar, colour key, session report | the app's existing `ImageExport` and results CSV | snapshot tests |

## 10. Commercial feature targets (public documentation only)

| Tool | Feature we match | Where it lives in macEM |
|---|---|---|
| Oxford AZtec / AZtecCrystal | live pattern view beside the map, band contrast and MAD maps, IPF with colour key, grain size with ASTM E112 number, KAM, GOS, Schmid, pole figures, phase maps, Refined Accuracy indexing | Patterns room, Maps room |
| EDAX OIM Analysis | IQ, CI, fit maps; partitioning by property; GROD, GOS, KAM; texture (ODF, PF, IPF) with harmonic series; grain CSL boundaries | Maps room (partitioning = Tools regions + property filters) |
| Bruker Esprit | hyperspectral map with phase analysis; SEM-EDS quant with standardless P/B-ZAF; line scans | EDS room (quant limits in section 7) |
| Thermo Avizo | 3D is out of scope; its 2D grain statistics tables map to the Maps room results table | |
| MTEX | ODF estimation, pole figures with contours, grain reconstruction, GND | Maps room, by paper |

## Out of scope for the program

3D EBSD and serial sectioning (3D reconstruction of FIB stacks: no GPL reference with tests, and the apps draw 2D); ECCI
simulation beyond the ECP master pattern reader; HR-EBSD cross-correlation strain (Wilkinson 2006; no GPL Python reference
with tests; strain from SEM image pairs by DIC is the section 5 row instead); dynamical simulation of master patterns (EMsoft
stays the source of master patterns); SEM-EDS ZAF beyond exspy. Each is an issue in the macTEM repo with this page as its
reason.
