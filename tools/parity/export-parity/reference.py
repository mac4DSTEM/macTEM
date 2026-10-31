#!/usr/bin/env python3
"""Truth and reader for tools/parity/export-parity: macTEM's PNG and CSV export (V1-10 slice 1) read back with Pillow and Python.

    reference.py plant <planted.dm4> <planted.truth.json> <rsciio-root> <planted-dir>
    reference.py check <planted-dir> <out-dir> [<case,case...|all> [<variant,variant...|all>]]

`plant` writes every input and its truth: the raw pixels (row-major little-endian float32, NaN and inf included), the two
look-up tables, and manifest.json (calibrations, windows, gammas, marks, profile ends, and the bar each case must draw,
worked BY HAND below). The Swift harness (main.swift) renders and writes the PNGs and CSVs with the production code and
dumps what it held in memory (profile samples and positions, the bar plan it returned, the window fractions, the real
images it opened); `check` reads all of it back with Pillow 12.3.0, numpy 2.5.4 and Python's own `float` and prints one
"  FAIL  <check>: <detail>" line per failure, then "export-parity: N FAILURES in M checks" (exit 1) or
"export-parity: all passed — ..." (exit 0). The checks, named as archive: roadmap-registrations-2026-10-15.md V1-10 registers them:

  P1  CSV: every sample and position cell re-reads bit-equal to the in-memory Double (NaN as "nan"); the rows equal the
      samples in count and order; the header's points, width, sizes, scales and units re-read equal to the planted ones.
  P3  the bar: the longest run of exact white in the bottom-left plate region, times x's scale, equals the label's length
      within one export pixel; the run equals the drawn length the metadata states, exactly, on every row of the bar.
  P4  PNG: W x H, RGB (colour type 2, 8 bit), the sRGB tag, valid chunks; and, without overlays, every channel equal to
      numpy's recomputation of the shader's mapping (round half up) from the canvas, window, gamma and LUT, 0 levels.
  P5  marks: on a black plant, the yellow-weighted centroid across a horizontal, a vertical and a 30 degree stroke lies
      within 0.15 export px of the line through the points' pixel centres; each ring's centre likewise.
  P6  the overlays touch only their own footprint: outside the plate's and the marks' grown boxes the export equals the
      overlay-free one bit for bit; with an option off, its footprint is untouched.
  R-P1 the Results room's CSV (V1-10 slice 3): every value re-reads bit-equal to the Double in memory (nan, +-0, +-inf, the smallest
      and the largest Double included); every label, text and unit round-trips through Python's csv (a comma, a quote and a newline);
      the numbers equal the owners' own (ImageMeasurement, SpotMeasure) and the closed forms to 1e-12; the header holds one validation
      line per product present, each the producer's constant (R-P2's reference side: no sentence claims "validated").
  P5-band, P7 (Gate B round 1): a profile's band is its width across, centred on the line (the red channel equals 46 x the
      share of each pixel the rectangle covers); an angle's two arms are strokes of their own; the label beside a mark and
      the bar's label equal the same string drawn upright by the harness, at the registered place, within 2 levels.

The reference is pinned: Pillow 12.3.0, numpy 2.5.4, ncempy 1.16 (the sha256 of its dm.py) and the Python minor the lock was
verified on, all equal to tools/lib/references-lock.txt; a different one is refused, never compared against.
"""
import csv
import hashlib
import importlib.metadata
import io
import json
import math
import os
import re
import struct
import sys
import zlib

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = os.path.join(HERE, "..", "..", "lib", "references-lock.txt")
PILLOW_VERSION = "12.3.0"
NUMPY_VERSION = "2.5.4"
NCEMPY_VERSION = "1.16"
DM_PY_SHA256 = "09edae58936747ae5c01437f0afb3bbee177746e3e30040b90817e24a47daa75"
PYTHON_MINOR = "3.14"          # tools/lib/python.sh MACTEM_PYTHON_MINOR: the lock was verified on it
REGISTRY_SHA256 = "31417482938f80160be2c03525ba58dd810c7f16b1790f597470ece8dd0b1bcb"
STEM_IMAGE = ("digitalmicrograph/2D/test_STEM_image.dm3",
              "fcba806af75bc3c2e50e7d7b0626cba545c1464f39e99c8922b225b0b0b0224c")

UM = "µm"                 # the DM files' micro sign, U+00B5
ANGSTROM = "Å"            # U+00C5
SOFTWARE = "macTEM 0.1.0 (1)"
VALIDATION_PNG = ("display rendering: window, gamma, 8-bit colour, not intensities; "
                  "the scale bar's length checked against its label (export-parity)")
LINEAGE_PNG = "none — marks carry no lineage id; the marks' parameters stand in"
LINEAGE_CSV = "none — marks carry no lineage id until V1-2; the mark's parameters above stand in"
VALIDATION_CSV = ("samples compared with scikit-image 0.26.0 profile_line(order=1, mode=\"reflect\", reduce_func=mean) "
                  "(1e-5 relative; 1e-5 of the image's largest magnitude near zero); calibration: as the file states it")
