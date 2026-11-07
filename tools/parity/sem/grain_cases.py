"""tools/parity/sem/grain_cases.py — the grain cases of emit.py (milestone 5, figures F11 and F12).

DefDAP 1.3.1 (Apache-2.0) on orix-data's Ti map (hcp, 622) and the two-phase steel (fcc and bcc, 432):
`Map.find_boundaries` (neighbour misorientation over DefDAP's symmetry list, grain and phase boundaries),
`Map.find_grains` (flood fill, minimum size), `Map.build_neighbour_network`, `Map.calc_kam`, `Grain.calc_average_ori`,
`Grain.build_mis_ori_list` and `Grain.calc_grod` (grain average orientation, GROD and its axis; GOS is the mean GROD
angle). DefDAP is run as a library on maps built with its `PythonDict` loader, Bunge angles in radians as its loaders
make them; nothing of DefDAP is patched. Next to DefDAP's KAM (3 x 3 kernel of the four first neighbours, mean of the
cosines, no crystal symmetry: its docstring says so) the bundles hold the symmetric KAM the port defaults to (D-SEM-55 in
docs/decisions.md): the same four neighbours, each misorientation the smallest over DefDAP's symmetry list (as
`find_boundaries` takes it), only neighbours of the same indexed phase, those above the threshold dropped, the mean of
the angles (Wright, Nowell and Field 2011). emit.py imports every `case_` function here.

Tolerances (catalogue section 5): grain maps, sizes, boundary images, neighbour network exact; KAM, GROD and GOS atol
1e-6 rad; the grain average orientation atol 1e-10 (one ordered sum per grain, the same closed formulas); the
neighbour misorientation angles atol 1e-7. Every bundle states how far the closest angle lies from the 10° threshold,
which is what makes exact boundary images a fair claim.
"""

from __future__ import annotations

import contextlib
import io
import json
import re
from pathlib import Path

import numpy as np

from refbundle import Bundle

HERE = Path(__file__).resolve().parent
GRAIN_INPUTS = HERE / "fixtures" / "grain_inputs.json"
GRAIN_INPUTS_LABEL = "fixtures/grain_inputs.json"

EXACT = {"rtol": 0.0, "atol": 0.0}
ANGLE = {"rtol": 0.0, "atol": 1e-6}     # KAM, GROD, GOS (brief P5-01; catalogue section 5)
NEIGHBOUR = {"rtol": 0.0, "atol": 1e-7}  # the neighbour misorientation angles behind the boundary images
QUAT = {"rtol": 0.0, "atol": 1e-10}     # quaternions from one closed formula, the grain average from one ordered sum

BOUNDARY_DEGREES = 10.0   # DefDAP's default `misori_tol`
MIN_GRAIN_SIZE = 10       # DefDAP's default `min_grain_size`
KAM_THRESHOLD_DEGREES = 5.0


def _defdap():
    """DefDAP at the lock's version, its progress lines silenced by the callers."""
    import defdap
    import defdap._version

    lock = (HERE / "requirements.lock").read_text()
    want = dict(re.findall(r"^([A-Za-z0-9_.-]+)==(\S+)", lock, re.M)).get("defdap")
    have = defdap._version.__version__
    if want != have:
        raise SystemExit(f"grain_cases.py: requirements.lock pins defdap {want}, running {have}")
    defdap.__version__ = have
    return defdap


def _quiet():
    return contextlib.redirect_stdout(io.StringIO())


def _map(shape, step, phases, phase, euler_radians):
    """A DefDAP EBSD map from Bunge angles in radians ((h, w, 3)), DefDAP phase numbers (0 not indexed, 1...) and
    `defdap.crystal.Phase` objects."""
    from defdap import ebsd

    h, w = shape
    eu = np.ascontiguousarray(np.asarray(euler_radians, dtype=np.float64).reshape(h, w, 3).transpose(2, 0, 1))
    with _quiet():
        return ebsd.Map({"step_size": step, "phases": phases, "phase": np.asarray(phase, dtype=np.uint8).reshape(h, w),
                         "euler_angle": eu, "band_contrast": np.zeros((h, w), np.uint8)}, data_type="PythonDict")


