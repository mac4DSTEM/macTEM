#!/usr/bin/env python
"""tools/parity/sem/emit.py — write the reference bundles of the SEM program from the pinned Python stack.

    emit.py --out DIR [--data References/sem-data] [--only m1/read-] [--require-data]

One function per case below; each reads a committed fixture (fixtures/, small, GPL-3 or CC BY, see
docs/data-sources.md) or a downloaded dataset (--data, fetched by fetch-data.sh, never committed) and writes a bundle
(lib/refbundle.py). A case whose dataset is absent is skipped with a line, unless --require-data (CI). check.py runs
this into a scratch folder and compares against references/ within the committed tolerances, so a change in the pinned
stack, a fixture or this script that moves a number is red until the bundle is regenerated on purpose
(`emit.py --out references`) and committed with the reason.

Milestones (docs/sem/north-star.md): m1 data in and seen (readers, pattern browser values, virtual BSE), m2 pattern
processing (static and dynamic background, emitted now so phase-2 ports can start from a committed reference), m3
orientation maths (orix's rotations, point groups, fundamental zones, orientations and misorientations), m7 SEM-EDS line
intensities on the TM002 spectrum (the numbers behind the EDS figure).

Run with `python -I -B` from outside this folder: a fixture is data, never code.
"""

from __future__ import annotations

import argparse
import re
import sys
import warnings
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
from refbundle import Bundle  # noqa: E402

warnings.filterwarnings("ignore")

FIXTURES = HERE / "fixtures"
LOCK = HERE / "requirements.lock"

# A tolerance states what the port must match: exact for anything a reader hands through, numpy float64 defaults
# (rtol 1e-7, the assert_allclose default) where the reference reduces in float64, 1 count where it rounds to uint8.
EXACT = {"rtol": 0.0, "atol": 0.0}
F64 = {"rtol": 1e-7, "atol": 0.0}
U8 = {"rtol": 0.0, "atol": 1.0}


def assert_pins() -> None:
    """The lock is the claim: the running stack must be exactly the pinned kikuchipy, orix, hyperspy, exspy, rsciio,
    pyebsdindex, diffsims and numpy, or an override (another venv) would emit references of another stack."""
    import importlib

    pins = dict(re.findall(r"^([A-Za-z0-9_.-]+)==(\S+)", LOCK.read_text(), re.M))
    names = {"kikuchipy": "kikuchipy", "orix": "orix", "hyperspy": "hyperspy", "exspy": "exspy",
             "rosettasciio": "rsciio", "pyebsdindex": "pyebsdindex", "diffsims": "diffsims", "numpy": "numpy"}
    bad = []
    for dist, mod in names.items():
        want = pins.get(dist)
        have = getattr(importlib.import_module(mod), "__version__", "?")
        if want != have:
            bad.append(f"{dist}: lock {want}, running {have}")
    if bad:
        sys.exit("emit.py: the running stack is not tools/parity/sem/requirements.lock:\n  " + "\n  ".join(bad))


# ----------------------------------------------------------------------------------------------- EBSD readers (m1)


def _ebsd_reader_bundle(ctx, case: str, path: Path, label: str, extra_inputs: list[tuple[Path, str]] = ()) -> None:
    """What `kikuchipy.load` hands an app for one EBSD file: shapes, axes, detector geometry, the SEM metadata, the
    static background, the crystal map, the patterns (exact), and the pattern-browser values (per-pattern range and
    mean, the mean pattern)."""
    import kikuchipy as kp

    s = kp.load(str(path))
    b = Bundle(case, 1, "kikuchipy", "kikuchipy.load", ctx.out)
    b.input(path, label)
    for p, l in extra_inputs:
        b.input(p, l)
    data = np.asarray(s.data)
    nav_shape = list(data.shape[:-2])
    b.value("navigation_shape_rc", nav_shape)
    b.value("signal_shape_rc", list(data.shape[-2:]))
    b.value("dtype", data.dtype.name)
    b.value("navigation_axes", [{"name": a.name, "size": int(a.size), "scale": float(a.scale), "offset": float(a.offset),
                                 "units": str(a.units)} for a in s.axes_manager.navigation_axes])
    b.value("signal_axes", [{"name": a.name, "size": int(a.size), "scale": float(a.scale), "offset": float(a.offset),
                             "units": str(a.units)} for a in s.axes_manager.signal_axes])
    d = s.detector
    b.value("detector", {"shape_rc": list(d.shape), "px_size": float(d.px_size), "binning": float(d.binning),
                         "tilt": float(d.tilt), "sample_tilt": float(d.sample_tilt), "azimuthal": float(d.azimuthal),
                         "pc_shape": list(d.pc.shape), "pc_first": [float(x) for x in d.pc.reshape(-1, 3)[0]]})
    if d.pc.reshape(-1, 3).shape[0] > 1:
        b.array("pc", d.pc.reshape(-1, 3).astype(np.float64), **EXACT, note="per-pattern projection centres, Bruker convention")
    md = s.metadata.as_dictionary()
    b.value("sem_metadata", md.get("Acquisition_instrument", {}).get("SEM", {}))
    b.value("title", str(s.metadata.General.title))
    if s.static_background is not None:
        b.array("static_background", np.asarray(s.static_background), **EXACT)
    else:
        b.value("static_background", None)
    if s.xmap is not None:
        xm = s.xmap
        b.value("xmap", {"size": int(xm.size), "shape": list(xm.shape), "phases": {int(k): v.name for k, v in xm.phases},
                         "phase_id_first": int(xm.phase_id[0]), "scan_unit": str(xm.scan_unit),
                         "properties": sorted(xm.prop.keys())})
        eu = xm.rotations.to_euler().astype(np.float64)
        b.array("xmap_euler_head", eu[: min(16, eu.shape[0])], **F64, note="Bunge Euler angles in radians, first 16 points")
        b.fingerprint("xmap_euler", eu)
    else:
        b.value("xmap", None)
    b.fingerprint("patterns", data)
    flat = data.reshape(-1, *data.shape[-2:])
    b.array("first_pattern", flat[0], **EXACT)
    b.array("pattern_min", flat.min(axis=(1, 2)).reshape(nav_shape), **EXACT)
    b.array("pattern_max", flat.max(axis=(1, 2)).reshape(nav_shape), **EXACT)
    b.array("pattern_mean", flat.astype(np.float64).mean(axis=(1, 2)).reshape(nav_shape), **F64,
            note="the navigator's mean-intensity map")
    if flat.shape[0] > 1:
        b.array("last_pattern", flat[-1], **EXACT)
        b.array("mean_pattern", flat.astype(np.float64).mean(axis=0), **F64)
    b.write()
    ctx.done(case)


