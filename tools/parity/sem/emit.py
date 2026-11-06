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
SEM-EDS line intensities on the TM002 spectrum (the numbers behind the EDS figure).

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


# ------------------------------------------------------------- pattern filters (m2: FFT filter, CLAHE, averaging)

# The FFT filters of kikuchipy's *Pattern processing* guide: the frequency-domain transfer function is the product of a
# Gaussian lowpass (cutoff 22, width 10) and highpass (cutoff 3, width 2) of the pattern's shape, applied with
# shift=True (north-star figure F4); the spatial-domain kernels are a 5 x 5 Gaussian (std 1) and a 3 x 4 asymmetric
# kernel that pins the taps' direction and an even window's offsets (Barnes et al. 2016, kikuchipy.filters.fft_barnes).
FFT_LOW = {"cutoff": 22, "cutoff_width": 10}
FFT_HIGH = {"cutoff": 3, "cutoff_width": 2}
FFT_ASYM = np.array([[0.0, 1.0, 2.0, 3.0], [4.0, 5.0, 6.0, 7.0], [-1.0, -2.0, 0.5, 1.5]])
# Values before the cast: within 1e-5 relative or 1e-3 grey levels of kikuchipy's (its FFT runs in float32). Cast
# patterns: within one grey level (kikuchipy truncates float32/fastmath values), the fraction bound in macTEMTests.
FILTER_VALUES = {"rtol": 1e-5, "atol": 1e-3}
WINDOW = {"rtol": 1e-12, "atol": 1e-15}


def _rescaled(values: np.ndarray) -> np.ndarray:
    """kikuchipy's `_rescale_with_min_max` to the uint8 range per pattern, before the cast (computed in float64)."""
    v = values.astype(np.float64)
    lo, hi = v.min(axis=(-2, -1), keepdims=True), v.max(axis=(-2, -1), keepdims=True)
    return ((v - lo) / (hi - lo) * 255.0).astype(np.float32)  # float32 on disk: 6e-8 relative, far inside the tolerance


def _fft_filter_bundle(ctx, case: str, path: Path, label: str, first_only: bool) -> None:
    """kikuchipy's EBSD.fft_filter: (a) frequency domain, transfer function lowpass x highpass with shift=True (F4) and
    the same function with shift=False, (b) spatial domain (Barnes' padded real FFT) with a 5 x 5 Gaussian and a 3 x 4
    asymmetric kernel; plus the windows themselves (lowpass, highpass, modified Hann, Gaussian, circular)."""
    import kikuchipy as kp
    from kikuchipy.filters.fft_barnes import _fft_filter, _fft_filter_setup
    from kikuchipy.pattern._pattern import fft_filter as freq_filter

    s = kp.load(str(path))
    if first_only:
        s = s.inav[:1, :1]
    shape = s.axes_manager.signal_shape[::-1]
    b = Bundle(case, 2, "kikuchipy", "kikuchipy.signals.EBSD.fft_filter; kikuchipy.filters.Window", ctx.out)
    b.input(path, label)
    raw = np.asarray(s.data)
    b.array("patterns", raw, **EXACT, note="the input patterns" + (" (pattern (0, 0) only)" if first_only else ""))
    w_low = kp.filters.Window("lowpass", shape=shape, **FFT_LOW)
    w_high = kp.filters.Window("highpass", shape=shape, **FFT_HIGH)
    transfer = np.asarray(w_low * w_high)
    gauss = kp.filters.Window("gaussian", shape=(5, 5), std=1)
    b.value("frequency", {"lowpass": FFT_LOW, "highpass": FFT_HIGH, "shape": list(shape)})
    b.value("spatial", {"gaussian": {"shape": [5, 5], "std": 1}, "asymmetric": FFT_ASYM.tolist()})
    b.array("window_lowpass", np.asarray(w_low), **WINDOW)
    b.array("window_highpass", np.asarray(w_high), **WINDOW)
    b.array("transfer_function", transfer, **WINDOW)
    b.array("window_gaussian_5x5_std1", np.asarray(gauss), **WINDOW)
    b.array("window_modified_hann_60", np.asarray(kp.filters.Window("modified_hann", shape=(shape[1],))), **WINDOW)
    b.array("window_circular_5x7", np.asarray(kp.filters.Window("circular", shape=(5, 7))), **EXACT)
    flat = raw.reshape(-1, *shape)
    runs = [("frequency_shift", dict(transfer_function=transfer, function_domain="frequency", shift=True)),
            ("frequency_noshift", dict(transfer_function=transfer, function_domain="frequency", shift=False)),
            ("spatial_gaussian", dict(transfer_function=np.asarray(gauss), function_domain="spatial")),
            ("spatial_asymmetric", dict(transfer_function=FFT_ASYM, function_domain="spatial"))]
    for name, kwargs in runs:
        out = s.fft_filter(inplace=False, show_progressbar=False, **kwargs)
        b.array(name, np.asarray(out.data), **U8)
        if kwargs["function_domain"] == "frequency":
            vals = [freq_filter(p.astype(np.float32), transfer_function=transfer, shift=kwargs["shift"]) for p in flat]
        else:
            k = kwargs["transfer_function"]
            fft_shape, tf, ob, oa = _fft_filter_setup(shape, k)
            vals = [_fft_filter(p.astype(np.float32), tf, fft_shape, k.shape, ob, oa) for p in flat]
        b.array(f"{name}_values", _rescaled(np.stack(vals)).reshape(raw.shape), **FILTER_VALUES,
                note="kikuchipy's filtered pattern rescaled to 0..255 before the uint8 cast")
    b.write()
    ctx.done(case)


