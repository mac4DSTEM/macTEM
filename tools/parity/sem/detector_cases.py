"""tools/parity/sem/detector_cases.py — the detector-geometry cases of emit.py (milestone 2, figure F5).

kikuchipy 0.13.1's `EBSDDetector` (projection-centre conventions both ways, sizes, gnomonic bounds, scales and r_max,
pixel <-> gnomonic coordinates, the sample-to-detector rotation) and `PCCalibrationMovingScreen` (Hjelen et al. 1991)
on the points kikuchipy's tutorial and tests pick on `si_ebsd_moving_screen` in (0 mm) and out (5 mm). The cases take
no downloaded data: the calibration reads only the points and the 480 x 480 detector shape, so the bundles are emitted
from those (the figure script, `detector_figure.py`, draws them on the fetched patterns). emit.py imports every
`case_` function here.

Tolerances: numpy's float64 default (rtol 1e-7) for everything kikuchipy computes in float64, part of it under numba
fastmath; atol 1e-12 where a value can be exactly zero (rotation-matrix entries, PC differences). The moving-screen PC
at rtol 1e-5 (the brief's bound; kikuchipy intersects lines through `np.linalg.det`'s LU, the port in closed form).
"""

from __future__ import annotations

import numpy as np

from refbundle import Bundle

F64 = {"rtol": 1e-7, "atol": 0.0}
F64Z = {"rtol": 1e-7, "atol": 1e-12}
PC5 = {"rtol": 1e-5, "atol": 1e-12}

# kikuchipy's names, aliases included; emsoft == emsoft5.
CONVENTIONS = ["bruker", "tsl", "edax", "amatek", "oxford", "aztec", "emsoft", "emsoft4", "emsoft5"]

# Detectors: (shape, px_size, binning). kikuchipy's tests use (60, 60), (510, 510), (1, 1) and (480, 640); its docstring
# example (60, 80) at 59.2 µm binned 8; an Oxford-like 1244 x 1024 unbinned; a tall one so min(rows, cols) != rows.
DETECTORS = [((60, 60), 1.0, 1), ((60, 80), 59.2, 8), ((480, 640), 70.0, 2), ((1, 1), 1.0, 1), ((1024, 1244), 6.5, 1),
             ((240, 200), 30.0, 4), ((510, 510), 2.5, 1)]

# PCs as given (2 x 3 navigation shape, so the per-position path is exercised); the EMsoft row is in pixels and µm.
PCS_FRACTION = np.array([[[0.4210, 0.7794, 0.5049], [0.4214844, 0.21500351, 0.50201974], [0.5, 0.5, 0.5]],
                         [[0.42088203, 0.2165417, 0.50079336], [0.3, 0.8, 0.7], [0.62, 0.15, 0.48]]])
PCS_EMSOFT = np.array([[[64.0, 144.0, 17049.6], [-12.5, 30.25, 15000.0], [0.0, 0.0, 12000.0]],
                       [[3.75, -88.0, 21000.0], [120.0, 10.0, 9000.0], [-40.0, -40.0, 18000.0]]])


def _det(kp, shape, px, b, pc, conv="bruker", **angles):
    return kp.detectors.EBSDDetector(shape=shape, px_size=px, binning=b, pc=pc, convention=conv, **angles)