def case_m1_read_kikuchipy_h5ebsd(ctx):
    _ebsd_reader_bundle(ctx, "m1/read-kikuchipy-h5ebsd", FIXTURES / "kikuchipy_h5ebsd_patterns.h5", "fixtures/kikuchipy_h5ebsd_patterns.h5")


def case_m1_read_nordif(ctx):
    _ebsd_reader_bundle(ctx, "m1/read-nordif", FIXTURES / "nordif" / "Pattern.dat", "fixtures/nordif/Pattern.dat",
                        [(FIXTURES / "nordif" / "Setting.txt", "fixtures/nordif/Setting.txt")])


def case_m1_read_oxford_binary(ctx):
    _ebsd_reader_bundle(ctx, "m1/read-oxford-binary", FIXTURES / "oxford_binary_patterns.ebsp", "fixtures/oxford_binary_patterns.ebsp")


def case_m1_read_oxford_h5oina(ctx):
    _ebsd_reader_bundle(ctx, "m1/read-oxford-h5oina", FIXTURES / "oxford_h5oina_patterns.h5oina", "fixtures/oxford_h5oina_patterns.h5oina")


def case_m1_read_bruker_h5ebsd(ctx):
    _ebsd_reader_bundle(ctx, "m1/read-bruker-h5ebsd", FIXTURES / "bruker_h5ebsd_patterns.h5", "fixtures/bruker_h5ebsd_patterns.h5")


def case_m1_read_edax_up1(ctx):
    _ebsd_reader_bundle(ctx, "m1/read-edax-up1", FIXTURES / "edax_binary.up1", "fixtures/edax_binary.up1")


def case_m1_read_edax_up2(ctx):
    _ebsd_reader_bundle(ctx, "m1/read-edax-up2", FIXTURES / "edax_binary.up2", "fixtures/edax_binary.up2")


def case_m1_read_edax_h5ebsd(ctx):
    _ebsd_reader_bundle(ctx, "m1/read-edax-h5ebsd", FIXTURES / "edax_h5ebsd_patterns.h5", "fixtures/edax_h5ebsd_patterns.h5")


def case_m1_read_emsoft_ebsd(ctx):
    _ebsd_reader_bundle(ctx, "m1/read-emsoft-ebsd", FIXTURES / "emsoft_ebsd_EBSD_TEST_Ni.h5", "fixtures/emsoft_ebsd_EBSD_TEST_Ni.h5")


def case_m1_read_nickel_ebsd_large(ctx):
    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if not ctx.have(p, "m1/read-nickel-ebsd-large"):
        return
    _ebsd_reader_bundle(ctx, "m1/read-nickel-ebsd-large", p, "sem-data/nickel_ebsd_large/patterns_v2.h5")


# ------------------------------------------------------------------------------------- orientation maps (ang, ctf; m1)


def _crystal_map_bundle(ctx, case: str, path: Path, label: str) -> None:
    """What `orix.io.load` hands an app for a vendor orientation file (EDAX .ang, Oxford .ctf): the map's shape, steps,
    phases, properties, the Euler angles and the phase ids."""
    from orix import io

    xm = io.load(str(path))
    b = Bundle(case, 1, "orix", "orix.io.load", ctx.out)
    b.input(path, label)
    b.value("size", int(xm.size))
    b.value("shape", list(xm.shape))
    b.value("dx", float(xm.dx))
    b.value("dy", float(xm.dy))
    b.value("scan_unit", str(xm.scan_unit))
    b.value("phases", {int(k): {"name": v.name, "space_group": (v.space_group.number if v.space_group else None),
                                "point_group": (v.point_group.name if v.point_group else None),
                                "color": v.color} for k, v in xm.phases})
    b.value("properties", sorted(xm.prop.keys()))
    b.value("phase_counts", {int(k): int((xm.phase_id == k).sum()) for k, _ in xm.phases})
    eu = xm.rotations.to_euler().astype(np.float64)
    b.array("euler_head", eu[:16], **F64, note="Bunge Euler angles in radians, first 16 points")
    b.fingerprint("euler", eu)
    b.array("phase_id", xm.phase_id.astype(np.int32), **EXACT)
    b.array("x_head", np.asarray(xm.x, dtype=np.float64)[:16], **F64)
    b.array("y_head", np.asarray(xm.y, dtype=np.float64)[:16], **F64)
    for name in sorted(xm.prop.keys()):
        v = np.asarray(xm.prop[name], dtype=np.float64)
        b.array(f"prop_{name}_head", v[:16], **F64)
    b.write()
    ctx.done(case)