def case_m2_fft_filter_small(ctx):
    _fft_filter_bundle(ctx, "m2/fft-filter-kikuchipy-h5ebsd", FIXTURES / "kikuchipy_h5ebsd_patterns.h5",
                       "fixtures/kikuchipy_h5ebsd_patterns.h5", first_only=False)


def case_m2_fft_filter_nickel_large(ctx):
    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if ctx.have(p, "m2/fft-filter-nickel-ebsd-large"):
        _fft_filter_bundle(ctx, "m2/fft-filter-nickel-ebsd-large", p, "sem-data/nickel_ebsd_large/patterns_v2.h5",
                           first_only=True)


# CLAHE: kikuchipy's default (kernel = pattern shape / 4, clip limit 0, 128 bins) and two others that exercise the
# clip-limit redistribution, a non-square kernel and the bin count. scikit-image's float32 accumulation is reproduced
# exactly, so the uint8 patterns are exact.
CLAHE_RUNS = [("default", None, 0.0, 128), ("k10x12_clip0p01_nbins64", (10, 12), 0.01, 64),
              ("k7_clip0p05_nbins256", (7, 7), 0.05, 256)]


def _clahe_bundle(ctx, case: str, path: Path, label: str, first_only: bool) -> None:
    """kikuchipy's EBSD.adaptive_histogram_equalization (scikit-image's equalize_adapthist, then rescaled to uint8)."""
    import kikuchipy as kp

    s = kp.load(str(path))
    if first_only:
        s = s.inav[:1, :1]
    b = Bundle(case, 2, "kikuchipy", "kikuchipy.signals.EBSD.adaptive_histogram_equalization (skimage.exposure.equalize_adapthist)", ctx.out)
    b.input(path, label)
    b.array("patterns", np.asarray(s.data), **EXACT, note="the input patterns" + (" (pattern (0, 0) only)" if first_only else ""))
    runs = {}
    for name, kernel, clip, nbins in CLAHE_RUNS:
        out = s.adaptive_histogram_equalization(kernel_size=kernel, clip_limit=clip, nbins=nbins, inplace=False,
                                                show_progressbar=False)
        runs[name] = {"kernel_size": list(kernel) if kernel else "pattern shape // 4", "clip_limit": clip, "nbins": nbins}
        b.array(name, np.asarray(out.data), **EXACT)
    b.value("runs", runs)
    b.write()
    ctx.done(case)


