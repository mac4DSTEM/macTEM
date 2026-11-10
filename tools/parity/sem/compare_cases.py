"""tools/parity/sem/compare_cases.py — the Indexing room's Compare (milestone 4, #230).

The per-point disorientation between two indexing results of one scan, its histogram, median and fraction over 2°, as
the room computes it (`IndexingComparison`, D-SEM-97): orix 0.15.0's `Orientation.angle_with` with each side's point
group (for one group the same number as `Misorientation.angle` of A - B: Grimmer 1974, Morawiec 2004), per group of
points whose (A phase, B phase) pair is compared; numpy's `rad2deg`, `histogram` on 1° edges from 0 to the bins top of the
compared groups, `median` and `mean(angle > 2°)`. The bins top of a group is the first whole degree above the largest
disorientation of its proper subgroup, the largest vertex angle of orix's `OrientationRegion.from_symmetry(G, G)`
(Mackenzie 1958 for 432: 62.8°, top 63); a group whose region has no vertex (1) spans the whole 180°.

Pairing: when A and B each list one phase, the two pair if their Laue classes agree (kikuchipy compares two single-phase
maps with `angle_with` and names nothing); otherwise phases pair by equal name within one Laue class. Outcome per point,
in this order: 1 no A (phase -1, or A's phase has no point group), 2 no B (likewise), 0 compared (the pair is paired),
3 unpaired phases. The phase index is the only mask: a Hough point that is not indexed has the quaternion (0, 0, 0, 0),
which `angle_with` turns into 0°, so a phase >= 0 with a zero quaternion is compared at 0.

`m4/indexing-compare-planted`: a 20 x 25 grid drawn from numpy's default_rng(230) in two pairs, `multi` (A ni m-3m, ti
6/mmm; B ni 432, ti 622, fe m-3m, x without a point group) and `single` (A ni m-3m; B Nickel 432). Planted: small
rotations (0 to 6°) times a random element of B's group; near-Σ3 (60° about <111> after a deviation under 1°, so the angle
keeps off the 60° edge); A not indexed with a zero quaternion; B not indexed with a unit quaternion; phase >= 0 with a
zero quaternion on either side; A ni against B fe and A ti against B ni (unpaired); B x (no group). A point whose
compared angle lies within 1e-3° of a whole degree (2° among them) is drawn again; 0° is a bin's low end, not a risk.
`m4/indexing-compare-nickel-large`: the shipped scan's three results, Hough (F8), Dictionary (F9) and the file's own
indexing, compared in the three pairs.

Harness conventions. A reference holds no NaN (SEMParityHarnessTests): an angle not compared is stored as -1, which no
angle takes; the outcomes say why. Inputs are fixtures/ or sem-data/ (testBundleInputsAreTheFixtures): the nickel case
reads the committed F8 and F9 bundles from references/ (check.py emits into a scratch folder, so `ctx.out` would hold a
fresh Hough bundle that drifts within its 0.02 tolerance) and names those files with their sha256 in `source_bundles`,
so a regenerated F8 or F9 bundle makes this one drift too.

Tolerances: inputs, outcomes, edges, counts and the fraction over 2° exact; angles atol 1e-7 rad (the orientation
maths' bound, docs/parity.md); the median atol 5.8e-6° (1e-7 rad); the margins atol 1e-9°. Every pair states how far
its closest angle lies from 2° and from a bin edge (the harness's rule: angles above 1e-6°), and each is asserted above
1e-7 rad in degrees, which is what makes exact counts and an exact fraction a fair claim.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np

from refbundle import Bundle, read_manifest, sha256_of_array, sha256_of_file

HERE = Path(__file__).resolve().parent
ORIENTATION_INPUTS = HERE / "fixtures" / "orientation_inputs.json"
HOUGH = HERE / "references" / "m4" / "hough-indexing-nickel-large"
DICTIONARY = HERE / "references" / "m4" / "dictionary-indexing-nickel-ebsd-large"
SCAN_LABEL = "sem-data/nickel_ebsd_large/patterns_v2.h5"

EXACT = {"rtol": 0.0, "atol": 0.0}
ORI = {"rtol": 0.0, "atol": 1e-7}
MEDIAN = {"rtol": 0.0, "atol": 5.8e-6}   # 1e-7 rad in degrees
MARGIN = {"rtol": 0.0, "atol": 1e-9}

COMPARED, NONE_IN_A, NONE_IN_B, UNPAIRED = 0, 1, 2, 3
NOT_COMPARED = -1.0
THRESHOLD_DEGREES = 2.0
EDGE_GUARD_DEGREES = 1e-3
PORT_DEGREES = float(np.rad2deg(1e-7))

# The first whole degree above the largest disorientation of each proper point group (orix vertices; 180° for 1).
BINS_TOP = {"432": 63, "23": 91, "622": 94, "422": 99, "32": 105, "222": 121, "1": 181, "2": 181, "3": 181, "4": 181, "6": 181}


# ------------------------------------------------------------------------------------------------- the app's rule


def _phases(spec: list[tuple[str, str | None]]) -> list[dict]:
    """A side's phase list in index order: name, orix's point group (None without one)."""
    from orix.crystal_map import Phase

    out = []
    for name, pg in spec:
        g = None if pg is None else Phase(name=name, point_group=pg).point_group
        assert pg is None or g.name == pg, (name, pg, g)
        out.append({"name": name, "point_group": None if g is None else g.name, "group": g})
    return out


def _listed(phases: list[dict]) -> list[dict]:
    return [{"name": p["name"], "point_group": p["point_group"]} for p in phases]


def _largest_disorientation_degrees(proper) -> float:
    from orix.quaternion import OrientationRegion

    v = OrientationRegion.from_symmetry(proper, proper).vertices()
    return 180.0 if v.size == 0 else float(np.rad2deg(v.angle).max())


def _bins_top(group) -> int:
    return int(np.floor(_largest_disorientation_degrees(group.proper_subgroup))) + 1


def _laue(p: dict) -> str | None:
    return None if p["group"] is None else p["group"].laue.name


def _pairing(a: list[dict], b: list[dict]) -> dict[int, int]:
    if len(a) == 1 and len(b) == 1:
        la, lb = _laue(a[0]), _laue(b[0])
        return {0: 0} if la is not None and la == lb else {}
    pairs: dict[int, int] = {}
    for i, pa in enumerate(a):
        for j, pb in enumerate(b):
            if pa["name"] == pb["name"] and _laue(pa) is not None and _laue(pa) == _laue(pb):
                pairs[i] = j
                break
    return pairs


def _outcomes(a: list[dict], a_phase: np.ndarray, b: list[dict], b_phase: np.ndarray, pairs: dict[int, int]) -> np.ndarray:
    out = np.empty(a_phase.size, dtype=np.uint8)
    for k, (pa, pb) in enumerate(zip(a_phase.tolist(), b_phase.tolist())):
        if pa < 0 or a[pa]["group"] is None:
            out[k] = NONE_IN_A
        elif pb < 0 or b[pb]["group"] is None:
            out[k] = NONE_IN_B
        elif pairs.get(pa) == pb:
            out[k] = COMPARED
        else:
            out[k] = UNPAIRED
    return out


def _compare(a: list[dict], a_phase, a_q, b: list[dict], b_phase, b_q) -> dict:
    """The room's comparison of side A with side B: pairs, outcomes, angles (radians, NaN where not compared), the
    compared pairs of phases."""
    from orix.quaternion import Orientation

    pairs = _pairing(a, b)
    outcomes = _outcomes(a, a_phase, b, b_phase, pairs)
    angles = np.full(a_phase.size, np.nan)
    cmp = outcomes == COMPARED
    groups = sorted(set(zip(a_phase[cmp].tolist(), b_phase[cmp].tolist())))
    for pa, pb in groups:
        m = cmp & (a_phase == pa) & (b_phase == pb)
        ga, gb = a[pa]["group"], b[pb]["group"]
        angles[m] = Orientation(a_q[m], ga).angle_with(Orientation(b_q[m], gb))
        # For one group, angle_with is the angle of the reduced misorientation A - B; for two groups of one proper
        # subgroup (m-3m and 432), the same on that subgroup. A zero quaternion has no misorientation: left out.
        same = ga if ga.name == gb.name else (ga.proper_subgroup if ga.proper_subgroup.name == gb.proper_subgroup.name else None)
        if same is not None:
            nz = (np.linalg.norm(a_q[m], axis=1) > 0) & (np.linalg.norm(b_q[m], axis=1) > 0)
            sub = (Orientation(a_q[m][nz], same) - Orientation(b_q[m][nz], same)).angle
            worst = float(np.max(np.abs(sub - angles[m][nz]), initial=0.0))
            assert worst <= 1e-7, (pa, pb, worst)
    return {"pairs": pairs, "outcomes": outcomes, "angles": angles, "groups": groups}


def _statistics(a: list[dict], b: list[dict], r: dict) -> dict:
    cmp = r["outcomes"] == COMPARED
    degrees = np.rad2deg(r["angles"][cmp])
    top = max(max(_bins_top(a[pa]["group"]), _bins_top(b[pb]["group"])) for pa, pb in r["groups"])
    edges = np.arange(0.0, top + 1)
    counts = np.histogram(degrees, edges)[0].astype(np.int64)
    assert int(counts.sum()) == degrees.size, "every compared angle lies on the histogram"
    frac = degrees - np.floor(degrees)
    return {
        "degrees": degrees,
        "edges": edges,
        "counts": counts,
        "median": float(np.median(degrees)),
        "fraction": float(np.mean(degrees > THRESHOLD_DEGREES)),
        "closest_to_2": float(np.min(np.abs(degrees - THRESHOLD_DEGREES))),
        "closest_to_edge": float(np.min(np.minimum(frac, 1 - frac)[degrees > 1e-6])),
    }


def _near_an_edge(r: dict) -> np.ndarray:
    """The compared points whose angle lies within EDGE_GUARD_DEGREES of a whole degree or of 2° (above 1e-6°, the
    harness's rule: 0° is the first bin's low end)."""
    deg = np.rad2deg(r["angles"])
    frac = deg - np.floor(deg)
    near = (np.minimum(frac, 1 - frac) < EDGE_GUARD_DEGREES) | (np.abs(deg - THRESHOLD_DEGREES) < EDGE_GUARD_DEGREES)
    return (r["outcomes"] == COMPARED) & (deg > 1e-6) & near


def _write_pair(b: Bundle, p: str, a: list[dict], bside: list[dict], r: dict) -> dict:
    s = _statistics(a, bside, r)
    assert s["closest_to_2"] > PORT_DEGREES and s["closest_to_edge"] > PORT_DEGREES, (p, s["closest_to_2"], s["closest_to_edge"])
    b.value(f"{p}_a_phases", _listed(a))
    b.value(f"{p}_b_phases", _listed(bside))
    b.value(f"{p}_pairs", {str(k): v for k, v in sorted(r["pairs"].items())})
    b.value(f"{p}_compared_count", int(s["degrees"].size))
    b.array(f"{p}_outcomes", r["outcomes"], **EXACT, note="0 compared, 1 no A (phase -1 or no point group), 2 no B, 3 unpaired phases")
    b.array(f"{p}_angles_radians", np.where(np.isnan(r["angles"]), NOT_COMPARED, r["angles"]), **ORI,
            note="orix Orientation.angle_with (A against B, each with its phase's point group); -1 where not compared")
    b.array(f"{p}_edges_degrees", s["edges"], **EXACT, note="numpy.arange(0, top + 1): 1 degree bins up to the compared groups' bins top")
    b.array(f"{p}_counts", s["counts"], **EXACT, note="numpy.histogram of numpy.rad2deg(angles) of the compared points")
    b.scalar(f"{p}_median_degrees", s["median"], **MEDIAN)
    b.scalar(f"{p}_fraction_over_2_degrees", s["fraction"], **EXACT)
    b.scalar(f"{p}_closest_to_2_degrees", s["closest_to_2"], **MARGIN)
    b.scalar(f"{p}_closest_to_an_edge_degrees", s["closest_to_edge"], **MARGIN)
    print(f"    {p}: compared {s['degrees'].size}, median {s['median']:.6f} deg, over 2 deg {s['fraction']:.6f}, "
          f"closest to 2 deg {s['closest_to_2']:.3g}, to an edge {s['closest_to_edge']:.3g}, top {int(s['edges'][-1])}, "
          f"outcomes {np.bincount(r['outcomes'], minlength=4).tolist()}")
    return s


# ------------------------------------------------------------------------------------------------ the planted case

PLANTED_SHAPE = (20, 25)
PLANTED_PAIRS = {
    "multi": {
        "a": [("ni", "m-3m"), ("ti", "6/mmm")],
        "b": [("ni", "432"), ("ti", "622"), ("fe", "m-3m"), ("x", None)],
        # kind: points. A ni = 0, ti = 1; B ni = 0, ti = 1, fe = 2, x = 3.
        "kinds": {"small_ni": 140, "small_ti": 110, "sigma3": 40, "none_a": 40, "none_b": 40, "zero_a": 15, "zero_b": 15,
                  "unpaired_ni_fe": 30, "unpaired_ti_ni": 30, "b_x": 40},
    },
    "single": {
        "a": [("ni", "m-3m")],
        "b": [("Nickel", "432")],
        "kinds": {"small_ni": 320, "sigma3": 60, "none_a": 40, "none_b": 40, "zero_a": 20, "zero_b": 20},
    },
}


def _unit(rng) -> np.ndarray:
    q = rng.normal(size=4)
    return q / _length(q)


def _length(v: np.ndarray) -> float:
    """The vector's length, the same bits on every CPU: `np.linalg.norm` of a vector goes through OpenBLAS's dot, whose
    kernel OpenBLAS picks per CPU at run time (emit.py's numpy pin does not reach it), and the planted inputs then moved
    in their last bits from one runner to the next (#434). `math.fsum` is exact and the square root is IEEE."""
    return math.sqrt(math.fsum(float(x) * float(x) for x in v))


def _about(rng, low: float, high: float):
    """A rotation by an angle drawn in [low, high) degrees about a random axis."""
    from orix.quaternion import Rotation

    axis = rng.normal(size=3)
    return Rotation.from_axes_angles(axis / _length(axis), np.deg2rad(rng.uniform(low, high)))


def _element(rng, group):
    """A random element of the group's rotations (B's groups here are proper: 432, 622)."""
    from orix.quaternion import Rotation

    proper = group.proper_subgroup
    return Rotation(proper.data[rng.integers(proper.size)])


def _plant(rng, kind: str, pair: str, b: list[dict]) -> tuple[int, np.ndarray, int, np.ndarray]:
    from orix.quaternion import Rotation

    zero = np.zeros(4)
    sigma3 = Rotation.from_axes_angles([1.0, 1.0, 1.0], np.deg2rad(60.0))
    if kind in ("small_ni", "small_ti"):
        i = 0 if kind == "small_ni" else 1
        qa = _unit(rng)
        qb = (_element(rng, b[i]["group"]) * _about(rng, 0.0, 6.0) * Rotation(qa)).data.reshape(4)
        return i, qa, i, qb
    if kind == "sigma3":
        qa = _unit(rng)
        qb = (_element(rng, b[0]["group"]) * sigma3 * _about(rng, 0.0, 1.0) * Rotation(qa)).data.reshape(4)
        return 0, qa, 0, qb
    if kind == "none_a":
        return -1, zero, int(rng.integers(-1, len(b))), _unit(rng)
    if kind == "none_b":
        return int(rng.integers(0, 2 if pair == "multi" else 1)), _unit(rng), -1, _unit(rng)
    if kind == "zero_a":
        return 0, zero, 0, _unit(rng)
    if kind == "zero_b":
        i = 1 if pair == "multi" else 0
        return i, _unit(rng), i, zero
    if kind == "unpaired_ni_fe":
        return 0, _unit(rng), 2, _unit(rng)
    if kind == "unpaired_ti_ni":
        return 1, _unit(rng), 0, _unit(rng)
    if kind == "b_x":
        return int(rng.integers(0, 2)), _unit(rng), 3, _unit(rng)
    raise ValueError(kind)


def case_m4_indexing_compare_planted(ctx):
    """Both pairs on the planted grid: inputs, outcomes, angles, histogram, median, fraction over 2°, margins, and the
    bins top of every proper point group."""
    from orix.quaternion import symmetry as S

    case = "m4/indexing-compare-planted"
    b = Bundle(case, 4, "orix", "orix.quaternion.Orientation.angle_with; numpy.rad2deg, histogram, median, mean", ctx.out)
    b.input(ORIENTATION_INPUTS, "fixtures/orientation_inputs.json")
    known = set(json.loads(ORIENTATION_INPUTS.read_text(encoding="utf-8"))["point_groups"])

    tops = {}
    for g in (S.O, S.T, S.D6, S.D4, S.D3, S.D2, S.C1, S.C2, S.C3, S.C4, S.C6):
        tops[g.name] = int(np.floor(_largest_disorientation_degrees(g))) + 1
    assert tops == BINS_TOP, tops
    b.value("bins_top_degrees", tops)
    print("    bins top: " + ", ".join(f"{k} {v}" for k, v in tops.items()))

    rng = np.random.default_rng(230)
    n = PLANTED_SHAPE[0] * PLANTED_SHAPE[1]
    b.value("grid_rc", list(PLANTED_SHAPE))
    b.value("outcome_codes", {"compared": COMPARED, "none_in_a": NONE_IN_A, "none_in_b": NONE_IN_B, "unpaired_phases": UNPAIRED})
    for p, spec in PLANTED_PAIRS.items():
        a, bside = _phases(spec["a"]), _phases(spec["b"])
        assert all(x["point_group"] is None or x["point_group"] in known for x in a + bside)
        kinds = np.array([k for k, c in spec["kinds"].items() for _ in range(c)])
        assert kinds.size == n
        kinds = kinds[rng.permutation(n)]
        a_phase = np.empty(n, dtype=np.int32)
        b_phase = np.empty(n, dtype=np.int32)
        a_q = np.empty((n, 4))
        b_q = np.empty((n, 4))

        def draw(k):
            a_phase[k], a_q[k], b_phase[k], b_q[k] = _plant(rng, str(kinds[k]), p, bside)

        for k in range(n):
            draw(k)
        redrawn = 0
        while True:
            r = _compare(a, a_phase, a_q, bside, b_phase, b_q)
            near = np.flatnonzero(_near_an_edge(r))
            if near.size == 0:
                break
            for k in near:
                draw(int(k))
            redrawn += near.size
        print(f"    {p}: {redrawn} points drawn again (an angle within {EDGE_GUARD_DEGREES} deg of a whole degree)")
        b.value(f"{p}_planted", {k: int(c) for k, c in spec["kinds"].items()})
        b.array(f"{p}_a_quaternions", a_q, **EXACT)
        b.array(f"{p}_a_phase", a_phase, **EXACT)
        b.array(f"{p}_b_quaternions", b_q, **EXACT)
        b.array(f"{p}_b_phase", b_phase, **EXACT)
        _write_pair(b, p, a, bside, r)
    b.write()
    ctx.done(case)


# -------------------------------------------------------------------------------------------- the shipped nickel scan

NICKEL_EXPECTED = {   # compared, median degrees, fraction over 2 degrees (measured with orix 0.15.0, plan #230)
    "hough_file": (4124, 0.436480, 0.010427),
    "dictionary_file": (4125, 2.442832, 0.715394),
    "hough_dictionary": (4124, 2.373265, 0.731329),
}


def _committed(folder: Path, name: str, dtype: str) -> tuple[np.ndarray, dict]:
    """A committed bundle's array read from references/ (never from ctx.out), checked against its manifest."""
    entry = read_manifest(folder)["arrays"][name]
    a = np.fromfile(folder / entry["file"], dtype=dtype)
    assert sha256_of_array(a) == entry["sha256"], f"{folder.name}/{entry['file']} is not its manifest's sha256"
    path = folder / entry["file"]
    return a, {"path": str(path.relative_to(HERE)), "sha256": sha256_of_file(path)}


def case_m4_indexing_compare_nickel_large(ctx):
    """The shipped scan's Hough (F8), Dictionary (F9) and file indexing compared in three pairs."""
    import kikuchipy as kp

    case = "m4/indexing-compare-nickel-large"
    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if not ctx.have(p, case):
        return
    hq, hq_src = _committed(HOUGH, "quaternion", "<f8")
    hp, hp_src = _committed(HOUGH, "phase", "<i4")
    dq, dq_src = _committed(DICTIONARY, "ncc_best_quaternions", "<f8")
    hq, dq = hq.reshape(-1, 4), dq.reshape(-1, 4)

    s = kp.load(str(p))
    rows, cols = (int(x) for x in s.axes_manager.navigation_shape[::-1])
    n = rows * cols
    xm = s.xmap
    r = np.rint(np.asarray(xm.y) / xm.dy).astype(np.int64)
    c = np.rint(np.asarray(xm.x) / xm.dx).astype(np.int64)
    k = r * cols + c
    assert np.unique(k).size == k.size and k.min() >= 0 and k.max() < n
    fq = np.zeros((n, 4))
    fp = np.full(n, -1, dtype=np.int32)
    fq[k] = np.asarray(xm.rotations.data, dtype=np.float64).reshape(-1, 4)
    fp[k] = np.asarray(xm.phase_id, dtype=np.int32)
    assert hq.shape == dq.shape == fq.shape and hp.size == n

    file_phases = [(ph.name, ph.point_group.name) for i, ph in xm.phases if i >= 0]
    hx = read_manifest(HOUGH)["values"]["xmap"]
    hough_phases = [(nm, pg) for i, nm, pg in zip(hx["phase_ids"], hx["phase_names"], hx["point_groups"]) if i >= 0]
    assert file_phases == hough_phases == [("ni", "m-3m")], (file_phases, hough_phases)
    sides = {
        "hough": (_phases(hough_phases), hp.astype(np.int32), hq),
        "dictionary": (_phases([("ni", "m-3m")]), np.zeros(n, dtype=np.int32), dq),
        "file": (_phases(file_phases), fp, fq),
    }

    b = Bundle(case, 4, "orix", "orix.quaternion.Orientation.angle_with; numpy.rad2deg, histogram, median, mean", ctx.out)
    b.input(p, SCAN_LABEL)
    b.value("navigation_shape_rc", [rows, cols])
    b.value("source_bundles", {"hough_quaternions": hq_src, "hough_phase": hp_src, "dictionary_quaternions": dq_src})
    b.value("sides", {
        "hough": "m4/hough-indexing-nickel-large quaternion and phase (-1 not indexed; phases: ni m-3m)",
        "dictionary": "m4/dictionary-indexing-nickel-ebsd-large ncc_best_quaternions, phase 0 everywhere (ni m-3m)",
        "file": "kikuchipy.load(patterns_v2.h5).xmap at row * columns + column: file_quaternions, file_phase",
    })
    b.value("outcome_codes", {"compared": COMPARED, "none_in_a": NONE_IN_A, "none_in_b": NONE_IN_B, "unpaired_phases": UNPAIRED})
    b.array("file_quaternions", fq, **ORI, note="orix rotations of the file's crystal map, row-major on the scan")
    b.array("file_phase", fp, **EXACT)
    for pair, (na, nb) in (("hough_file", ("hough", "file")), ("dictionary_file", ("dictionary", "file")),
                           ("hough_dictionary", ("hough", "dictionary"))):
        a, a_phase, a_q = sides[na]
        bside, b_phase, b_q = sides[nb]
        res = _compare(a, a_phase, a_q, bside, b_phase, b_q)
        st = _write_pair(b, pair, a, bside, res)
        count, median, fraction = NICKEL_EXPECTED[pair]
        assert st["degrees"].size == count and round(st["median"], 6) == median and round(st["fraction"], 6) == fraction, \
            (pair, st["degrees"].size, st["median"], st["fraction"])
    b.write()
    ctx.done(case)
