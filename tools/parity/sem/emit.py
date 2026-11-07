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
orientation maths (orix's rotations, point groups, fundamental zones, orientations and misorientations), m5 maps and
grains (DefDAP's slip systems, Schmid factors, slip traces and GND density), m7 SEM-EDS line
intensities, background windows and Cliff-Lorimer on the TM002 spectrum (figures F16, F17), m6 master patterns (EMsoft EBSD, TKD and ECP
master pattern files read, the Ni 20 kV pattern projected onto a detector: figure F15), m4 dictionary indexing against
that pattern (figure F9, dictionary_cases.py).

Run with `python -I -B` from outside this folder: a fixture is data, never code.
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import sys
import warnings
from pathlib import Path

# numpy dispatches some ufuncs (arctan2 among them) to AVX-512 kernels on CPUs that have them, and those differ from the
# AVX2 kernels in the last bit. GitHub's runners come with and without AVX-512, so a vector on a bin edge (the Ti map's
# basal poles sit exactly on 1 degree azimuth edges) changed bins from one runner to the next and the drift gate failed
# on m5/texture-ti-full. Every x86-64 emit runs the AVX2 (x86-64-v3) kernels, which every runner has; set before numpy
# loads, an explicit setting wins.
if platform.machine().lower() in ("x86_64", "amd64") and "NPY_DISABLE_CPU_FEATURES" not in os.environ:
    os.environ.setdefault("NPY_ENABLE_CPU_FEATURES", "X86_V3")

import numpy as np  # noqa: E402

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
from refbundle import Bundle, sha256_of_file  # noqa: E402

sys.path.append(str(HERE))
from detector_cases import (  # noqa: E402,F401  (milestone 2 detector geometry and figure F5; emit collects case_ names)
    case_m2_detector_gnomonic, case_m2_detector_pc_conventions, case_m2_detector_sample_to_detector,
    case_m2_detector_tkd_geometry, case_m2_pc_moving_screen_si)
from hough_cases import (  # noqa: E402,F401  (milestone 4 Hough indexing and figure F8)
    case_m4_hough_indexing_nickel_large, case_m4_hough_library, case_m4_hough_nickel_block)
from dictionary_cases import (  # noqa: E402,F401  (milestone 4 dictionary indexing, figure F9)
    case_m4_dictionary_indexing_nickel_large, case_m4_dictionary_indexing_small)
from similarity_cases import (  # noqa: E402,F401  (milestone 4 orientation similarity map and merge of dictionary maps)
    case_m4_merge_crystal_maps, case_m4_orientation_similarity_map)
from writer_cases import (  # noqa: E402,F401  (milestone 8 .ang and .ctf writers and figure F18)
    case_m8_write_ang_sdss, case_m8_write_ang_sdss_ferrite, case_m8_write_ang_sdss_window, case_m8_write_ang_ti,
    case_m8_write_ctf_sdss, case_m8_write_ctf_sdss_ferrite, case_m8_write_ctf_sdss_window, case_m8_write_ctf_ti)
from grain_cases import case_m5_grains_sdss, case_m5_grains_ti, case_m5_grains_ti_full  # noqa: E402,F401  (m5, F11 and F12)
from simulation_cases import (  # noqa: E402,F401  (milestone 6 Kikuchi simulation and figure F14)
    case_m6_geometrical_simulation_nickel, case_m6_geometrical_simulation_tilted, case_m6_kikuchi_lattice,
    case_m6_kikuchi_reflectors_al2cu, case_m6_kikuchi_reflectors_ni, case_m6_kikuchi_reflectors_ti,
    case_m6_kikuchi_scattering_tables, case_m6_kinematic_master_pattern_ni)
from texture_cases import case_m5_texture_cubic, case_m5_texture_ti, case_m5_texture_ti_full  # noqa: E402,F401  (m5, F13)

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
             "rosettasciio": "rsciio", "pyebsdindex": "pyebsdindex", "diffsims": "diffsims", "numpy": "numpy", "defdap": "defdap._version"}
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


def _sem_tiff_bundle(ctx, case: str, path: Path, label: str, member: str | None = None) -> None:
    """What RosettaSciIO's TIFF reader hands an app for a vendor SEM image: the calibrated axes and the SEM metadata it
    parses from the vendor tag (Zeiss SmartSEM CZ_SEM, FEI/Thermo FEI_HELIOS), the pixels (exact for a committed fixture,
    a fingerprint for a downloaded file), plus what tifffile parses from the same tag that RosettaSciIO does not
    map (databar height, spot, chamber pressure, detector), and the vendor tag's own bytes, so the Swift unit tests plant
    the tag into a TIFF of the file's size and run on CI without the file. `member` names the file inside the zip at
    `path` (RosettaSciIO ships its TIFF test files zipped)."""
    import tempfile
    import zipfile

    import hyperspy.api as hs
    import tifffile
    from traits.api import Undefined

    with tempfile.TemporaryDirectory() as tmp:
        tif = path
        if member is not None:
            with zipfile.ZipFile(path) as z:
                tif = Path(z.extract(member, tmp))
        # Through HyperSpy, not rsciio.tiff.file_reader alone: the vendor-tag parse (CZ_SEM, FEI_HELIOS) into
        # Acquisition_instrument.SEM happens on the HyperSpy load path (rsciio 0.15.0), and the app's Info shows that.
        s = hs.load(str(tif))
        b = Bundle(case, 1, "rsciio", "hyperspy.api.load (rsciio.tiff)", ctx.out)
        b.input(path, label)
        if member is not None:
            b.value("zip_member", {"name": member, "sha256": sha256_of_file(tif)})
        data = np.asarray(s.data)
        b.value("shape", list(data.shape))
        b.value("dtype", data.dtype.name)
        b.value("axes", [{"name": a.name, "size": int(a.size), "scale": float(a.scale), "offset": float(a.offset),
                          "units": None if a.units is Undefined else str(a.units)} for a in s.axes_manager.signal_axes])
        md = s.metadata.as_dictionary()
        sem = md.get("Acquisition_instrument", {}).get("SEM", {})
        if not sem:
            raise RuntimeError(f"{case}: no SEM metadata parsed from the vendor tag")
        b.value("sem_metadata", sem)
        gen = md.get("General", {})
        b.value("general", {k: gen[k] for k in ("authors", "date", "time", "original_filename") if k in gen})

        with tifffile.TiffFile(str(tif)) as t:
            page = t.pages[0]
            code = next(c for c in (34682, 34680, 34118) if c in page.tags)
            tag = page.tags[code]
            with open(tif, "rb") as fh:
                fh.seek(tag.valueoffset)
                raw = fh.read(tag.count)
            b.value("image", {"width": int(page.imagewidth), "height": int(page.imagelength), "pages": len(t.pages),
                              "vendor": "zeiss" if code == 34118 else "fei", "tag": code, "tag_type": int(tag.dtype)})
            b.array("vendor_tag", np.frombuffer(raw, dtype=np.uint8), **EXACT,
                    note="the vendor tag's bytes as stored, planted by SEMImageMetadataTests")
            if code == 34118:
                cz = t.sem_metadata
                b.value("tifffile_cz_sem", {k: cz.get(k) for k in ("ap_spotsize", "ap_chamber_pressure", "ap_line_counter",
                                                                     "dp_image_store")} | {"keys": len(cz)})
            else:
                fei = t.fei_metadata
                b.value("tifffile_fei", {"DatabarHeight": fei.get("PrivateFei", {}).get("DatabarHeight"),
                                         "ResolutionY": fei.get("Image", {}).get("ResolutionY"),
                                         "Spot": fei.get("Beam", {}).get("Spot"),
                                         "ChPressure": fei.get("Vacuum", {}).get("ChPressure"),
                                         "DetectorName": fei.get("Detectors", {}).get("Name"),
                                         "sections": sorted(fei.keys())})
        if member is None:
            b.array("pixels", data, **EXACT)
        else:   # a downloaded file's pixels stay out of the repo too: their sha256, compared exactly by check.py
            b.fingerprint("pixels", data)
        b.scalar("mean", data.astype(np.float64).mean(), **F64)
        b.write()
    ctx.done(case)


def case_m1_read_sem_tiff_zeiss(ctx):
    _sem_tiff_bundle(ctx, "m1/read-sem-tiff-zeiss", FIXTURES / "rsciio_Zeiss_SEM_512pix.tif", "fixtures/rsciio_Zeiss_SEM_512pix.tif")


def case_m1_read_sem_tiff_fei(ctx):
    _sem_tiff_bundle(ctx, "m1/read-sem-tiff-fei-helios", FIXTURES / "rsciio_FEI_Helios_Ebeam_8bits.tif", "fixtures/rsciio_FEI_Helios_Ebeam_8bits.tif")


# RosettaSciIO 0.15.0's other six SEM test TIFFs, from its zips (fetch-data.sh): the 16-bit Helios frame, the three navcam
# frames (one without [IRBeam], one with unparseable floats), the 1k Zeiss frame and the two-page Zeiss stack.
SEM_TIFF_ZIPPED = [
    ("m1/read-sem-tiff-fei-helios-16bits", "tiff_FEI_Helios.zip", "FEI-Helios-Ebeam-16bits.tif"),
    ("m1/read-sem-tiff-fei-navcam", "tiff_FEI_Helios.zip", "FEI-Helios-navcam.tif"),
    ("m1/read-sem-tiff-fei-navcam-no-irbeam", "tiff_FEI_Helios.zip", "FEI-Helios-navcam-with-no-IRBeam.tif"),
    ("m1/read-sem-tiff-fei-navcam-bad-floats", "tiff_FEI_Helios.zip", "FEI-Helios-navcam-with-no-IRBeam-bad-floats.tif"),
    ("m1/read-sem-tiff-zeiss-1k", "tiff_Zeiss_SEM.zip", "test_tiff_Zeiss_SEM_1k.tif"),
    ("m1/read-sem-tiff-zeiss-multipage", "tiff_Zeiss_SEM.zip", "ZEISS_SEM_multipage.tif"),
]


def case_m1_read_sem_tiff_zipped(ctx):
    for case, zip_name, member in SEM_TIFF_ZIPPED:
        p = ctx.data / "rsciio" / "tiff" / zip_name
        if ctx.have(p, case):
            _sem_tiff_bundle(ctx, case, p, f"sem-data/rsciio/tiff/{zip_name}", member)


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


def _intensity_bundle(ctx, case: str, path: Path, label: str) -> None:
    """kikuchipy's intensity and size stages on background-corrected patterns (static then dynamic, as the background
    bundle): `rescale_intensity` to the dtype range with and without `percentiles`, `normalize_intensity` on float32,
    `downsample` by 2 and 3. The input of every stage is kikuchipy's own corrected uint8 patterns (`corrected`), so a port
    checks each stage alone; `chain` is the Patterns room's default run (static, dynamic, rescale 2 to 98 %, bin 2).
    A whole scan keeps a 3 x 3 corner; the fixture keeps all nine patterns."""
    import kikuchipy as kp

    s = kp.load(str(path))
    b = Bundle(case, 2, "kikuchipy", "kikuchipy.signals.EBSD.rescale_intensity / normalize_intensity / downsample", ctx.out)
    b.input(path, label)
    s.remove_static_background(operation="subtract")
    s.remove_dynamic_background(operation="subtract", filter_domain="frequency", truncate=4.0)
    if s.data.shape[0] * s.data.shape[1] > 9:
        s = s.inav[:3, :3]
        b.value("positions", "scan rows 0..2, cols 0..2")
    else:
        b.value("positions", "the whole scan")
    corrected = np.asarray(s.data)
    b.array("corrected", corrected, **EXACT, note="kikuchipy's static then dynamic subtract: every stage's input")
    b.value("rescale_percentiles", [2.0, 98.0])
    r = s.rescale_intensity(inplace=False)
    b.array("rescaled", np.asarray(r.data), **U8, note="rescale_intensity() to uint8's range: a corrected pattern already spans it")
    rp = s.rescale_intensity(percentiles=(2.0, 98.0), inplace=False)
    b.array("rescaled_percentiles", np.asarray(rp.data), **U8, note="np.nanpercentile per pattern, clipped, rescaled, cast by truncation")
    f = s.deepcopy()
    f.change_dtype("float32")
    n = f.normalize_intensity(num_std=1, inplace=False)
    b.array("normalized", np.asarray(n.data), rtol=1e-5, atol=1e-6, note="float32 input, mean 0, population std 1 (fastmath)")
    n2 = f.normalize_intensity(num_std=2, divide_by_square_root=True, inplace=False)
    b.array("normalized_std2_sqrt", np.asarray(n2.data), rtol=1e-5, atol=1e-8)
    for k in (2, 3):
        d = s.downsample(k, inplace=False)
        b.array(f"downsampled_{k}", np.asarray(d.data), **U8, note=f"_bin2d sums in float32, rescaled to uint8's range, truncated")
    c = rp.downsample(2, inplace=False)
    b.array("chain", np.asarray(c.data), **U8, note="static, dynamic, rescale 2 to 98 %, bin 2")
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


def case_m2_intensity_small(ctx):
    _intensity_bundle(ctx, "m2/intensity-kikuchipy-h5ebsd", FIXTURES / "kikuchipy_h5ebsd_patterns.h5", "fixtures/kikuchipy_h5ebsd_patterns.h5")


def case_m2_intensity_nickel_large(ctx):
    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if ctx.have(p, "m2/intensity-nickel-ebsd-large"):
        _intensity_bundle(ctx, "m2/intensity-nickel-ebsd-large", p, "sem-data/nickel_ebsd_large/patterns_v2.h5")


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


SAMPLING_INPUTS = FIXTURES / "sampling_inputs.json"


def _strided_rows(a: np.ndarray, rows: int) -> tuple[int, np.ndarray]:
    """Every stride-th row of a sample in orix's order and the last one, stride = ceil(count / rows): the rows a
    bundle keeps of a large sample (the count is exact on its own)."""
    n = a.shape[0]
    stride = max(1, -(-n // rows))
    idx = np.arange(0, n, stride)
    if idx[-1] != n - 1:
        idx = np.append(idx, n - 1)
    return stride, a[idx]


def case_m3_orientation_sampling(ctx):
    """orix.sampling with the cubochoric method (Rosca et al. 2014; Singh & De Graef 2016): resolution to semi-edge
    steps, the full grid S000(N) for a small N, get_sample_fundamental for m-3m at 4, 2 and 1.5 degrees, 6/mmm at 4
    degrees and three more groups, and get_sample_local around the identity and two centres. Counts exact; rotations in
    orix's order within atol 1e-7 (every stride-th row and the last of a large sample, see sampling_inputs.json)."""
    import json

    from orix.quaternion import Rotation
    from orix.sampling import get_sample_fundamental, get_sample_local
    from orix.sampling._cubochoric_sampling import cubochoric_sampling, resolution_to_semi_edge_steps

    inp = json.loads(SAMPLING_INPUTS.read_text(encoding="utf-8"))
    rows = int(inp["rows_per_case"])
    b = Bundle("m3/orientation-sampling", 3, "orix", "orix.sampling.get_sample_fundamental / get_sample_local (cubochoric)", ctx.out)
    b.input(SAMPLING_INPUTS, "fixtures/sampling_inputs.json")
    res = [float(x) for x in inp["semi_edge_resolutions"]]
    b.value("semi_edge_resolutions", res)
    b.value("semi_edge_steps", [int(resolution_to_semi_edge_steps(x)) for x in res])
    n = int(inp["full_grid_semi_edge_steps"])
    b.array("full_grid", cubochoric_sampling(semi_edge_steps=n).data, **ORI)
    fundamental = []
    for i, c in enumerate(inp["fundamental"]):
        (g,) = _point_groups([c["point_group"]])
        R = get_sample_fundamental(float(c["resolution"]), point_group=g)
        stride, kept = _strided_rows(R.data, rows)
        fundamental.append({"point_group": g.name, "resolution": float(c["resolution"]), "count": int(R.size), "stride": stride})
        b.array(f"fundamental_{i:02d}", kept, **ORI)
    b.value("fundamental", fundamental)
    local = []
    for i, c in enumerate(inp["local"]):
        eu = c["center_euler_degrees"]
        center = None if eu is None else Rotation.from_euler(np.asarray(eu, dtype=np.float64), degrees=True)
        R = get_sample_local(float(c["resolution"]), center=center, grid_width=float(c["grid_width"]))
        stride, kept = _strided_rows(R.data, rows)
        local.append({"resolution": float(c["resolution"]), "grid_width": float(c["grid_width"]), "count": int(R.size), "stride": stride})
        b.array(f"local_{i:02d}", kept, **ORI)
    b.value("local", local)
    b.write()
    ctx.done("m3/orientation-sampling")


TI_MAP_COLUMNS = 507  # orix-data's Ti map is 381 x 507 (x varies fastest)
F7_EDGES = np.arange(0.0, 95.0, 1.0)  # 1 degree bins to 94, above 622's largest disorientation (93.84 degrees)


def _neighbour_pairs(O, rows):
    """Horizontal (right, left) and vertical (below, above) neighbour pairs of a row-major map as flat Orientation arrays.
    Taken flat on purpose: in orix 0.15.0, `O2[:, 1:] - O2[:, :-1]` on a 2D-shaped Orientation returns the right angles in a
    permuted order (a pair of identical orientations comes out at 90 degrees; the histogram is unchanged), while the same pairs taken flat agree
    with `angle_with` on the 2D arrays; D-SEM-48."""
    from orix.quaternion import Orientation

    q = O.data.reshape(rows, TI_MAP_COLUMNS, 4)
    g = O.symmetry
    flat = lambda a: Orientation(np.ascontiguousarray(a).reshape(-1, 4), symmetry=g)  # noqa: E731
    h = flat(q[:, 1:]) - flat(q[:, :-1])
    v = flat(q[1:, :]) - flat(q[:-1, :])
    O2 = O.reshape(rows, TI_MAP_COLUMNS)
    check = np.concatenate([O2[:, 1:].angle_with(O2[:, :-1]).ravel(), O2[1:, :].angle_with(O2[:-1, :]).ravel()])
    assert np.allclose(np.concatenate([h.angle, v.angle]), check, atol=1e-7), "flat pairs disagree with angle_with"
    return h, v


def case_m3_ti_neighbour_misorientations(ctx):
    """Figure F7 on a committed map: the first three rows (3 x 507) of orix-data's Ti orientations (point group 622), the
    misorientations of horizontal and vertical neighbours (Orientation subtraction, reduced into the (622, 622) zone),
    their angles and the histogram of the angles in degrees on 1-degree bins (numpy.histogram)."""
    from orix.quaternion import Orientation
    from orix.quaternion.symmetry import D6

    inp = _orientation_inputs()
    assert inp["ti_point_group"] == D6.name
    rows = 3
    eu = np.asarray(inp["ti_euler_degrees"], dtype=np.float64)[: rows * TI_MAP_COLUMNS]
    O = Orientation.from_euler(eu, symmetry=D6, degrees=True)
    h, v = _neighbour_pairs(O, rows)
    angles = np.rad2deg(np.concatenate([h.angle, v.angle]))
    counts, edges = np.histogram(angles, F7_EDGES)
    b = Bundle("m3/ti-neighbour-misorientations", 3, "orix",
               "orix.quaternion.Orientation.__sub__ of map neighbours, Misorientation.angle; numpy.histogram", ctx.out)
    b.input(ORIENTATION_INPUTS, "fixtures/orientation_inputs.json")
    b.value("point_group", D6.name)
    b.value("map_shape", [rows, TI_MAP_COLUMNS])
    b.value("pairs", {"horizontal": int(h.size), "vertical": int(v.size)})
    b.array("euler_degrees", eu, **EXACT)
    b.array("horizontal_misorientations", h.data, **ORI)
    b.array("vertical_misorientations", v.data, **ORI)
    b.array("horizontal_angles", h.angle, **ORI)
    b.array("vertical_angles", v.angle, **ORI)
    b.array("edges_degrees", edges.astype(np.float64), **EXACT)
    b.array("counts", counts.astype(np.int64), **EXACT)
    frac = angles - np.floor(angles)
    b.scalar("closest_to_an_edge_degrees", float(np.min(np.minimum(frac, 1 - frac)[angles > 1e-6])), atol=1e-9)
    b.write()
    ctx.done("m3/ti-neighbour-misorientations")


def case_m3_ti_neighbour_misorientations_full(ctx):
    """Figure F7: the neighbour disorientation angle histogram of orix-data's whole Ti map (Ti_orientations.ctf, 381 x
    507, point group 622, read as orix.data.ti_orientations reads it: numpy.loadtxt of phi1, Phi, phi2 in degrees). Counts
    and edges exact; a sample of the angles (every 997th) within atol 1e-7 rad."""
    from orix.quaternion import Orientation
    from orix.quaternion.symmetry import D6

    p = ctx.data / "orix" / "Ti_orientations.ctf"
    if not ctx.have(p, "m3/ti-neighbour-misorientations-full"):
        return
    table = np.loadtxt(p, skiprows=1)
    rows = len(np.unique(table[:, 10]))
    assert len(np.unique(table[:, 9])) == TI_MAP_COLUMNS and rows * TI_MAP_COLUMNS == table.shape[0]
    O = Orientation.from_euler(np.deg2rad(table[:, :3]), D6)
    h, v = _neighbour_pairs(O, rows)
    rad = np.concatenate([h.angle, v.angle])
    angles = np.rad2deg(rad)
    counts, edges = np.histogram(angles, F7_EDGES)
    b = Bundle("m3/ti-neighbour-misorientations-full", 3, "orix",
               "orix.data.ti_orientations; Orientation.__sub__ of map neighbours, Misorientation.angle; numpy.histogram", ctx.out)
    b.input(p, "sem-data/orix/Ti_orientations.ctf")
    b.value("point_group", D6.name)
    b.value("map_shape", [rows, TI_MAP_COLUMNS])
    b.value("pairs", {"horizontal": int(h.size), "vertical": int(v.size)})
    b.value("above_7_degrees", int(np.count_nonzero(angles > 7)))
    b.array("edges_degrees", edges.astype(np.float64), **EXACT)
    b.array("counts", counts.astype(np.int64), **EXACT)
    b.array("sample_index", np.arange(0, rad.size, 997, dtype=np.int64), **EXACT)
    b.array("sample_angles", rad[::997], **ORI)
    frac = angles - np.floor(angles)
    b.scalar("closest_to_an_edge_degrees", float(np.min(np.minimum(frac, 1 - frac)[angles > 1e-6])), atol=1e-9)
    b.write()
    ctx.done("m3/ti-neighbour-misorientations-full")


def case_m3_crystal_map_sdss(ctx):
    """orix's CrystalMap on a two-phase map (orix-data's sdss_ferrite_austenite.ang, 100 x 117):
    the phase list, the slices by phase, by "indexed" and by rows and columns, their sizes, shapes, rows and columns, map
    data with NaN where a point is not in the slice, and the orientations of one phase. Everything a reader hands through
    is exact; orientations within atol 1e-7."""
    from orix import io

    p = ctx.data / "orix" / "sdss_ferrite_austenite.ang"
    if not ctx.have(p, "m3/crystal-map-sdss"):
        return
    xm = io.load(str(p))
    b = Bundle("m3/crystal-map-sdss", 3, "orix", "orix.crystal_map.CrystalMap (__getitem__, row, col, get_map_data, orientations)", ctx.out)
    b.input(p, "sem-data/orix/sdss_ferrite_austenite.ang")
    b.value("shape", list(xm.shape))
    b.value("size", int(xm.size))
    b.value("dx", float(xm.dx))
    b.value("dy", float(xm.dy))
    b.value("phase_ids", [int(i) for i in xm.phases.ids])
    b.value("phase_names", list(xm.phases.names))
    b.value("phase_colors", list(xm.phases.colors))
    b.value("point_groups", [pg.name if pg is not None else None for pg in xm.phases.point_groups])
    b.value("all_indexed", bool(xm.all_indexed))
    b.value("indexed_count", int(np.count_nonzero(xm.is_indexed)))
    slices = {}
    for key in list(xm.phases.names) + ["indexed"]:
        s = xm[key]
        slices[key] = {"size": int(s.size), "shape": list(s.shape),
                       "phases_in_data": [int(i) for i in s.phases_in_data.ids]}
    b.value("phase_slices", slices)
    window = xm[10:20, 5:15]
    b.value("window", {"rows": [10, 20], "columns": [5, 15], "size": int(window.size), "shape": list(window.shape)})
    b.array("window_row", window.row.astype(np.int64), **EXACT)
    b.array("window_col", window.col.astype(np.int64), **EXACT)
    b.array("window_iq", window.get_map_data("iq").astype(np.float64), **EXACT)
    b.array("window_id", window.id.astype(np.int64), **EXACT)
    first, second = xm.phases.names  # orix autogenerates "austenite/austenite", "ferrite/ferrite" (name/formula)
    b.value("ferrite_name", second)
    ferrite = xm[second]
    b.array("ferrite_iq_map", ferrite.get_map_data("iq", fill_value=-1).astype(np.float64), **EXACT,
            note="-1 where the point is not ferrite (get_map_data fill_value; a bundle holds no NaN)")
    b.array("ferrite_row", ferrite.row.astype(np.int64), **EXACT)
    b.array("ferrite_col", ferrite.col.astype(np.int64), **EXACT)
    b.array("phase_id_map", xm.get_map_data("phase_id").astype(np.float64), **EXACT)
    aus = xm[first].orientations
    b.value("austenite_symmetry", aus.symmetry.name)
    b.array("austenite_quaternions", aus.data, **ORI)
    b.write()
    ctx.done("m3/crystal-map-sdss")


IPF_INPUTS = FIXTURES / "ipf_inputs.json"
LAUE = ["-1", "2/m", "mmm", "4/m", "4/mmm", "-3", "-3m", "6/m", "6/mmm", "m-3", "m-3m"]
# Colours: the brief's 1e-6 on RGB in [0, 1]; geometry of the sectors as the symmetry normals (1e-10), edges 1e-9 (they are
# rotated 1000 times and rounded to 10 decimals by `unique`).
RGB = {"rtol": 0.0, "atol": 1e-6}
EDGE = {"rtol": 0.0, "atol": 1e-9}
KEY_STRIDE = 5
SECTOR_ROWS = 100


def _ipf_inputs() -> dict:
    import json

    return json.loads(IPF_INPUTS.read_text(encoding="utf-8"))


def case_m3_ipf_color_keys(ctx):
    """orix's vectors, Miller indices, stereographic projection, fundamental sectors (vertices, centre, edges, projection
    into the sector) and colour keys: the TSL inverse-pole-figure key (Nolze & Hielscher 2016 as orix ports MTEX) on seeded
    directions for the 11 Laue groups, its key image for m-3m and 6/mmm, and the Euler colour key of every group."""
    from diffpy.structure import Lattice, Structure
    from orix.crystal_map import Phase
    from orix.plot import DirectionColorKeyTSL, EulerColorKey
    from orix.projections import InverseStereographicProjection, StereographicProjection
    from orix.quaternion import Orientation
    from orix.vector import Miller, Vector3d
    from orix.vector.miller import _round_indices

    inp = _ipf_inputs()
    groups = _point_groups(_orientation_inputs()["point_groups"])
    by_name = {g.name: g for g in groups}
    b = Bundle("m3/ipf-color-keys", 3, "orix", "orix.vector (Vector3d, Miller, FundamentalSector), orix.projections, orix.plot (DirectionColorKeyTSL, IPFColorKeyTSL, EulerColorKey)", ctx.out)
    b.input(IPF_INPUTS, "fixtures/ipf_inputs.json")
    b.input(ORIENTATION_INPUTS, "fixtures/orientation_inputs.json")

    # Vectors and the stereographic projection (upper hemisphere pole -1, lower pole 1, split, inverse).
    d = np.asarray(inp["directions"], dtype=np.float64)
    v = Vector3d(d)
    b.array("directions", d, **EXACT)
    b.array("azimuth", v.azimuth, **ORI)
    b.array("polar", v.polar, **ORI)
    upper, lower = StereographicProjection(pole=-1), StereographicProjection(pole=1)
    b.array("upper_xy", np.column_stack(upper.vector2xy(v)), **ORI)
    b.array("lower_xy", np.column_stack(lower.vector2xy(v)), **ORI)
    xu, yu, xl, yl = StereographicProjection.vector2xy_split(v)
    b.value("split_counts", [int(xu.size), int(xl.size)])
    b.array("split_upper_xy", np.column_stack((xu, yu)), **ORI)
    b.array("split_lower_xy", np.column_stack((xl, yl)), **ORI)
    xy = np.asarray(inp["stereographic_xy"], dtype=np.float64)
    b.array("stereographic_xy", xy, **EXACT)
    b.array("inverse_upper", InverseStereographicProjection(pole=-1).xy2vector(xy[:, 0], xy[:, 1]).data, **ORI)
    b.array("inverse_lower", InverseStereographicProjection(pole=1).xy2vector(xy[:, 0], xy[:, 1]).data, **ORI)

    # Lattices and Miller indices.
    b.value("lattices", inp["lattices"])
    for i, lat in enumerate(inp["lattices"]):
        phase = Phase(point_group=lat["point_group"], structure=Structure(lattice=Lattice(*lat["abc"], *lat["angles"])))
        L = phase.structure.lattice
        tag = f"{i:02d}"
        b.array(f"lattice_base_{tag}", np.asarray(L.base, dtype=np.float64), **SYM)
        b.array(f"lattice_recbase_{tag}", np.asarray(L.recbase, dtype=np.float64), **SYM)
        hkl = Miller(hkl=inp["hkl"], phase=phase)
        b.array(f"hkl_xyz_{tag}", hkl.data, **ORI)
        b.array(f"hkl_uvw_{tag}", hkl.uvw, **ORI)
        b.array(f"hkl_length_{tag}", hkl.length, **ORI)
        uvw = Miller(uvw=inp["uvw"], phase=phase)
        b.array(f"uvw_xyz_{tag}", uvw.data, **ORI)
        b.array(f"uvw_hkl_{tag}", uvw.hkl, **ORI)
        b.array(f"uvw_length_{tag}", uvw.length, **ORI)
        b.array(f"uvw_UVTW_{tag}", uvw.UVTW, **ORI)
        b.array(f"hkl_hkil_{tag}", hkl.hkil, **ORI)
        rnd = Miller(xyz=inp["round_xyz"], phase=phase)
        b.array(f"round_hkl_{tag}", _round_indices(rnd.hkl, 20).astype(np.float64), **EXACT,
                note="Miller.round's indices (MTEX's rounding, max index 20) of the vectors read as (hkl)")
        b.array(f"round_uvw_{tag}", _round_indices(rnd.uvw, 20).astype(np.float64), **EXACT)
        if lat["point_group"] == "6/mmm":
            b.array(f"hkil_xyz_{tag}", Miller(hkil=inp["hkil"], phase=phase).data, **ORI)
            b.array(f"UVTW_xyz_{tag}", Miller(UVTW=inp["UVTW"], phase=phase).data, **ORI)

    # Fundamental sectors of every group: vertices, centre, projection of the directions into the sector.
    for i, g in enumerate(groups):
        tag = f"{i:02d}"
        fs = g.fundamental_sector
        b.array(f"vertices_{tag}", fs.vertices.data.reshape(-1, 3), **SYM)
        b.array(f"center_{tag}", fs.center.data.reshape(-1, 3), **SYM)
        b.array(f"in_sector_{tag}", v[:SECTOR_ROWS].in_fundamental_sector(g).data, **ORI)

    # The TSL key: colours of the directions per Laue group, and the edges and key image of m-3m and 6/mmm.
    b.value("laue_groups", LAUE)
    for name in LAUE:
        k = DirectionColorKeyTSL(by_name[name])
        tag = name.replace("/", "_")
        b.array(f"tsl_rgb_{tag}", k.direction2color(v), **RGB)
        edges = k.symmetry.fundamental_sector.edges
        b.value(f"edges_count_{tag}", int(edges.size))
        if name in ("m-3m", "6/mmm"):
            b.array(f"edges_{tag}", edges.data, **EDGE)
            grid, (xr, yr) = k._create_rgba_grid(return_extent=True)
            b.value(f"key_extent_{tag}", [float(xr[0]), float(xr[1]), float(yr[0]), float(yr[1])])
            b.value(f"key_shape_{tag}", list(grid.shape[:2]))
            gy, gx = np.mgrid[yr[0]:yr[1]:0.001, xr[0]:xr[1]:0.001]
            gy, gx = gy[::-1][::KEY_STRIDE, ::KEY_STRIDE], gx[::-1][::KEY_STRIDE, ::KEY_STRIDE]
            pv = InverseStereographicProjection().xy2vector(gx.ravel(), gy.ravel())
            inside = (pv <= k.symmetry.fundamental_sector).reshape(gx.shape)
            rgb = k.direction2color(pv).reshape(gx.shape + (3,))
            rgb[~inside] = 0
            b.value("key_stride", KEY_STRIDE)
            b.array(f"key_rgb_{tag}", rgb.astype(np.float32), **RGB,
                    note="orix's direction2color at every KEY_STRIDE-th pixel of _create_rgba_grid's grid, 0 outside the sector")
            b.array(f"key_alpha_{tag}", inside.astype(np.uint8), **EXACT)
            sub = grid[::2 * KEY_STRIDE, ::2 * KEY_STRIDE, :3]
            b.array(f"key_orix_interpolated_{tag}", sub.astype(np.float32), rtol=0.0, atol=0.05,
                    note="orix's own key image at every 2*KEY_STRIDE-th pixel, RGB (scipy griddata cubic over 2-degree samples); the port draws the exact colours, "
                         "which differ from this interpolation by up to 0.048 (decision in docs/decisions.md)")

    # The Euler colour key of every group on seeded rotations.
    q = np.asarray(inp["quaternions"], dtype=np.float64)[:100]
    b.array("euler_key_quaternions", q, **EXACT)
    for i, g in enumerate(groups):
        tag = f"{i:02d}"
        O = Orientation(q, symmetry=g)
        b.array(f"euler_region_{tag}", O.in_euler_fundamental_region(), **ORI)
        b.array(f"euler_rgb_{tag}", EulerColorKey(g).orientation2color(O), **RGB)
    b.write()
    ctx.done("m3/ipf-color-keys")


def _ipf_map_bundle(ctx, case: str, xm, label: str, path: Path) -> None:
    """The IPF-Z colours of a crystal map, each phase with `IPFColorKeyTSL` of its point group, as
    `CrystalMap.plot` draws them (figure F6)."""
    from orix.plot import IPFColorKeyTSL
    from orix.vector import Vector3d

    b = Bundle(case, 3, "orix", "orix.plot.IPFColorKeyTSL.orientation2color per phase", ctx.out)
    b.input(path, label)
    b.value("shape", list(xm.shape))
    b.value("phases", {int(k): {"name": p.name, "point_group": p.point_group.name if p.point_group else None}
                       for k, p in xm.phases if k != -1})
    eu = xm.rotations.to_euler().astype(np.float64)
    b.array("euler", eu, **EXACT, note="Bunge angles in radians as orix read them, the input of the colours")
    b.array("phase_id", xm.phase_id.astype(np.int32), **EXACT)
    for axis, vec in (("z", (0, 0, 1)),):
        rgb = np.zeros((xm.size, 3))
        for k, p in xm.phases:
            if k == -1 or p.point_group is None:
                continue
            mask = xm.phase_id == k
            key = IPFColorKeyTSL(p.point_group, direction=Vector3d(vec))
            rgb[mask] = key.orientation2color(xm[mask].orientations)
        b.array(f"ipf_{axis}_rgb", rgb, **RGB)
    b.write()
    ctx.done(case)


def case_m3_ipf_sdss_ferrite_austenite(ctx):
    p = ctx.data / "orix" / "sdss_ferrite_austenite.ang"
    if ctx.have(p, "m3/ipf-sdss-ferrite-austenite"):
        from orix import io

        _ipf_map_bundle(ctx, "m3/ipf-sdss-ferrite-austenite", io.load(str(p)), "sem-data/orix/sdss_ferrite_austenite.ang", p)


def case_m3_ipf_nickel_ebsd_large(ctx):
    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if ctx.have(p, "m3/ipf-nickel-ebsd-large"):
        import kikuchipy as kp

        xm = kp.load(str(p), lazy=True).xmap
        _ipf_map_bundle(ctx, "m3/ipf-nickel-ebsd-large", xm, "sem-data/nickel_ebsd_large/patterns_v2.h5", p)


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


# ------------------------------------------------------------------------------------- SEM-EDS map readers (m7)

RSCIIO = FIXTURES / "rsciio"
# The keyword arguments the app reads JEOL files with (decision in docs/decisions.md): every count kept (uint32 instead
# of rsciio's uint8 default, which raises on the 255th X-ray in a channel) and the S(T)EM image of a .pts returned too.
JEOL_APP_KWARGS = {"SI_dtype": np.uint32, "read_em_image": True}


def _eds_metadata(md: dict) -> dict:
    """The metadata fields the app maps, flattened, present only where rsciio states them."""
    out = {}
    g = md.get("General", {})
    for k in ("original_filename", "title", "date", "time"):
        if k in g:
            out[k] = str(g[k])
    sig = md.get("Signal", {})
    if "signal_type" in sig:
        out["signal_type"] = str(sig["signal_type"])
    ai = md.get("Acquisition_instrument", {})
    if ai:
        mode = next(iter(ai))
        out["mode"] = mode
        inst = ai[mode]
        for k in ("beam_energy", "magnification"):
            if k in inst:
                out[k] = float(inst[k])
        eds = inst.get("Detector", {}).get("EDS", {})
        for k in ("azimuth_angle", "elevation_angle", "energy_resolution_MnKa", "live_time", "real_time"):
            if k in eds:
                out[k] = float(eds[k])
        if "detector_type" in eds:
            out["detector_type"] = str(eds["detector_type"])
        if "tilt_alpha" in inst.get("Stage", {}):
            out["tilt_alpha"] = float(inst["Stage"]["tilt_alpha"])
    sample = md.get("Sample", {})
    if "name" in sample:
        out["sample_name"] = str(sample["name"])
    for k in ("elements", "xray_lines"):
        if k in sample:
            out[k] = [str(x) for x in sample[k]]
    return out


def _eds_kind(d: dict) -> str:
    data = np.asarray(d["data"])
    eds = str(d["metadata"].get("Signal", {}).get("signal_type", "")).startswith("EDS")
    if data.ndim == 1:
        return "spectrum"
    if eds:
        return "spectrum_image"
    return "image"


def _eds_bundle(ctx, case: str, path: Path, label: str, function: str, read, extra_inputs=()) -> None:
    """What RosettaSciIO hands an app for one SEM-EDS file, signal by signal in its own order: kind, shape, dtype, axes,
    the mapped metadata, and the data exact (spectra as arrays; a spectrum image as its nonzero entries' flat C-order
    indices and counts, fingerprinted, with the summed spectrum as an array and the per-pixel total fingerprinted;
    images fingerprinted in their own dtype). A file rsciio refuses records the exception's class."""
    b = Bundle(case, 7, "rsciio", function, ctx.out)
    b.input(path, label)
    for p, l in extra_inputs:
        b.input(p, l)
    try:
        signals = read(str(path))
    except Exception as e:  # noqa: BLE001 - the refusal is the reference
        b.value("refusal", type(e).__name__)
        b.value("signals", [])
        b.write()
        ctx.done(case)
        return
    b.value("refusal", None)
    entries = []
    for i, d in enumerate(signals):
        data = np.asarray(d["data"])
        kind = _eds_kind(d)
        entries.append({
            "kind": kind, "shape": list(data.shape), "dtype": data.dtype.name,
            "axes": [{"name": str(a.get("name")), "size": int(a["size"]) if "size" in a else int(data.shape[j]),
                      "scale": float(a["scale"]), "offset": float(a["offset"]),
                      "units": None if a.get("units") is None else str(a["units"])} for j, a in enumerate(d["axes"])],
            "metadata": _eds_metadata(d["metadata"]),
        })
        if kind == "spectrum":
            b.array(f"signal{i}_counts", data.astype(np.int64), **EXACT)
        elif kind == "spectrum_image":
            flat = data.reshape(-1)
            nz = np.flatnonzero(flat).astype(np.int64)
            b.value(f"signal{i}_nonzero", {"count": int(nz.size), "index_sha256": _sha(nz),
                                           "value_sha256": _sha(flat[nz].astype(np.int64))})
            b.array(f"signal{i}_sum_spectrum", data.reshape(-1, data.shape[-1]).sum(axis=0, dtype=np.int64), **EXACT)
            b.fingerprint(f"signal{i}_pixel_totals", data.reshape(-1, data.shape[-1]).sum(axis=1, dtype=np.int64))
        else:
            b.fingerprint(f"signal{i}_pixels", data)
            b.scalar(f"signal{i}_pixel_sum", float(data.astype(np.float64).sum()), **EXACT)
    b.value("signals", entries)
    b.write()
    ctx.done(case)


# k-factors for F17. exspy ships no SEM k-factors and the TM002 layer has no certified composition, so the
# quantification parity runs on two stated sets (D-SEM-59): unit factors (composition = intensity fractions) and a
# planted set with distinct values, so every ratio of the Cliff-Lorimer chain is exercised. Neither is a measurement.
TM002_KFACTORS_PLANTED = {"Al_Ka": 1.0, "C_Ka": 2.5, "Cu_La": 1.5, "Mn_La": 1.25, "Zr_La": 2.0}


def _tm002(beam_energy=None):
    import hyperspy.api as hs

    s = hs.load(str(FIXTURES / "exspy_EDS_SEM_TM002.hspy"), file_format="hspy")
    s.set_signal_type("EDS_SEM")
    if beam_energy is not None:
        s.set_microscope_parameters(beam_energy=beam_energy)
    return s


def case_m7_eds_quant_tm002(ctx):
    """F17: exspy's Cliff-Lorimer (`quantification_cliff_lorimer`, as `EDSTEMSpectrum.quantification(method="CL")`
    calls it, times 100, no absorption correction) on F16's background-subtracted intensities, weight and atomic
    percent (`exspy.material.weight_to_atomic`), with the unit and the planted k-factors; the take-off angle; each
    line's FWHM; the default background windows (line_width [2, 2]) and their intensities; the lines exspy picks at
    5, 20 and 30 kV."""
    from exspy._misc.eds import utils as utils_eds
    from exspy.material import weight_to_atomic

    p = FIXTURES / "exspy_EDS_SEM_TM002.hspy"
    s = _tm002()
    b = Bundle("m7/eds-quant-tm002", 7, "exspy", "exspy._misc.eds.utils.quantification_cliff_lorimer", ctx.out)
    b.input(p, "fixtures/exspy_EDS_SEM_TM002.hspy")
    s.add_lines()
    lines = list(s.metadata.Sample.xray_lines)
    elements = [ln.split("_")[0] for ln in lines]
    b.value("xray_lines", lines)
    b.value("kfactors_planted", [TM002_KFACTORS_PLANTED[ln] for ln in lines])
    b.scalar("take_off_angle_deg", s.get_take_off_angle(), **F64)
    fwhm = [s._get_line_energy(ln, FWHM_MnKa="auto")[1] for ln in lines]
    b.array("line_fwhm_keV", np.asarray(fwhm, dtype=np.float64), **F64)
    iw = s.estimate_integration_windows(windows_width=2.0)
    bw = s.estimate_background_windows(line_width=[5.0, 2.0])
    sub = s.get_lines_intensity(xray_lines=lines, integration_windows=iw, background_windows=bw)
    for name, k in (("unit", [1.0] * len(lines)), ("planted", [TM002_KFACTORS_PLANTED[ln] for ln in lines])):
        stack = np.asarray([np.asarray(i.data, dtype=np.float64).reshape(1) for i in sub])
        wt = utils_eds.quantification_cliff_lorimer(stack, k) * 100.0
        at = weight_to_atomic(wt, elements)
        b.array(f"weight_percent_{name}", wt.reshape(-1).astype(np.float64), **F64)
        b.array(f"atomic_percent_{name}", np.asarray(at, dtype=np.float64).reshape(-1), **F64)
    bw22 = s.estimate_background_windows()
    b.array("background_windows_default_keV", np.asarray(bw22, dtype=np.float64), **F64)
    sub22 = s.get_lines_intensity(xray_lines=lines, integration_windows=iw, background_windows=bw22)
    b.array("intensity_background_default", np.asarray([float(np.asarray(i.data).ravel()[0]) for i in sub22]), **F64)
    iw21 = s.estimate_integration_windows(windows_width=2.1)
    raw21 = s.get_lines_intensity(xray_lines=lines, integration_windows=iw21)
    b.array("intensity_raw_width_2_1", np.asarray([float(np.asarray(i.data).ravel()[0]) for i in raw21]), **F64)
    b.value("xray_lines_by_beam_energy", {str(kv): list(_lines_at(kv)) for kv in (5.0, 20.0, 30.0)})
    _xray_database(b)
    b.write()
    ctx.done("m7/eds-quant-tm002")


def _xray_database(b):
    """exspy's element database as the quantification above reads it: every element's Z and atomic weight and every X-ray
    line's energy and weight, in the database's own order, exact (Sources/TEMCore/EDX/XrayLineDatabase.swift is generated
    from the same dict by make_xray_database.py and must equal these arrays)."""
    from exspy._misc.elements import elements as db

    symbols, names, energies, weights, z, aw = [], [], [], [], [], []
    for el in db:
        symbols.append(el)
        z.append(int(db[el]["General_properties"]["Z"]))
        aw.append(float(db[el]["General_properties"]["atomic_weight"]))
        for ln, d in db[el]["Atomic_properties"].get("Xray_lines", {}).items():
            names.append(f"{el}_{ln}")
            energies.append(float(d["energy (keV)"]))
            weights.append(float(d["weight"]))
    b.value("db_elements", symbols)
    b.value("db_xray_lines", names)
    b.array("db_z", np.asarray(z, dtype=np.int64), **EXACT)
    b.array("db_atomic_weight", np.asarray(aw, dtype=np.float64), **EXACT)
    b.array("db_line_energy_keV", np.asarray(energies, dtype=np.float64), **EXACT)
    b.array("db_line_weight", np.asarray(weights, dtype=np.float64), **EXACT)


def _lines_at(kv):
    t = _tm002(beam_energy=kv)
    t.add_lines()
    return t.metadata.Sample.xray_lines


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


def _sha(a: np.ndarray) -> str:
    from refbundle import sha256_of_array

    return sha256_of_array(a)


def _bruker(name):
    def read(p):
        from rsciio.bruker import file_reader

        return file_reader(p)
    return read


def _edax(p):
    from rsciio.edax import file_reader

    return file_reader(p)


def _jeol(p):
    from rsciio.jeol import file_reader

    return file_reader(p, **JEOL_APP_KWARGS)


BRUKER_FIXTURES = {
    "m7/read-bcf-16x16-12bit": "16x16_12bit_packed_8bit.bcf",
    "m7/read-bcf-30x30-zlib": "30x30_instructively_packed_16bit_compressed.bcf",
    "m7/read-bcf-p45-bse-se": "P45_the_default_job.bcf",
    "m7/read-bcf-tem": "test_TEM.bcf",
    "m7/read-bcf-over16bit": "over16bit.bcf",
    "m7/read-bcf-not-sfs": "Nope.bcf",
    "m7/read-bcf-v2-edx-ebsd": "bcf-edx-ebsd.bcf",
    "m7/read-spx-m6-jetstream": "bruker_m6_jetstream_file_example.spx",
    "m7/read-spx-nano": "bruker_nano.spx",
    "m7/read-spx-extracted": "extracted_from_bcf.spx",
}
BRUKER_DATA = {"m7/read-bcf-hitachi": "Hitachi_TM3030Plus.bcf", "m7/read-bcf-v2-50x50-zlib": "bcf_v2_50x50px.bcf"}
EDAX_FIXTURES = {
    "m7/read-spd-map-crop8": "spd_map_crop8.spd",
    "m7/read-spd-xrf-crop8": "spc0_61-ipr333_xrf_crop8.spd",
    "m7/read-lsd-line-scan-crop": "line_scan_crop.lsd",
    "m7/read-spc-single": "single_spect.spc",
}
EDAX_COMPANIONS = {
    "spd_map_crop8.spd": ["spd_map_crop8.spc", "Live Map 2_Img.ipr"],
    "spc0_61-ipr333_xrf_crop8.spd": ["spc0_61-ipr333_xrf_crop8.spc", "Garnet1_Img.ipr"],
    "line_scan_crop.lsd": ["line_scan_crop.spc", "line_scan_crop.csv"],
}
JEOL_FIXTURES = {
    "m7/read-pts-4frames": "View000_0000006_4frames.pts",
    "m7/read-pts-incomplete-frame": "View000_0000006_2.5frames.pts",
    "m7/read-pts-interrupted-first-sweep": "InvalidFrame/Dummy-Data_0000007.pts",
    "m7/read-pts-interrupted-second-sweep": "InvalidFrame/Dummy-Data_0000015.pts",
    "m7/read-pts-stopped-after-sweep": "InvalidFrame/Dummy-Data_0000023.pts",
    "m7/read-jeol-img": "InvalidFrame/Dummy-Data_0000000.img",
    "m7/read-jeol-eds-met03": "met03.EDS",
    "m7/read-asw-seq-eds": "seq/1.ASW",
    "m7/read-asw-shift-jis-missing-views": "181019-BN.ASW",
}
JEOL_DATA = {"m7/read-asw-rawdata": "rawdata.ASW", "m7/read-pts-full": "Sample/00_View000/View000_0000006.pts"}


def case_m7_read_bruker(ctx):
    for case, name in BRUKER_FIXTURES.items():
        p = RSCIIO / "bruker" / name
        _eds_bundle(ctx, case, p, f"fixtures/rsciio/bruker/{name}", "rsciio.bruker.file_reader", _bruker(name))
    for case, name in BRUKER_DATA.items():
        p = ctx.data / "rsciio" / "bruker" / name
        if ctx.have(p, case):
            _eds_bundle(ctx, case, p, f"sem-data/rsciio/bruker/{name}", "rsciio.bruker.file_reader", _bruker(name))


def case_m7_read_edax(ctx):
    for case, name in EDAX_FIXTURES.items():
        p = RSCIIO / "edax" / name
        extra = [(RSCIIO / "edax" / c, f"fixtures/rsciio/edax/{c}") for c in EDAX_COMPANIONS.get(name, [])]
        _eds_bundle(ctx, case, p, f"fixtures/rsciio/edax/{name}", "rsciio.edax.file_reader", _edax, extra)


def case_m7_read_jeol(ctx):
    for case, name in JEOL_FIXTURES.items():
        p = RSCIIO / "jeol" / name
        extra = []
        if name == "seq/1.ASW":
            extra = [(q, "fixtures/rsciio/jeol/seq/Sample/00_View002/" + q.name)
                     for q in sorted((RSCIIO / "jeol" / "seq" / "Sample" / "00_View002").iterdir())]
        _eds_bundle(ctx, case, p, f"fixtures/rsciio/jeol/{name}", "rsciio.jeol.file_reader", _jeol, extra)
    for case, name in JEOL_DATA.items():
        p = ctx.data / "rsciio" / "jeol" / name
        if ctx.have(p, case):
            _eds_bundle(ctx, case, p, f"sem-data/rsciio/jeol/{name}", "rsciio.jeol.file_reader", _jeol)


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


# --------------------------------------------------------------------------- slip systems, Schmid factors, slip traces, GND (m5)

SLIP_INPUTS = FIXTURES / "slip_inputs.json"
SLIP = {"rtol": 0.0, "atol": 1e-6}      # DefDAP's Schmid factors and trace angles (catalogue section 5)
UNIT = {"rtol": 0.0, "atol": 1e-12}     # unit vectors and quaternions computed by the same closed formulas
GND = {"rtol": 1e-5, "atol": 1e6}       # m^-2; atol is far below any physical density (1e12 to 1e16 m^-2) and above
                                        # the rounding of R - I between identical neighbours (about 1e1 m^-2)


def _defdap():
    """DefDAP with its progress lines silenced and its version where Bundle looks for it."""
    import defdap
    import defdap._version

    defdap.__version__ = defdap._version.__version__
    return defdap


def _quiet():
    import contextlib
    import io

    return contextlib.redirect_stdout(io.StringIO())


def _nye_separate_derivatives():
    """DefDAP 1.3.1's `Map.calc_nye` with its one defect corrected: `betadery = betaderx` makes both lattice-curvature
    arrays one object, so the y derivative overwrites the x derivative and the Nye tensor is built from the y
    neighbour alone. The corrected reference is DefDAP's own source with that line replaced by a second array (asserted
    to occur exactly once), everything else as written."""
    import inspect
    import textwrap

    from defdap import ebsd

    src = textwrap.dedent(inspect.getsource(ebsd.Map.calc_nye))
    old = "betadery = betaderx"
    assert src.count(old) == 1, "DefDAP's calc_nye no longer aliases the derivative arrays; drop the corrected variant"
    src = src.replace(old, "betadery = np.zeros((3, 3) + self.shape)")
    ns = dict(vars(ebsd))
    exec(compile(src, "<defdap calc_nye, derivatives separate>", "exec"), ns)
    return ns["calc_nye"]


def _slip_bundle(ctx, case: str, maps: dict, note: str) -> None:
    """One map through DefDAP 1.3.1: the slip systems of each phase (DefDAP's files, grouped by plane), the quaternions,
    the Nye tensor and GND density (as DefDAP computes them, and with the x and y derivatives kept apart), the grains
    (`find_boundaries` at 10 degrees, `find_grains` with at least 10 points), each grain's average orientation, Schmid
    factors for a load along x and slip-trace angles and inclinations, and the same per-orientation values for every
    37th point under loads along x and y."""
    from defdap import ebsd
    from defdap.quat import Quat

    m = maps["map"]
    shape = m.shape
    b = Bundle(case, 5, "defdap", "defdap.ebsd.Map.calc_nye, find_grains; Grain.calc_average_ori, calc_average_schmid_factors, calc_slip_traces; crystal.SlipSystem.load", ctx.out)
    b.input(SLIP_INPUTS, "fixtures/slip_inputs.json")
    b.value("note", note)
    b.value("shape", list(shape))
    b.value("step_um", float(m.step_size))
    b.value("phases", [{"name": ph.name, "laue_group": ph.laue_group, "space_group": ph.spaceGroup,
                        "crystal_structure": ph.crystal_structure.name, "c_over_a": ph.c_over_a,
                        "slip_system_file": ph.ss_file, "trace_colours": ph.slip_trace_colours,
                        "groups": [[{"plane": [int(x) for x in ss.plane_idc], "direction": [int(x) for x in ss.dir_idc]}
                                    for ss in grp] for grp in ph.slip_systems]} for ph in m.phases])
    for k, ph in enumerate(m.phases):
        flat = [ss for grp in ph.slip_systems for ss in grp]
        b.array(f"slip_planes_{k}", np.array([ss.slip_plane for ss in flat]), **UNIT)
        b.array(f"slip_directions_{k}", np.array([ss.slip_dir for ss in flat]), **UNIT)

    with _quiet():
        q = np.array([o.quat_coef for o in m.data.orientation.ravel()])
    b.array("quaternions", q.reshape(shape + (4,)), **UNIT, note="DefDAP Quat.create_many_quats, northern hemisphere")

    with _quiet():
        gnd_defdap, nye_defdap = m.data.GND, m.data.Nye_tensor
        gnd, nye = _nye_separate_derivatives()(m)
    b.array("gnd_defdap_1_3_1", gnd_defdap, **GND, note="calc_nye as DefDAP 1.3.1 runs it (y derivative in both arrays)")
    b.array("gnd", gnd, **GND, note="calc_nye with the x and y derivatives kept apart")
    win = (slice(None), slice(None), slice(0, 30), slice(0, 40))
    b.array("nye_defdap_1_3_1_window", np.ascontiguousarray(nye_defdap[win]), **GND, note="alpha[i, j, row, col], rows 0-29, columns 0-39")
    b.array("nye_window", np.ascontiguousarray(nye[win]), **GND, note="alpha[i, j, row, col], rows 0-29, columns 0-39")

    with _quiet():
        m.data.generate("grain_boundaries", misori_tol=10)
        m.find_grains(min_grain_size=10)
        m.calc_average_grain_schmid_factors(np.array([1.0, 0.0, 0.0]))
        for g in m:
            g.calc_slip_traces()
    points, offsets, phase_of, ref = [], [0], [], []
    for g in m:
        pts = np.asarray(g.data.point)
        points.extend(int(y) * shape[1] + int(x) for x, y in pts)
        offsets.append(len(points))
        phase_of.append(m.phases.index(g.phase))
        ref.append(g.ref_ori.quat_coef)
    b.value("grain_count", len(m))
    b.array("grain_points", np.array(points, dtype=np.int32), **EXACT, note="row * width + column, each grain's points in DefDAP's order")
    b.array("grain_offsets", np.array(offsets, dtype=np.int32), **EXACT)
    b.array("grain_phase", np.array(phase_of, dtype=np.int32), **EXACT, note="index into phases")
    b.array("grain_average_orientation", np.array(ref), **{"rtol": 0.0, "atol": 1e-10})
    for k in range(len(m.phases)):
        gs = [g for g in m if m.phases.index(g.phase) == k]
        if not gs:
            continue
        b.array(f"grain_schmid_x_{k}", np.array([[sf for grp in g.average_schmid_factors for sf in grp] for g in gs]), **SLIP)
        b.array(f"grain_trace_angles_{k}", np.array([g.slip_trace_angles for g in gs]), **SLIP)
        b.array(f"grain_trace_inclinations_{k}", np.array([g.slip_trace_inclinations for g in gs]), **SLIP)

    # Per orientation: every 37th point, each through a grain of its phase with the point's orientation as reference.
    phase_map = np.asarray(m.data.phase).ravel()
    idx = np.array([i for i in range(0, phase_map.size, 37) if phase_map[i] > 0], dtype=np.int32)
    b.array("sample_points", idx, **EXACT, note="row * width + column")
    carrier = {}
    for g in m:
        carrier.setdefault(m.phases.index(g.phase), g)
    for k in range(len(m.phases)):
        sel = idx[phase_map[idx] - 1 == k]
        if sel.size == 0:
            continue
        g = carrier[k]
        sx, sy, ta, ti = [], [], [], []
        for i in sel:
            g.ref_ori = Quat(q[i])
            g.calc_average_schmid_factors(np.array([1.0, 0.0, 0.0]))
            sx.append([sf for grp in g.average_schmid_factors for sf in grp])
            g.calc_average_schmid_factors(np.array([0.0, 1.0, 0.0]))
            sy.append([sf for grp in g.average_schmid_factors for sf in grp])
            g.calc_slip_traces()
            ta.append(g.slip_trace_angles)
            ti.append(g.slip_trace_inclinations)
        b.array(f"sample_points_{k}", sel.astype(np.int32), **EXACT)
        b.array(f"sample_schmid_x_{k}", np.array(sx), **SLIP)
        b.array(f"sample_schmid_y_{k}", np.array(sy), **SLIP)
        b.array(f"sample_trace_angles_{k}", np.array(ta), **SLIP)
        b.array(f"sample_trace_inclinations_{k}", np.array(ti), **SLIP)
    b.write()
    ctx.done(case)


def _slip_inputs() -> dict:
    import json

    return json.loads(SLIP_INPUTS.read_text(encoding="utf-8"))


def case_m5_slip_ti(ctx):
    """Hexagonal titanium: DefDAP's `hexagonal_withca` slip systems (basal, prismatic, pyramidal <a> and <c+a>) on the
    90 x 120 corner of orix-data's Ti map, Bunge angles converted to radians as DefDAP's loaders do (degrees * pi / 180)."""
    _defdap()
    from defdap import ebsd
    from defdap.crystal import Phase

    t = _slip_inputs()["ti"]
    h, w = t["shape"]
    a, b_, c, al, be, ga = t["lattice_angstrom_degrees"]
    phase = Phase(t["phase"], 9, t["space_group"], (a, b_, c, al * np.pi / 180, be * np.pi / 180, ga * np.pi / 180))
    eu = np.asarray(t["euler_degrees"], dtype=np.float64).reshape(h, w, 3).transpose(2, 0, 1) * np.pi / 180
    with _quiet():
        m = ebsd.Map({"step_size": t["step_um"], "phases": [phase], "phase": np.ones((h, w), np.uint8),
                      "euler_angle": np.ascontiguousarray(eu), "band_contrast": np.zeros((h, w), np.uint8)},
                     data_type="PythonDict")
    _slip_bundle(ctx, "m5/slip-ti", {"map": m},
                 "orix-data Ti_orientations.ctf rows 0-89, columns 0-119; Ti a = 2.951, c = 4.684 Angstrom (c/a 1.5872)")


def case_m5_slip_sdss(ctx):
    """The duplex steel: austenite with DefDAP's `cubic_fcc` systems, ferrite with `cubic_bcc`, on the whole sdss map.
    The EDAX Bunge angles get DefDAP's EdaxAngLoader frame change (phi1 - pi/2, wrapped into [0, 2 pi)) in float64;
    DefDAP's own .ang loader would also name every cubic phase bcc (space group 229) and parse in float32, so the map
    is built from the file's numbers with the phases named by their space groups (225 fcc, 229 bcc)."""
    _defdap()
    from defdap import ebsd
    from defdap.crystal import Phase

    t = _slip_inputs()["sdss"]
    h, w = t["shape"]
    phases = []
    for p in t["phases"]:
        a, b_, c, al, be, ga = p["lattice_angstrom_degrees"]
        phases.append(Phase(p["name"], 11, p["space_group"], (a, b_, c, al * np.pi / 180, be * np.pi / 180, ga * np.pi / 180)))
    eu = np.asarray(t["euler_radians"], dtype=np.float64).reshape(h, w, 3).transpose(2, 0, 1).copy()
    eu[0] -= np.pi / 2
    eu[0, eu[0] < 0.0] += 2 * np.pi
    with _quiet():
        m = ebsd.Map({"step_size": t["step_um"], "phases": phases,
                      "phase": np.asarray(t["phase_id"], dtype=np.uint8).reshape(h, w),
                      "euler_angle": eu, "band_contrast": np.zeros((h, w), np.uint8)}, data_type="PythonDict")
    _slip_bundle(ctx, "m5/slip-sdss", {"map": m},
                 "orix-data sdss_ferrite_austenite.ang, the whole 100 x 117 map; phase 1 austenite (fcc), 2 ferrite (bcc)")


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