def case_m2_detector_pc_conventions(ctx):
    """Every convention name kikuchipy accepts, read in (to Bruker) and written out (pc_tsl, pc_oxford, pc_emsoft 4/5)."""
    import kikuchipy as kp

    b = Bundle("m2/detector-pc-conventions", 2, "kikuchipy", "kikuchipy.detectors.EBSDDetector(pc, convention) / pc_tsl / pc_oxford / pc_emsoft", ctx.out)
    b.value("detectors", [{"shape": list(s), "px_size": px, "binning": bb} for s, px, bb in DETECTORS])
    b.value("conventions", CONVENTIONS)
    b.array("pcs_fraction", PCS_FRACTION, **F64)
    b.array("pcs_emsoft", PCS_EMSOFT, **F64)
    to_bruker = []   # (detector, convention, 2, 3, 3)
    out = []         # (detector, [tsl, oxford, emsoft4, emsoft5], 2, 3, 3) from PCS_FRACTION read as Bruker
    for shape, px, bb in DETECTORS:
        row = []
        for conv in CONVENTIONS:
            pcs = PCS_EMSOFT if conv.startswith("emsoft") else PCS_FRACTION
            row.append(_det(kp, shape, px, bb, pcs, conv).pc)
        to_bruker.append(row)
        d = _det(kp, shape, px, bb, PCS_FRACTION)
        out.append([d.pc_tsl(), d.pc_oxford(), d.pc_emsoft(4), d.pc_emsoft(5)])
    b.array("to_bruker", np.asarray(to_bruker, dtype=np.float64), **F64Z,
            note="detector, convention (as `conventions`), scan row, scan column, (x, y, z) in Bruker's convention")
    b.array("from_bruker", np.asarray(out, dtype=np.float64), **F64Z,
            note="detector, (tsl, oxford, emsoft4, emsoft5), scan row, scan column, (x, y, z); input pcs_fraction as Bruker")
    b.write()
    ctx.done("m2/detector-pc-conventions")


def case_m2_detector_gnomonic(ctx):
    """Sizes, gnomonic bounds, scales and r_max per PC; pixel -> gnomonic -> pixel for kikuchipy's test points."""
    import kikuchipy as kp

    b = Bundle("m2/detector-gnomonic", 2, "kikuchipy", "kikuchipy.detectors.EBSDDetector gnomonic_bounds / x_scale / y_scale / r_max / to_gnomonic_coords / to_pixel_coords", ctx.out)
    b.value("detectors", [{"shape": list(s), "px_size": px, "binning": bb} for s, px, bb in DETECTORS])
    b.array("pcs_bruker", PCS_FRACTION, **F64)
    sizes, bounds, scales, rmax, ssd = [], [], [], [], []
    for shape, px, bb in DETECTORS:
        d = _det(kp, shape, px, bb, PCS_FRACTION)
        sizes.append([d.height, d.width, d.px_size_binned, *d.unbinned_shape])
        bounds.append(d.gnomonic_bounds)
        scales.append(np.stack([d.x_scale, d.y_scale], axis=-1))
        rmax.append(np.asarray(d.r_max).reshape(d.navigation_shape))
        ssd.append(d.specimen_scintillator_distance)
    b.array("sizes", np.asarray(sizes, dtype=np.float64), **F64, note="detector, (height, width, px_size_binned, unbinned rows, unbinned cols)")
    b.array("gnomonic_bounds", np.asarray(bounds), **F64, note="detector, row, col, (x_min, x_max, y_min, y_max)")
    b.array("gnomonic_scale", np.asarray(scales), **F64, note="detector, row, col, (x_scale, y_scale)")
    b.array("r_max", np.asarray(rmax), **F64, note="detector, row, col; kikuchipy's corner list (lower left as x_min, y_min)")
    b.array("specimen_scintillator_distance", np.asarray(ssd), **F64)

    # kikuchipy's test_coordinate_conversions: a 60 x 60 detector with a 2 x 2 PC map, pixel (y, x) points.
    pc = np.array([[[0.4214844, 0.21500351, 0.50201974], [0.42414583, 0.21014019, 0.50104439]],
                   [[0.42088203, 0.2165417, 0.50079336], [0.42725023, 0.21450546, 0.49996293]]])
    coords = np.array([[12.7, 36.2], [43.7, 2.5], [27.7, 8.2], [0.0, 0.0], [59.0, 59.0]])
    d = kp.detectors.EBSDDetector(shape=(60, 60), pc=pc)
    gn = d.to_gnomonic_coords(coords)
    b.array("coords_pc", pc, **F64)
    b.array("coords_pixel", coords, **F64)
    b.array("coords_gnomonic", gn, **F64Z, note="row, col, point, (gy, gx)")
    b.array("coords_back", d.to_pixel_coords(gn), **F64Z, note="row, col, row, col, point, (y, x): kikuchipy broadcasts gn per PC again")
    b.array("coords_back_same_pc", np.stack([np.stack([d.to_pixel_coords(gn[i, j], (i, j)) for j in range(2)]) for i in range(2)]),
            **F64Z, note="row, col, point, (y, x)")
    b.write()
    ctx.done("m2/detector-gnomonic")


