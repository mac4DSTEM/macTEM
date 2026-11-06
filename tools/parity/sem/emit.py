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
processing (static and dynamic background, emitted now so phase-2 ports can start from a committed reference), m7
SEM-EDS line intensities on the TM002 spectrum (the numbers behind the EDS figure), m6 master patterns (EMsoft EBSD, TKD
and ECP master pattern files read, the Ni 20 kV pattern projected onto a detector: figure F15).

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


# ------------------------------------------------------------------------------- master patterns and projection (m6)

# Allclose's defaults (kikuchipy's tests compare simulated patterns with `np.allclose`): the float32 patterns.
ALLCLOSE = {"rtol": 1e-5, "atol": 1e-8}
NI_MP = FIXTURES / "emsoft_ebsd_master_pattern_ni_mc_mp_20kv_uint8_gzip_opts9.h5"
DUMMY_MP = FIXTURES / "emsoft_ebsd_master_pattern_dummy.h5"


def _master_pattern_read(path: Path, plugin: str, **kw) -> dict:
    """One reading through the plugin's `file_reader` (what `kikuchipy.load` calls), reduced to what an app keeps."""
    import importlib

    reader = importlib.import_module(f"kikuchipy.io.plugins.{plugin}._api").file_reader
    d = reader(str(path), **kw)[0]
    data = np.asarray(d["data"])
    phase = d["phase"]
    return {
        "data": data,
        "values": {
            "kwargs": {k: (list(v) if isinstance(v, (tuple, range)) else v) for k, v in kw.items()},
            "shape": list(data.shape), "dtype": data.dtype.name,
            "axes": [{"name": a["name"], "size": int(a["size"]), "scale": float(a["scale"]), "offset": float(a["offset"]),
                      "units": a["units"]} for a in d["axes"]],
            "projection": d["projection"], "hemisphere": d["hemisphere"],
            "signal_type": d["metadata"]["Signal"]["signal_type"],
            "phase": {"name": phase.name, "space_group": int(phase.space_group.number),
                      "point_group": phase.point_group.name, "inversion": bool(phase.point_group.contains_inversion),
                      "lattice": [float(x) for x in (phase.structure.lattice.a, phase.structure.lattice.b,
                                                     phase.structure.lattice.c, phase.structure.lattice.alpha,
                                                     phase.structure.lattice.beta, phase.structure.lattice.gamma)],
                      "atoms": len(phase.structure)},
        },
    }


def case_m6_read_master_pattern_ni(ctx):
    """kikuchipy's in-package Ni 20 kV EBSD master pattern (`nickel_ebsd_master_pattern_small`: EMsoft's 401 x 401
    Lambert and stereographic projections of both hemispheres, reduced to uint8 with gzip by kikuchipy's own script), read
    in every projection and hemisphere. Exact: the bytes as kikuchipy hands them (stereographic flipped up-down)."""
    case = "m6/read-master-pattern-ni"
    b = Bundle(case, 6, "kikuchipy", "kikuchipy.io.plugins.emsoft_ebsd_master_pattern.file_reader", ctx.out)
    b.input(NI_MP, "fixtures/" + NI_MP.name)
    readings = {}
    for projection in ("lambert", "stereographic"):
        for hemisphere in ("upper", "lower", "both"):
            r = _master_pattern_read(NI_MP, "emsoft_ebsd_master_pattern", projection=projection, hemisphere=hemisphere)
            key = f"{projection}_{hemisphere}"
            readings[key] = r["values"]
            b.fingerprint(f"data_{key}", r["data"])
            if hemisphere == "both":
                d = r["data"]
                b.array(f"rows_{key}", np.ascontiguousarray(d[:, ::50, :]), **EXACT,
                        note="every 50th row of both hemispheres (rows 0, 50, ..., 400)")
                b.array(f"sum_{key}", d.reshape(2, -1).astype(np.uint64).sum(axis=1).astype(np.int64), **EXACT)
    b.value("readings", readings)
    b.value("point_groups", {str(n): _point_group(n) for n in range(1, 231)})
    b.write()
    ctx.done(case)


def _point_group(number: int) -> dict:
    from orix.quaternion.symmetry import get_point_group

    pg = get_point_group(number, proper=False)
    return {"name": pg.name, "inversion": bool(pg.contains_inversion)}


