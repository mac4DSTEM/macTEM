"""tools/parity/sem/dictionary_cases.py — the dictionary-indexing cases of emit.py (milestone 4, figure F9).

kikuchipy 0.13.1's `EBSD.dictionary_indexing` (Chen et al. 2015; Jackson et al. 2019) with its two metrics,
`NormalizedCrossCorrelationMetric` ("ncc", the default) and `NormalizedDotProductMetric` ("ndp"), on a dictionary that
`EBSDMasterPattern.get_patterns` projects from kikuchipy's in-package Ni 20 kV master pattern (uint8, D-SEM-32) for the
cubochoric sample of m-3m at 4 deg (`orix.sampling.get_sample_fundamental`, 11 935 rotations), onto the north-star
detector of F15 (60 x 60, PC (0.4214, 0.2142, 0.5013) Bruker, sample tilt 70 deg). The experimental patterns are
kikuchipy's static then dynamic background removal of the scan (its tutorials' chain).

Two cases. `m4/dictionary-indexing-kikuchipy-h5ebsd` runs on the committed 3 x 3 nickel cut and carries kikuchipy's
corrected patterns, so the port is checked on kikuchipy's exact input: the default float32 NCC, NCC in float64, NDP,
NCC with a circular signal mask and a navigation mask, and NCC over chunks of 1000 dictionary patterns (the merge).
`m4/dictionary-indexing-nickel-ebsd-large` is figure F9: the whole 55 x 75 scan (the shipped demo file), keep_n 5, and a
6 x 6 block of corrected patterns with the block's own result (exact input on real data).

Tolerances: the scores of a float32 run at rtol 1e-4 (the brief's bound: kikuchipy matches in float32 through BLAS, a
port sums in another order), of a float64 run at rtol 1e-5 (`np.allclose`'s default, kikuchipy's own tests); simulation
indices exact (the Swift test lets two ranks swap only where their scores tie within the score tolerance). The whole-scan
F9 scores at rtol 2e-3 on the app's own background chain (D-SEM-18's one-grey-level differences: a 0.2 % one-level
perturbation of kikuchipy's corrected scan measured 1.04e-3 and moved the best match of 2 of 4125 points).
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from refbundle import Bundle

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
NI_MP = FIXTURES / "emsoft_ebsd_master_pattern_ni_mc_mp_20kv_uint8_gzip_opts9.h5"
SMALL = FIXTURES / "kikuchipy_h5ebsd_patterns.h5"

EXACT = {"rtol": 0.0, "atol": 0.0}
F32_SCORES = {"rtol": 1e-4, "atol": 0.0}
F64_SCORES = {"rtol": 1e-5, "atol": 0.0}
CHAIN_SCORES = {"rtol": 2e-3, "atol": 0.0}
F64 = {"rtol": 1e-7, "atol": 0.0}

DETECTOR = {"shape": (60, 60), "pc": [0.4214, 0.2142, 0.5013], "sample_tilt": 70.0, "binning": 8}
RESOLUTION = 4.0
BLOCK = (slice(20, 26), slice(30, 36))


def _dictionary():
    """The Ni dictionary: the master pattern, the m-3m sample at RESOLUTION, the patterns as an EBSD signal with its
    crystal map (what `dictionary_indexing` takes)."""
    import kikuchipy as kp
    from orix.sampling import get_sample_fundamental

    mp = kp.load(str(NI_MP), projection="lambert", hemisphere="both")
    rot = get_sample_fundamental(resolution=RESOLUTION, point_group=mp.phase.point_group, method="cubochoric")
    det = kp.detectors.EBSDDetector(**DETECTOR)
    sim = mp.get_patterns(rot, det, compute=True, show_progressbar=False)
    return mp, rot, sim


def _corrected(s):
    s = s.deepcopy()
    s.remove_static_background(operation="subtract")
    s.remove_dynamic_background(operation="subtract", filter_domain="frequency", truncate=4.0)
    return s


def _common(b: Bundle, mp, rot, keep_n: int) -> None:
    b.input(NI_MP, "fixtures/" + NI_MP.name)
    b.value("detector", {k: (list(v) if isinstance(v, (tuple, list)) else v) for k, v in DETECTOR.items()})
    b.value("resolution", RESOLUTION)
    b.value("point_group", mp.phase.point_group.name)
    b.value("dictionary_size", int(rot.size))
    b.value("keep_n", keep_n)
    b.value("background", "remove_static_background(operation='subtract') then remove_dynamic_background("
                          "operation='subtract', filter_domain='frequency', truncate=4.0)")


def _run(b: Bundle, name: str, xmap, tol: dict, note: str) -> None:
    """One indexing run: the scores and simulation indices of the points in the data (orix's `prop` hands only those;
    a masked point's row is np.empty's garbage in kikuchipy, so only `is_in_data` is kept for it), in scan order, keep_n
    columns."""
    inside = np.asarray(xmap.is_in_data)
    keep_n = int(np.asarray(xmap.prop["scores"]).size // inside.sum())
    scores = np.asarray(xmap.prop["scores"]).reshape(-1, keep_n)
    indices = np.asarray(xmap.prop["simulation_indices"]).reshape(-1, keep_n).astype(np.int32)
    b.array(f"{name}_scores", scores, **tol, note=note)
    b.array(f"{name}_simulation_indices", indices, **EXACT, note=note)
    if not inside.all():
        b.array(f"{name}_is_in_data", inside.astype(np.uint8), **EXACT)


def _crystal_map(b: Bundle, prefix: str, xmap) -> None:
    """The crystal map kikuchipy returns, best match per point: Bunge Euler angles (orix's `to_euler`), the coordinates."""
    rot = xmap.rotations
    best = rot[:, 0] if rot.ndim == 2 else rot
    b.array(f"{prefix}best_quaternions", best.data.reshape(-1, 4).astype(np.float64), **EXACT,
            note="the dictionary's rotation at the best simulation index")
    b.array(f"{prefix}best_euler", best.to_euler().reshape(-1, 3).astype(np.float64), **F64)
    b.array(f"{prefix}x", np.asarray(xmap.x, dtype=np.float64), **EXACT)
    b.array(f"{prefix}y", np.asarray(xmap.y, dtype=np.float64), **EXACT)


def case_m4_dictionary_indexing_small(ctx):
    """kikuchipy's dictionary indexing on the committed 3 x 3 nickel cut, every option the port has."""
    import kikuchipy as kp

    case = "m4/dictionary-indexing-kikuchipy-h5ebsd"
    mp, rot, sim = _dictionary()
    s = _corrected(kp.load(str(SMALL)))
    b = Bundle(case, 4, "kikuchipy", "kikuchipy.signals.EBSD.dictionary_indexing", ctx.out)
    b.input(SMALL, "fixtures/" + SMALL.name)
    _common(b, mp, rot, 20)
    b.array("experimental", np.asarray(s.data), **EXACT, note="kikuchipy's corrected uint8 patterns, the indexing input")
    b.value("step_sizes", [float(a.scale) for a in s.axes_manager.navigation_axes[::-1]])

    window = kp.filters.Window("circular", DETECTOR["shape"])
    signal_mask = ~window.astype(bool)
    navigation_mask = np.zeros((3, 3), dtype=bool)
    navigation_mask[1, 1] = True
    navigation_mask[0, 2] = True
    b.array("signal_mask", signal_mask.astype(np.uint8), **EXACT, note="1 = pixel left out (kikuchipy's circular window, negated)")
    b.array("navigation_mask", navigation_mask.astype(np.uint8), **EXACT, note="1 = point left out")

    runs = {
        "ncc": dict(metric="ncc", keep_n=20),
        "ncc_float64": dict(metric="ncc", keep_n=20, dtype="float64"),
        "ndp": dict(metric="ndp", keep_n=20),
        "ncc_masked": dict(metric="ncc", keep_n=20, signal_mask=signal_mask, navigation_mask=navigation_mask),
        "ncc_chunked": dict(metric="ncc", keep_n=20, n_per_iteration=1000),
    }
    b.value("runs", {k: {kk: vv for kk, vv in v.items() if kk not in ("signal_mask", "navigation_mask")}
                     | ({"signal_mask": True, "navigation_mask": True} if "signal_mask" in v else {})
                     for k, v in runs.items()})
    for name, kw in runs.items():
        xmap = s.dictionary_indexing(sim, **kw)
        tol = F64_SCORES if kw.get("dtype") == "float64" else F32_SCORES
        _run(b, name, xmap, tol, f"dictionary_indexing({', '.join(f'{k}={v!r}' for k, v in kw.items() if k not in ('signal_mask', 'navigation_mask'))})")
        if name == "ncc":
            _crystal_map(b, "ncc_", xmap)
    b.write()
    ctx.done(case)


def case_m4_dictionary_indexing_nickel_large(ctx):
    """Figure F9: the whole nickel_ebsd_large scan indexed against the Ni dictionary, keep_n 5, and a 6 x 6 block of
    kikuchipy's corrected patterns indexed as its own signal."""
    import kikuchipy as kp

    case = "m4/dictionary-indexing-nickel-ebsd-large"
    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if not ctx.have(p, case):
        return
    mp, rot, sim = _dictionary()
    s = _corrected(kp.load(str(p)))
    b = Bundle(case, 4, "kikuchipy", "kikuchipy.signals.EBSD.dictionary_indexing", ctx.out)
    b.input(p, "sem-data/nickel_ebsd_large/patterns_v2.h5")
    _common(b, mp, rot, 5)
    b.value("step_sizes", [float(a.scale) for a in s.axes_manager.navigation_axes[::-1]])
    b.fingerprint("experimental", np.asarray(s.data))
    xmap = s.dictionary_indexing(sim, metric="ncc", keep_n=5)
    _run(b, "ncc", xmap, CHAIN_SCORES, "figure F9: the whole scan after kikuchipy's background chain")
    _crystal_map(b, "ncc_", xmap)
    r, k = BLOCK
    b.value("block", {"rows": [r.start, r.stop], "cols": [k.start, k.stop]})
    blk = s.inav[k, r]
    b.array("block_experimental", np.asarray(blk.data), **EXACT, note="scan rows 20..25, cols 30..35, kikuchipy's corrected uint8")
    _run(b, "block_ncc", blk.dictionary_indexing(sim, metric="ncc", keep_n=5), F32_SCORES, "the block as its own signal")
    b.write()
    ctx.done(case)