# kikuchipy's test_sample_to_detector angles, a grid around a typical EBSD set-up, and TKD set-ups (the detector below
# a sample that is flat or tilted a few degrees either way; kikuchipy takes TKD through the same four angles).
ROTATION_ANGLES = [(0, 0, 0, 90.0), (0, 0, 0, 70.0), (8.3, 4.7, -1.02, 70.0), (0, 0, 0, 0.0), (40.0, 0, 0, 0.0),
                   (40.0, 20.0, 0, 70.0), (40.0, -40.0, 0, 70.0), (-5.0, 2.0, 3.0, 65.0), (10.0, 0, 15.0, 75.0)]
TKD_ANGLES = [(0, 0, 0, -20.0), (-10.0, 0, 0, -20.0), (0, 0, 0, 0.0), (5.0, 3.0, -2.0, -10.0), (-20.0, 0, 0, 10.0)]


def case_m2_detector_sample_to_detector(ctx):
    """The passive sample-to-detector matrix (`_sample_to_detector_matrix`, rows = detector axes in sample coordinates)."""
    import kikuchipy as kp
    from kikuchipy.detectors._ebsd_detector import _sample_to_detector_matrix

    b = Bundle("m2/detector-sample-to-detector", 2, "kikuchipy", "kikuchipy.detectors.EBSDDetector.sample_to_detector", ctx.out)
    ang = np.asarray(ROTATION_ANGLES, dtype=np.float64)
    b.array("angles_deg", ang, **F64, note="(tilt, azimuthal, twist, sample_tilt)")
    mats, quats = [], []
    for t, a, tw, st in ROTATION_ANGLES:
        mats.append(_sample_to_detector_matrix(*np.deg2rad([st, t, a, tw])))
        quats.append(kp.detectors.EBSDDetector(tilt=t, azimuthal=a, twist=tw, sample_tilt=st).sample_to_detector.data[0])
    b.array("matrix", np.asarray(mats), **F64Z, note="case, row (detector X, Y, Z), sample (x, y, z)")
    b.array("quaternion_orix", np.asarray(quats), **F64Z, note="orix Rotation.from_matrix of each matrix, (a, b, c, d); kikuchipy's test values for the first three")
    b.write()
    ctx.done("m2/detector-sample-to-detector")


def case_m2_detector_tkd_geometry(ctx):
    """TKD: the detector below the sample. Same four angles and the Bruker PC; bounds, r_max and the rotation per set-up."""
    import kikuchipy as kp
    from kikuchipy.detectors._ebsd_detector import _sample_to_detector_matrix

    b = Bundle("m2/detector-tkd-geometry", 2, "kikuchipy", "kikuchipy.detectors.EBSDDetector (TKD angles)", ctx.out)
    ang = np.asarray(TKD_ANGLES, dtype=np.float64)
    pcs = np.array([[0.5, 0.35, 0.65], [0.48, 0.42, 0.55], [0.5, 0.5, 0.8], [0.52, 0.3, 0.6], [0.45, 0.6, 0.7]])
    b.array("angles_deg", ang, **F64, note="(tilt, azimuthal, twist, sample_tilt)")
    b.array("pcs_bruker", pcs, **F64)
    mats, bounds, rmax, emsoft = [], [], [], []
    for (t, a, tw, st), pc in zip(TKD_ANGLES, pcs):
        d = kp.detectors.EBSDDetector(shape=(480, 640), px_size=70.0, binning=2, tilt=t, azimuthal=a, twist=tw, sample_tilt=st, pc=pc)
        mats.append(_sample_to_detector_matrix(*np.deg2rad([st, t, a, tw])))
        bounds.append(d.gnomonic_bounds[0])
        rmax.append(float(np.asarray(d.r_max).ravel()[0]))
        emsoft.append(d.pc_emsoft()[0])
    b.value("detector", {"shape": [480, 640], "px_size": 70.0, "binning": 2})
    b.array("matrix", np.asarray(mats), **F64Z)
    b.array("gnomonic_bounds", np.asarray(bounds), **F64)
    b.array("r_max", np.asarray(rmax), **F64)
    b.array("pc_emsoft", np.asarray(emsoft), **F64Z)
    b.write()
    ctx.done("m2/detector-tkd-geometry")