def _quats(m):
    return np.array([o.quat_coef for o in m.data.orientation.ravel()]).reshape(m.shape + (4,))


def _sym_eqv(q, syms):
    """DefDAP's `Quat.calc_sym_eqvs` on an (n, 4) array: (num_syms, n, 4), sym * q, northern hemisphere."""
    out = np.empty((len(syms), q.shape[0], 4))
    out[0] = q
    for i, s in enumerate(syms[1:], start=1):
        s = s.quat_coef
        out[i, :, 0] = q[:, 0] * s[0] - q[:, 1] * s[1] - q[:, 2] * s[2] - q[:, 3] * s[3]
        out[i, :, 1] = q[:, 0] * s[1] + q[:, 1] * s[0] - q[:, 2] * s[3] + q[:, 3] * s[2]
        out[i, :, 2] = q[:, 0] * s[2] + q[:, 2] * s[0] - q[:, 3] * s[1] + q[:, 1] * s[3]
        out[i, :, 3] = q[:, 0] * s[3] + q[:, 3] * s[0] - q[:, 1] * s[2] + q[:, 2] * s[1]
        flip = out[i, :, 0] < 0
        out[i, flip] *= -1
    return out


def _neighbour_angles(m, q):
    """The angles behind `find_boundaries`: right and below neighbour, the smallest misorientation over the primary
    phase's symmetries (DefDAP takes the primary phase for every point); NaN on the last column / row."""
    syms = m.primary_phase.crystal_structure.symmetries
    h, w = m.shape
    eq = _sym_eqv(q.reshape(-1, 4), syms).reshape(len(syms), h, w, 4)
    dx = np.max(np.abs(np.einsum("ijk,sijk->sij", q[:, :-1], eq[:, :, 1:])), axis=0)
    dy = np.max(np.abs(np.einsum("ijk,sijk->sij", q[:-1], eq[:, 1:])), axis=0)
    ax = np.full((h, w), np.nan)
    ay = np.full((h, w), np.nan)
    ax[:, :-1] = 2 * np.arccos(np.minimum(dx, 1))
    ay[:-1] = 2 * np.arccos(np.minimum(dy, 1))
    return ax, ay


def _symmetric_kam(q, phase, sym_lists, threshold):
    """The symmetric KAM (the port's default; DefDAP has no such function): each point's four first neighbours (above,
    below, left, right, summed in that order) of the same phase, both indexed, the misorientation angle the smallest over
    the phase's DefDAP symmetry list, neighbours above `threshold` (radians, None for none) dropped, the mean of the kept
    angles; NaN where none is kept or the point is not indexed."""
    h, w = phase.shape
    sums = np.zeros((h, w))
    counts = np.zeros((h, w), dtype=np.int64)
    rows, cols = np.indices((h, w))
    for dr, dc in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        rr, cc = rows + dr, cols + dc
        inside = (rr >= 0) & (rr < h) & (cc >= 0) & (cc < w)
        nb_phase = np.zeros((h, w), dtype=phase.dtype)
        nb_phase[inside] = phase[rr[inside], cc[inside]]
        for p in range(1, len(sym_lists) + 1):
            mask = inside & (phase == p) & (nb_phase == p)
            if not mask.any():
                continue
            qp = q[mask]
            qn = q[rr[mask], cc[mask]]
            eq = _sym_eqv(qn, sym_lists[p - 1])
            d = np.minimum(np.max(np.abs(np.einsum("snk,nk->sn", eq, qp)), axis=0), 1.0)
            a = 2 * np.arccos(d)
            keep = np.ones(a.shape, dtype=bool) if threshold is None else a <= threshold
            sums[mask] += np.where(keep, a, 0.0)
            counts[mask] += keep
    kam = np.full((h, w), np.nan)
    ok = counts > 0
    kam[ok] = sums[ok] / counts[ok]
    return kam


def _image(points, shape):
    image = np.zeros(shape, dtype=bool)
    for x, y in points:
        image[y, x] = True
    return image


def _closest_to(angles, threshold):
    a = angles[np.isfinite(angles)]
    return float(np.min(np.abs(a - threshold)))