def case_m1_read_ang_sdss(ctx):
    p = ctx.data / "orix" / "sdss_ferrite_austenite.ang"
    if ctx.have(p, "m1/read-ang-sdss-ferrite-austenite"):
        _crystal_map_bundle(ctx, "m1/read-ang-sdss-ferrite-austenite", p, "sem-data/orix/sdss_ferrite_austenite.ang")


def case_m1_read_ctf_planted(ctx):
    _crystal_map_bundle(ctx, "m1/read-ctf-planted-oxford", FIXTURES / "planted_oxford.ctf", "fixtures/planted_oxford.ctf")


# ------------------------------------------------------------------------------------------ SEM images (TIFF; m1)


def _sem_tiff_bundle(ctx, case: str, path: Path, label: str) -> None:
    """What RosettaSciIO's TIFF reader hands an app for a vendor SEM image: pixels (exact), the calibrated axes, and the
    SEM metadata it parses from the vendor tag (Zeiss SmartSEM CZ_SEM, FEI/Thermo FEI_HELIOS)."""
    import hyperspy.api as hs

    # Through HyperSpy, not rsciio.tiff.file_reader alone: the vendor-tag parse (CZ_SEM, FEI_HELIOS) into
    # Acquisition_instrument.SEM happens on the HyperSpy load path (rsciio 0.15.0), and the app's Info shows that.
    s = hs.load(str(path))
    b = Bundle(case, 1, "rsciio", "hyperspy.api.load (rsciio.tiff)", ctx.out)
    b.input(path, label)
    data = np.asarray(s.data)
    b.value("shape", list(data.shape))
    b.value("dtype", data.dtype.name)
    b.value("axes", [{"name": a.name, "size": int(a.size), "scale": float(a.scale), "offset": float(a.offset),
                      "units": str(a.units)} for a in s.axes_manager.signal_axes])
    md = s.metadata.as_dictionary()
    sem = md.get("Acquisition_instrument", {}).get("SEM", {})
    if not sem:
        raise RuntimeError(f"{case}: no SEM metadata parsed from the vendor tag")
    b.value("sem_metadata", sem)
    gen = md.get("General", {})
    b.value("general", {k: gen[k] for k in ("authors", "date", "time", "original_filename") if k in gen})
    b.array("pixels", data, **EXACT)
    b.scalar("mean", data.astype(np.float64).mean(), **F64)
    b.write()
    ctx.done(case)


def case_m1_read_sem_tiff_zeiss(ctx):
    _sem_tiff_bundle(ctx, "m1/read-sem-tiff-zeiss", FIXTURES / "rsciio_Zeiss_SEM_512pix.tif", "fixtures/rsciio_Zeiss_SEM_512pix.tif")


def case_m1_read_sem_tiff_fei(ctx):
    _sem_tiff_bundle(ctx, "m1/read-sem-tiff-fei-helios", FIXTURES / "rsciio_FEI_Helios_Ebeam_8bits.tif", "fixtures/rsciio_FEI_Helios_Ebeam_8bits.tif")


# ------------------------------------------------------------------------------------ virtual BSE imaging (m1)

RGB_TILES = {"r": [2, 1], "g": [2, 2], "b": [2, 3]}
ROI_PX = {"left": 10, "top": 20, "right": 50, "bottom": 40}   # detector pixels, half-open [left, right) x [top, bottom)


def _vbse_bundle(ctx, case: str, path: Path, label: str, grid=(5, 5)) -> None:
    """kikuchipy's VirtualBSEImager on one scan: the detector grid, every grid tile's image (sum of the tile's
    intensities per pattern; integer sums, exact in float32), the RGB image from three tiles (each channel
    min-max normalised to uint8 before stacking, kikuchipy's default normalize=True), one explicit rectangular ROI,
    and the whole-detector mean per pattern."""
    import hyperspy.api as hs
    import kikuchipy as kp

    s = kp.load(str(path))
    v = kp.imaging.VirtualBSEImager(s)
    v.grid_shape = grid
    b = Bundle(case, 1, "kikuchipy", "kikuchipy.imaging.VirtualBSEImager", ctx.out)
    b.input(path, label)
    b.value("grid_shape", list(grid))
    b.value("grid_rows", [float(x) for x in v.grid_rows])
    b.value("grid_cols", [float(x) for x in v.grid_cols])
    b.value("tile_bounds", {f"{r},{c}": {"left": float(v.roi_from_grid((r, c)).left), "top": float(v.roi_from_grid((r, c)).top),
                                         "right": float(v.roi_from_grid((r, c)).right), "bottom": float(v.roi_from_grid((r, c)).bottom)}
                            for r in range(grid[0]) for c in range(grid[1])},
            )
    imgs = v.get_images_from_grid(dtype_out="float32")
    b.array("grid_images", np.asarray(imgs.data, dtype=np.float32), **EXACT,
            note="[grid_row, grid_col, scan_row, scan_col]: sum of the tile's pixels, HyperSpy ROI half-open on the right and bottom")
    rgb = v.get_rgb_image(r=tuple(RGB_TILES["r"]), g=tuple(RGB_TILES["g"]), b=tuple(RGB_TILES["b"]))
    rgb_arr = np.asarray(rgb.data)
    rgb_u8 = np.stack([rgb_arr["R"], rgb_arr["G"], rgb_arr["B"]], axis=-1).astype(np.uint8)
    b.value("rgb_tiles", RGB_TILES)
    b.array("rgb_image", rgb_u8, **U8, note="[scan_row, scan_col, channel]; each channel min-max rescaled to 0..255 then rounded")
    roi = hs.roi.RectangularROI(**ROI_PX)
    b.value("roi_px", ROI_PX)
    b.array("roi_image", np.asarray(s.get_virtual_bse_intensity(roi).data, dtype=np.float64), **EXACT)
    data = np.asarray(s.data)
    b.array("mean_intensity_map", data.astype(np.float64).mean(axis=(-2, -1)), **F64)
    b.write()
    ctx.done(case)