NUMBERS_CSV = "%.17g (exact round trip); nan where a NaN pixel enters a sample"
MASKED_GREY = (82, 82, 87)     # (0.32, 0.32, 0.34) x 255 rounded


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def sha256(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def locked_versions():
    pins = {}
    with open(LOCK) as fh:
        for line in fh:
            m = re.match(r"^([A-Za-z0-9_.-]+)==(\S+)\s*$", line)
            if m:
                pins[m.group(1).lower()] = m.group(2)
    return pins


def check_reference():
    python = "%d.%d" % sys.version_info[:2]
    if python != PYTHON_MINOR:
        fail(f"Python {python} is not the pinned {PYTHON_MINOR} (tools/lib/python.sh)")
    pins = locked_versions()
    for package, want in (("pillow", PILLOW_VERSION), ("numpy", NUMPY_VERSION), ("ncempy", NCEMPY_VERSION)):
        have = importlib.metadata.version(package)
        if have != want:
            fail(f"{package} {have} is not the pinned {want}")
        if pins.get(package) != want:
            fail(f"tools/lib/references-lock.txt pins {package} {pins.get(package)}, reference.py expects {want}")
    import PIL
    if PIL.__version__ != PILLOW_VERSION or np.__version__ != NUMPY_VERSION:
        fail(f"the Pillow/numpy imported are {PIL.__version__}/{np.__version__}")
    return f"Pillow {PILLOW_VERSION}, numpy {NUMPY_VERSION}, Python {python}"


# ---------------------------------------------------------------------------------------------------------------------
# The twins' arithmetic, restated in Python from the registration (never read off the Swift): the shader's mapping,
# DisplayWindow.fractions and FloatImage.normalized, all in the precision the app uses.

def overlay_scale(w, h):
    """u = max(1, round(min(W, H) / 512)), round half up (every operand here is positive)."""
    return max(1, int(math.floor(min(w, h) / 512 + 0.5)))


def canvas_of(raw):
    """FloatImage.normalized(): (p - lo) / (hi - lo) in Float32 over the FINITE range; non-finite pixels -1; a constant
    (or empty) range gives 0 for every finite pixel. Returns (canvas float32, rawRange (lo, hi) float32 or None)."""
    finite = np.isfinite(raw)
    if not finite.any():
        return np.full(raw.shape, -1.0, np.float32), None
    lo, hi = np.float32(raw[finite].min()), np.float32(raw[finite].max())
    span = np.float32(hi - lo)
    out = np.full(raw.shape, -1.0, np.float32)
    if not span > 0:
        out[finite] = 0.0
    else:
        with np.errstate(all="ignore"):
            out[finite] = ((raw[finite] - lo) / span).astype(np.float32)
    return out, (lo, hi)


def window_fractions(low, high, raw_range):
    """DisplayWindow.fractions (TEMSession/ImagePresentation.swift), in Float32."""
    if raw_range is None or not raw_range[1] > raw_range[0]:
        return np.float32(0), np.float32(1)
    lo_r, hi_r = raw_range
    span = np.float32(hi_r - lo_r)

    def frac(v, default):
        x = np.float32(np.float32(default if v is None else v) - lo_r) / span
        return np.float32(min(max(x, np.float32(0)), np.float32(1)))
    lo, hi = frac(low, lo_r), frac(high, hi_r)
    return (lo, hi) if lo < hi else (np.float32(0), np.float32(1))


def shader_rgb(canvas, low, high, gamma, lut):
    """Colormaps.metal colormapFragment then Colormaps.sampleRGB, in Double, round half up (exact: floor, then +1 when
    the fraction is >= 0.5). Evaluated once per distinct canvas value (math.pow is the C library's pow, as Swift's)."""
    flat = canvas.reshape(-1)
    uniq, inverse = np.unique(flat, return_inverse=True)
    lo = float(low)
    width = float(high) - float(low)
    span = width if width > 1e-6 else 1e-6
    exponent = 1.0 / (gamma if gamma > 0.05 else 0.05)
    table = np.empty((len(uniq), 3), np.uint8)
    for k, n in enumerate(uniq.tolist()):
        if not n >= 0:
            table[k] = MASKED_GREY
            continue
        v = min(max(n, 0.0), 1.0)
        v = min(max((v - lo) / span, 0.0), 1.0)
        v = math.pow(v, exponent)
        p = min(max(v * 256.0 - 0.5, 0.0), 255.0)
        i0 = int(math.floor(p))
        i1 = min(i0 + 1, 255)
        t = p - i0
        for c in range(3):
            a, b = float(lut[i0 * 4 + c]), float(lut[i1 * 4 + c])
            x = a + (b - a) * t
            fl = math.floor(x)
            table[k, c] = min(max(fl + (1 if x - fl >= 0.5 else 0), 0), 255)
    return table[inverse.reshape(-1)].reshape(canvas.shape + (3,))


# ---------------------------------------------------------------------------------------------------------------------
# Units, and what a bar's label means.

# A unit spelling -> (dimension, size in that dimension's base unit): enough to compare "20 nm" with a metre axis.
UNIT_SIZE = {
    "px": ("px", 1.0),
    "nm": ("L", 1e-9), "µm": ("L", 1e-6), "μm": ("L", 1e-6), "um": ("L", 1e-6), "mm": ("L", 1e-3),
    "m": ("L", 1.0), ANGSTROM: ("L", 1e-10), "pm": ("L", 1e-12),
    "1/nm": ("1/L", 1e9), "nm⁻¹": ("1/L", 1e9),
    "1/" + ANGSTROM: ("1/L", 1e10), ANGSTROM + "⁻¹": ("1/L", 1e10),
}


def axis_calibrated(a):
    return a is not None and a["units"] != "" and math.isfinite(a["scale"]) and a["scale"] > 0


def sanitize(s):
    """One header value: C0 controls, DEL, C1 controls (U+0085 included), U+2028, U+2029 -> a space (the registration)."""
    return "".join(" " if (ord(c) < 0x20 or 0x7F <= ord(c) <= 0x9F or ord(c) in (0x2028, 0x2029)) else c for c in s)


# ---------------------------------------------------------------------------------------------------------------------
# The planted cases.

def axis(scale, units, origin=0.0):
    return {"scale": scale, "units": units, "origin": origin}


NM_X, NM_Y = axis(0.5, "nm"), axis(0.8, "nm")


def lut_gray():
    t = np.zeros((256, 4), np.uint8)
    t[:, :3] = np.arange(256, dtype=np.uint8)[:, None]
    t[:, 3] = 255
    return t


def lut_planted(seed):
    """A non-linear planted LUT: every texel random in 0...250 (neighbours differ by up to 250, so nearest sampling and
    linear interpolation give different colours almost everywhere), no channel above 250 so that exact white (255, 255,
    255) is never a colormap value or an interpolation of two: the only exact white in a bar's region is the bar."""
    rng = np.random.default_rng(20261013)
    t = np.zeros((256, 4), np.uint8)
    t[:, :3] = rng.integers(0, 251, size=(256, 3)).astype(np.uint8)
    t[:, 3] = 255
    return t


def field(w, h, seed, top):
    """Integer-valued float32 pixels in 0...top (smooth structure, noise, 1 % hot pixels), asymmetric under flips and
    transposes; the pixels under and around the plate (the bottom-left W/2 x H/3 region) are capped at 30 % of the range so
    that no pixel there can map to exact white; the range is pinned by a minimum at (0, 0) and a maximum at (0, W-1)."""
    rng = np.random.default_rng(seed)
    xx = np.arange(w, dtype=np.float32)[None, :]
    yy = np.arange(h, dtype=np.float32)[:, None]
    f = (0.5 + 0.3 * np.sin(xx / np.float32(37.0)) * np.cos(yy / np.float32(23.0))
         + 0.2 * rng.random((h, w), dtype=np.float32)).astype(np.float32)
    raw = np.floor(f * np.float32(top))
    hot = rng.random((h, w), dtype=np.float32) < 0.01
    raw[hot] = rng.integers(0, top + 1, size=int(hot.sum())).astype(np.float32)
    r0, c1 = h - h // 3 - 2, w // 2 + 3
    raw[r0:, :c1] = np.floor(raw[r0:, :c1] * np.float32(0.3))
    raw[0, 0], raw[0, w - 1] = 0, top
    return raw.astype(np.float32)


def sprinkle_nonfinite(raw, seed, top):
    """2 % of the pixels non-finite: NaN, +inf, -inf (the range pins stay finite)."""
    rng = np.random.default_rng(seed)
    h, w = raw.shape
    idx = rng.choice(h * w, size=h * w // 50, replace=False)
    k = len(idx) // 5
    raw.flat[idx[:3 * k]] = np.nan
    raw.flat[idx[3 * k:4 * k]] = np.inf
    raw.flat[idx[4 * k:]] = -np.inf
    raw[0, 0], raw[0, w - 1] = 0, top
    return raw


def ties(w, h):
    """Integers 0...256 (every value occurs outside the plate region): the canvas is j/256, exactly, so with a gray LUT
    (texel i = i) and gamma 1 every pixel sits at t = 0.5 between two texels: a value a + (b - a) / 2 = i + 0.5 exactly,
    where round half up and round half to even part."""
    r, c = np.mgrid[0:h, 0:w]
    raw = ((c * 5 + r * 3) % 257).astype(np.float32)
    r0, c1 = h - h // 3 - 2, w // 2 + 3
    raw[r0:, :c1] = raw[r0:, :c1] % np.float32(77)
    raw[0, 0], raw[0, w - 1] = 0, 256
    if set(np.unique(raw).tolist()) != set(range(257)):
        fail("the ties image does not hold every integer 0...256")
    return raw


def wave(w=37, h=53):
    """profile-parity's planted wave: values of both signs, so many CSV samples are near zero (%.17g's small numbers)."""
    r, c = np.mgrid[0:h, 0:w].astype(np.float64)
    v = (300 * np.sin(2 * np.pi * (r / 11.3 + c / 7.7)) + 150 * np.cos(2 * np.pi * c / 5.3)
         + 4 * (r - 26) + 2.5 * (c - 18))
    return v.astype(np.float32)


def ramp_value(r, c):
    return 1000 + 3.7 * r + 2.1 * c + 0.013 * r * c


def ramp(w=37, h=53):
    r, c = np.mgrid[0:h, 0:w].astype(np.float64)
    return ramp_value(r, c).astype(np.float32)


def bar(label, value, unit, per_pixel, per_pixel_unit, nice, drawn):
    """The bar a case must draw, worked by hand in the case's comment (see cases())."""
    return {"label": label, "value": value, "unit": unit, "per_pixel": per_pixel, "per_pixel_unit": per_pixel_unit,
            "nice": nice, "drawn": drawn}


def mark(kind, points, label, width=1):
    return {"kind": kind, "points": [{"x": x, "y": y} for x, y in points], "width": width, "label": label}


def read_ncempy(path):
    from ncempy.io import dm
    with dm.fileDM(path, on_memory=True) as f:
        if not (f.numObjects == 1 or f.thumbnail):
            fail(f"{path}: {f.numObjects} objects and no thumbnail")
        d = f.getDataset(0)
    data = np.asarray(d["data"])
    if data.ndim != 2:
        fail(f"{path}: ncempy read {data.shape}, not a 2D image")
    (sy, sx), (uy, ux), (oy, ox) = d["pixelSize"], d["pixelUnit"], d["pixelOrigin"]
    ax = lambda s, u, o: axis(float(np.float32(s)), u, float(np.float32(o)))
    return data.astype(np.float32), ax(sx, ux, ox), ax(sy, uy, oy)


def plant(dm4, truth_path, rsciio, out):
    versions = check_reference()
    from ncempy.io import dm
    if sha256(dm.__file__) != DM_PY_SHA256:
        fail(f"{dm.__file__} is not the pinned ncempy/io/dm.py")
    os.makedirs(out, exist_ok=True)

    luts = {"gray": lut_gray(), "planted-a": lut_planted(0)}
    if (luts["planted-a"][:, :3] == 255).all(axis=1).any():
        fail("the planted LUT holds a white texel")
    for name, table in luts.items():
        table.reshape(-1).tofile(os.path.join(out, f"lut-{name}.u8"))

    images = {}

    def add(name, raw, x, y, file_name, obj="", notes=(), open_path=None):
        h, w = raw.shape
        raw.astype("<f4").tofile(os.path.join(out, f"{name}.f32"))
        images[name] = {"width": w, "height": h, "pixels": f"{name}.f32", "open": open_path, "x": x, "y": y,
                        "fileName": file_name, "object": obj, "notes": list(notes)}

    renders = []

    def render(name, image, lut, colormap, gamma, bar_expect, variants, marks=(), low=None, high=None, u=None):
        h, w = images[image]["height"], images[image]["width"]
        if u is not None and u != overlay_scale(w, h):
            fail(f"{name}: u = {u} by hand, {overlay_scale(w, h)} by the formula")
        renders.append({"name": name, "image": image, "lut": f"lut-{lut}.u8", "colormap": colormap, "windowLow": low,
                        "windowHigh": high, "gamma": gamma, "software": SOFTWARE, "u": overlay_scale(w, h),
                        "variants": [{"name": v, "scaleBar": v in ("bar", "full"), "marks": v in ("marks", "full")}
                                     for v in variants], "marks": list(marks), "bar": bar_expect})

    # -- hand-worked bars. Rule (registration): target T = min(70 u, W/4) export px; nice = the nearest of 1, 2, 5, 10 x 10^n
    # to per_pixel x T (the boundaries are at mantissa 1.5, 3.5, 7.5, an equal mantissa going up); the drawn length is
    # nice / per_pixel rounded half up; the label is the number in [1, 1000) of nm / um / mm (a metre axis is first
    # shown in nm, um or mm by the length of the image side), Angstrom, 1/nm and px are left as they are.

    # aniso512: 512 x 384, x 0.5 nm, y 0.8 nm: u = 1, T = 70, 0.5 x 70 = 35 nm, mantissa 3.5 exactly -> the boundary goes up -> 5,
    # nice 50 nm, 50 / 0.5 = 100 px, "50 nm". On y's scale (0.8) the bar would be 56 -> 50 nm in 62.5 -> 63 px.
    add("aniso512", field(512, 384, 101, 65535), NM_X, NM_Y, "aniso512.dm4", "ImageList.1 · planted")
    p6_marks = [mark("distance", [(80.5, 60.25), (230.0, 110.75)], "75.3 nm"),
                mark("angle", [(260.0, 150.0), (300.0, 200.0), (380.0, 230.0)], "63.4°"),
                mark("profile", [(100.0, 250.0), (260.0, 300.0)], "12.5 nm", width=5)]
    render("aniso512", "aniso512", "planted-a", "planted-a", 1.0, bar("50 nm", 50, "nm", 0.5, "nm", 50.0, 100),
           ["plain", "bar", "marks", "full"], p6_marks, u=1)

    # big4096: 4096 x 4096 at 5 nm: u = 8, T = min(560, 1024) = 560, 5 x 560 = 2800 nm, mantissa 2.8 -> 2, nice 2000 nm,
    # 2000 / 5 = 400 px; 2000 nm is read in um: "2 µm".
    add("big4096", field(4096, 4096, 102, 4095), axis(5.0, "nm"), axis(5.0, "nm"), "big4096.dm4", "ImageList.1 · big")
    render("big4096", "big4096", "gray", "gray", 2.2, bar("2 " + UM, 2, UM, 5.0, "nm", 2000.0, 400), ["plain", "bar"], u=8)

    # up512: 512 x 512 at 0.0004 um: u = 1, T = 70, 0.0004 x 70 = 0.028 um, mantissa 2.8 -> 2, nice 0.02 um, 0.02 / 0.0004 =
    # 50 px; 0.02 um is read in nm: "20 nm".
    add("up512", field(512, 512, 103, 65535), axis(0.0004, UM), axis(0.0004, UM), "up512.dm4", "ImageList.1 · up")
    render("up512", "up512", "planted-a", "planted-a", 0.5, bar("20 nm", 20, "nm", 0.0004, UM, 0.02, 50), ["plain", "bar"],
           low=16384.0, high=40960.0, u=1)

    # velox4096: 4096 x 4096 at 4.46179e-11 m (a Velox pixel in metres): shown in nm (the image side is 1.8e-7 m < 1 um):
    # 0.0446179 nm per pixel; u = 8, T = 560, 0.0446179 x 560 = 24.99 nm, mantissa 2.5 -> 2, nice 20 nm, 20 / 0.0446179 =
    # 448.2 px -> 448; "20 nm".
    add("velox4096", field(4096, 4096, 104, 4095), axis(4.46179e-11, "m"), axis(4.46179e-11, "m"), "velox4096.emd",
        "Velox · HAADF", ["8-bit render, not counts", "scale unvalidated (one acquisition)"])
    render("velox4096", "velox4096", "gray", "gray", 1.0, bar("20 nm", 20, "nm", 4.46179e-11 * 1e9, "nm", 20.0, 448),
           ["plain", "bar"], low=1024.0, high=3072.0, u=8)

    # ang1000: 1000 x 700 at 0.1 Angstrom: u = round(1.37) = 1, T = 70, 0.1 x 70 = 7.0 (7.000000000000001), mantissa 7 -> 5,
    # nice 5 A, 5 / 0.1 = 50 px; Angstrom is left alone: "5 Å". The file name and a mark's label carry A and u.
    add("ang1000", field(1000, 700, 105, 65535), axis(0.1, ANGSTROM), axis(0.1, ANGSTROM), "sample Å µ.dm4",
        "ImageList.1 · Å image")
    render("ang1000", "ang1000", "planted-a", "planted-a", 2.2, bar("5 " + ANGSTROM, 5, ANGSTROM, 0.1, ANGSTROM, 5.0, 50),
           ["plain", "bar", "full"], [mark("distance", [(200.0, 150.0), (420.0, 260.0)], "1.25 " + ANGSTROM)], u=1)

    # recip256: 256 x 256 at 2 1/nm: u = round(0.5) = 1 (half up), T = min(70, 64) = 64, 2 x 64 = 128, mantissa 1.28 -> 1,
    # nice 100 1/nm, 100 / 2 = 50 px; a reciprocal unit is left alone, in its canonical spelling: "100 nm^-1".
    add("recip256", field(256, 256, 106, 65535), axis(2.0, "1/nm"), axis(2.0, "1/nm"), "recip256.dm4", "ImageList.1 · recip")
    render("recip256", "recip256", "gray", "gray", 0.5, bar("100 nm⁻¹", 100, "nm⁻¹", 2.0, "nm⁻¹", 100.0, 50),
           ["plain", "bar"], u=1)

    # uncal640: 640 x 480, no calibration: u = round(0.94) = 1, T = min(70, 160) = 70 px, mantissa 7.0 -> 5, nice 50 px, 50 px.
    add("uncal640", ties(640, 480), None, None, "uncal640.tif", "")
    render("uncal640", "uncal640", "gray", "gray", 1.0, bar("50 px", 50, "px", 1.0, "px", 50.0, 50), ["plain", "bar"], u=1)

    # frac512: 512 x 512 at 0.66 nm: u = 1, T = 70, 0.66 x 70 = 46.2 nm, mantissa 4.62 -> 5, nice 50 nm,
    # 50 / 0.66 = 75.76 px -> 76 (a floor would give 75).
    add("frac512", field(512, 512, 107, 65535), axis(0.66, "nm"), axis(0.66, "nm"), "frac512.dm4", "ImageList.1 · frac")
    render("frac512", "frac512", "gray", "gray", 1.0, bar("50 nm", 50, "nm", 0.66, "nm", 50.0, 76), ["plain", "bar"], u=1)

    # nan400: 400 x 300 at 1.25 nm, 2 % NaN / inf pixels: u = round(0.59) = 1, T = 70, 87.5 nm, mantissa 8.75 -> 10, nice
    # 100 nm, 100 / 1.25 = 80 px, "100 nm".
    add("nan400", sprinkle_nonfinite(field(400, 300, 108, 65535), 1008, 65535), axis(1.25, "nm"), axis(1.25, "nm"),
        "nan400.dm4", "ImageList.1 · nan")
    render("nan400", "nan400", "planted-a", "planted-a", 1.0, bar("100 nm", 100, "nm", 1.25, "nm", 100.0, 80), ["plain", "bar"],
           low=8192.0, high=49152.0, u=1)

    # tiny64: 64 x 48, no calibration: the plate is at least 16 + 20 px wide and the image allows W/2 = 32: left out.
    add("tiny64", field(64, 48, 109, 255), None, None, "tiny64.tif", "")
    render("tiny64", "tiny64", "gray", "gray", 1.0, "left_out", ["plain", "bar"], u=1)

    # mid1024: 1024 x 1024 at 0.3 nm: u = 2, T = 140, 42 nm, mantissa 4.2 -> 5, nice 50 nm, 50 / 0.3 = 166.67 px -> 167.
    add("mid1024", field(1024, 1024, 110, 65535), axis(0.3, "nm"), axis(0.3, "nm"), "mid1024.dm4", "ImageList.1 · mid")
    render("mid1024", "mid1024", "gray", "gray", 1.0, bar("50 nm", 50, "nm", 0.3, "nm", 50.0, 167),
           ["plain", "bar", "marks", "full"], [mark(m["kind"], [(p["x"] * 2, p["y"] * 2) for p in m["points"]], m["label"], m["width"] * 2 if m["width"] > 1 else 1)
                                                for m in p6_marks], u=2)

    # -- GATE B R1 ADDITIONS (anti-vacuity). The registered ten bars have fractional parts {0, .25, .67, .76} only, x <= y in the
    # one anisotropic plant, and never a y-only axis or two spellings of one number.
    # tie512: x 0.8 nm, y 0.5 nm (x COARSER than y): u = 1, T = 70, 0.8 x 70 = 56 nm, mantissa 5.6 -> 5, nice 50 nm,
    # 50 / 0.8 = 62.5 EXACTLY (a tie): half away from zero gives 63; half to even gives 62; the bar on y would be 100.
    add("tie512", field(512, 512, 111, 65535), axis(0.8, "nm"), axis(0.5, "nm"), "tie512.dm4", "ImageList.1 · tie")
    render("tie512", "tie512", "gray", "gray", 1.0, bar("50 nm", 50, "nm", 0.8, "nm", 50.0, 63), ["plain", "bar"], u=1)
    # frac40: x 0.672 nm: T = 70, 47.04 nm, mantissa 4.7 -> 5, nice 50 nm, 50 / 0.672 = 74.4048 -> 74 (a bias of +0.2 gives 75).
    add("frac40", field(512, 512, 112, 65535), axis(0.672, "nm"), axis(0.672, "nm"), "frac40.dm4", "ImageList.1 · frac40")
    render("frac40", "frac40", "gray", "gray", 1.0, bar("50 nm", 50, "nm", 0.672, "nm", 50.0, 74), ["plain", "bar"], u=1)
    # unitsmix512: x 0.5 nm, y 0.5 Angstrom: the same number, two units: anisotropic by the rule (the units differ); the bar is x's:
    # 35 nm -> 50 nm, 100 px.
    add("unitsmix512", field(512, 384, 113, 65535), axis(0.5, "nm"), axis(0.5, ANGSTROM), "unitsmix512.dm4", "ImageList.1 · mix")
    render("unitsmix512", "unitsmix512", "gray", "gray", 1.0, bar("50 nm", 50, "nm", 0.5, "nm", 50.0, 100), ["plain", "bar"], u=1)
    # yonly512: no x axis, y 0.8 nm: the bar counts pixels (the unit is x's): 70 px -> 50 px; y_scale is still the file's.
    add("yonly512", field(512, 384, 114, 65535), None, axis(0.8, "nm"), "yonly512.dm4", "ImageList.1 · yonly")
    render("yonly512", "yonly512", "gray", "gray", 1.0, bar("50 px", 50, "px", 1.0, "px", 50.0, 50), ["plain", "bar"], u=1)

    # -- the real images: the planted DM fixture and one RosettaSciIO GMS image; Swift opens them with ImageOpening and
    # dumps what it opened; the truth is what ncempy reads (profile-parity's reading).
    with open(truth_path) as fh:
        truth = json.load(fh)
    if sha256(dm4) != truth["file_sha256"]:
        fail(f"{os.path.basename(dm4)}: sha256 differs from its truth file")
    planted = np.array(truth["pixels_row_major"], dtype=np.float64).reshape(truth["height"], truth["width"])
    if not np.array_equal(planted, np.array([[1000 * r + c - 12000 for c in range(truth["width"])]
                                             for r in range(truth["height"])], dtype=np.float64)):
        fail("the planted DM fixture's values are not row*1000 + col - 12000")
    bits = lambda a: float(np.frombuffer(int(a["scale_f32_bits"], 16).to_bytes(4, "little"), dtype="<f4")[0])
    fx = axis(bits(truth["x"]), truth["x"]["units"], float(truth["x"]["origin"]))
    fy = axis(bits(truth["y"]), truth["y"]["units"], float(truth["y"]["origin"]))
    dm_data, dm_x, dm_y = read_ncempy(dm4)
    if not (np.array_equal(dm_data, planted.astype(np.float32)) and dm_x == fx and dm_y == fy):
        fail("ncempy's reading of the planted DM fixture differs from its truth file")
    add("planted2d", planted.astype(np.float32), fx, fy, "planted-2d.dm4", "", open_path=os.path.abspath(dm4))

    registry = os.path.join(rsciio, "rsciio", "tests", "registry.txt")
    if sha256(registry) != REGISTRY_SHA256:
        fail("rsciio registry.txt is not the lock's")
    rel, want_sha = STEM_IMAGE
    stem_path = os.path.join(rsciio, "rsciio", "tests", "data", rel)
    if sha256(stem_path) != want_sha or f"'{rel}' {want_sha}" not in open(registry).read():
        fail(f"{rel}: not the pinned RosettaSciIO file")
    s_data, s_x, s_y = read_ncempy(stem_path)
    add("stem", s_data, s_x, s_y, os.path.basename(stem_path), "", open_path=os.path.abspath(stem_path))

    # left out: the bar is 0.1 nm = 8 px at 0.0123 nm (planted2d, 40 x 24: 8 + 16 > 20) and 5 nm = 20 px at 0.2485 nm (stem,
    # 68 x 68: 20 + 16 > 34).
    render("planted2d", "planted2d", "gray", "gray", 1.0, "left_out", ["plain", "bar"], u=1)
    render("stem", "stem", "gray", "gray", 1.0, "left_out", ["plain", "bar"], u=1)

    # -- P5: black plants, strokes and rings; coordinates are image points (x column, y row, centres at integers).
    def strokes(scale):
        c30 = math.cos(math.radians(30.0))
        a = (60.4 * scale, 300.2 * scale)
        b = (260.3 * scale, 470.6 * scale)
        return [("horizontal", (40.0 * scale, 80.3 * scale), (200.0 * scale, 80.3 * scale)),
                ("vertical", (300.6 * scale, 60.0 * scale), (300.6 * scale, 220.0 * scale)),
                ("30deg", a, (a[0] + 200.0 * scale * c30, a[1] + 100.0 * scale)),
                ("30deg-up", b, (b[0] + 200.0 * scale * c30, b[1] - 100.0 * scale))]

    ring_points = [(100.3, 160.7), (200.0, 200.0), (400.25, 120.75), (450.5, 250.5)]
    p5 = {}
    for plant_name, side, scale in (("p5-u1", 512, 1), ("p5-u2", 1024, 2)):
        add(plant_name, np.zeros((side, side), np.float32), None, None, plant_name + ".tif", "")
        ms = [mark("distance", [p, q], "") for _, p, q in strokes(scale)]
        ms += [mark("distance", [(x * scale, y * scale)] * 2, "") for x, y in ring_points]
        render(plant_name, plant_name, "gray", "gray", 1.0, None, ["marks"], ms, u=scale)
        p5[plant_name] = {"strokes": [{"name": n, "p0": list(p), "p1": list(q)} for n, p, q in strokes(scale)],
                          "rings": [[x * scale, y * scale] for x, y in ring_points]}
    for r in renders:
        if r["name"] in p5:
            r["p5"] = p5[r["name"]]

    # -- GATE B R1: P5x (a profile's band: its width and its direction; an angle's two arms) on black plants, no labels.
    def p5x_layout(s):
        c30 = math.cos(math.radians(30.0))
        a = (60.4 * s, 340.2 * s)
        bands = [("horizontal", (40.0 * s, 260.3 * s), (220.0 * s, 260.3 * s), 7 * s),
                 ("vertical", (300.6 * s, 40.0 * s), (300.6 * s, 200.0 * s), 9 * s),
                 ("30deg", a, (a[0] + 200.0 * s * c30, a[1] + 100.0 * s), 11 * s)]
        arm_a, arm_v, arm_c = (60.4 * s, 150.6 * s), (150.7 * s, 60.3 * s), (240.2 * s, 140.9 * s)
        return bands, (arm_a, arm_v, arm_c)
    p5x = {}
    for plant_name, side, scale in (("p5x-u1", 512, 1), ("p5x-u2", 1024, 2)):
        bands, (arm_a, arm_v, arm_c) = p5x_layout(scale)
        add(plant_name, np.zeros((side, side), np.float32), None, None, plant_name + ".tif", "")
        ms = [mark("profile", [p, q], "", width=wd) for _, p, q, wd in bands] + [mark("angle", [arm_a, arm_v, arm_c], "")]
        render(plant_name, plant_name, "gray", "gray", 1.0, None, ["marks"], ms, u=scale)
        p5x[plant_name] = {"strokes": [{"name": "angle-arm-1", "p0": list(arm_a), "p1": list(arm_v)},
                                       {"name": "angle-arm-2", "p0": list(arm_v), "p1": list(arm_c)}], "rings": []}
        renders[-1]["p5"] = p5x[plant_name]
        renders[-1]["p5b"] = [{"name": n, "p0": list(p), "p1": list(q), "width": wd} for n, p, q, wd in bands]

    # -- GATE B R1: P7 (the label drawn beside a mark, and the scale bar's, against the same string drawn UPRIGHT in a plain
    # CoreGraphics context by the harness). Anchors chosen so the label boxes sit on whole pixels.
    p7_marks = {
        "p7-u1": [mark("distance", [(100.0, 120.5), (251.0, 120.5)], "75.3 nm"),
                  mark("profile", [(100.0, 250.5), (251.0, 250.5)], "12.5 nm", width=5),
                  mark("angle", [(60.0, 400.5), (150.5, 330.5), (241.0, 400.5)], "63.4\u00b0")],
        "p7-u2": [mark("distance", [(200.0, 241.5), (503.0, 241.5)], "75.3 nm"),
                  mark("profile", [(200.0, 501.5), (503.0, 501.5)], "12.5 nm", width=10),
                  mark("angle", [(120.0, 801.5), (301.5, 661.5), (483.0, 801.5)], "63.4\u00b0")]}
    for plant_name, side, scale, label in (("p7-u1", 512, 1, "50 px"), ("p7-u2", 1024, 2, "100 px")):
        add(plant_name, np.zeros((side, side), np.float32), None, None, plant_name + ".tif", "")
        render(plant_name, plant_name, "gray", "gray", 1.0, bar(label, int(label.split()[0]), "px", 1.0, "px", float(label.split()[0]),
                                                                 int(label.split()[0])), ["marks", "bar"], p7_marks[plant_name], u=scale)
        renders[-1]["p7"] = True

    # -- CSV cases
    add("ramp", ramp(), NM_X, NM_Y, "ramp.dm4", "ImageList.2 · ramp")
    add("wave-uncal", wave(), None, None, "wave-uncal.tif", "")
    add("wave-units", wave(), NM_X, axis(0.8, UM), "wave-units.dm4", "")
    nan_wave = wave()
    nan_wave[20, 15] = np.nan
    nan_wave[30, 10] = np.nan
    add("wave-nan", nan_wave, NM_X, NM_Y, "wave-nan.dm4", "")
    add("csv-evil", wave(40, 30), axis(0.25, 'a,b"c'), axis(0.25, 'a,b"c'),
        "evil\r\nname" + chr(0x2028) + chr(0x85) + "\x7f.dm4",
        "obj\tx · \x01", ["Unvalidated scale (test)", "second; note"])
    csvs = []
    ramp_fn = {"fn": "ramp"}

    def csv_case(name, image, start, end, width, shown=None, analytic=None, empty=False):
        csvs.append({"name": name, "image": image, "start": {"x": start[0], "y": start[1]}, "end": {"x": end[0], "y": end[1]},
                     "width": width, "shown": shown, "software": SOFTWARE, "analytic": analytic, "empty": empty})

    csv_case("csv-ramp", "ramp", (7.8, 3.3), (28.4, 46.3), 3, analytic="ramp")
    csv_case("csv-ramp-w4", "ramp", (6.25, 5.5), (30.0, 40.0), 4, analytic="ramp")
    csv_case("csv-wave-uncal", "wave-uncal", (3.0, 4.0), (30.0, 48.0), 2)
    csv_case("csv-wave-units", "wave-units", (3.5, 4.5), (31.0, 47.5), 3)
    csv_case("csv-velox", "velox4096", (100.5, 200.25), (3900.75, 3000.5), 5, shown={"unit": "nm", "factor": 1e9})
    csv_case("csv-evil", "csv-evil", (2.5, 3.5), (36.0, 25.5), 1)
    # through the two NaN pixels (column 15, row 20) and (column 10, row 30): x = 17.5 - 10 t, y = 15 + 20 t at t = 1/4 and 3/4
    csv_case("csv-nan", "wave-nan", (17.5, 15.0), (7.5, 35.0), 1)
    csv_case("csv-empty", "ramp", (1.0, 1.0), (2e15, 1.0), 1, empty=True)
    csv_case("csv-dm4", "planted2d", (3.3, 2.5), (36.1, 20.4), 3, analytic="dm4")
    csv_case("csv-stem", "stem", (4.0, 60.0), (60.3, 8.2), 3)

    # -- the Results case (V1-10 slice 3, R-P1): a 128 x 128 lattice with two non-dyadic frequencies (0.1731 and 0.0627 cycles per
    # pixel: a peak 22.2 bins right and 8.0 bins below the centre of the whole image's spectrum, 11.1 and 4.0 on a 64 x 64 crop), the
    # calibration anisotropic (x 0.0731 nm, y 0.0789 nm). Three marks of every kind with non-dyadic points (an uncalibrated pair
    # for the pixel grid, an angle whose arm has zero length), three spot clicks (the peak, the peak on a crop, a click on the DC:
    # refused), and one raw row of planted bit patterns: +0, -0, NaN, +inf, -inf, the smallest and the largest Double, 0.1 and 1/3,
    # a words-only entry, a unit with a comma, and a label, a text and a refusal each with a comma, a quote and a newline.
    gy, gx = np.mgrid[0:128, 0:128].astype(np.float64)
    lattice = (1000 + 120 * np.cos(2 * np.pi * (0.1731 * gx + 0.0627 * gy)) + 0.01 * gx).astype(np.float32)
    add("results-lattice", lattice, axis(0.0731, "nm"), axis(0.0789, "nm"), "results.dm4", "ImageList.1 · lattice")
    # the same pixels in a file whose reader says it is unvalidated: every claim the CSV makes carries that qualifier
    add("results-lattice-unvalidated", lattice, axis(0.0731, "nm"), axis(0.0789, "nm"), "results-unvalidated.dm4",
        "ImageList.1 · lattice", notes=["Unvalidated scale (test)"])

    def hexbits(v):
        return struct.pack(">d", v).hex()

    def raw_entry(name, v, unit="", text=""):
        return {"name": name, "bits": None if v is None else hexbits(v), "unit": unit, "text": text}

    results_marks = [
        {"kind": "distance", "id": "mark:D1", "label": "Distance 1", "points": [[12.3, 45.6], [101.7, 23.1]], "lineage": "s1"},
        {"kind": "distance", "id": "mark:D2", "label": "Distance 2", "points": [[3.7, 9.1], [64.9, 117.3]], "lineage": None,
         "uncalibrated": True},
        {"kind": "angle", "id": "mark:A1", "label": "Angle 1", "points": [[20.5, 30.1], [60.7, 62.3], [110.9, 40.2]], "lineage": "s2"},
        {"kind": "angle", "id": "mark:A2", "label": "Angle 2", "points": [[20.5, 30.1], [60.7, 62.3], [110.9, 40.2]],
         "lineage": None, "uncalibrated": True},
        {"kind": "angle", "id": "mark:A3", "label": "Angle 3", "points": [[5.5, 5.5], [5.5, 5.5], [9.1, 2.3]], "lineage": None},
        {"kind": "profile", "id": "mark:P1", "label": "Profile 1", "points": [[8.4, 100.2], [120.6, 77.7]], "width": 5, "lineage": "s3"},
    ]
    results_spots = [
        {"id": "spot:S1", "number": 1, "click": [72, 86], "crop": None},
        {"id": "spot:S2", "number": 2, "click": [36, 43], "crop": {"row": 20, "col": 10, "height": 64, "width": 64}},
        {"id": "spot:S3", "number": 3, "click": [64, 64], "crop": None},
    ]
    results_raw = [{
        "product": "distance", "id": "raw:1", "label": "odd, \"label\"\nline two", "lineage": "s7",
        "refusal": "words, with \"quotes\"\nand a newline",
        "entries": [raw_entry("zero", 0.0, "px"), raw_entry("negzero", -0.0, "px"), raw_entry("nan", float("nan"), "deg"),
                    raw_entry("inf", float("inf"), "m"), raw_entry("-inf", float("-inf"), "m"),
                    raw_entry("tiny", 5e-324, "m"), raw_entry("huge", 1.7976931348623157e308, "m"),
                    raw_entry("tenth", 0.1, "nm"), raw_entry("third", 1.0 / 3.0, "nm,per \"px\""),
                    raw_entry("words", None, "", "a, \"b\"\nc")],
    }]
    results = [{"name": "results", "image": "results-lattice", "software": SOFTWARE, "session": "Saved at 14:03 to results.dm4.mactem.h5.",
                "marks": results_marks, "spots": results_spots, "raw": results_raw},
               {"name": "results-unvalidated", "image": "results-lattice-unvalidated", "software": SOFTWARE,
                "session": "Not saved.", "marks": [results_marks[0], results_marks[2], results_marks[5]],
                "spots": results_spots[:1], "raw": []}]

    manifest = {"reference": versions, "images": images, "renders": renders, "csvs": csvs, "results": results}
    with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False)
    print(f"reference: {len(images)} images, {len(renders)} render cases, {len(csvs)} CSV cases, {len(results)} Results cases; {versions}")


# ---------------------------------------------------------------------------------------------------------------------
# check

class Report:
    def __init__(self):
        self.failures = 0
        self.checks = 0
        self.family_failures = {}
        self.family_checks = {}

    def check(self, ok, name, detail=""):
        self.checks += 1
        family = name.split("/")[0]
        self.family_checks[family] = self.family_checks.get(family, 0) + 1
        if ok:
            return True
        self.failures += 1
        self.family_failures[family] = self.family_failures.get(family, 0) + 1
        print(f"  FAIL  {name}: {detail}")
        return False


def parse_png(data):
    """(signature ok, [(type, body, crc ok)], consumed everything) of a PNG, chunk by chunk, CRCs recomputed here."""
    chunks, pos = [], 8
    while pos + 12 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        ctype, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]
        crc = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0]
        chunks.append((ctype.decode("latin-1"), body, zlib.crc32(ctype + body) & 0xFFFFFFFF == crc))
        pos += 12 + length
    return data[:8] == b"\x89PNG\r\n\x1a\n", chunks, pos == len(data)


