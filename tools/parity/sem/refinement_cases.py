"""tools/parity/sem/refinement_cases.py — the refinement cases of emit.py (milestone 4, figure F10).

kikuchipy 0.13.1's `EBSD.refine_orientation`, `refine_projection_center` and `refine_orientation_projection_center`
(`kikuchipy.indexing._refinement`) with their default solver, SciPy 1.18.1's `minimize(method="Nelder-Mead")` (Gao and
Han 2012 parameters off, scipy's default initial simplex and tolerances xatol = fatol = 1e-4, 200 iterations and
evaluations per control variable). The patterns are kikuchipy's docs chain (static then dynamic background, uint8) of a
10 x 10 block of nickel_ebsd_large (scan rows 20 to 29, columns 30 to 39), the PC the file's mean, the starting
orientations kikuchipy's Hough indexing of the block (pyEBSDindex, as `m4/hough-indexing-nickel-large`), the master
pattern the Ni 20 kV uint8 copy (kikuchipy's in-package file, the fixture `m6/read-master-pattern-ni` reads; the app ships
the same bytes as DemoData/ni_mc_mp_20kv_uint8_gzip_opts9.h5)
at 20 kV. The bundle stores the block's patterns and the starting Euler angles, so the port starts from kikuchipy's input.

The solver itself (`m4/nelder-mead`) is SciPy's `_minimize_neldermead` on closed-form functions: float64 throughout, so
the port's x, fun, nfev and nit follow it step for step (rtol 1e-12 on x and fun; counts exact).

Tolerances (brief P4-03, docs/parity.md "Refinement"). The objective projects in float64 and takes the normalised
cross-correlation in float32 under numba fastmath (a vectorised float32 sum), so the simplex walks a slightly different
path: orientations within 0.1 degree (symmetry-reduced) of kikuchipy's, PCs and scores rtol 1e-4. The evaluation counts
follow the path and are stored for the record, not compared.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from refbundle import Bundle

EXACT = {"rtol": 0.0, "atol": 0.0}
NM = {"rtol": 1e-12, "atol": 1e-14}
SCORE = {"rtol": 1e-4, "atol": 0.0}
# Euler angles near a gimbal or the 2 pi wrap compare as rotations; the test holds the misorientation under 0.1 degree.
EULER = {"rtol": 0.0, "atol": 2e-3}
COUNT = {"rtol": 1.0, "atol": 1e9}
# The bundle's own element tolerances are what check.py holds a re-emit to on another CPU (numba's float32 sums follow
# the vector width): PCs from a PC-only run move up to 5e-4 relative; the six-variable joint run scatters a few points
# into neighbouring optima (up to 0.4 degree, PC 1 %, score 0.3 %). The Swift tests hold the tighter bounds of D-SEM-87.
PC_RUN = {"rtol": 1e-3, "atol": 0.0}
# The starting orientations come from pyEBSDindex's float32 fastmath Hough fit, so a
# re-emit on another CPU moves them in the last bits (5e-15 measured).
START = {"rtol": 0.0, "atol": 1e-10}
# The PC run's fixed rotations are the orientation run's result, so they move with it (3e-5 measured on CI).
PC_START = {"rtol": 0.0, "atol": 2e-3}
JOINT_EULER = {"rtol": 0.0, "atol": 2e-2}
JOINT_SCORE = {"rtol": 1e-2, "atol": 0.0}
JOINT_PC = {"rtol": 5e-2, "atol": 0.0}

MASTER_LABEL = "fixtures/emsoft_ebsd_master_pattern_ni_mc_mp_20kv_uint8_gzip_opts9.h5"
SCAN_LABEL = "sem-data/nickel_ebsd_large/patterns_v2.h5"
BLOCK_ROWS = (20, 30)
BLOCK_COLS = (30, 40)
ENERGY = 20.0
TRUST_ORI = [1.0, 1.0, 1.0]
TRUST_PC = [0.05, 0.05, 0.05]
TRUST_ORI_PC = TRUST_ORI + TRUST_PC
MASK_BORDER = 6
# Pseudo-symmetry operators (axis, degrees) for the check: not Ni's, so the original solution should win.
PSEUDO_OPS = [([0.0, 0.0, 1.0], 30.0), ([1.0, 1.0, 0.0], 45.0)]


def _rosen(x):
    x = np.asarray(x)
    return float(np.sum(100.0 * (x[1:] - x[:-1] ** 2) ** 2 + (1 - x[:-1]) ** 2))


def _sphere_shift(x):
    x = np.asarray(x)
    c = np.array([0.3, -0.2, 0.1, 0.4])[: x.size]
    return float(np.sum((x - c) ** 2))


def _abs_sum(x):
    x = np.asarray(x)
    return float(np.sum(np.abs(x - 0.25)))


# name, function, x0, bounds, options
NM_CASES = [
    ("rosen2", _rosen, [-1.2, 1.0], None, {}),
    ("rosen3_bounded", _rosen, [1.3, 0.7, 0.8], [(0.0, 2.0)] * 3, {}),
    ("sphere_zero_start", _sphere_shift, [0.0, 0.5, 0.0], None, {}),
    ("near_upper_bound", _sphere_shift, [0.99, 0.5], [(0.0, 1.0), (0.0, 1.0)], {}),
    ("rosen3_maxfev", _rosen, [1.3, 0.7, 0.8], None, {"maxfev": 30}),
    ("abs_sum4_maxiter", _abs_sum, [1.0, -1.0, 0.5, 2.0], None, {"maxiter": 25}),
]


def case_m4_nelder_mead(ctx):
    """SciPy's Nelder-Mead on closed-form functions: unbounded, bounded (clipping), a zero start coordinate (zdelt), a
    start next to an upper bound (the simplex reflected into the box), stopped by maxfev and by maxiter."""
    from scipy.optimize import minimize

    b = Bundle("m4/nelder-mead", 4, "scipy", "scipy.optimize.minimize(method='Nelder-Mead')", ctx.out)
    names = []
    for name, f, x0, bounds, opts in NM_CASES:
        res = minimize(f, np.asarray(x0, dtype=np.float64), method="Nelder-Mead", bounds=bounds, options=opts or None)
        names.append(name)
        b.value(f"{name}_case", {"x0": list(map(float, x0)), "bounds": bounds, "options": opts,
                                 "nfev": int(res.nfev), "nit": int(res.nit), "status": int(res.status)})
        b.array(f"{name}_x", np.asarray(res.x, dtype=np.float64), **NM)
        b.array(f"{name}_fun", np.asarray([res.fun], dtype=np.float64), **NM)
        b.array(f"{name}_final_simplex", np.asarray(res.final_simplex[0], dtype=np.float64), **NM)
    b.value("cases", names)
    b.write()
    ctx.done("m4/nelder-mead")


def _block(ctx):
    from hough_cases import _corrected, _detector, _indexer
    from orix.crystal_map import PhaseList

    import kikuchipy as kp

    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    mp_path = Path(__file__).resolve().parent / MASTER_LABEL
    s, c = _corrected(p)
    (r0, r1), (k0, k1) = BLOCK_ROWS, BLOCK_COLS
    blk = c.inav[k0:k1, r0:r1].deepcopy()
    det = _detector(s)
    pl, indexer = _indexer(det, blk.axes_manager.signal_shape[::-1])
    xmap = blk.hough_indexing(pl, indexer, verbose=0)
    mp = kp.load(str(mp_path), projection="lambert", hemisphere="both")
    # The Hough phase carries no atoms; the refinement checks the map's phase against the master pattern's.
    xmap.phases = PhaseList(mp.phase.deepcopy())
    return p, mp_path, blk, det, xmap, mp


def case_m4_refine_nickel_block(ctx):
    """North-star figure F10 on the block: orientations (trust region 1 degree, none, with a signal mask, with
    pseudo-symmetry operators), then PCs from the refined orientations (trust region 0.05), then both together."""
    from orix.quaternion import Rotation

    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if not ctx.have(p, "m4/refine-nickel-block"):
        return
    p, mp_path, blk, det, xmap, mp = _block(ctx)
    b = Bundle("m4/refine-nickel-block", 4, "kikuchipy", "kikuchipy.signals.EBSD.refine_orientation / "
               "refine_projection_center / refine_orientation_projection_center (SciPy Nelder-Mead)", ctx.out)
    b.input(p, SCAN_LABEL)
    b.input(mp_path, MASTER_LABEL)
    nav = list(blk.axes_manager.navigation_shape[::-1])
    b.value("block_rows", list(BLOCK_ROWS))
    b.value("block_cols", list(BLOCK_COLS))
    b.value("energy", ENERGY)
    b.value("detector", {"shape": [int(n) for n in det.shape], "pc": [float(v) for v in det.pc.ravel()[:3]],
                         "tilt": float(det.tilt), "sample_tilt": float(det.sample_tilt),
                         "azimuthal": float(det.azimuthal), "twist": float(det.twist), "binning": int(det.binning),
                         "px_size": float(det.px_size)})
    b.value("trust_region", {"ori": TRUST_ORI, "pc": TRUST_PC, "ori_pc": TRUST_ORI_PC})
    b.value("mask_border", MASK_BORDER)
    b.value("pseudo_symmetry_ops", [{"axis": a, "degrees": d} for a, d in PSEUDO_OPS])
    b.array("patterns", np.asarray(blk.data), **EXACT, note="kikuchipy's corrected uint8 patterns of the block")
    b.array("start_euler", np.asarray(xmap.rotations.to_euler(), dtype=np.float64).reshape(*nav, 3), **START,
            note="Bunge radians, orix's to_euler of the Hough rotations: the refinement's x0 (the tests start from these)")
    b.array("start_phase", np.asarray(xmap.phase_id, dtype=np.int32).reshape(nav), **EXACT)

    def ori_arrays(prefix, xr, ps=False, joint=False):
        b.array(f"{prefix}_euler", np.asarray(xr.rotations.to_euler(), dtype=np.float64).reshape(*nav, 3),
                **(JOINT_EULER if joint else EULER),
                note="Bunge radians; the test holds the symmetry-reduced angle under 0.1 degree (D-SEM-87 for the joint run)")
        b.array(f"{prefix}_scores", np.asarray(xr.scores, dtype=np.float64).reshape(nav), **(JOINT_SCORE if joint else SCORE))
        b.array(f"{prefix}_num_evals", np.asarray(xr.num_evals, dtype=np.int32).reshape(nav), **COUNT,
                note="for the record: the path follows the float32 objective")
        if ps:
            b.array(f"{prefix}_pseudo_symmetry_index", np.asarray(xr.prop["pseudo_symmetry_index"], dtype=np.int32)
                    .reshape(nav), **EXACT)

    kw = {"show_progressbar": False} if "show_progressbar" in blk.refine_orientation.__code__.co_varnames else {}
    xr = blk.refine_orientation(xmap, det, mp, energy=ENERGY, trust_region=TRUST_ORI, **kw)
    ori_arrays("ori", xr)
    ori_arrays("ori_free", blk.refine_orientation(xmap, det, mp, energy=ENERGY, **kw))
    mask = np.ones(det.shape, dtype=bool)
    m = MASK_BORDER
    mask[m:-m, m:-m] = False
    ori_arrays("ori_masked", blk.refine_orientation(xmap, det, mp, energy=ENERGY, trust_region=TRUST_ORI,
                                                     signal_mask=mask, **kw))
    ops = Rotation.from_axes_angles([a for a, _ in PSEUDO_OPS], [d for _, d in PSEUDO_OPS], degrees=True)
    b.array("pseudo_symmetry_quaternions", np.asarray(ops.data, dtype=np.float64), **EXACT)
    rot_ps = ops.flatten().outer(xmap.rotations)
    b.array("ori_ps_start_euler", np.asarray(rot_ps.to_euler(), dtype=np.float64).transpose(1, 0, 2).reshape(*nav, 2, 3),
            rtol=0.0, atol=1e-10, note="each operator times each start rotation (orix outer), Bunge radians")
    ori_arrays("ori_ps", blk.refine_orientation(xmap, det, mp, energy=ENERGY, trust_region=TRUST_ORI,
                                                 pseudo_symmetry_ops=ops, **kw), ps=True)

    sc, det_pc, ne = blk.refine_projection_center(xr, det, mp, energy=ENERGY, trust_region=TRUST_PC, **kw)
    b.array("pc_start_quaternion", np.asarray(xr.rotations.data, dtype=np.float64).reshape(*nav, 4), **PC_START,
            note="the orientation run's result as orix quaternions, the PC refinement's fixed rotations")
    b.array("pc_scores", np.asarray(sc, dtype=np.float64).reshape(nav), **SCORE)
    b.array("pc_pc", np.asarray(det_pc.pc, dtype=np.float64).reshape(*nav, 3), **PC_RUN,
            note="Bruker PCx, PCy, PCz; the test holds rtol 1e-4 on 95 % of values")
    b.array("pc_num_evals", np.asarray(ne, dtype=np.int32).reshape(nav), **COUNT)

    xo, det_o = blk.refine_orientation_projection_center(xmap, det, mp, energy=ENERGY, trust_region=TRUST_ORI_PC, **kw)
    ori_arrays("ori_pc", xo, joint=True)
    b.array("ori_pc_pc", np.asarray(det_o.pc, dtype=np.float64).reshape(*nav, 3), **JOINT_PC)
    b.write()
    ctx.done("m4/refine-nickel-block")