def case_m1_vbse_small(ctx):
    _vbse_bundle(ctx, "m1/vbse-kikuchipy-h5ebsd", FIXTURES / "kikuchipy_h5ebsd_patterns.h5", "fixtures/kikuchipy_h5ebsd_patterns.h5")


def case_m1_vbse_nickel_large(ctx):
    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if ctx.have(p, "m1/vbse-nickel-ebsd-large"):
        _vbse_bundle(ctx, "m1/vbse-nickel-ebsd-large", p, "sem-data/nickel_ebsd_large/patterns_v2.h5")


# ---------------------------------------------------------------------------------- pattern processing (m2, preview)


def _background_bundle(ctx, case: str, path: Path, label: str) -> None:
    """kikuchipy's static and dynamic background removal with its defaults (operation="subtract", the file's static
    background; dynamic: Gaussian std = pattern width / 8, truncate 4.0, in the frequency domain), each rescaled to
    uint8 as kikuchipy does. The numbers behind north-star figure 1's right half."""
    import kikuchipy as kp

    s = kp.load(str(path))
    b = Bundle(case, 2, "kikuchipy", "kikuchipy.signals.EBSD.remove_static_background / remove_dynamic_background", ctx.out)
    b.input(path, label)
    b.value("static_kwargs", {"operation": "subtract", "static_bg": "from file", "scale_bg": False})
    b.value("dynamic_kwargs", {"operation": "subtract", "filter_domain": "frequency", "std": None, "truncate": 4.0})
    s1 = s.deepcopy()
    s1.remove_static_background(operation="subtract")
    s2 = s1.deepcopy()
    s2.remove_dynamic_background(operation="subtract", filter_domain="frequency", truncate=4.0)
    a1, a2 = np.asarray(s1.data), np.asarray(s2.data)
    if a1.size <= 1 << 16:
        b.array("after_static", a1, **U8)
        b.array("after_static_and_dynamic", a2, **U8)
    else:
        # A whole scan is megabytes: the fingerprint for the exact claim, the first pattern and a 3 x 3 corner as files.
        b.fingerprint("after_static", a1)
        b.fingerprint("after_static_and_dynamic", a2)
        b.array("after_static_corner", a1[:3, :3], **U8, note="scan rows 0..2, cols 0..2")
        b.array("after_static_and_dynamic_corner", a2[:3, :3], **U8, note="scan rows 0..2, cols 0..2")
    b.array("after_static_first", a1.reshape(-1, *a1.shape[-2:])[0], **U8)
    b.array("after_static_and_dynamic_first", a2.reshape(-1, *a2.shape[-2:])[0], **U8)
    b.write()
    ctx.done(case)


def case_m2_background_small(ctx):
    _background_bundle(ctx, "m2/background-kikuchipy-h5ebsd", FIXTURES / "kikuchipy_h5ebsd_patterns.h5", "fixtures/kikuchipy_h5ebsd_patterns.h5")


def case_m2_background_nickel_large(ctx):
    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if ctx.have(p, "m2/background-nickel-ebsd-large"):
        _background_bundle(ctx, "m2/background-nickel-ebsd-large", p, "sem-data/nickel_ebsd_large/patterns_v2.h5")


# ------------------------------------------------------------------------------------------- orientation maths (m3)
# orix 0.15.0's quaternion package: the conversions of Rowenhorst et al. (2015), the point groups built from orix's
# generator lists, the orientation regions (fundamental zones) and the symmetry-reduced orientation and misorientation
# angles. Every input is in fixtures/orientation_inputs.json (make_fixtures.py: seeded rotations, the point-group names,
# the Ti head of orix-data). Angles and components within atol 1e-7 (the brief's bound; orix's own tests use numpy's
# allclose defaults); symmetry elements and region normals within 1e-10 (products of exact generators).

ORI = {"rtol": 0.0, "atol": 1e-7}
SYM = {"rtol": 0.0, "atol": 1e-10}
ORIENTATION_INPUTS = FIXTURES / "orientation_inputs.json"


def _orientation_inputs() -> dict:
    import json

    return json.loads(ORIENTATION_INPUTS.read_text(encoding="utf-8"))


def _with_inf_note(name: str) -> str:
    return f"{name}: rows at 180 degrees hold +inf (ax2ro), compared as equal infinities"