def png_text(chunks):
    out = {}
    for ctype, body, _ in chunks:
        if ctype == "tEXt":
            key, _, value = body.partition(b"\0")
            out[key.decode("latin-1")] = value.decode("latin-1")
        elif ctype == "iTXt":
            key, rest = body.split(b"\0", 1)
            flag, rest = rest[0], rest[2:]                      # compression flag, method
            _, rest = rest.split(b"\0", 1)                      # language tag
            _, text = rest.split(b"\0", 1)                      # translated keyword
            if flag == 0:
                out[key.decode("utf-8")] = text.decode("utf-8")
    return out


def sorted_keys_everywhere(pairs):
    keys = [k for k, _ in pairs]
    if keys != sorted(keys):
        raise ValueError("keys not sorted: " + str(keys))
    return dict(pairs)


def longest_run(mask_row):
    """The longest run of True in a 1-D boolean array."""
    if not mask_row.any():
        return 0
    padded = np.concatenate(([0], mask_row.astype(np.int8), [0]))
    edges = np.flatnonzero(np.diff(padded))
    return int((edges[1::2] - edges[0::2]).max())


def run_from(mask_row, start):
    k = 0
    while start + k < len(mask_row) and mask_row[start + k]:
        k += 1
    return k


def f32(v):
    return None if v is None else float(np.float32(v))