def _multi_energy_bundle(ctx, case: str, path: Path, plugin: str, function: str, label: str,
                         lambert_energy_pick: bool = True) -> None:
    """A float32 master pattern file of 11 energies (10 to 20 kV) in 13 x 13 px: every energy, one energy by nearest
    match, an energy range, in each projection and hemisphere; the values are small enough to commit whole.
    `lambert_energy_pick=False` leaves out the Lambert readings of one energy or a range (ECP: kikuchipy 0.13.1 applies
    the energy slice to the first axis of the (numset, energy, y, x) Lambert dataset, which is the numset axis, and
    returns an empty array; docs/parity.md)."""
    b = Bundle(case, 6, "kikuchipy", function, ctx.out)
    b.input(path, label)
    readings = {}
    selections = {"all": {}, "nearest_15_4": {"energy": 15.4}, "range_12_16": {"energy": (12, 16)},
                  "nearest_25": {"energy": 25}}
    for projection in ("lambert", "stereographic"):
        for hemisphere in ("upper", "lower", "both"):
            for sel, kw in selections.items():
                if not lambert_energy_pick and projection == "lambert" and sel != "all":
                    continue
                r = _master_pattern_read(path, plugin, projection=projection, hemisphere=hemisphere, **kw)
                key = f"{projection}_{hemisphere}_{sel}"
                readings[key] = r["values"]
                b.array(f"data_{key}", r["data"].astype(np.float32), **EXACT)
    b.value("readings", readings)
    b.write()
    ctx.done(case)


def case_m6_read_master_pattern_dummy(ctx):
    _multi_energy_bundle(ctx, "m6/read-master-pattern-dummy", DUMMY_MP, "emsoft_ebsd_master_pattern",
                         "kikuchipy.io.plugins.emsoft_ebsd_master_pattern.file_reader", "fixtures/" + DUMMY_MP.name)


def case_m6_read_master_pattern_tkd(ctx):
    p = FIXTURES / "planted_emsoft_tkd_master_pattern.h5"
    _multi_energy_bundle(ctx, "m6/read-master-pattern-tkd", p, "emsoft_tkd_master_pattern",
                         "kikuchipy.io.plugins.emsoft_tkd_master_pattern.file_reader", "fixtures/" + p.name)


def case_m6_read_master_pattern_ecp(ctx):
    p = FIXTURES / "planted_emsoft_ecp_master_pattern.h5"
    _multi_energy_bundle(ctx, "m6/read-master-pattern-ecp", p, "emsoft_ecp_master_pattern",
                         "kikuchipy.io.plugins.emsoft_ecp_master_pattern.file_reader", "fixtures/" + p.name,
                         lambert_energy_pick=False)


def _projection_bundle(ctx, case: str, mp_path: Path, mp_label: str, detector: dict, euler_deg, dtypes, energies=(None,),
                       note: str = "") -> None:
    """`EBSDMasterPattern.get_patterns` for Bunge Euler angles (degrees, through orix's `Rotation.from_euler`, the
    quaternions are in the bundle so the port starts from the same rotation) onto a detector: the detector's direction
    cosines, its sample-to-detector matrix and gnomonic bounds, and the patterns in each output dtype."""
    import kikuchipy as kp
    from kikuchipy.signals.util._master_pattern import _get_direction_cosines_from_detector
    from orix.quaternion import Rotation

    mp = kp.load(str(mp_path), projection="lambert", hemisphere="both")
    det = kp.detectors.EBSDDetector(**detector)
    rot = Rotation.from_euler(np.deg2rad(np.asarray(euler_deg, dtype=np.float64)))
    b = Bundle(case, 6, "kikuchipy", "kikuchipy.signals.EBSDMasterPattern.get_patterns", ctx.out)
    b.input(mp_path, mp_label)
    if note:
        b.value("note", note)
    b.value("detector", {k: (np.asarray(v).tolist() if not isinstance(v, (int, float)) else v) for k, v in detector.items()})
    b.value("master_pattern_shape", list(mp.data.shape))
    b.array("euler_deg", np.asarray(euler_deg, dtype=np.float64), **EXACT)
    b.array("quaternions", rot.data.reshape(-1, 4).astype(np.float64), **EXACT, note="orix (a, b, c, d) of the Euler angles")
    # orix builds the matrix through a quaternion, so an exact zero comes back as ~1e-17: atol at float64 rounding.
    b.array("sample_to_detector", det.sample_to_detector.to_matrix().squeeze().astype(np.float64), rtol=1e-7, atol=1e-12)
    b.array("gnomonic_bounds", det.gnomonic_bounds.reshape(-1, 4).astype(np.float64), **F64)
    dc = _get_direction_cosines_from_detector(det)
    b.array("direction_cosines", np.asarray(dc, dtype=np.float64).reshape(-1, 3), **F64,
            note="(n PCs x) rows x columns x 3, row-major")
    b.value("dtypes", list(dtypes))
    b.value("energies", [e for e in energies])
    for energy in energies:
        for dt in dtypes:
            sim = mp.get_patterns(rot, det, energy=energy, dtype_out=dt, compute=True, show_progressbar=False)
            data = np.asarray(sim.data).reshape(-1, *det.shape)
            tol = ALLCLOSE if np.dtype(dt).kind == "f" else U8
            name = f"patterns_{dt}" + ("" if energy is None else f"_e{str(energy).replace('.', '_')}")
            b.array(name, data, **tol)
    b.write()
    ctx.done(case)