def _grain_bundle(ctx, case: str, m, inputs, note: str, full_arrays: bool, sample_stride: int = 1) -> None:
    from defdap import ebsd  # noqa: F401  (imported for its side effects on the datastore)

    b = Bundle(case, 5, "defdap",
               "defdap.ebsd.Map.find_boundaries, find_grains, build_neighbour_network, calc_kam; "
               "Grain.calc_average_ori, build_mis_ori_list, calc_grod", ctx.out)
    for path, label in inputs:
        b.input(path, label)
    h, w = m.shape
    b.value("note", note)
    b.value("shape", [h, w])
    b.value("step_um", float(m.step_size))
    b.value("phases", [{"name": ph.name, "laue_group": ph.laue_group, "space_group": ph.spaceGroup,
                        "crystal_structure": ph.crystal_structure.name} for ph in m.phases])
    b.value("boundary_degrees", BOUNDARY_DEGREES)
    b.value("min_grain_size", MIN_GRAIN_SIZE)
    b.value("kam_threshold_degrees", KAM_THRESHOLD_DEGREES)

    q = _quats(m)
    phase = np.asarray(m.data.phase).astype(np.int32)
    tol = np.deg2rad(BOUNDARY_DEGREES)
    with _quiet():
        m.data.generate("grain_boundaries", misori_tol=BOUNDARY_DEGREES)
        m.data.generate("grains", min_grain_size=MIN_GRAIN_SIZE)
        grains = np.asarray(m.data.grains).astype(np.int32)
        kam_defdap = np.asarray(m.data.KAM)
        m.build_neighbour_network()
        m.calc_grain_av_oris()
        m.calc_grain_mis_ori()

    gb = m.data.grain_boundaries
    pb = m.data.phase_boundaries
    ax, ay = _neighbour_angles(m, q)
    # The angles reproduce DefDAP's boundary images (phase boundaries are added to them as DefDAP adds them). The phase
    # boundary images are drawn from the point sets: DefDAP's `BoundarySet._image` of an empty set marks every point
    # (`image[()] = True`), so `pb.image_x` of a one-phase map is all True although it holds no point.
    pbx, pby = _image(pb.points_x, (h, w)), _image(pb.points_y, (h, w))
    assert np.array_equal(gb.image_x, ((ax > tol) & np.isfinite(ax)) | pbx)
    assert np.array_equal(gb.image_y, ((ay > tol) & np.isfinite(ay)) | pby)
    b.scalar("closest_neighbour_angle_to_threshold_rad", min(_closest_to(ax, tol), _closest_to(ay, tol)), atol=1e-9)
    kt = np.deg2rad(KAM_THRESHOLD_DEGREES)
    same_x = np.zeros((h, w), dtype=bool)
    same_x[:, :-1] = (phase[:, :-1] == phase[:, 1:]) & (phase[:, :-1] > 0)
    same_y = np.zeros((h, w), dtype=bool)
    same_y[:-1] = (phase[:-1] == phase[1:]) & (phase[:-1] > 0)
    b.scalar("closest_neighbour_angle_to_kam_threshold_rad",
             min(_closest_to(np.where(same_x, ax, np.nan), kt), _closest_to(np.where(same_y, ay, np.nan), kt)), atol=1e-9)

    sym_lists = [ph.crystal_structure.symmetries for ph in m.phases]
    kam_sym = _symmetric_kam(q, phase, sym_lists, None)
    kam_thr = _symmetric_kam(q, phase, sym_lists, np.deg2rad(KAM_THRESHOLD_DEGREES))

    # Grains: points in DefDAP's flood order, sizes, phases, average orientation, GROD and its axis, GOS.
    points, offsets, phase_of, ref, avg_cos, grod, grod_axis = [], [0], [], [], [], [], []
    for g in m:
        pts = np.asarray(g.data.point)
        points.extend(int(y) * w + int(x) for x, y in pts)
        offsets.append(len(points))
        phase_of.append(g.phase_id)
        ref.append(g.ref_ori.quat_coef)
        avg_cos.append(g.average_mis_ori)
        with _quiet():
            angle, axis = g.data.GROD, g.data.GROD_axis
        grod.extend(np.asarray(angle).tolist())
        grod_axis.extend(np.asarray(axis).T.tolist())
    grod = np.array(grod)
    sizes = np.diff(offsets)
    gos = np.array([grod[offsets[k]:offsets[k + 1]].mean() for k in range(len(sizes))])

    # The neighbour network: each pair of grains (ids from 0, smaller first) with its boundary points of each kind.
    edges = []
    for g1, g2, data in m.neighbour_network.edges(data=True):
        seg = data["boundary"]
        a, c = sorted((g1.grain_id, g2.grain_id))
        edges.append((a, c, len(seg.boundary_points_x), len(seg.boundary_points_y)))
    edges.sort()

    b.value("grain_count", len(m))
    b.value("small_grain_points", int(np.count_nonzero(grains == -2)))
    b.value("unassigned_points", int(np.count_nonzero(grains == 0)))
    b.array("grain_sizes", sizes.astype(np.int32), **EXACT, note="points per grain, DefDAP's grain order")
    b.array("grain_phase", np.array(phase_of, dtype=np.int32), **EXACT, note="DefDAP phase index (0-based) per grain")
    b.array("grain_average_orientation", np.array(ref), **QUAT, note="Grain.ref_ori (calc_average_ori), DefDAP order")
    b.array("gos", gos, **ANGLE, note="mean GROD angle per grain, radians")
    b.array("grain_average_cosine", np.array(avg_cos), **ANGLE, note="Grain.average_mis_ori: mean of |q . ref| per grain")
    b.array("neighbour_network", np.array(edges, dtype=np.int32).reshape(-1, 4), **EXACT,
            note="grain a, grain b (a < b, ids from 0), boundary points in x, boundary points in y; sorted")
    if full_arrays:
        b.array("quaternions", q, **QUAT, note="DefDAP Quat.create_many_quats, northern hemisphere")
        b.array("phase", phase, **EXACT, note="DefDAP phase numbers: 0 not indexed, 1...")
        b.array("neighbour_angle_x", np.nan_to_num(ax, nan=-1.0), **NEIGHBOUR, note="right neighbour; -1 on the last column")
        b.array("neighbour_angle_y", np.nan_to_num(ay, nan=-1.0), **NEIGHBOUR, note="neighbour below; -1 on the last row")
        b.array("grain_boundary_x", gb.image_x.astype(np.uint8), **EXACT)
        b.array("grain_boundary_y", gb.image_y.astype(np.uint8), **EXACT)
        b.array("phase_boundary_x", pbx.astype(np.uint8), **EXACT)
        b.array("phase_boundary_y", pby.astype(np.uint8), **EXACT)
        b.array("grains", grains, **EXACT, note="DefDAP grain map: 1... grains, -2 points of grains below the minimum size, 0 never filled")
        b.array("grain_points", np.array(points, dtype=np.int32), **EXACT, note="row * width + column, DefDAP's flood order")
        b.array("grod", grod, **ANGLE, note="GROD per grain point, in grain_points order, radians")
        b.array("grod_axis", np.array(grod_axis), **ANGLE, note="Grain.calc_grod axis (angle times unit axis), grain_points order")
        b.array("kam_defdap", kam_defdap, **ANGLE, note="Map.calc_kam: no crystal symmetry")
        b.array("kam", np.nan_to_num(kam_sym, nan=-1.0), **ANGLE, note="symmetric KAM, no threshold; -1 where none")
        b.array("kam_threshold", np.nan_to_num(kam_thr, nan=-1.0), **ANGLE, note="symmetric KAM, 5 degree threshold; -1 where none")
    else:
        b.fingerprint("grains", grains)
        idx = np.arange(0, h * w, sample_stride, dtype=np.int32)
        b.array("sample_index", idx, **EXACT, note="row * width + column")
        b.array("sample_grains", grains.ravel()[idx], **EXACT)
        b.array("sample_kam_defdap", kam_defdap.ravel()[idx], **ANGLE)
        b.array("sample_kam", np.nan_to_num(kam_sym, nan=-1.0).ravel()[idx], **ANGLE)
        b.array("sample_kam_threshold", np.nan_to_num(kam_thr, nan=-1.0).ravel()[idx], **ANGLE)
        gidx = np.arange(0, len(points), sample_stride, dtype=np.int32)
        b.array("sample_grod_index", gidx, **EXACT, note="position in the grains' points, DefDAP's flood order")
        b.array("sample_grod_point", np.array(points, dtype=np.int32)[gidx], **EXACT)
        b.array("sample_grod", grod[gidx], **ANGLE)
        b.value("kam_mean", {"defdap": float(np.mean(kam_defdap)), "symmetric": float(np.nanmean(kam_sym)),
                             "threshold": float(np.nanmean(kam_thr))})
    b.write()
    ctx.done(case)