# The moving-screen points: kikuchipy's tutorial (three zone axes, px 0.09 mm) and its tests (five points, px 46/508 mm).
POINTS_IN = [(109, 131), (390, 139), (246, 232), (129, 228), (364, 237)]
POINTS_OUT = [(77, 146), (424, 156), (246, 269), (104, 265), (392, 276)]
MOVING_SCREEN = [  # (label, n points, px_size, binning, convention)
    ("tutorial-3-tsl", 3, 90e-3, 1, "tsl"),
    ("tutorial-3-mm", 3, None, 1, "tsl"),
    ("tests-3-tsl", 3, 46 / 508, 1, "tsl"),
    ("tests-4-tsl", 4, 46 / 508, 1, "tsl"),
    ("tests-5-tsl", 5, 46 / 508, 1, "tsl"),
    ("tests-5-bruker", 5, 46 / 508, 1, "bruker"),
    ("tests-5-mm", 5, None, 1, "tsl"),
    ("tests-5-binned", 5, 46 / 508 / 2, 2, "tsl"),
]


def case_m2_pc_moving_screen_si(ctx):
    """Figure F5: the moving-screen PC of si_in / si_out5mm (480 x 480, Δz 5 mm), every estimate and the average."""
    import kikuchipy as kp

    b = Bundle("m2/pc-moving-screen-si", 2, "kikuchipy", "kikuchipy.detectors.PCCalibrationMovingScreen", ctx.out)
    b.value("shape", [480, 480])
    b.value("delta_z_mm", 5.0)
    b.value("cases", [{"label": l, "n_points": n, "px_size_mm": px, "binning": bb, "convention": c} for l, n, px, bb, c in MOVING_SCREEN])
    b.array("points_in", np.asarray(POINTS_IN, dtype=np.float64), **F64, note="(x, y) px in si_in (0 mm)")
    b.array("points_out", np.asarray(POINTS_OUT, dtype=np.float64), **F64, note="(x, y) px in si_out5mm")
    blank = np.zeros((480, 480), dtype=np.uint8)  # the class reads only the shape of the patterns
    for label, n, px, bb, conv in MOVING_SCREEN:
        cal = kp.detectors.PCCalibrationMovingScreen(blank, blank, POINTS_IN[:n], POINTS_OUT[:n], delta_z=5.0, px_size=px,
                                                     binning=bb, convention=conv)
        b.array(f"{label}__pc", cal.pc, **PC5)
        b.array(f"{label}__pc_all", cal.pc_all, **PC5, note="one row per point pair whose intersection is on the detector")
        b.array(f"{label}__pc_std", np.std(cal.pc_all, axis=0), **PC5, note="population std of pc_all (the tutorial's uncertainty)")
        b.array(f"{label}__pxy", cal.pxy, **PC5)
        b.array(f"{label}__pxy_all", cal.pxy_all, **PC5)
        b.array(f"{label}__within", cal.pxy_within_detector.astype(np.uint8))
        b.array(f"{label}__line_lengths", cal.line_lengths, **PC5)
    b.write()
    ctx.done("m2/pc-moving-screen-si")