def case_m3_rotation_conversions(ctx):
    """Every conversion of orix.quaternion._conversions through the public Rotation API, composition, inverse, angles,
    vector rotation (proper and improper), outer products and unique."""
    from orix.quaternion import Rotation, _conversions as cv
    from orix.vector import Vector3d

    inp = _orientation_inputs()
    qu = np.asarray(inp["quaternions"], dtype=np.float64)
    b = Bundle("m3/rotation-conversions", 3, "orix", "orix.quaternion.Rotation (to_/from_ conversions, *, ~, angle_with, outer, unique)", ctx.out)
    b.input(ORIENTATION_INPUTS, "fixtures/orientation_inputs.json")
    b.value("rows", int(qu.shape[0]))
    b.value("special_rows", inp["special_rows"])
    b.array("qu", qu, **EXACT)
    R = Rotation(qu)
    b.array("qu2eu", R.to_euler(), **ORI)
    b.array("qu2om", R.to_matrix(), **ORI)
    ax = np.concatenate(cv.qu2ax(R.data), axis=-1)
    b.array("qu2ax", ax, **ORI)
    b.array("axangle", R.to_axes_angles().data, **ORI)
    b.array("qu2ho", R.to_homochoric().data, **ORI)
    b.array("angle", R.angle, **ORI)
    b.array("axis", R.axis.data, **ORI)
    finite = np.abs(R.angle - np.pi) > 1e-3
    b.value("rodrigues_rows", [int(i) for i in np.flatnonzero(finite)])
    b.array("ro", R[finite].to_rodrigues().data, rtol=1e-7, atol=1e-7)
    b.array("ro_frank", R.to_rodrigues(frank=True), rtol=1e-7, atol=1e-7, note=_with_inf_note("ro_frank"))
    b.array("om2qu", Rotation.from_matrix(R.to_matrix()).data, **ORI)
    b.array("ho2ax", cv.ho2ax(R.to_homochoric().data), **ORI)
    b.array("ho2qu", Rotation.from_homochoric(R.to_homochoric().data).data, **ORI)
    b.array("ro2qu", Rotation.from_rodrigues(R[finite].to_rodrigues().data).data, **ORI)
    b.array("ax2qu", Rotation.from_axes_angles(ax[:, :3], ax[:, 3]).data, **ORI)
    eu = np.asarray(inp["euler_radians"], dtype=np.float64)
    b.array("eu", eu, **EXACT)
    b.array("eu2qu", Rotation.from_euler(eu).data, **ORI)
    b.array("eu2qu_crystal2lab", Rotation.from_euler(eu, direction="crystal2lab").data, **ORI)
    b.array("eu_roundtrip", Rotation.from_euler(eu).to_euler(), **ORI)
    cu = np.asarray(inp["cubochoric"], dtype=np.float64)
    b.array("cu", cu, **EXACT)
    b.array("cu_pyramid", cv.get_pyramid(cu).astype(np.int64), **EXACT)
    b.array("cu2ho", cv.cu2ho(cu), **ORI)
    b.array("cu2ro", cv.cu2ro(cu), rtol=1e-7, atol=1e-7, note=_with_inf_note("cu2ro"))
    R1, R2 = Rotation(qu[:32]), Rotation(qu[32:])
    b.array("product", (R1 * R2).data, **ORI)
    b.array("inverse", (~R).data, **ORI)
    b.array("angle_with", R1.angle_with(R2), **ORI)
    v = np.asarray(inp["vectors"], dtype=np.float64)
    b.array("vectors", v, **EXACT)
    b.array("rotated", (R * Vector3d(v)).data, **ORI)
    Ri = Rotation(qu)
    improper = np.arange(qu.shape[0]) % int(inp["improper_every"]) == 0
    Ri.improper = improper
    b.array("improper_mask", improper.astype(np.uint8), **EXACT)
    b.array("rotated_improper", (Ri * Vector3d(v)).data, **ORI)
    b.array("product_improper", (Ri[:32] * Ri[32:]).improper.astype(np.uint8), **EXACT)
    b.array("outer", R[:4].outer(R[4:7]).data, **ORI)
    b.array("outer_vectors", R[:4].outer(Vector3d(v[:5])).data, **ORI)
    b.array("dot_outer", Rotation(qu[:8]).dot_outer(Rotation(qu[8:16])), **ORI)
    b.array("angle_with_outer", Rotation(qu[:8]).angle_with_outer(Rotation(qu[8:16])), **ORI)
    dup = Rotation(np.concatenate([qu[:10], -qu[3:6], qu[:2]]))
    _, idx, inv = dup.unique(return_index=True, return_inverse=True)
    b.array("unique_input", dup.data, **EXACT)
    b.array("unique_index", idx.astype(np.int64), **EXACT)
    b.array("unique_inverse", inv.astype(np.int64), **EXACT)
    b.write()
    ctx.done("m3/rotation-conversions")


def _point_groups(names: list[str]):
    from orix.quaternion import symmetry as S

    table = {g.name: g for g in list(S._groups) + [S.C2, S.Cs]}
    return [table[n] for n in names]