def _ti_phase():
    from defdap.crystal import Phase

    return Phase("Ti", 9, 194, (2.951, 2.951, 4.684, np.pi / 2, np.pi / 2, 2 * np.pi / 3))


def case_m5_grains_ti(ctx):
    """The 90 x 120 corner of orix-data's Ti map (committed in fixtures/grain_inputs.json), hcp: every array."""
    _defdap()
    t = json.loads(GRAIN_INPUTS.read_text(encoding="utf-8"))["ti"]
    h, w = t["shape"]
    eu = np.deg2rad(np.asarray(t["euler_degrees"], dtype=np.float64))
    m = _map((h, w), t["step_um"], [_ti_phase()], np.ones((h, w)), eu)
    _grain_bundle(ctx, "m5/grains-ti", m, [(GRAIN_INPUTS, GRAIN_INPUTS_LABEL)],
                  "orix-data Ti_orientations.ctf rows 0-89, columns 0-119; Bunge angles degrees -> radians (numpy.deg2rad)",
                  full_arrays=True)


def case_m5_grains_ti_full(ctx):
    """Figures F11 and F12: orix-data's whole 381 x 507 Ti map (fetched). The grain map as its fingerprint, sizes, phases,
    average orientations, GOS and the neighbour network in full, KAM and GROD every 37th value."""
    _defdap()
    p = ctx.data / "orix" / "Ti_orientations.ctf"
    if not ctx.have(p, "m5/grains-ti-full"):
        return
    table = np.loadtxt(p, skiprows=1)
    h, w = len(np.unique(table[:, 10])), len(np.unique(table[:, 9]))
    assert h * w == table.shape[0]
    m = _map((h, w), 0.25, [_ti_phase()], np.ones((h, w)), np.deg2rad(table[:, :3]))
    _grain_bundle(ctx, "m5/grains-ti-full", m, [(p, "sem-data/orix/Ti_orientations.ctf")],
                  "orix-data Ti_orientations.ctf, the whole 381 x 507 map; Bunge angles degrees -> radians (numpy.deg2rad)",
                  full_arrays=False, sample_stride=37)