def case_m6_project_master_pattern_docs(ctx):
    """The docs example of `EBSDMasterPattern.get_patterns` (kikuchipy 0.13.1): four identity rotations onto a 60 x 60
    detector with PCs (0.4, 0.5, 0.4), (0.6, 0.5, 0.4), (0.4, 0.5, 0.6), (0.6, 0.5, 0.6), one per rotation."""
    pc = [[[0.4, 0.5, 0.4], [0.6, 0.5, 0.4]], [[0.4, 0.5, 0.6], [0.6, 0.5, 0.6]]]
    _projection_bundle(ctx, "m6/project-master-pattern-docs", NI_MP, "fixtures/" + NI_MP.name,
                       {"shape": (60, 60), "pc": np.asarray(pc)}, [[[0.0, 0.0, 0.0]] * 2] * 2, ("float32", "uint8"),
                       note="figure F15, left: the docstring example")


def case_m6_project_master_pattern_ni(ctx):
    """Figure F15, right: the Ni 20 kV master pattern projected onto the north-star detector (nickel_ebsd_large: 60 x 60,
    sample tilt 70 deg, the scan's mean PC in the Bruker convention) for three orientations of the scan's Ni."""
    _projection_bundle(ctx, "m6/project-master-pattern-ni", NI_MP, "fixtures/" + NI_MP.name,
                       {"shape": (60, 60), "pc": [0.4214, 0.2142, 0.5013], "sample_tilt": 70.0, "binning": 8},
                       [[0.0, 0.0, 0.0], [120.0, 45.0, 60.0], [263.7, 32.1, 151.4]], ("float32", "uint8", "float64"),
                       note="figure F15, right")


def case_m6_project_master_pattern_tilted(ctx):
    """Every angle of the detector at once (sample tilt 68, tilt 10, azimuthal 2.5, twist 1.2 deg) on a non-square
    48 x 64 detector, one PC per rotation, and the multi-energy float32 master pattern at its highest energy (None) and
    at 12.4 kV (rounded to the 12 kV pattern): the energy pick and the varying-PC path."""
    pc = [[0.52, 0.31, 0.61], [0.47, 0.28, 0.55], [0.5, 0.35, 0.7]]
    _projection_bundle(ctx, "m6/project-master-pattern-tilted", DUMMY_MP, "fixtures/" + DUMMY_MP.name,
                       {"shape": (48, 64), "pc": np.asarray(pc), "sample_tilt": 68.0, "tilt": 10.0, "azimuthal": 2.5,
                        "twist": 1.2},
                       [[200.0, 30.0, 10.0], [15.0, 80.0, 300.0], [90.0, 90.0, 90.0]], ("float32",),
                       energies=(None, 12.4),
                       note="the dummy master pattern is flat at each energy (its value is the energy), so only the "
                            "float32 output (no rescale) is compared: a rescale of a flat pattern divides zero by zero")


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