class Loader:
    def __init__(self, planted, out):
        self.planted, self.out = planted, out
        self.manifest = json.load(open(os.path.join(planted, "manifest.json"), encoding="utf-8"))
        self.cache = {}

    def raw(self, image):
        if image not in self.cache:
            img = self.manifest["images"][image]
            self.cache[image] = np.fromfile(os.path.join(self.planted, img["pixels"]), dtype="<f4").reshape(img["height"], img["width"])
        return self.cache[image]

    def identity(self, image):
        """fileName, object, notes: planted for synthetic images; for the real ones, what Swift opened (the readers' naming
        of the object and their notes are tools/parity/dm4-reader-parity's to check)."""
        img = self.manifest["images"][image]
        if img["open"]:
            path = os.path.join(self.out, "opened", f"{image}.json")
            if os.path.exists(path):
                o = json.load(open(path, encoding="utf-8"))
                return {"fileName": o["fileName"], "object": o["source"], "notes": o["notes"]}
        return {"fileName": img["fileName"], "object": img["object"], "notes": img["notes"]}


def expected_description(r, img, ident, variant, canvas, raw_range, fractions):
    def ax(a):
        return {"scale": a["scale"], "units": a["units"], "origin": a["origin"]} if axis_calibrated(a) else None
    xs, ys = ax(img["x"]), ax(img["y"])
    aniso = bool(xs and ys and (xs["scale"] != ys["scale"] or xs["units"] != ys["units"]))
    return {"software": r["software"], "file": ident["fileName"], "object": ident["object"], "width": img["width"],
            "height": img["height"], "x_scale": xs, "y_scale": ys,
            "raw_range": None if raw_range is None else [float(raw_range[0]), float(raw_range[1])],
            "colormap": r["colormap"],
            "window": {"low": f32(r["windowLow"]), "high": f32(r["windowHigh"]),
                       "fractions": [float(fractions[0]), float(fractions[1])]},
            "gamma": r["gamma"], "masked_pixels": int((canvas < 0).sum()), "notes": ident["notes"],
            "overlay_scale": r["u"], "anisotropic": aniso, "validation": VALIDATION_PNG, "lineage": LINEAGE_PNG}


BAR_KEYS = {"label", "value", "unit", "per_pixel", "per_pixel_unit", "length_px", "drawn_px", "x0", "top", "height_px", "measures"}


def check_png_format(rep, tag, data, r, img, meta_expect, variant, im, png_path):
    """P4-format: the container (signature, CRCs, IHDR, sRGB tag, the three text chunks), Pillow's reading, and the Description."""
    sig_ok, chunks, whole = parse_png(data)
    rep.check(sig_ok and whole and all(ok for _, _, ok in chunks), f"P4-format/{tag}/chunks",
              f"signature {sig_ok}, whole file consumed {whole}, bad CRCs: {[t for t, _, ok in chunks if not ok]}")
    ihdr = next((b for t, b, _ in chunks if t == "IHDR"), b"\0" * 13)
    w, h, depth, ctype = struct.unpack(">IIBB", ihdr[:10])
    rep.check((w, h, depth, ctype) == (img["width"], img["height"], 8, 2), f"P4-format/{tag}/ihdr",
              f"{w} x {h}, bit depth {depth}, colour type {ctype} (want {img['width']} x {img['height']}, 8, 2 = RGB)")
    types = [t for t, _, _ in chunks]
    first_idat = types.index("IDAT") if "IDAT" in types else len(types)
    # the standard sRGB chunk, or an iCCP whose profile is named as the sRGB profile (a profile with sRGB in its name, such as
    # a linear one, is another colour space)
    tagged = any(t == "sRGB" and i < first_idat for i, (t, _, _) in enumerate(chunks)) \
        or any(t == "iCCP" and i < first_idat and b.split(b"\0", 1)[0] == b"sRGB IEC61966-2.1" for i, (t, b, _) in enumerate(chunks))
    rep.check(tagged, f"P4-format/{tag}/srgb", f"no sRGB or sRGB iCCP chunk before the image data (chunks: {types[:8]})")
    rep.check(im.mode == "RGB" and im.size == (img["width"], img["height"]), f"P4-format/{tag}/pillow",
              f"Pillow reads mode {im.mode}, size {im.size}")
    text = png_text(chunks)
    ident_file = meta_expect["file"]
    rep.check({"Title", "Software", "Description"} <= set(text), f"P4-format/{tag}/text-chunks", f"chunks {sorted(text)}")
    rep.check(text.get("Software") == sanitize(r["software"]) and text.get("Title") == sanitize(ident_file),
              f"P4-format/{tag}/title-software", f"{text.get('Software')!r}, {text.get('Title')!r}")
    pil_text = getattr(im, "text", {})
    rep.check(all(pil_text.get(k) == text.get(k) for k in ("Title", "Software", "Description")), f"P4-format/{tag}/pillow-text",
              "Pillow's im.text differs from the chunks read here: " + str({k: pil_text.get(k) == text.get(k) for k in text}))
    try:
        meta = json.loads(text["Description"], object_pairs_hook=sorted_keys_everywhere)
    except Exception as e:                                    # noqa: BLE001 - any failure to read it is the finding
        rep.check(False, f"P4-format/{tag}/description", f"not JSON with sorted keys: {e}")
        return None
    mismatches = [f"{k}: {meta.get(k)!r} vs {v!r}" for k, v in meta_expect.items() if meta.get(k) != v]
    rep.check(not mismatches and set(meta) == set(meta_expect) | {"scale_bar", "marks"}, f"P4-format/{tag}/meta",
              "; ".join(mismatches[:6]) + f" (keys {sorted(set(meta) ^ (set(meta_expect) | {'scale_bar', 'marks'}))})")
    # the bar and marks entries' shapes (P3 and the marks' parameters read their values)
    wants_bar = next(v for v in r["variants"] if v["name"] == variant)["scaleBar"]
    sb = meta.get("scale_bar")
    if not wants_bar:
        rep.check(sb is None, f"P4-format/{tag}/scale-bar-entry", f"{sb!r}, the bar was not asked for")
    elif r["bar"] == "left_out":
        rep.check(sb == {"left_out": "the image is too small"}, f"P4-format/{tag}/scale-bar-entry", f"{sb!r}")
    else:
        rep.check(isinstance(sb, dict) and set(sb) == BAR_KEYS, f"P4-format/{tag}/scale-bar-entry", f"{sb!r}")
    wants_marks = next(v for v in r["variants"] if v["name"] == variant)["marks"]
    mk = meta.get("marks")
    if not wants_marks:
        rep.check(mk is None, f"P4-format/{tag}/marks-entry", f"{mk!r}, marks were not asked for")
    else:
        ok = isinstance(mk, list) and len(mk) == len(r["marks"])
        if ok:
            for got, want in zip(mk, r["marks"]):
                ok = ok and got["kind"] == want["kind"] and got["width"] == want["width"] and got["label"] == want["label"] \
                    and len(got["points"]) == len(want["points"]) \
                    and all(float(g["x"]) == w_["x"] and float(g["y"]) == w_["y"] for g, w_ in zip(got["points"], want["points"]))
        rep.check(ok, f"P4-format/{tag}/marks-entry", f"{mk!r} vs the planted marks")
    return meta