def case_m5_grains_sdss(ctx):
    """The two-phase steel (fetched; the Swift test reads the same file committed as
    macTEMTests/Fixtures/ebsd-sdss-ferrite-austenite.ang): austenite (fcc, 225) and ferrite (bcc, 229), both DefDAP
    cubic, the file's Bunge angles in radians as written (no frame change: misorientations, grains, KAM and GROD do not
    move under a common sample rotation), phase boundaries."""
    _defdap()
    from defdap.crystal import Phase

    p = ctx.data / "orix" / "sdss_ferrite_austenite.ang"
    if not ctx.have(p, "m5/grains-sdss"):
        return
    ang = np.loadtxt(p, comments="#")
    assert ang.shape == (100 * 117, 8), ang.shape
    phases = [Phase("austenite", 11, 225, (3.595, 3.595, 3.595, np.pi / 2, np.pi / 2, np.pi / 2)),
              Phase("ferrite", 11, 229, (2.867, 2.867, 2.867, np.pi / 2, np.pi / 2, np.pi / 2))]
    phase = ang[:, 7].astype(int)
    assert set(np.unique(phase)) <= {1, 2}
    m = _map((100, 117), 1.5, phases, phase.reshape(100, 117), ang[:, :3])
    _grain_bundle(ctx, "m5/grains-sdss", m, [(p, "sem-data/orix/sdss_ferrite_austenite.ang")],
                  "orix-data sdss_ferrite_austenite.ang, the whole 100 x 117 map; phase 1 austenite, 2 ferrite",
                  full_arrays=True)