def case_m3_point_groups(ctx):
    """The 38 point-group objects orix defines (32 point groups, the axis variants 211/121/112, m11/1m1/11m and 321/312)
    and the aliases 2, m, 32: elements in orix's order, improper flags, proper subgroup, Laue group, its proper subgroup,
    inversion, crystal system, Euler fundamental region, subgroups, the fundamental sector normals (inverse pole figure)
    and the fundamental zone normals."""
    names = _orientation_inputs()["point_groups"]
    groups = _point_groups(names)
    b = Bundle("m3/point-groups", 3, "orix", "orix.quaternion.symmetry (Symmetry.from_generators and the group table)", ctx.out)
    b.input(ORIENTATION_INPUTS, "fixtures/orientation_inputs.json")
    b.value("names", [g.name for g in groups])
    rows = []
    for i, g in enumerate(groups):
        b.array(f"elements_{i:02d}", g.data, **SYM)
        b.array(f"improper_{i:02d}", g.improper.astype(np.uint8), **EXACT)
        fs = g.fundamental_sector
        b.array(f"sector_{i:02d}", fs.data.reshape(-1, 3), **SYM)
        b.array(f"zone_{i:02d}", g.fundamental_zone().data.reshape(-1, 3), **SYM)
        rows.append({
            "name": g.name,
            "order": int(g.order),
            "is_proper": bool(g.is_proper),
            "contains_inversion": bool(g.contains_inversion),
            "proper_subgroup": g.proper_subgroup.name,
            "laue": g.laue.name,
            "laue_order": int(g.laue.order),
            "laue_proper_subgroup": g.laue_proper_subgroup.name,
            "system": g.system,
            "euler_fundamental_region": list(g.euler_fundamental_region),
            "subgroups": [h.name for h in g.subgroups],
            "sector_center": None if fs._center is None else [float(x) for x in fs._center.data.ravel()],
        })
    b.value("groups", rows)
    b.write()
    ctx.done("m3/point-groups")


def case_m3_orientation_regions(ctx):
    """OrientationRegion.from_symmetry: the orientation fundamental zone of each point group (one symmetry) and the
    misorientation zone of each pair (G, G), as the unit-quaternion normals of its bounding planes, in orix's order."""
    from orix.quaternion.orientation_region import OrientationRegion

    names = _orientation_inputs()["point_groups"]
    groups = _point_groups(names)
    b = Bundle("m3/orientation-regions", 3, "orix", "orix.quaternion.OrientationRegion.from_symmetry", ctx.out)
    b.input(ORIENTATION_INPUTS, "fixtures/orientation_inputs.json")
    b.value("names", [g.name for g in groups])
    pair_ok = []
    for i, g in enumerate(groups):
        b.array(f"orientation_{i:02d}", OrientationRegion.from_symmetry(g).data.reshape(-1, 4), **SYM)
        try:
            region = OrientationRegion.from_symmetry(g, g)
        except NotImplementedError:
            pair_ok.append(False)
            continue
        pair_ok.append(True)
        b.array(f"misorientation_{i:02d}", region.data.reshape(-1, 4), **SYM)
    b.value("misorientation_defined", pair_ok)
    b.write()
    ctx.done("m3/orientation-regions")


def case_m3_ti_disorientations(ctx):
    """The Ti orientations (orix-data Ti_orientations.ctf, first 2000 rows, point group 622) and a seeded m-3m set (the
    Ni symmetry): orientations reduced into the fundamental zone, neighbour angles with symmetry, disorientation angles
    of neighbours (Orientation subtraction, the reduced misorientation), the orientation distance matrix and the
    misorientation distance matrix."""
    from orix.quaternion import Orientation
    from orix.quaternion.symmetry import D6, Oh

    inp = _orientation_inputs()
    assert inp["ti_point_group"] == D6.name and inp["cubic_point_group"] == Oh.name
    eu = np.asarray(inp["ti_euler_degrees"], dtype=np.float64)
    b = Bundle("m3/ti-disorientations", 3, "orix", "orix.quaternion.Orientation / Misorientation (reduce, angle_with, -, get_distance_matrix)", ctx.out)
    b.input(ORIENTATION_INPUTS, "fixtures/orientation_inputs.json")
    b.value("point_group", D6.name)
    b.array("euler_degrees", eu, **EXACT)
    O = Orientation.from_euler(eu, symmetry=D6, degrees=True)
    b.array("quaternions", O.data, **ORI)
    b.array("reduced", O.reduce().data, **ORI)
    b.array("angle_with_next", O[1:].angle_with(O[:-1]), **ORI)
    M = O[1:] - O[:-1]
    b.array("disorientation_next", M.angle, **ORI)
    b.array("misorientation_next", M.data, **ORI)
    b.array("distance_matrix_150", O[:150].get_distance_matrix(), **ORI)
    b.array("misorientation_distance_matrix_40", M[:40].get_distance_matrix(lazy=False), **ORI)

    C = Orientation(np.asarray(inp["cubic_quaternions"], dtype=np.float64), symmetry=Oh)
    b.value("cubic_point_group", Oh.name)
    b.array("cubic_quaternions", C.data, **EXACT)
    b.array("cubic_reduced", C.reduce().data, **ORI)
    Mc = C[1:] - C[:-1]
    b.array("cubic_disorientation_next", Mc.angle, **ORI)
    b.array("cubic_misorientation_next", Mc.data, **ORI)
    b.array("cubic_distance_matrix", C.get_distance_matrix(), **ORI)
    b.array("cubic_misorientation_distance_matrix_30", Mc[:30].get_distance_matrix(lazy=False), **ORI)
    b.write()
    ctx.done("m3/ti-disorientations")