def case_m2_clahe_small(ctx):
    _clahe_bundle(ctx, "m2/clahe-kikuchipy-h5ebsd", FIXTURES / "kikuchipy_h5ebsd_patterns.h5",
                  "fixtures/kikuchipy_h5ebsd_patterns.h5", first_only=False)


def case_m2_clahe_nickel_large(ctx):
    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if ctx.have(p, "m2/clahe-nickel-ebsd-large"):
        _clahe_bundle(ctx, "m2/clahe-nickel-ebsd-large", p, "sem-data/nickel_ebsd_large/patterns_v2.h5", first_only=True)


# Neighbour averaging: kikuchipy's default circular 3 x 3 window, the 3 x 3 Gaussian (std 1) of its guide, and a 1 x 3
# rectangular window (along the scan rows only; upstream's 1D window shape fails on a chunked 2D map, so the 2D form). Map borders read zeros; each pattern divided by the sum
# of the window weights inside the map (an integer: SciPy's correlate of ones into an int array truncates).
AVERAGE_RUNS = [("circular_3x3", "circular", (3, 3), {}), ("gaussian_3x3_std1", "gaussian", (3, 3), {"std": 1}),
                ("rectangular_1x3", "rectangular", (1, 3), {})]


def _average_bundle(ctx, case: str, path: Path, label: str, corner: int | None) -> None:
    """kikuchipy's EBSD.average_neighbour_patterns. For a whole scan, the input's (corner + 1)^2 corner and the averaged
    corner^2 corner (which reads no pattern beyond the input corner for a 3-wide window)."""
    import kikuchipy as kp
    from scipy.ndimage import correlate

    s = kp.load(str(path))
    b = Bundle(case, 2, "kikuchipy", "kikuchipy.signals.EBSD.average_neighbour_patterns", ctx.out)
    b.input(path, label)
    data = np.asarray(s.data)
    cut = (slice(None), slice(None)) if corner is None else (slice(0, corner), slice(0, corner))
    inp = data if corner is None else data[: corner + 1, : corner + 1]
    b.array("patterns", inp, **EXACT, note="the input patterns" + ("" if corner is None else f" (scan rows and columns 0..{corner})"))
    runs = {}
    for name, window, wshape, kw in AVERAGE_RUNS:
        w = np.asarray(kp.filters.Window(window, shape=wshape, **kw))
        out = s.average_neighbour_patterns(window=window, window_shape=wshape, inplace=False, show_progressbar=False, **kw)
        w2 = w
        sums = correlate(np.ones(data.shape[:2], dtype=int), weights=w2, mode="constant")
        vals = correlate(data.astype(np.float32), weights=w2.reshape(w2.shape + (1, 1)), mode="constant")
        vals = _rescaled(vals.astype(np.float64) / sums[..., None, None])
        runs[name] = {"window": window, "window_shape": list(wshape), **kw}
        b.array(f"window_{name}", w, **WINDOW)
        b.array(f"window_sums_{name}", sums[cut].astype(np.int64), **EXACT)
        b.array(name, np.asarray(out.data)[cut], **U8)
        b.array(f"{name}_values", vals[cut], rtol=1e-5, atol=1e-4,
                note="kikuchipy's steps (float32 correlate, window sums, min-max) before the uint8 cast")
    b.value("runs", runs)
    b.write()
    ctx.done(case)


def case_m2_average_small(ctx):
    _average_bundle(ctx, "m2/average-neighbours-kikuchipy-h5ebsd", FIXTURES / "kikuchipy_h5ebsd_patterns.h5",
                    "fixtures/kikuchipy_h5ebsd_patterns.h5", corner=None)


def case_m2_average_nickel_large(ctx):
    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if ctx.have(p, "m2/average-neighbours-nickel-ebsd-large"):
        _average_bundle(ctx, "m2/average-neighbours-nickel-ebsd-large", p, "sem-data/nickel_ebsd_large/patterns_v2.h5", corner=3)


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