def check_p3(rep, stats, r, img, arr, meta, rendered):
    """P3: the bar against its label, read back from the pixels."""
    name, w, h, u = r["name"], img["width"], img["height"], r["u"]
    expect, sb = r["bar"], meta["scale_bar"]
    if expect == "left_out":
        rep.check(sb == {"left_out": "the image is too small"} and rendered["barLeftOut"] and rendered.get("bar") is None,
                  f"P3-length/{name}/left-out", f"metadata {sb!r}, harness plan {rendered.get('bar')!r}, barLeftOut {rendered['barLeftOut']}")
        return
    if not (isinstance(sb, dict) and set(sb) == BAR_KEYS):
        rep.check(False, f"P3-length/{name}", f"no bar in the metadata ({sb!r}); the case must draw {expect['label']!r}")
        rep.check(False, f"P3-drawn/{name}", f"no bar in the metadata ({sb!r})")
        return
    # -- the label and the planned length: planted by hand
    want_len = expect["nice"] / expect["per_pixel"]
    close = lambda a, b: abs(a - b) <= 1e-12 * abs(b)
    bad = []
    if sb["label"] != expect["label"]:
        bad.append(f"label {sb['label']!r} vs {expect['label']!r}")
    if not close(sb["value"], expect["value"]) or sb["unit"] != expect["unit"]:
        bad.append(f"value/unit {sb['value']!r} {sb['unit']!r} vs {expect['value']!r} {expect['unit']!r}")
    if not close(sb["per_pixel"], expect["per_pixel"]) or sb["per_pixel_unit"] != expect["per_pixel_unit"]:
        bad.append(f"per pixel {sb['per_pixel']!r} {sb['per_pixel_unit']!r} vs {expect['per_pixel']!r} {expect['per_pixel_unit']!r}")
    if not close(sb["length_px"], want_len):
        bad.append(f"planned length {sb['length_px']!r} vs nice/per_pixel = {want_len!r}")
    if sb["measures"] != "x":
        bad.append(f"measures {sb['measures']!r}")
    plan = rendered.get("bar")
    if plan is None or (plan["label"], plan["drawnPixels"], plan["overlayScale"]) != (sb["label"], sb["drawn_px"], u) \
            or plan["lengthPixels"] != sb["length_px"]:
        bad.append(f"the plan the harness got back ({plan!r}) differs from the metadata")
    # -- the pixels: the label's length against the white run, within one export pixel
    x0, top, hp = 16 * u, h - 15 * u, 2 * u
    region_top = h - h // 3 - 1
    region = arr[region_top:, :w // 2 + 1]
    white = (region == 255).all(axis=2)
    drawn = sb["drawn_px"]
    longest = max(longest_run(row) for row in white)
    label_size = UNIT_SIZE.get(sb["unit"])
    x_axis = img["x"]
    if axis_calibrated(x_axis):
        file_size = UNIT_SIZE.get(x_axis["units"])
        per_px_si = x_axis["scale"] * file_size[1] if file_size else None
        dim_ok = file_size is not None and label_size is not None and file_size[0] == label_size[0]
    else:
        file_size, per_px_si, dim_ok = ("px", 1.0), 1.0, label_size is not None and label_size[0] == "px"
        per_px_si = 1.0
    if not dim_ok:
        bad.append(f"cannot compare the label's unit {sb['unit']!r} with the x axis ({x_axis!r})")
    else:
        label_len = sb["value"] * label_size[1]
        run_len = longest * per_px_si
        stats["p3_max"] = max(stats.get("p3_max", 0.0), abs(run_len - label_len) / per_px_si)
        if not abs(run_len - label_len) <= per_px_si:
            bad.append(f"white run {longest} px x x scale = {run_len:.6g} vs the label's {label_len:.6g} (one pixel = {per_px_si:.6g})")
    rep.check(not bad, f"P3-length/{name}", "; ".join(bad))
    # -- the run against the drawn length, exactly, on every row of the bar; geometry; rounding
    bad = []
    if (sb["x0"], sb["top"], sb["height_px"]) != (x0, top, hp):
        bad.append(f"metadata geometry {(sb['x0'], sb['top'], sb['height_px'])} vs {(x0, top, hp)}")
    if drawn != expect["drawn"] or drawn != int(math.floor(sb["length_px"] + 0.5)):
        bad.append(f"drawn {drawn} vs planted {expect['drawn']}, round-half-up of the planned length {sb['length_px']!r} = "
                   f"{int(math.floor(sb['length_px'] + 0.5))}")
    runs = []
    for row in range(top, top + hp):
        mask = white[row - region_top]
        run = run_from(mask, x0)
        runs.append(run)
        if run != drawn or (x0 > 0 and mask[x0 - 1]) or (x0 + drawn < len(mask) and mask[x0 + drawn]):
            bad.append(f"row {row - top} of the bar: white run {run} from x0 = {x0} (want exactly {drawn}; neighbours "
                       f"{bool(mask[x0 - 1])}/{bool(mask[x0 + drawn]) if x0 + drawn < len(mask) else None})")
    if not (top - 1 - region_top >= 0 and not white[top - 1 - region_top][x0:x0 + drawn].any()
            and not white[top + hp - region_top][x0:x0 + drawn].any()):
        bad.append("white above or below the bar's rows")
    if longest != drawn:
        bad.append(f"the longest white run in the plate region is {longest}, the drawn length {drawn}")
    rep.check(not bad, f"P3-drawn/{name}", "; ".join(bad[:4]))
    stats["p3_bars"] = stats.get("p3_bars", 0) + 1


def check_p5(rep, stats, r, arr):
    name, u = r["name"], r["u"]
    weight = arr[..., 0].astype(np.float64) / 255.0
    worst = 0.0
    for s in r["p5"]["strokes"]:
        (x0, y0), (x1, y1) = s["p0"], s["p1"]
        dx, dy = x1 - x0, y1 - y0
        length = math.hypot(dx, dy)
        offsets, sums = [], []
        margin = 5 * u + 2
        half = int(math.ceil(3 * u)) + 2
        if abs(dx) >= abs(dy):
            cos = abs(dx) / length
            for col in range(int(math.ceil(min(x0, x1) + margin)), int(math.floor(max(x0, x1) - margin)) + 1):
                line = y0 + (col - x0) * dy / dx
                j0 = int(round(line)) - half
                cut = weight[j0:j0 + 2 * half + 1, col]
                total = cut.sum()
                sums.append(total / (1.5 * u / cos))
                offsets.append(((cut * np.arange(j0, j0 + 2 * half + 1)).sum() / total - line) * cos if total > 0 else 9.0)
        else:
            cos = abs(dy) / length
            for row in range(int(math.ceil(min(y0, y1) + margin)), int(math.floor(max(y0, y1) - margin)) + 1):
                line = x0 + (row - y0) * dx / dy
                i0 = int(round(line)) - half
                cut = weight[row, i0:i0 + 2 * half + 1]
                total = cut.sum()
                sums.append(total / (1.5 * u / cos))
                offsets.append(((cut * np.arange(i0, i0 + 2 * half + 1)).sum() / total - line) * cos if total > 0 else 9.0)
        peak = max(abs(o) for o in offsets)
        worst = max(worst, peak)
        thin = [x for x in sums if not 0.75 <= x <= 1.25]
        rep.check(peak <= 0.15 and not thin, f"P5-stroke/{name}/{s['name']}",
                  f"yellow-weighted centroid {peak:.4f} px from the line through the pixel centres (band 0.15) over "
                  f"{len(offsets)} cross-sections; {len(thin)} cross-sections whose weight is not 1.5 u / cos of a stroke")
    stats["p5_stroke"] = max(stats.get("p5_stroke", 0.0), worst)
    worst = 0.0
    for k, (cx, cy) in enumerate(r["p5"]["rings"]):
        half = int(math.ceil(4.5 * u)) + 3
        xi, yi = int(round(cx)), int(round(cy))
        sub = weight[yi - half:yi + half + 1, xi - half:xi + half + 1]
        total = sub.sum()
        if total <= 0.5 * 2 * math.pi * 3 * u * 1.5 * u:
            rep.check(False, f"P5-ring/{name}/{k}", f"no ring near ({cx}, {cy}): yellow weight {total:.2f}")
            continue
        xs = np.arange(xi - half, xi + half + 1)
        ys = np.arange(yi - half, yi + half + 1)
        gx = (sub.sum(axis=0) * xs).sum() / total
        gy = (sub.sum(axis=1) * ys).sum() / total
        err = max(abs(gx - cx), abs(gy - cy))
        worst = max(worst, err)
        rep.check(err <= 0.15, f"P5-ring/{name}/{k}", f"ring centre ({gx:.3f}, {gy:.3f}) vs the point ({cx}, {cy}): {err:.3f} px (band 0.15)")
    stats["p5_ring"] = max(stats.get("p5_ring", 0.0), worst)


def check_p5_band(rep, stats, r, arr):
    """P5-band: a profile's band is `width` px across, centred on the line, and yellow at 18 %: away from the line itself (outside
    the black under-stroke and its antialiasing), the red channel of every pixel equals 46 (= 0.18 x 255) times the share of the
    pixel the band's rectangle covers (an 8 x 8 supersample worked out here), within 12 levels. A band twice as wide, a band
    along the line instead of across it, or no band at all, differ from it by up to 46."""
    u = r["u"]
    red = arr[..., 0].astype(np.float64)
    h, w = red.shape
    n = 8
    sub = (np.arange(n) + 0.5) / n
    for b in r["p5b"]:
        (x0, y0), (x1, y1), width = b["p0"], b["p1"], b["width"]
        half = width / 2
        dx, dy = x1 - x0, y1 - y0
        length = math.hypot(dx, dy)
        nx, ny = -dy / length, dx / length
        pad = int(math.ceil(half)) + 6 * u
        xs = slice(max(0, int(min(x0, x1)) - pad), min(w, int(max(x0, x1)) + pad + 1))
        ys = slice(max(0, int(min(y0, y1)) - pad), min(h, int(max(y0, y1)) + pad + 1))
        jj, ii = np.mgrid[ys, xs]
        # pixel (i, j) covers [i, i + 1] x [j, j + 1] in drawing coordinates; the image point (x, y) is drawn at (x + 0.5, y + 0.5)
        cover = np.zeros(ii.shape)
        for oy in sub:
            for ox in sub:
                px, py = ii + ox - (x0 + 0.5), jj + oy - (y0 + 0.5)
                s_ = (px * dx + py * dy) / length
                d_ = px * nx + py * ny
                cover += ((s_ >= 0) & (s_ <= length) & (np.abs(d_) <= half))
        cover /= n * n
        s = ((ii - x0) * dx + (jj - y0) * dy) / length
        d = (ii - x0) * nx + (jj - y0) * ny
        margin = 5 * u + 3
        region = (s >= margin) & (s <= length - margin) & (np.abs(d) > 1.75 * u + 1.0) & (np.abs(d) < half + 4)
        err = np.abs(red[ys, xs] - 45.9 * cover)[region]
        worst = float(err.max()) if err.size else 999.0
        rep.check(err.size > 0 and worst <= 12.0, f"P5-band/{r['name']}/{b['name']}",
                  f"the band's red channel differs from 46 x the share of each pixel a {width} px wide rectangle along the line covers "
                  f"by up to {worst:.1f} levels over {err.size} pixels (band 12; 46 = a band that is missing or in the wrong place)")
        stats["p5_band"] = max(stats.get("p5_band", 0.0), worst)


def check_p7(rep, stats, r, img, shots, out):
    """P7-label: the text beside a mark and the scale bar's label equal, pixel for pixel (within 2 levels), the same string drawn
    upright by the harness in a plain CoreGraphics context (no flip), at the place the registration puts them."""
    u, w, h = r["u"], img["width"], img["height"]
    info = json.load(open(os.path.join(out, f"{r['name']}.labels.json"), encoding="utf-8"))

    def bitmap(entry):
        return np.fromfile(os.path.join(out, entry["rgb"]), dtype=np.uint8).reshape(entry["boxHeight"], entry["boxWidth"], 3).astype(np.int16)
    worst = 0
    labelled = [m for m in r["marks"] if m["label"]]
    for k, (m, entry) in enumerate(zip(labelled, info["marks"])):
        pts = [(p["x"] + 0.5, p["y"] + 0.5) for p in m["points"]]
        ax, ay = pts[1] if m["kind"] == "angle" else ((pts[0][0] + pts[1][0]) / 2, (pts[0][1] + pts[1][1]) / 2)
        bw, bh = entry["boxWidth"], entry["boxHeight"]
        x = min(max(ax + 6 * u, 2 * u), max(w - bw - 2 * u, 2 * u))
        y = min(max(ay - bh - 6 * u, 2 * u), max(h - bh - 2 * u, 2 * u))
        xi, yi = int(round(x)), int(round(y))
        crop = shots["marks"][yi:yi + bh, xi:xi + bw].astype(np.int16)
        diff = int(np.abs(crop - bitmap(entry)).max()) if crop.shape == (bh, bw, 3) else 999
        worst = max(worst, diff)
        rep.check(abs(x - xi) < 1e-9 and abs(y - yi) < 1e-9 and diff <= 2, f"P7-label/{r['name']}/mark-{k}",
                  f"label {m['label']!r}: the box at ({x}, {y}) differs from the string drawn upright by up to {diff} levels (band 2)")
    bar = info["bar"]
    top = h - 15 * u
    bw, bh = bar["boxWidth"], bar["boxHeight"]
    x0, y = 16 * u, top - 3 * u - bh
    crop = shots["bar"][y:y + bh, x0:x0 + bw].astype(np.int16)
    diff = int(np.abs(crop - bitmap(bar)).max()) if crop.shape == (bh, bw, 3) else 999
    worst = max(worst, diff)
    rep.check(diff <= 2, f"P7-label/{r['name']}/bar", f"the bar's label differs from the string drawn upright by up to {diff} levels (band 2)")
    stats["p7_worst"] = max(stats.get("p7_worst", 0), worst)


def mark_boxes(mark, u, w, h):
    pts = [(p["x"] + 0.5, p["y"] + 0.5) for p in mark["points"]]
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    grow = max(4.5 * u, 1.75 * u + 0.5, mark["width"] / 2 if mark["kind"] == "profile" else 0) + 3
    boxes = [(min(xs) - grow, min(ys) - grow, max(xs) + grow, max(ys) + grow)]
    if mark["label"]:
        ax, ay = pts[1] if mark["kind"] == "angle" else ((pts[0][0] + pts[1][0]) / 2, (pts[0][1] + pts[1][1]) / 2)
        boxes.append((ax + 6 * u - 3, ay - 18 * u - 6 * u - 3, ax + 6 * u + 7.5 * u * len(mark["label"]) + 8 * u + 6 + 3, ay - 6 * u + 3))
    return [(max(0, int(math.floor(a))), max(0, int(math.floor(b))), min(w, int(math.ceil(c))), min(h, int(math.ceil(d))))
            for a, b, c, d in boxes]


def plate_box(r, w, h):
    u, expect = r["u"], r["bar"]
    m = 8 * u
    wide = max(8 * u * len(expect["label"]), expect["drawn"]) + 16 * u
    tall = 16 * u + 15 * u
    return (max(0, m - 3), max(0, h - m - tall - 3), min(w, m + wide + 3), min(h, h - m + 3))


def check_p6(rep, stats, r, img, plain, shots):
    """`plain` is numpy's recomputation of the overlay-free export (P4's truth), not the harness's own plain PNG: an overlay
    option ignored by the code under test must show here even when it is ignored on the plain export as well."""
    name, w, h = r["name"], img["width"], img["height"]
    barred, marked, full = (shots.get(v) for v in ("bar", "marks", "full"))
    plate = plate_box(r, w, h) if r["bar"] not in (None, "left_out") else None
    boxes = [b for m in r["marks"] for b in mark_boxes(m, r["u"], w, h)]

    def mask_of(box_list):
        mask = np.zeros((h, w), bool)
        for x0, y0, x1, y1 in box_list:
            mask[y0:y1, x0:x1] = True
        return mask

    def differing(a, b, mask=None):
        d = (a != b).any(axis=2)
        return d if mask is None else d & mask

    plate_mask = mask_of([plate]) if plate else np.zeros((h, w), bool)
    marks_mask = mask_of(boxes)
    if full is not None and plate is not None:
        outside = differing(plain, full, ~(plate_mask | marks_mask))
        rep.check(not outside.any(), f"P6-footprint/{name}/outside",
                  f"{int(outside.sum())} pixels outside the plate's and the marks' grown boxes differ from the overlay-free export, "
                  f"first at (x, y) = {tuple(int(v) for v in np.argwhere(outside)[0][::-1]) if outside.any() else None}")
    if barred is not None and plate is not None:
        rep.check(not differing(plain, barred, ~plate_mask).any(), f"P6-footprint/{name}/bar-only-outside-plate",
                  f"{int(differing(plain, barred, ~plate_mask).sum())} pixels outside the plate's box differ with the bar alone")
        drawn = int(differing(plain, barred, plate_mask).sum())
        rep.check(drawn >= r["bar"]["drawn"] * 2 * r["u"], f"P6-footprint/{name}/bar-drawn", f"only {drawn} pixels changed in the plate's box")
    if barred is not None and r["marks"]:
        rep.check(not differing(plain, barred, marks_mask).any(), f"P6-footprint/{name}/bar-only-marks-untouched",
                  f"{int(differing(plain, barred, marks_mask).sum())} pixels in the marks' boxes differ with the marks option off")
    if marked is not None and plate is not None:
        rep.check(not differing(plain, marked, plate_mask).any(), f"P6-footprint/{name}/marks-only-plate-untouched",
                  f"{int(differing(plain, marked, plate_mask).sum())} pixels in the plate's box differ with the bar option off")
    if marked is not None:
        rep.check(not differing(plain, marked, ~marks_mask).any(), f"P6-footprint/{name}/marks-only-outside",
                  f"{int(differing(plain, marked, ~marks_mask).sum())} pixels outside the marks' boxes differ with the marks alone")
        for k, m in enumerate(r["marks"]):
            touched = int(differing(plain, marked, mask_of(mark_boxes(m, r["u"], w, h))).sum())
            rep.check(touched >= 10 * r["u"], f"P6-footprint/{name}/mark-{k}-drawn", f"only {touched} pixels changed in mark {k}'s boxes")
    if barred is not None and marked is not None and full is not None:
        composed = plain.copy()
        composed[plate_mask] = barred[plate_mask]
        composed[marks_mask] = marked[marks_mask]
        diff = differing(composed, full)
        rep.check(not diff.any(), f"P6-footprint/{name}/full-composes",
                  f"{int(diff.sum())} pixels of the export with both options differ from the bar-only export in the plate's box, "
                  "the marks-only export in the marks' boxes and the plain one elsewhere")
    if r["bar"] == "left_out" and barred is not None:
        diff = differing(plain, barred)
        rep.check(not diff.any(), f"P6-footprint/{name}/left-out-untouched", f"{int(diff.sum())} pixels differ though the bar was left out")
    stats["p6"] = stats.get("p6", 0) + 1


def read_f64(path):
    return np.fromfile(path, dtype="<f8")


def bits(v):
    return struct.pack("<d", float(v))


def analytic_profile(fn, start, end, width):
    x0, y0 = start
    x1, y1 = end
    dr, dc = y1 - y0, x1 - x0
    length = math.hypot(dr, dc)
    n = int(math.ceil(length + 1))
    t = np.linspace(0.0, 1.0, n)
    rows, cols = y0 + t * dr, x0 + t * dc
    pr, pc = (dc / length, -dr / length) if length > 0 else (1.0, 0.0)
    offsets = np.arange(width) - (width - 1) / 2.0
    return fn(rows[:, None] + offsets[None, :] * pr, cols[:, None] + offsets[None, :] * pc).mean(axis=1)


ANALYTIC = {"ramp": ramp_value, "dm4": lambda r, c: 1000 * r + c - 12000}
HEADER_KEYS = ["software", "file", "object", "image", "start", "end", "width", "samples", "length", "x scale", "y scale",
               "position", "shown in macTEM as", "method", "notes", "validation", "lineage", "numbers"]


def check_csv(rep, stats, ld, c):
    name, out = c["name"], ld.out
    img = ld.manifest["images"][c["image"]]
    ident = ld.identity(c["image"])
    positions = read_f64(os.path.join(out, f"{name}.positions.f64"))
    samples = read_f64(os.path.join(out, f"{name}.samples.f64"))
    prof = json.load(open(os.path.join(out, f"{name}.profile.json"), encoding="utf-8"))
    n_mem = len(samples)
    if c["empty"]:
        rep.check(n_mem == 0 and not os.path.exists(os.path.join(out, f"{name}.csv")) and os.path.exists(os.path.join(out, f"{name}.csv.none")),
                  f"P1-rows/{name}", f"a profile of no samples must give no file: {n_mem} samples in memory, "
                  f"csv {os.path.exists(os.path.join(out, f'{name}.csv'))}, marker {os.path.exists(os.path.join(out, f'{name}.csv.none'))}")
        return
    path = os.path.join(out, f"{name}.csv")
    if not rep.check(os.path.exists(path), f"P1-rows/{name}", "no CSV was written"):
        return
    raw = open(path, "rb").read()
    rep.check(not raw.startswith(b"\xef\xbb\xbf") and b"\r" not in raw and raw.endswith(b"\n") and not raw.endswith(b"\n\n"),
              f"P1-header/{name}/bytes", "a BOM, a CR, no final LF or an empty last line")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        rep.check(False, f"P1-header/{name}/utf8", str(e))
        return
    lines = text.split("\n")[:-1]
    n_header = 0
    while n_header < len(lines) and lines[n_header].startswith("# "):
        n_header += 1
    header, body = lines[:n_header], lines[n_header:]
    # -- the planted truth
    x, y = img["x"], img["y"]
    sx, sy, ex, ey = c["start"]["x"], c["start"]["y"], c["end"]["x"], c["end"]["y"]
    hyp = math.hypot(ey - sy, ex - sx)
    n_want = int(math.ceil(hyp + 1))
    physical = axis_calibrated(x) and axis_calibrated(y) and x["units"] == y["units"]
    total = math.hypot((ex - sx) * x["scale"], (ey - sy) * y["scale"]) if physical else hyp
    unit = x["units"] if physical else "px"
    # -- P1-rows
    rows = list(csv.reader(io.StringIO("\n".join(body) + "\n")))
    rep.check(len(rows) == n_mem + 1 and n_mem == n_want and prof["count"] == n_mem and all(len(r_) == 2 for r_ in rows),
              f"P1-rows/{name}", f"{len(rows) - 1} data rows, {n_mem} samples in memory, {n_want} by the sample-count rule "
              f"ceil(hypot + 1), harness {prof['count']}; cells per row {sorted({len(r_) for r_ in rows})}")
    # -- the header
    kv = []
    for line in header:
        key, sep, value = line[2:].partition(": ")
        kv.append((key, value) if sep else (key, None))
    bad = []
    if not header or header[0] != "# macTEM line profile":
        bad.append(f"first line {header[:1]!r}")
    keys = [k for k, _ in kv[1:]]
    want_keys = [k for k in HEADER_KEYS if k != "shown in macTEM as" or c["shown"]]
    if keys != want_keys:
        bad.append(f"keys {keys} vs {want_keys}")
    d = dict(kv[1:])
    point = lambda value: re.fullmatch(r"x=(\S+), y=(\S+)(?: \(image pixels: x column, y row, pixel centres at integers\))?", value or "")
    for key, (px, py), suffix in (("start", (sx, sy), True), ("end", (ex, ey), False)):
        m = point(d.get(key))
        if not m or bits(float(m.group(1))) != bits(px) or bits(float(m.group(2))) != bits(py) \
                or (suffix and "(image pixels" not in d[key]) or (not suffix and "(" in d[key]):
            bad.append(f"{key} {d.get(key)!r} vs x={px!r}, y={py!r}")
    expect = {"software": sanitize(c["software"]), "file": sanitize(ident["fileName"]), "object": sanitize(ident["object"]),
              "image": f"{img['width']} x {img['height']} px", "width": f"{c['width']} px", "samples": str(n_mem),
              "position": f"distance from the start along the line, in {sanitize(unit)} as the file states it "
                          "(not an axis coordinate; origins unused)",
              "method": "bilinear interpolation (order 1), scipy's \"reflect\" boundary (half-sample symmetric), "
                        f"mean of {c['width']} samples 1 px apart along the perpendicular on the pixel grid",
              "notes": "; ".join(sanitize(n) for n in ident["notes"]) if ident["notes"] else "none",
              "validation": VALIDATION_CSV + (", unvalidated (reader note)" if any("unvalidated" in n.lower() for n in ident["notes"]) else ""),
              "lineage": LINEAGE_CSV, "numbers": NUMBERS_CSV}
    for key, want in expect.items():
        if d.get(key) != want:
            bad.append(f"{key}: {d.get(key)!r} vs {want!r}")
    m = re.fullmatch(r"(\S+) (.*)", d.get("length") or "")
    if not m or bits(float(m.group(1))) != bits(positions[-1]) or m.group(2) != sanitize(unit):
        bad.append(f"length {d.get('length')!r} vs {positions[-1]!r} {unit!r}")
    for name_, a in (("x scale", x), ("y scale", y)):
        value = d.get(name_)
        if not axis_calibrated(a):
            if value != "none":
                bad.append(f"{name_}: {value!r}, the axis is not calibrated")
            continue
        m = re.fullmatch(r"(\S+) (.*) per px, origin (\S+) px", value or "")
        if not m or bits(float(m.group(1))) != bits(a["scale"]) or m.group(2) != sanitize(a["units"]) \
                or bits(float(m.group(3))) != bits(a["origin"]):
            bad.append(f"{name_}: {value!r} vs {a!r}")
    if c["shown"]:
        m = re.fullmatch(r"(.*) \(x (\S+)\)", d.get("shown in macTEM as") or "")
        if not m or m.group(1) != sanitize(c["shown"]["unit"]) or bits(float(m.group(2))) != bits(c["shown"]["factor"]):
            bad.append(f"shown: {d.get('shown in macTEM as')!r} vs {c['shown']!r}")
    if not rows or rows[0] != [f"position ({sanitize(unit)})", "value"]:
        bad.append(f"column header {rows[:1]!r} vs {[f'position ({sanitize(unit)})', 'value']!r}")
    if prof["unit"] != unit or prof["isPhysical"] != physical or prof["width"] != c["width"]:
        bad.append(f"the profile in memory says unit {prof['unit']!r}, physical {prof['isPhysical']}, width {prof['width']}; "
                   f"planted {unit!r}, {physical}, {c['width']}")
    rep.check(not bad, f"P1-header/{name}", "; ".join(bad[:5]))
    # -- P1-values and P1-positions
    data_rows = rows[1:]
    bad_v, bad_p, nans = [], [], 0
    for i, row in enumerate(data_rows[:n_mem]):
        if len(row) != 2:
            bad_v.append(f"row {i}: {row!r} is not two cells")
            continue
        pos_cell, val_cell = row
        try:
            pv, vv = float(pos_cell), float(val_cell)
        except ValueError:
            bad_v.append(f"row {i}: {row!r} is not a number")
            continue
        if bits(pv) != bits(positions[i]):
            bad_p.append(f"row {i}: {pos_cell!r} vs {positions[i]!r}")
        mem = samples[i]
        if math.isnan(mem):
            nans += 1
            if val_cell != "nan":
                bad_v.append(f"row {i}: {val_cell!r}, the sample is NaN (must be 'nan')")
        elif val_cell == "nan" or bits(vv) != bits(mem):
            bad_v.append(f"row {i}: {val_cell!r} vs {mem!r}")
    detail = []
    if c["analytic"]:
        truth = analytic_profile(ANALYTIC[c["analytic"]], (sx, sy), (ex, ey), c["width"])
        floor = 0.1 * float(np.abs(ld.raw(c["image"])).max())
        rel = np.abs(samples - truth) / np.maximum(np.abs(truth), floor)
        if not (len(truth) == n_mem and float(rel.max()) <= 1e-5):
            detail.append(f"the samples differ from the analytic profile by {float(rel.max()) if len(truth) == n_mem else 'count'} relative")
        stats["p1_analytic"] = max(stats.get("p1_analytic", 0.0), float(rel.max()) if len(truth) == n_mem else 9.0)
    rep.check(not bad_v and not detail, f"P1-values/{name}", "; ".join(bad_v[:3] + detail) + (f" ({len(bad_v)} cells differ)" if bad_v else ""))
    closed = np.arange(n_mem) * (total / (n_mem - 1)) if n_mem > 1 else np.zeros(n_mem)
    if n_mem > 1:
        closed[-1] = total
    detail = []
    if not np.all(np.abs(positions - closed) <= 1e-12 * max(total, 1e-300)):
        detail.append(f"the positions in memory differ from i/(n-1) of {total!r} {unit}")
    if n_mem > 1 and not np.all(np.diff(positions) > 0):
        detail.append("the positions do not increase")
    rep.check(not bad_p and not detail, f"P1-positions/{name}", "; ".join(bad_p[:3] + detail) + (f" ({len(bad_p)} cells differ)" if bad_p else ""))
    stats["p1_rows"] = stats.get("p1_rows", 0) + n_mem
    stats["p1_nan"] = stats.get("p1_nan", 0) + nans
    stats["p1_csv"] = stats.get("p1_csv", 0) + 1


def check_open(rep, ld, image):
    img = ld.manifest["images"][image]
    path = os.path.join(ld.out, "opened", f"{image}.json")
    if not rep.check(os.path.exists(path), f"P0-open/{image}", "Swift wrote no dump of the image it opened"):
        return
    o = json.load(open(path, encoding="utf-8"))
    pixels = np.fromfile(os.path.join(ld.out, "opened", f"{image}.f32"), dtype="<f4")
    truth = ld.raw(image)
    bad = []
    if (o["width"], o["height"]) != (img["width"], img["height"]) or not np.array_equal(pixels.reshape(-1), truth.reshape(-1)):
        bad.append("the pixels ImageOpening returned differ from ncempy's / the planted ones")
    for key in ("x", "y"):
        a, b = o[key], img[key]
        if (a is None) != (b is None) or (a is not None and (bits(a["scale"]) != bits(b["scale"]) or a["units"] != b["units"]
                                                              or bits(a["origin"]) != bits(b["origin"]))):
            bad.append(f"axis {key}: opened {a!r}, truth {b!r}")
    if o["fileName"] != img["fileName"]:
        bad.append(f"file name {o['fileName']!r} vs {img['fileName']!r}")
    rep.check(not bad, f"P0-open/{image}", "; ".join(bad))


RESULTS_COLUMNS = ["group", "id", "label", "quantity", "value", "unit", "text", "validation", "lineage"]
# Every product of the Results room (ResultRow.Product, in its order); the harness dumps one sentence per product. The planted cases
# use the first four; calibration and ring come from the Diffraction room, edsComposition from the EDS room, eelsThickness and eelsEdge from the EELS room. macTEMTests/ExportParityReferenceTests holds this line
# equal to the app's list on every unit run.
RESULTS_PRODUCTS = ("distance", "angle", "profile", "spot", "calibration", "ring", "edsComposition", "eelsThickness", "eelsEdge")


def check_results(rep, stats, ld, c):
    """R-P1: the Results CSV re-read by Python's own csv and float. The file is compared with (a) the rows as the harness held them
    in memory (every value bit-equal, every text equal), (b) the measurements read straight from ImageMeasurement and SpotMeasure
    (not through the row builders), (c) the closed forms (distance, angle) and the spot's own identities (|q| = hypot(qx, qy),
    d = 1/|q|) to 1e-12, and (d) the header: software, file, size, scales, session, and one validation line per product present, equal
    to the producers' constants the harness dumped."""
    name, out = c["name"], ld.out
    img = ld.manifest["images"][c["image"]]
    rows = json.load(open(os.path.join(out, f"{name}.rows.json"), encoding="utf-8"))
    truth = json.load(open(os.path.join(out, f"{name}.truth.json"), encoding="utf-8"))
    sentences = json.load(open(os.path.join(out, f"{name}.validation.json"), encoding="utf-8"))
    raw = open(os.path.join(out, f"{name}.csv"), encoding="utf-8", newline="").read()

    # R-P2's reference side: every product has its sentence, and "validated" is never claimed (only "unvalidated" may contain it).
    rep.check(set(sentences) == set(RESULTS_PRODUCTS) and all(sentences.values()), f"R-P2/sentences/{name}",
              f"the producers' constants: {sorted(sentences)}")
    rep.check(not any("validated" in v.lower().replace("unvalidated", "") for v in sentences.values()), f"R-P2/never-validated/{name}",
              "a validation sentence claims 'validated'")

    # -- header and body
    lines = raw.split("\n")
    k = 0
    while k < len(lines) and lines[k].startswith("#"):
        k += 1
    header, body = lines[:k], "\n".join(lines[k:])
    parsed = {}
    for h in header[1:]:
        key, _, value = h[2:].partition(": ")
        parsed[key] = value
    present = [p for p in RESULTS_PRODUCTS if any(r["product"] == p for r in rows)]
    got_validation = {key[len("validation ("):-1]: v for key, v in parsed.items() if key.startswith("validation (")}
    problems = []
    # a file whose reader notes say "unvalidated" keeps the qualifier on every claim (header lines and the validation column)
    suffix = ", unvalidated (reader note)" if any("unvalidated" in n.lower() for n in ld.identity(c["image"])["notes"]) else ""
    if header[0] != "# macTEM results":
        problems.append(f"first line {header[0]!r}")
    if got_validation != {p: sentences[p] + suffix for p in present}:
        problems.append(f"validation lines {sorted(got_validation)} for products {present}, or a sentence that is not the producer's constant")
    ident = ld.identity(c["image"])
    want = {"software": c["software"], "file": sanitize(ident["fileName"]), "object": sanitize(ident["object"]),
            "image": f"{img['width']} x {img['height']} px", "session": sanitize(c["session"]),
            "notes": "; ".join(sanitize(n) for n in ident["notes"]) or "none"}
    for key, value in want.items():
        if parsed.get(key) != value:
            problems.append(f"{key}: {parsed.get(key)!r} want {value!r}")
    for key, ax in (("x scale", img["x"]), ("y scale", img["y"])):
        want_scale = f"{ax['scale']!r} {sanitize(ax['units'])} per px, origin {ax['origin']!r} px" if axis_calibrated(ax) else "none"
        if parsed.get(key) != want_scale:
            problems.append(f"{key}: {parsed.get(key)!r} want {want_scale!r}")
    if parsed.get("numbers") is None or not parsed["numbers"].startswith("%.17g"):
        problems.append(f"numbers line {parsed.get('numbers')!r}")
    rep.check(not problems, f"R-P1/header/{name}", "; ".join(problems))

    cells = list(csv.reader(io.StringIO(body, newline="")))
    cells = [r for r in cells if r != []]
    expected = []
    for r in rows:
        for e in r["entries"]:
            expected.append((r, e["name"], e.get("bits"), e["unit"], e["text"]))
        if r.get("refusal") is not None:
            expected.append((r, "outcome", None, "", r.get("refusal")))
    shape_ok = (bool(cells) and cells[0] == RESULTS_COLUMNS and len(cells) - 1 == len(expected)
                and all(len(row) == len(RESULTS_COLUMNS) for row in cells))
    if not rep.check(shape_ok, f"R-P1/text/{name}/lines",
                     f"{len(cells) - 1} lines of {sorted({len(r) for r in cells})} cells for {len(expected)} quantities"):
        return
    bad_text, bad_value, nan_count = [], [], 0
    by_key = {}
    for row, (r, quantity, bits_hex, unit, text) in zip(cells[1:], expected):
        group, rid, label, q, value, u, t, validation, lineage = row
        if [group, rid, label, q, u, t, validation, lineage] != [r["group"], r["id"], r["label"], quantity, unit, text,
                                                                  sentences[r["product"]] + suffix, (r.get("lineage") or "")]:
            bad_text.append((r["id"], quantity, row))
        if bits_hex is None:
            if value != "":
                bad_value.append((r["id"], quantity, f"words-only line holds {value!r}"))
            continue
        mem = struct.unpack(">d", bytes.fromhex(bits_hex))[0]
        if math.isnan(mem):
            nan_count += 1
            if value != "nan":
                bad_value.append((r["id"], quantity, f"memory NaN, file {value!r}"))
            continue
        try:
            back = float(value)
        except ValueError:
            bad_value.append((r["id"], quantity, f"{value!r} is not a number"))
            continue
        if struct.pack(">d", back).hex() != bits_hex:
            bad_value.append((r["id"], quantity, f"memory {mem!r}, file {value!r} re-reads as {back!r}"))
        by_key[(r["id"], quantity)] = back
    rep.check(not bad_text, f"R-P1/text/{name}", f"{len(bad_text)} lines differ, first {bad_text[:1]}")
    rep.check(not bad_value, f"R-P1/values/{name}", f"{len(bad_value)} values differ, first {bad_value[:1]}")
    stats["rp1_lines"] = stats.get("rp1_lines", 0) + len(expected)
    stats["rp1_nan"] = stats.get("rp1_nan", 0) + nan_count

    # -- the measurements read straight from the owners, and the closed forms
    def from_truth(hex_bits):
        return struct.unpack(">d", bytes.fromhex(hex_bits))[0]
    bad_marks, bad_spots, bad_closed = [], [], []
    marks_by_id = {m["id"]: m for m in c["marks"]}
    for mid, quantities in truth["marks"].items():
        for quantity, hex_bits in quantities.items():
            got = by_key.get((mid, quantity))
            if got is None or struct.pack(">d", got).hex() != hex_bits:
                bad_marks.append((mid, quantity, got, from_truth(hex_bits)))
        m = marks_by_id[mid]
        ax, ay = (None, None) if m.get("uncalibrated") else (img["x"], img["y"])
        sx, sy = (ax["scale"], ay["scale"]) if axis_calibrated(ax) and axis_calibrated(ay) and ax["units"] == ay["units"] else (None, None)
        p = m["points"]
        if m["kind"] in ("distance", "profile"):
            dc, dr = p[1][0] - p[0][0], p[1][1] - p[0][1]
            wants = {"length_px": math.hypot(dc, dr)}
            if sx is not None:
                wants["length"] = math.hypot(dc * sx, dr * sy)
        else:
            ux, uy = (p[0][0] - p[1][0]) * (sx or 1), (p[0][1] - p[1][1]) * (sy or 1)
            vx, vy = (p[2][0] - p[1][0]) * (sx or 1), (p[2][1] - p[1][1]) * (sy or 1)
            wants = {}
            if not (ux == 0 and uy == 0) and not (vx == 0 and vy == 0):
                wants["angle"] = math.degrees(math.atan2(abs(ux * vy - uy * vx), ux * vx + uy * vy))
        for quantity, want_value in wants.items():
            got = by_key.get((mid, quantity))
            if got is None or abs(got - want_value) > 1e-12 * abs(want_value):
                bad_closed.append((mid, quantity, got, want_value))
        if set(wants) != {q for q in quantities}:
            bad_closed.append((mid, "quantities", sorted(quantities), sorted(wants)))
    for sid, quantities in truth["spots"].items():
        for quantity, hex_bits in quantities.items():
            got = by_key.get((sid, quantity))
            if got is None or struct.pack(">d", got).hex() != hex_bits:
                bad_spots.append((sid, quantity, got, from_truth(hex_bits)))
        qx, qy, q, d = (by_key.get((sid, k)) for k in ("qx", "qy", "q", "d"))
        if None in (qx, qy, q, d) or abs(q - math.hypot(qx, qy)) > 1e-12 * q or abs(d - 1.0 / q) > 1e-12 * d:
            bad_closed.append((sid, "|q| = hypot(qx, qy), d = 1/|q|", (qx, qy, q, d), None))
    for rr in rows:
        if rr["id"].startswith("spot:") and rr.get("refusal") is None and rr["id"] not in truth["spots"]:
            bad_spots.append((rr["id"], "a spot row with no measurement behind it", None, None))
    rep.check(not bad_marks, f"R-P1/mark-values/{name}", f"{len(bad_marks)} differ from ImageMeasurement, first {bad_marks[:1]}")
    rep.check(not bad_spots, f"R-P1/spot-values/{name}", f"{len(bad_spots)} differ from SpotMeasure, first {bad_spots[:1]}")
    rep.check(not bad_closed, f"R-P1/closed-form/{name}", f"{len(bad_closed)} differ from the closed form, first {bad_closed[:1]}")
    stats["rp1_marks"] = stats.get("rp1_marks", 0) + sum(len(q) for q in truth["marks"].values())
    stats["rp1_spots"] = stats.get("rp1_spots", 0) + sum(len(q) for q in truth["spots"].values())
    kinds = {}
    for rr in rows:
        kinds[rr["product"]] = kinds.get(rr["product"], 0) + 1
    rep.check(all(kinds.get(k, 0) >= 1 for k in ("distance", "angle", "profile", "spot"))
              and (name != "results" or sum(1 for rr in rows if rr.get("refusal")) >= 2),
              f"R-P1/planted/{name}", f"the planted ledger holds {kinds}, refusals {sum(1 for rr in rows if rr.get('refusal'))}")


def guarded(rep, name, fn, *args):
    """Runs one check; a check that cannot even read its input (an output so broken that it raises) is a failure of that
    check with a FAIL line, never a traceback (a traceback exits 1 without saying which check saw it)."""
    try:
        fn(*args)
    except Exception as e:                                    # noqa: BLE001 - any failure is the finding
        rep.check(False, name, f"the check could not read the output: {type(e).__name__}: {e}")


def run_check(planted, out, only, variants):
    ld = Loader(planted, out)
    m = ld.manifest
    rep, stats = Report(), {}
    pngs = csvs = 0
    wanted = lambda n: only is None or n in only
    wanted_variant = lambda v: variants is None or v in variants

    opened = set()
    for r in m["renders"]:
        if wanted(r["name"]):
            opened.add(r["image"])
    for c in m["csvs"]:
        if wanted(c["name"]):
            opened.add(c["image"])
    for image in sorted(opened):
        if m["images"][image]["open"]:
            check_open(rep, ld, image)

    for r in m["renders"]:
        if not wanted(r["name"]):
            continue
        img = m["images"][r["image"]]
        raw = ld.raw(r["image"])
        ident = ld.identity(r["image"])
        canvas, raw_range = canvas_of(raw)
        fractions = window_fractions(r["windowLow"], r["windowHigh"], raw_range)
        lut = np.fromfile(os.path.join(planted, r["lut"]), dtype=np.uint8)
        shots, held = {}, []

        def truth_of():
            """numpy's recomputation of the overlay-free export, once per case."""
            if not held:
                held.append(shader_rgb(canvas, fractions[0], fractions[1], r["gamma"], lut))
            return held[0]
        expect_meta = expected_description(r, img, ident, None, canvas, raw_range, fractions)
        wj = os.path.join(out, f"{r['name']}.window.json")
        if os.path.exists(wj):
            got = json.load(open(wj))
            rep.check(got == {"low": float(fractions[0]), "high": float(fractions[1])}, f"P4-format/{r['name']}/window-fractions",
                      f"the harness passed the fractions {got} where DisplayWindow.fractions gives {float(fractions[0])}, {float(fractions[1])}")
        for v in r["variants"]:
            vname = v["name"]
            if not wanted_variant(vname):
                continue
            png_path = os.path.join(out, f"{r['name']}.{vname}.png")
            if not rep.check(os.path.exists(png_path), f"P4-format/{r['name']}/{vname}", "the harness wrote no PNG"):
                continue
            data = open(png_path, "rb").read()
            with Image.open(png_path) as im:
                tag = f"{r['name']}/{vname}"
                meta = check_png_format(rep, tag, data, r, img, expect_meta, vname, im, png_path)
                arr = np.asarray(im.convert("RGB")) if im.size == (img["width"], img["height"]) else None
            pngs += 1
            if arr is None:
                continue
            rendered = json.load(open(os.path.join(out, f"{r['name']}.{vname}.rendered.json")))
            rep.check((rendered["width"], rendered["height"]) == (img["width"], img["height"]), f"P4-format/{tag}/rendered-size",
                      f"{rendered['width']} x {rendered['height']}")
            shots[vname] = arr
            if vname == "plain":
                want = truth_of()
                diff = np.abs(arr.astype(np.int16) - want.astype(np.int16))
                worst = int(diff.max())
                stats["p4_pixels"] = stats.get("p4_pixels", 0) + arr.shape[0] * arr.shape[1]
                stats["p4_worst"] = max(stats.get("p4_worst", 0), worst)
                where = tuple(int(q) for q in np.argwhere(diff.any(axis=2))[0][::-1]) if worst else None
                rep.check(worst == 0, f"P4-pixels/{r['name']}",
                          f"{int((diff > 0).sum())} channels differ from numpy's recomputation, by up to {worst} levels, first at (x, y) = "
                          f"{where}: got {arr[where[1], where[0]].tolist() if where else None} want {want[where[1], where[0]].tolist() if where else None}")
                masked = int((canvas < 0).sum())
                if masked:
                    rep.check(meta is not None and meta["masked_pixels"] == masked, f"P4-pixels/{r['name']}/masked-count", f"{masked} masked pixels")
            if vname == "bar" and meta is not None:
                guarded(rep, f"P3-length/{r['name']}", check_p3, rep, stats, r, img, arr, meta, rendered)
            if vname == "marks" and "p5" in r:
                guarded(rep, f"P5-stroke/{r['name']}", check_p5, rep, stats, r, arr)
            if vname == "marks" and "p5b" in r:
                guarded(rep, f"P5-band/{r['name']}", check_p5_band, rep, stats, r, arr)
        if "p7" in r and "marks" in shots and "bar" in shots:
            guarded(rep, f"P7-label/{r['name']}", check_p7, rep, stats, r, img, shots, out)
        if "p5" not in r and img["width"] * img["height"] <= 1_100_000 and any(k in shots for k in ("bar", "marks", "full")):
            guarded(rep, f"P6-footprint/{r['name']}", check_p6, rep, stats, r, img, truth_of(), shots)
        del shots, held

    for c in m["csvs"]:
        if wanted(c["name"]):
            guarded(rep, f"P1-rows/{c['name']}", check_csv, rep, stats, ld, c)
            csvs += 1

    results = 0
    for c in m["results"]:
        if wanted(c["name"]):
            guarded(rep, f"R-P1/read/{c['name']}", check_results, rep, stats, ld, c)
            results += 1

    # the ok lines (a family with a failure has printed its FAIL lines already)
    def ok(family, text):
        if not rep.family_failures.get(family) and rep.family_checks.get(family):
            print(f"  ok    {family}: {text}")
    ok("P0-open", "the images ImageOpening returned are the pinned files' pixels and calibration")
    ok("R-P1", f"{stats.get('rp1_lines', 0)} lines of the Results CSVs ({results} cases, one with an unvalidated file) re-read: values bit-equal to memory ({stats.get('rp1_nan', 0)} nan), "
       f"{stats.get('rp1_marks', 0)} mark and {stats.get('rp1_spots', 0)} spot quantities equal the owners' own, closed forms within 1e-12, "
       "texts round-trip, the header's validation lines are the producers' constants")
    ok("P1-values", f"{stats.get('p1_csv', 0)} CSV files, {stats.get('p1_rows', 0)} rows re-read bit-equal ({stats.get('p1_nan', 0)} nan)"
       + (f"; analytic ramps within {stats['p1_analytic']:.2e} relative" if "p1_analytic" in stats else ""))
    ok("P1-positions", "positions bit-equal to memory and within 1e-12 of i/(n-1) of the planted length")
    ok("P1-rows", "rows = samples = ceil(hypot + 1); an empty profile writes nothing")
    ok("P1-header", "points, sizes, scales, units, notes and the fixed lines re-read equal to the planted ones")
    ok("P3-length", f"{stats.get('p3_bars', 0)} bars: the white run times x's scale is within {stats.get('p3_max', 0.0):.3f} of a pixel "
       "of the label's length (band: 1 pixel); left-out cases left out")
    ok("P3-drawn", "the run equals the drawn length on every row of the bar, exactly; geometry and rounding as planted")
    ok("P4-format", f"{pngs} PNGs: RGB 8 bit, sRGB, CRCs, the three text chunks, the Description")
    ok("P4-pixels", f"{stats.get('p4_pixels', 0):,} pixels, largest difference {stats.get('p4_worst', 0)} levels")
    ok("P5-stroke", f"yellow-weighted centroids within {stats.get('p5_stroke', 0.0):.3f} px of the lines (band 0.15)")
    ok("P5-ring", f"ring centres within {stats.get('p5_ring', 0.0):.3f} px of their points (band 0.15)")
    ok("P5-band", f"bands equal 46 x the covered share of each pixel within {stats.get('p5_band', 0.0):.1f} levels (band 12)")
    ok("P7-label", f"labels equal the string drawn upright within {stats.get('p7_worst', 0)} levels (band 2)")
    ok("P6-footprint", f"{stats.get('p6', 0)} cases: nothing outside the footprints changed, options off leave theirs untouched")
    reference = m["reference"]
    if rep.failures:
        print(f"export-parity: {rep.failures} FAILURES in {rep.checks} checks ({reference})")
        sys.exit(1)
    print(f"export-parity: all passed — {pngs} PNGs, {csvs} CSV cases, {results} Results cases, {rep.checks} checks against {reference}")


def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "plant" and len(argv) == 5:
        plant(*argv[1:])
    elif argv and argv[0] == "check" and 3 <= len(argv) <= 5:
        names = None if len(argv) < 4 or argv[3] == "all" else set(argv[3].split(","))
        variants = None if len(argv) < 5 or argv[4] == "all" else set(argv[4].split(","))
        run_check(argv[1], argv[2], names, variants)
    else:
        fail("usage: reference.py plant <planted.dm4> <planted.truth.json> <rsciio-root> <planted-dir> | "
             "check <planted-dir> <out-dir> [<cases|all> [<variants|all>]]")


if __name__ == "__main__":
    main()