# Pattern quality maps (m2, figure F3): float32 in kikuchipy, float64 in the port; rtol 1e-5 is the float32 bound the brief
# states (measured: the float64 port is within 1e-7 of kikuchipy for IQ and 6e-7 for ADP on the same patterns).
F32Q = {"rtol": 1e-5, "atol": 0.0}


def _quality_maps(s, prefix: str, b, note: str = "") -> None:
    """kikuchipy's image quality (Krieger Lassen 1994, normalize=True) and average neighbour dot product map (default
    window: 3 x 3 circular, the four nearest neighbours; zero_mean and normalize True) of signal `s`."""
    b.array(f"{prefix}iq", np.asarray(s.get_image_quality(show_progressbar=False), dtype=np.float32), **F32Q, note=note or None)
    b.array(f"{prefix}adp", np.asarray(s.get_average_neighbour_dot_product_map(show_progressbar=False), dtype=np.float32),
            **F32Q, note=note or None)


def _corrected(s):
    """kikuchipy's docs chain: static background (from the file) then dynamic background, both subtracted, uint8."""
    c = s.deepcopy()
    c.remove_static_background(operation="subtract")
    c.remove_dynamic_background(operation="subtract", filter_domain="frequency", truncate=4.0)
    return c


def case_m2_quality_small(ctx):
    """Every option of both maps on the 3 x 3 nickel fixture: corrected patterns as the input array (so the port is fed
    exactly kikuchipy's uint8 patterns), IQ with and without normalisation, ADP under the default, a rectangular 3 x 3,
    a circular 5 x 5 and a 1 x 3 window, without zero mean and without normalisation; the raw patterns' maps too."""
    import kikuchipy as kp
    from kikuchipy.filters import Window

    path = FIXTURES / "kikuchipy_h5ebsd_patterns.h5"
    s = kp.load(str(path))
    b = Bundle("m2/quality-kikuchipy-h5ebsd", 2, "kikuchipy",
               "kikuchipy.signals.EBSD.get_image_quality / get_average_neighbour_dot_product_map", ctx.out)
    b.input(path, "fixtures/kikuchipy_h5ebsd_patterns.h5")
    sy, sx = s.axes_manager.signal_shape[::-1]
    b.array("frequency_vectors", kp.pattern.fft_frequency_vectors((sy, sx)).astype(np.float64), **EXACT)
    _quality_maps(s, "raw_", b)
    c = _corrected(s)
    b.array("corrected_patterns", np.asarray(c.data), **EXACT, note="static then dynamic background, kikuchipy's uint8")
    _quality_maps(c, "", b)
    b.array("iq_unnormalized", np.asarray(c.get_image_quality(normalize=False, show_progressbar=False), dtype=np.float32), **F32Q)
    windows = {"rect3": Window("rectangular", shape=(3, 3)), "circ5": Window("circular", shape=(5, 5)),
               "rect1x3": Window("rectangular", shape=(1, 3))}
    b.value("windows", {k: np.asarray(w).astype(int).tolist() for k, w in windows.items()})
    for k, w in windows.items():
        b.array(f"adp_{k}", np.asarray(c.get_average_neighbour_dot_product_map(window=w, show_progressbar=False), dtype=np.float32), **F32Q)
    b.array("adp_no_zero_mean", np.asarray(c.get_average_neighbour_dot_product_map(zero_mean=False, show_progressbar=False), dtype=np.float32), **F32Q)
    b.array("adp_no_normalize", np.asarray(c.get_average_neighbour_dot_product_map(normalize=False, show_progressbar=False), dtype=np.float32), **F32Q)
    b.write()
    ctx.done("m2/quality-kikuchipy-h5ebsd")


QUALITY_BLOCK = (slice(20, 26), slice(30, 36))


def case_m2_quality_nickel_large(ctx):
    """North-star figure F3: the IQ and ADP maps of nickel_ebsd_large after kikuchipy's static and dynamic background
    (its docs' chain), whole map. The raw patterns' maps (input = the shipped file, exact through the reader) and a 6 x 6
    block of corrected patterns with the block's own maps let the port be checked on kikuchipy's exact input."""
    import kikuchipy as kp

    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if not ctx.have(p, "m2/quality-nickel-ebsd-large"):
        return
    s = kp.load(str(p))
    b = Bundle("m2/quality-nickel-ebsd-large", 2, "kikuchipy",
               "kikuchipy.signals.EBSD.get_image_quality / get_average_neighbour_dot_product_map", ctx.out)
    b.input(p, "sem-data/nickel_ebsd_large/patterns_v2.h5")
    _quality_maps(s, "raw_", b, "raw patterns, no background removed")
    c = _corrected(s)
    _quality_maps(c, "", b, "figure F3: after static and dynamic background")
    r, k = QUALITY_BLOCK
    b.value("block", {"rows": [r.start, r.stop], "cols": [k.start, k.stop]})
    blk = c.inav[k, r]
    b.array("block_corrected_patterns", np.asarray(blk.data), **EXACT, note="scan rows 20..25, cols 30..35, kikuchipy's uint8")
    _quality_maps(blk, "block_", b, "the 6 x 6 block as its own signal (edges at the block border)")
    b.write()
    ctx.done("m2/quality-nickel-ebsd-large")


# --------------------------------------------------------------------------------------------- SEM-EDS (m1 read, m7)


