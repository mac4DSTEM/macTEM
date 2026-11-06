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


# ------------------------------------------------------------------------------------- NLPAR denoising (m2)

F32 = {"rtol": 1e-5, "atol": 0.0}   # float32 results: the harness rule for float32 scores (D-SEM-13)
NLPAR_TILE_BYTES = 32e9             # pyebsdindex's cap on its tile budget; fixed so the tiling is machine-independent


class _MemoryPatternFile:
    """The in-memory stand-in for a pyebsdindex pattern file: `read_data` hands out a slab of the scan as float32
    (as `convertToFloat=True` does), `write_data` keeps NLPAR's float32 output before any cast to a file type. The
    NLPAR code itself runs unchanged."""

    def __init__(self, data: np.ndarray):
        self.data = data
        self.nRows, self.nCols, self.patternH, self.patternW = data.shape
        self.filetype, self.filepath, self.version = "MEMORY", "memory", 1
        self.filedatatype = np.float32
        self.datamin = self.datamax = None
        self.out = np.full(data.shape, np.nan, dtype=np.float32)

    def read_header(self):
        pass

    def read_datamaxmin(self):
        pass

    def write_datamaxmin(self):
        pass

    def read_data(self, patStartCount, convertToFloat=True, returnArrayOnly=True):
        (c0, r0), (nc, nr) = patStartCount
        block = self.data[r0:r0 + nr, c0:c0 + nc].reshape(-1, self.patternH, self.patternW).astype(np.float32)
        return block, None

    def write_data(self, newpatterns, patStartCount, flt2int=None, scalevalue=1.0):
        (c0, r0), (nc, nr) = patStartCount
        self.out[r0:r0 + nr, c0:c0 + nc] = np.asarray(newpatterns, dtype=np.float32).reshape(nr, nc, self.patternH, self.patternW)


def _nlpar_bundle(ctx, case: str, path: Path, label: str, searchradius: int, blocks: dict | None) -> None:
    """pyebsdindex's NLPAR as its documentation runs it: `opt_lambda()` (noise estimate over the 3 x 3 neighbourhood,
    Nelder-Mead on the three target weights 0.5, 0.34, 0.25; lambda = their median), then `calcnlpar()` with that
    lambda and the estimate, defaults otherwise (dthresh 0, saturation protection, automask). The CPU path
    (`pyebsdindex.nlpar_cpu`, what `pyebsdindex.nlpar.NLPAR` is without a GPU), tile budget fixed at pyebsdindex's
    32e9-byte cap. The input is the raw uint8 scan as float32. `blocks` None writes the noise estimate and lambda only:
    on a scan whose tiles are narrower than the search window pyebsdindex reads outside the tile, so its average there
    is not a reference."""
    import contextlib
    import io

    import kikuchipy as kp
    from pyebsdindex.nlpar_cpu import NLPAR

    class MemoryNLPAR(NLPAR):
        def __init__(self, data, **kw):
            super().__init__(**kw)
            self._file = _MemoryPatternFile(data)
            self.nrows, self.ncols = data.shape[:2]

        def getinfileobj(self):
            return self._file

        def getoutfileobj(self):
            return self._file

        def setoutfile(self, patternfile, filepath=None):
            pass

    s = kp.load(str(path))
    data = np.asarray(s.data)
    rows, cols, h, w = data.shape
    nl = MemoryNLPAR(data, searchradius=searchradius)
    with contextlib.redirect_stdout(io.StringIO()):
        lambdas = np.asarray(nl.opt_lambda(chunksize=NLPAR_TILE_BYTES, verbose=0), dtype=np.float64)
        sigma, d2, n2 = nl.calcsigma_cpu(chunksize=NLPAR_TILE_BYTES, nn=1, verbose=0)
        if blocks is not None:
            nl.calcnlpar(chunksize=NLPAR_TILE_BYTES, verbose=0)
    out = nl._file.out
    if blocks is not None and np.isnan(out).any():
        raise RuntimeError(f"{case}: NLPAR left patterns unwritten")
    sig_tiles = nl._calcchunks([w, h], cols, rows, target_bytes=NLPAR_TILE_BYTES, col_overlap=1, row_overlap=1)
    nl_tiles = nl._calcchunks([w, h], cols, rows, target_bytes=NLPAR_TILE_BYTES, col_overlap=searchradius, row_overlap=searchradius)

    b = Bundle(case, 2, "pyebsdindex", "pyebsdindex.nlpar_cpu.NLPAR.opt_lambda / calcsigma / calcnlpar", ctx.out)
    b.input(path, label)
    b.value("scan_shape_rc", [rows, cols])
    b.value("pattern_shape", [h, w])
    b.value("search_radius", searchradius)
    b.value("dthresh", 0.0)
    b.value("target_weights", [0.5, 0.34, 0.25])
    b.value("tile_bytes", NLPAR_TILE_BYTES)
    b.value("sigma_tiles", {"columns": sig_tiles[2].tolist(), "rows": sig_tiles[3].tolist()})
    b.value("nlpar_tiles", {"columns": nl_tiles[2].tolist(), "rows": nl_tiles[3].tolist()})
    b.array("automask", np.asarray(nl.mask, dtype=np.uint8), **EXACT)
    b.array("sigma", np.asarray(sigma, dtype=np.float32), **F32)
    b.array("distances", np.asarray(d2, dtype=np.float32), rtol=1e-5, atol=1e-5,
            note="normalised squared distances to the 3 x 3 neighbours, the lambda optimisation's input")
    b.array("lambdas", lambdas, rtol=1e-4, atol=0.0, note="target weights 0.5, 0.34, 0.25")
    b.scalar("lambda", float(np.median(lambdas)), rtol=1e-4)
    if blocks is None:
        b.write()
        ctx.done(case)
        return
    b.fingerprint("denoised", out)
    b.array("denoised_mean", out.astype(np.float64).mean(axis=(-2, -1)), **F32)
    for name, (r0, r1, c0, c1) in blocks.items():
        b.array(name, out[r0:r1, c0:c1], rtol=1e-5, atol=1e-4, note=f"scan rows {r0}..{r1 - 1}, cols {c0}..{c1 - 1}")
    b.write()
    ctx.done(case)


def case_m2_nlpar_small(ctx):
    _nlpar_bundle(ctx, "m2/nlpar-kikuchipy-h5ebsd", FIXTURES / "kikuchipy_h5ebsd_patterns.h5",
                  "fixtures/kikuchipy_h5ebsd_patterns.h5", searchradius=1, blocks=None)


def case_m2_nlpar_nickel_large(ctx):
    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if ctx.have(p, "m2/nlpar-nickel-ebsd-large"):
        # the corner (window shifted at two edges) and a block across the seam of pyebsdindex's two column tiles
        _nlpar_bundle(ctx, "m2/nlpar-nickel-ebsd-large", p, "sem-data/nickel_ebsd_large/patterns_v2.h5", searchradius=3,
                      blocks={"denoised_corner": (0, 3, 0, 3), "denoised_seam": (26, 29, 33, 40)})


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