def case_m1_read_eds_msa(ctx):
    """The TM002 spectrum as an EMSA/MSA file (fixtures/exspy_EDS_SEM_TM002.msa, written by HyperSpy from exspy's
    bundled copy): what RosettaSciIO's MSA reader hands an app."""
    from rsciio.msa import file_reader

    p = FIXTURES / "exspy_EDS_SEM_TM002.msa"
    d = file_reader(str(p))[0]
    b = Bundle("m1/read-eds-msa-tm002", 1, "rsciio", "rsciio.msa.file_reader", ctx.out)
    b.input(p, "fixtures/exspy_EDS_SEM_TM002.msa")
    data = np.asarray(d["data"])
    b.value("dtype", data.dtype.name)
    b.value("axes", [{"name": a["name"], "size": int(a["size"]), "scale": float(a["scale"]), "offset": float(a["offset"]),
                      "units": str(a["units"])} for a in d["axes"]])
    md = d["metadata"]
    b.value("sem_metadata", md.get("Acquisition_instrument", {}).get("SEM", {}))
    b.value("signal_type", md.get("Signal", {}).get("signal_type"))
    om = d["original_metadata"]
    b.value("original_metadata", {k: om[k] for k in sorted(om) if isinstance(om[k], (str, int, float))})
    b.array("counts", data.astype(np.float64), **EXACT)
    b.scalar("total_counts", data.astype(np.float64).sum(), **EXACT)
    b.write()
    ctx.done("m1/read-eds-msa-tm002")


def case_m7_eds_lines_tm002(ctx):
    """exspy on the TM002 spectrum: the X-ray lines its Sample.elements select, the default line windows, the
    estimated background windows (line_width [5, 2]) and the line intensities with and without background
    subtraction, as the EDS tutorial draws them."""
    import exspy

    p = FIXTURES / "exspy_EDS_SEM_TM002.hspy"
    s = exspy.data.EDS_SEM_TM002() if not p.exists() else __import__("hyperspy.api").api.load(str(p), reader="hspy")
    s.set_signal_type("EDS_SEM")
    b = Bundle("m7/eds-lines-tm002", 7, "exspy", "exspy.signals.EDSSEMSpectrum.get_lines_intensity", ctx.out)
    b.input(p, "fixtures/exspy_EDS_SEM_TM002.hspy")
    elements = list(s.metadata.Sample.elements)
    s.add_lines()
    lines = list(s.metadata.Sample.xray_lines)
    b.value("elements", elements)
    b.value("xray_lines", lines)
    b.value("beam_energy_keV", float(s.metadata.Acquisition_instrument.SEM.beam_energy))
    from exspy._misc.elements import elements as elements_db

    b.value("line_energies_keV", {ln: float(elements_db[ln.split("_")[0]]["Atomic_properties"]["Xray_lines"][ln.split("_")[1]]["energy (keV)"]) for ln in lines})
    bw = s.estimate_background_windows(line_width=[5.0, 2.0])
    iw = s.estimate_integration_windows(windows_width=2.0)
    b.value("background_line_width", [5.0, 2.0])
    b.value("integration_windows_width", 2.0)
    b.array("background_windows_keV", np.asarray(bw, dtype=np.float64), **F64)
    b.array("integration_windows_keV", np.asarray(iw, dtype=np.float64), **F64)
    raw = s.get_lines_intensity(xray_lines=lines, integration_windows=iw)
    sub = s.get_lines_intensity(xray_lines=lines, integration_windows=iw, background_windows=bw)
    b.array("intensity_raw", np.asarray([float(np.asarray(i.data).ravel()[0]) for i in raw], dtype=np.float64), **F64)
    b.array("intensity_background_subtracted", np.asarray([float(np.asarray(i.data).ravel()[0]) for i in sub], dtype=np.float64), **F64)
    b.write()
    ctx.done("m7/eds-lines-tm002")


# --------------------------------------------------------------------------------------------------------- driver


class Context:
    def __init__(self, out: Path, data: Path, require_data: bool):
        self.out, self.data, self.require_data = out, data, require_data
        self.written: list[str] = []
        self.skipped: list[str] = []

    def have(self, path: Path, case: str) -> bool:
        if path.exists():
            return True
        if self.require_data:
            sys.exit(f"emit.py: {case} needs {path} (run tools/parity/sem/fetch-data.sh)")
        print(f"  skip  {case}: {path.name} not fetched (fetch-data.sh)")
        self.skipped.append(case)
        return False

    def done(self, case: str) -> None:
        print(f"  wrote {case}")
        self.written.append(case)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True, type=Path, help="bundle root (references/ to regenerate the committed ones)")
    ap.add_argument("--data", type=Path, default=HERE.parent.parent.parent / "References" / "sem-data")
    ap.add_argument("--only", default="", help="case-name prefix filter, e.g. m1/read-")
    ap.add_argument("--require-data", action="store_true", help="fail instead of skipping a case whose dataset is absent")
    args = ap.parse_args(argv)
    assert_pins()
    ctx = Context(args.out.resolve(), args.data.resolve(), args.require_data)
    cases = [(n, f) for n, f in sorted(globals().items()) if n.startswith("case_") and callable(f)]
    for name, fn in cases:
        label = name[len("case_"):].replace("_", "-")
        if args.only and not label.startswith(args.only.replace("/", "-")):
            continue
        fn(ctx)
    print(f"emit.py: {len(ctx.written)} bundles written to {ctx.out}" + (f", {len(ctx.skipped)} skipped" if ctx.skipped else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
