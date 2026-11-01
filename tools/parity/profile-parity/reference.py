#!/usr/bin/env python3
"""Truth for tools/parity/profile-parity: scikit-image's line profiles and the closed forms of distance and angle.

    reference.py <planted.dm4> <planted.truth.json> <rsciio-root> <out-dir>

The reference is pinned: scikit-image 0.26.0 (and the sha256 of the skimage/measure/profile.py it imports), scipy 1.18.1,
numpy 2.5.4 (the lock's), and the Python minor the lock was verified on. A different reference (an override interpreter, an
edited site-packages) is refused, never compared against.

Before scikit-image is trusted it is checked, as every other comparator of this repo is:
  1. a profile geometry written here from the definition (unit-vector perpendicular, no arctan2) equals skimage's
     `_line_profile_coordinates` to 1e-12;
  2. skimage's profile of the image cast to float64 equals an INDEPENDENT bilinear interpolation of the half-sample
     symmetric extension (numpy.pad mode "symmetric", no scipy) to 1e-12 of the image's largest magnitude, on every line —
     so what scipy's "reflect" does outside the image is a measured fact here, not a belief;
  3. on a planted bilinear ramp (value 1000 + 3.7 r + 2.1 c + 0.013 r c) skimage equals the analytic value at the sample
     points, and on the planted DM fixture's own ramp (1000 r + c - 12000, from its truth file) likewise.

The profile the Swift side must match is skimage's own: the image as the app holds it (float32, as CalibratedImage does),
`profile_line(image, (r0, c0), (r1, c1), linewidth=w, order=1, mode="reflect", reduce_func=np.mean)`. skimage returns
float32 there (map_coordinates writes the image's dtype, np.mean accumulates in float32); the same call on the image cast
to float64 is written too, and the Swift port, which works in Double, is held to both. The distance, angle and positions are
closed forms, written from the definitions in the registration and checked against hand-derived values.

Writes <out>/manifest.json and one <name>.f32 per image (row-major little-endian float32). Any disagreement exits 1.
"""
import hashlib
import importlib.metadata
import json
import math
import os
import re
import sys

import numpy as np
import scipy
import skimage
from skimage.measure import profile_line
from skimage.measure.profile import _line_profile_coordinates

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = os.path.join(HERE, "..", "..", "lib", "references-lock.txt")
SKIMAGE_VERSION = "0.26.0"
SCIPY_VERSION = "1.18.1"
NUMPY_VERSION = "2.5.4"
PYTHON_MINOR = "3.14"          # tools/lib/python.sh MACTEM_PYTHON_MINOR: the lock was verified on it
# sha256 of skimage/measure/profile.py in the scikit-image 0.26.0 wheel (cp314, macosx arm64; the file is pure Python).
PROFILE_PY_SHA256 = "fabf6c23d892b2ee7bcda14ab46734ac4e7ec755b96603ff5e5791fdb012d1dd"
# rsciio/tests/registry.txt at the lock commit 049e7d70 (the git blob's sha256, as tools/parity/metadata-parity pins it) and the
# two real files this harness reads from it.
REGISTRY_SHA256 = "31417482938f80160be2c03525ba58dd810c7f16b1790f597470ece8dd0b1bcb"
REAL_IMAGES = [
    ("rsciio-STEM-image", "digitalmicrograph/2D/test_STEM_image.dm3",
     "fcba806af75bc3c2e50e7d7b0626cba545c1464f39e99c8922b225b0b0b0224c"),
    ("rsciio-diffraction-pattern", "digitalmicrograph/2D/test_diffraction_pattern.dm3",
     "ebd6c192ce39e6bd5e67e2c6d53a36809307723023b16c9e149c7afbc3ef601a"),
]


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
    for package, want in (("scikit-image", SKIMAGE_VERSION), ("scipy", SCIPY_VERSION), ("numpy", NUMPY_VERSION)):
        have = importlib.metadata.version(package)
        if have != want:
            fail(f"{package} {have} is not the pinned {want}")
        locked = pins.get(package)
        if locked != want:
            fail(f"tools/lib/references-lock.txt pins {package} {locked}, reference.py expects {want}")
    for module, want in ((np, NUMPY_VERSION), (scipy, SCIPY_VERSION), (skimage, SKIMAGE_VERSION)):
        if module.__version__ != want:
            fail(f"the {module.__name__} imported is {module.__version__}, not {want}")
    profile_py = sys.modules["skimage.measure.profile"].__file__
    if sha256(profile_py) != PROFILE_PY_SHA256:
        fail(f"{profile_py} is not the pinned skimage/measure/profile.py (sha256 {PROFILE_PY_SHA256[:16]}...)")
    return f"scikit-image {SKIMAGE_VERSION} (profile.py pinned), scipy {SCIPY_VERSION}, numpy {NUMPY_VERSION}, Python {python}"


# ---------------------------------------------------------------------------------------------------------------------
# Independent geometry and interpolation: written from the definitions, sharing no code with skimage or scipy.

def my_coordinates(src, dst, width):
    """The (rows, cols) of the width points at each of the n samples, shape (n, width): n = ceil(hypot + 1), the line
    from src to dst including dst, the width points one pixel apart along the unit perpendicular (cos, -sin)."""
    (r0, c0), (r1, c1) = src, dst
    dr, dc = r1 - r0, c1 - c0
    length = math.hypot(dr, dc)
    n = int(math.ceil(length + 1))
    t = np.linspace(0.0, 1.0, n)
    rows, cols = r0 + t * dr, c0 + t * dc
    if length > 0:
        pr, pc = dc / length, -dr / length         # (cos theta, -sin theta) with theta = atan2(dr, dc)
    else:
        pr, pc = 1.0, 0.0                          # atan2(0, 0) = 0
    offsets = (np.arange(width) - (width - 1) / 2.0)
    return rows[:, None] + offsets[None, :] * pr, cols[:, None] + offsets[None, :] * pc


def my_profile(image, src, dst, width):
    """Mean over the width of the bilinear interpolation of the half-sample symmetric extension of `image`
    (numpy.pad mode "symmetric": d c b a | a b c d | d c b a), computed in float64."""
    rows, cols = my_coordinates(src, dst, width)
    h, w = image.shape
    pad = int(max(np.abs(rows).max(), np.abs(cols).max(), h, w)) + 4 * max(h, w) + 8
    ext = np.pad(image.astype(np.float64), pad, mode="symmetric")
    r, c = rows + pad, cols + pad
    r0, c0 = np.floor(r).astype(int), np.floor(c).astype(int)
    fr, fc = r - r0, c - c0
    v = (ext[r0, c0] * (1 - fr) * (1 - fc) + ext[r0, c0 + 1] * (1 - fr) * fc
         + ext[r0 + 1, c0] * fr * (1 - fc) + ext[r0 + 1, c0 + 1] * fr * fc)
    return v.mean(axis=1)


def skimage_profile(image, src, dst, width):
    return profile_line(image, src, dst, linewidth=width, order=1, mode="reflect", reduce_func=np.mean)


def lines_for(h, w):
    """The planted lines of one image, in (row, col) endpoints; coordinates relative to the image so every image gets
    horizontal, vertical, diagonal, sub-pixel, border-crossing, far-outside and zero-length lines."""
    return {
        "horizontal": ((h // 2, 3), (h // 2, w - 4)),
        "vertical": ((3, w // 2), (h - 4, w // 2)),
        "diagonal": ((4, 4), (h - 5, w - 6)),
        "reverse diagonal": ((h - 5, w - 5), (5, 4)),
        "subpixel": ((3.3, 7.8), (h - 6.7, w - 8.6)),
        "short subpixel": ((0.3 * h + 0.25, 0.4 * w + 0.5), (0.3 * h + 2.0, 0.4 * w + 2.75)),
        "3-4-5": ((10, 10), (13, 14)),
        "anti-diagonal": ((h - 5, 4), (5, w - 6)),
        "anti-diagonal reversed": ((6, w - 5), (h - 6, 5)),
        "45 degrees": ((4, 4), (4 + min(h, w) - 9, 4 + min(h, w) - 9)),
        "45 degrees anti": ((4 + min(h, w) - 9, 4), (4, 4 + min(h, w) - 9)),
        "length 10": ((8, 5), (8, 15)),
        "length 10 plus 1e-7": ((8, 5), (8, 15.0000001)),
        "border-crossing": ((-5.5, -7.25), (h + 7.3, w + 5.9)),
        "far outside": ((-90, -120), (h + 100, w + 140)),
        "starts outside": ((h + 17.5, w + 13.5), (0.4 * h, 0.4 * w)),
        "along top edge": ((0, 0), (0, w - 1)),
        "along right edge": ((0, w - 1), (h - 1, w - 1)),
        "zero length": ((h / 2 + 0.5, w / 2 + 0.5), (h / 2 + 0.5, w / 2 + 0.5)),
        "length 1e-7": ((10, 10), (10, 10.0000001)),
    }


# ---------------------------------------------------------------------------------------------------------------------
# Closed forms.

def axis_pair(x, y):
    """(sx, sy, unit) when both axes are calibrated in one unit, else None: the registration's rule."""
    def ok(a):
        return a is not None and a["units"] != "" and math.isfinite(a["scale"]) and a["scale"] > 0
    if ok(x) and ok(y) and x["units"] == y["units"]:
        return x["scale"], y["scale"], x["units"]
    return None


def distance_truth(a, b, x, y):
    """The length in px and, calibrated, in the unit: from the definitions, np.hypot of the scaled differences."""
    dr, dc = b[0] - a[0], b[1] - a[1]
    px = float(np.hypot(dc, dr))
    pair = axis_pair(x, y)
    if pair is None:
        return px, None, None
    return px, float(np.hypot(dc * pair[0], dr * pair[1])), pair[2]


def angle_truth(a, b, c, x, y):
    """The angle at b in degrees and the plane, or (None, None) for a zero arm."""
    pair = axis_pair(x, y)
    sx, sy = (pair[0], pair[1]) if pair else (1.0, 1.0)
    ux, uy = (a[1] - b[1]) * sx, (a[0] - b[0]) * sy
    vx, vy = (c[1] - b[1]) * sx, (c[0] - b[0]) * sy
    if (ux == 0 and uy == 0) or (vx == 0 and vy == 0):
        return None, None
    degrees = float(np.degrees(np.arctan2(abs(ux * vy - uy * vx), ux * vx + uy * vy)))
    return degrees, ("physical" if pair else "pixel")


def acos_degrees(a, b, c, x, y):
    """A second formulation (arccos of the normalised dot), valid away from 0 and 180 degrees."""
    pair = axis_pair(x, y)
    sx, sy = (pair[0], pair[1]) if pair else (1.0, 1.0)
    u = np.array([(a[1] - b[1]) * sx, (a[0] - b[0]) * sy])
    v = np.array([(c[1] - b[1]) * sx, (c[0] - b[0]) * sy])
    return float(np.degrees(np.arccos(np.dot(u, v) / (np.linalg.norm(u) * np.linalg.norm(v)))))


NM_X = {"scale": 0.5, "units": "nm", "origin": 0.0}
NM_Y = {"scale": 0.8, "units": "nm", "origin": 0.0}
UM_Y = {"scale": 0.8, "units": "µm", "origin": 0.0}      # µ is U+00B5, as the DM files write it


def distance_cases():
    """(name, a, b, x, y, hand) with a, b in (row, col); `hand` is the closed form worked by hand (px, physical), or None."""
    r5c6 = ((0, 0), (5, 6))
    return [
        # 6 columns at 0.5 nm = 3 nm, 5 rows at 0.8 nm = 4 nm: 5 nm exactly; sqrt(36 + 25) px.
        ("3-4-5 anisotropic", *r5c6, NM_X, NM_Y, (math.sqrt(61), 5.0)),
        ("3-4-5 reversed off the origin", (12.5, 30), (7.5, 24), NM_X, NM_Y, (math.sqrt(61), 5.0)),
        ("3-4-5 pixels", (2, 3), (5, 7), None, None, (5.0, None)),
        ("sub-pixel anisotropic", (3.3, 7.8), (41.7, 28.4), NM_X, NM_Y, None),
        ("sub-pixel square", (3.3, 7.8), (41.7, 28.4), {"scale": 0.0123, "units": "nm", "origin": 0.0},
         {"scale": 0.0123, "units": "nm", "origin": 0.0}, None),
        ("zero length", (4, 4), (4, 4), NM_X, NM_Y, (0.0, 0.0)),
        ("uncalibrated", *r5c6, None, None, None),
        ("x only", *r5c6, NM_X, None, None),
        ("y only", *r5c6, None, NM_Y, None),
        ("units differ", *r5c6, NM_X, UM_Y, None),
        ("unit empty", *r5c6, {"scale": 0.5, "units": "", "origin": 0.0}, NM_Y, None),
        ("scale zero", *r5c6, {"scale": 0.0, "units": "nm", "origin": 0.0}, NM_Y, None),
        ("reciprocal unit", *r5c6, {"scale": 0.17443286, "units": "1/nm", "origin": 0.0},
         {"scale": 0.17443286, "units": "1/nm", "origin": 0.0}, None),
        ("micrometres", *r5c6, {"scale": 0.16867469, "units": "µm", "origin": 0.0},
         {"scale": 0.16867469, "units": "µm", "origin": 0.0}, None),
    ]


def angle_cases():
    """(name, a, vertex b, c, x, y, hand degrees or None); points in (row, col)."""
    right = ((25, 22), (20, 18), (25, 2))    # (2, 4) nm and (-8, 4) nm: perpendicular in nm, 4*-16 + 5*5 = -39 in pixels
    tri_b = ((0, 6), (0, 0), (5, 0))          # 3-4-5 with the right angle at B
    cases = [
        ("right angle in nm not in pixels", *right, NM_X, NM_Y, 90.0),
        ("same arms uncalibrated", *right, None, None, None),
        ("same arms units differ", *right, NM_X, UM_Y, None),
        ("3-4-5 at the right angle", *tri_b, NM_X, NM_Y, 90.0),
        ("3-4-5 at A", (0, 0), (0, 6), (5, 0), NM_X, NM_Y, math.degrees(math.atan(4 / 3))),
        ("3-4-5 at C", (0, 6), (5, 0), (0, 0), NM_X, NM_Y, math.degrees(math.atan(3 / 4))),
        ("straight on", (4, 9), (4, 4), (4, 6), NM_X, NM_Y, 0.0),
        ("folded back", (4, 9), (4, 4), (4, 1), NM_X, NM_Y, 180.0),
        ("sub-pixel anisotropic", (3.3, 7.8), (20.6, 14.2), (41.7, 28.4), NM_X, NM_Y, None),
        ("A on B", (3, 3), (3, 3), (8, 1), NM_X, NM_Y, None),
        ("C on B", (8, 1), (3, 3), (3, 3), NM_X, NM_Y, None),
        ("both arms zero", (3, 3), (3, 3), (3, 3), None, None, None),
    ]
    # An angle of 1e-9 rad between two arms of 1000 px: atan2(|cross|, dot) keeps it, arccos rounds the ratio to 1.
    delta = 1e-9
    cases.append(("nearly parallel arms", (0, 1000), (0, 0), (1000 * math.sin(delta), 1000 * math.cos(delta)),
                  None, None, math.degrees(delta)))
    return cases


def check_closed_forms():
    """The closed forms reproduce the hand-worked values before the Swift code is compared with them."""
    for name, a, b, x, y, hand in distance_cases():
        px, phys, unit = distance_truth(a, b, x, y)
        if hand is not None:
            want_px, want_phys = hand
            if abs(px - want_px) > 1e-12 * max(want_px, 1) or (want_phys is None) != (phys is None) \
               or (phys is not None and abs(phys - want_phys) > 1e-12 * max(want_phys, 1)):
                fail(f"distance '{name}': computed ({px}, {phys}), worked by hand ({want_px}, {want_phys})")
    for name, a, b, c, x, y, hand in angle_cases():
        degrees, plane = angle_truth(a, b, c, x, y)
        if hand is not None and (degrees is None or abs(degrees - hand) > max(1e-12 * hand, 1e-14)):
            fail(f"angle '{name}': computed {degrees}, worked by hand {hand}")
        if degrees is not None and name != "nearly parallel arms" and 1 < degrees < 179:
            other = acos_degrees(a, b, c, x, y)
            if abs(degrees - other) > 1e-9:
                fail(f"angle '{name}': atan2 {degrees} and arccos {other} disagree")
    # The anisotropic right angle is not right in the pixel plane: the plant would be vacuous otherwise.
    pixel = angle_truth(*angle_cases()[1][1:4], None, None)[0]
    if abs(pixel - 90) < 10:
        fail("the planted right angle is also nearly right in pixels")


# ---------------------------------------------------------------------------------------------------------------------
# Images.

def planted_wave(w=37, h=53):
    """A sinusoid in both directions plus a cosine in c and a signed ramp, as float32: values of both signs, so many
    samples are near zero, and variation across every line's perpendicular, so the width matters."""
    r, c = np.mgrid[0:h, 0:w].astype(np.float64)
    v = (300 * np.sin(2 * np.pi * (r / 11.3 + c / 7.7)) + 150 * np.cos(2 * np.pi * c / 5.3)
         + 4 * (r - 26) + 2.5 * (c - 18))
    return v.astype(np.float32)


def ramp_value(r, c):
    return 1000 + 3.7 * r + 2.1 * c + 0.013 * r * c


def planted_ramp(w=37, h=53):
    r, c = np.mgrid[0:h, 0:w].astype(np.float64)
    return ramp_value(r, c).astype(np.float32)


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
    axis = lambda s, u, o: {"scale": float(np.float32(s)), "units": u, "origin": float(np.float32(o))}
    return data.astype(np.float32), axis(sx, ux, ox), axis(sy, uy, oy)


# ---------------------------------------------------------------------------------------------------------------------

def main():
    if len(sys.argv) != 5:
        fail("usage: reference.py <planted.dm4> <planted.truth.json> <rsciio-root> <out-dir>")
    dm4, truth_path, rsciio, out = sys.argv[1:5]
    versions = check_reference()
    check_closed_forms()
    os.makedirs(out, exist_ok=True)

    # ---- the images: name -> (float32 array, x axis or None, y axis or None, analytic function or None)
    images = {}
    wave, ramp = planted_wave(), planted_ramp()
    images["wave"] = (wave, NM_X, NM_Y, None)
    images["wave uncalibrated"] = (wave, None, None, None)
    images["wave units differ"] = (wave, NM_X, UM_Y, None)
    images["ramp"] = (ramp, NM_X, NM_Y, ramp_value)
    # Images one pixel thin and a 2 x 3 one, with seeded noise: scipy maps a length-1 axis to index 0 and every coordinate
    # of a length-2 axis is within one pixel of an edge, so the clamped neighbours of the port are exercised in full.
    rng = np.random.default_rng(20261013)
    for name, shape in (("strip one row", (1, 15)), ("strip one column", (17, 1)), ("tiny 2 x 3", (2, 3))):
        images[name] = (rng.normal(0, 100, size=shape).astype(np.float32), NM_X, NM_Y, None)

    with open(truth_path) as fh:
        truth = json.load(fh)
    if sha256(dm4) != truth["file_sha256"]:
        fail(f"{os.path.basename(dm4)}: sha256 differs from its truth file")
    planted = np.array(truth["pixels_row_major"], dtype=np.float64).reshape(truth["height"], truth["width"])
    if not np.array_equal(planted, np.array([[1000 * r + c - 12000 for c in range(truth["width"])]
                                             for r in range(truth["height"])], dtype=np.float64)):
        fail("the planted DM fixture's values are not row*1000 + col - 12000")
    axis_of = lambda a: {"scale": float(np.float32(np.frombuffer(int(a["scale_f32_bits"], 16).to_bytes(4, "little"),
                                                                 dtype="<f4")[0])), "units": a["units"],
                         "origin": float(a["origin"])}
    images["planted-2d.dm4"] = (planted.astype(np.float32), axis_of(truth["x"]), axis_of(truth["y"]),
                                lambda r, c: 1000 * r + c - 12000)

    registry = os.path.join(rsciio, "rsciio", "tests", "registry.txt")
    if sha256(registry) != REGISTRY_SHA256:
        fail("rsciio registry.txt is not the lock's")
    for name, rel, want_sha in REAL_IMAGES:
        path = os.path.join(rsciio, "rsciio", "tests", "data", rel)
        if sha256(path) != want_sha or f"'{rel}' {want_sha}" not in open(registry).read():
            fail(f"{rel}: not the pinned RosettaSciIO file")
        data, x, y = read_ncempy(path)
        images[name] = (data, x, y, None)

    # ---- the comparator, checked before the app: geometry, independent interpolation, analytic ramps
    for width in (1, 2, 3, 4, 5, 25):
        for src, dst in (((3.3, 7.8), (41.7, 28.4)), ((-5.5, -7.25), (60.3, 44.9)), ((10, 10), (10, 10)),
                         ((20.5, 3), (4.25, 31))):
            mine = my_coordinates(src, dst, width)
            theirs = _line_profile_coordinates(src, dst, linewidth=width)      # (2, n, width)
            if mine[0].shape != theirs[0].shape or max(np.abs(mine[0] - theirs[0]).max(),
                                                       np.abs(mine[1] - theirs[1]).max()) > 1e-12:
                fail(f"the geometry written here differs from skimage's _line_profile_coordinates ({src}, {dst}, w={width})")

    profiles = []
    summary = {"lines": 0, "ramp_max_rel": 0.0, "indep_max": 0.0, "f32_max": 0.0, "f32_max_rel_above_floor": 0.0}

    def add(image_name, line_name, src, dst, width, analytic):
        data, x, y, fn = images[image_name]
        maxabs = float(np.abs(data).max())
        f32 = skimage_profile(data, src, dst, width)
        f64 = skimage_profile(data.astype(np.float64), src, dst, width)
        if f32.dtype != np.float32:
            fail(f"skimage returned {f32.dtype} for a float32 image: the dtype note in LineProfile.swift is wrong")
        mine = my_profile(data, src, dst, width)
        if len(mine) != len(f64) or float(np.abs(mine - f64).max()) > 1e-12 * maxabs:
            fail(f"{image_name} {line_name} w{width}: skimage (float64) differs from the independent interpolation by "
                 f"{float(np.abs(mine - f64).max()) if len(mine) == len(f64) else 'count'}")
        summary["indep_max"] = max(summary["indep_max"], float(np.abs(mine - f64).max()) / maxabs)
        summary["f32_max"] = max(summary["f32_max"], float(np.abs(f32.astype(np.float64) - f64).max()) / maxabs)
        n = len(f64)
        # positions: i/(n-1) of the length, physical when both axes are calibrated in one unit
        px = math.hypot(dst[0] - src[0], dst[1] - src[1])
        _, phys, unit = distance_truth(src, dst, x, y)
        total = phys if phys is not None else px
        positions = np.linspace(0.0, total, n)
        entry = {"name": f"{image_name} {line_name} w{width}", "image": image_name,
                 "r0": float(src[0]), "c0": float(src[1]), "r1": float(dst[0]), "c1": float(dst[1]), "width": width,
                 "count": n, "f32": [float(v) for v in f32], "f64": [float(v) for v in f64],
                 "positions": [float(v) for v in positions], "unit": unit if phys is not None else "px",
                 "physical": phys is not None, "analytic": None}
        if analytic:
            rows, cols = my_coordinates(src, dst, width)
            if rows.min() < 0 or cols.min() < 0 or rows.max() > data.shape[0] - 1 or cols.max() > data.shape[1] - 1:
                fail(f"{image_name} {line_name}: an analytic line leaves the image")
            truth_v = fn(rows, cols).mean(axis=1)
            floor = 0.1 * maxabs
            rel = np.abs(f32.astype(np.float64) - truth_v) / np.maximum(np.abs(truth_v), floor)
            if float(rel.max()) > 1e-5:
                fail(f"{image_name} {line_name} w{width}: skimage differs from the analytic ramp by {float(rel.max())}")
            summary["ramp_max_rel"] = max(summary["ramp_max_rel"], float(rel.max()))
            entry["analytic"] = [float(v) for v in truth_v]
        profiles.append(entry)
        summary["lines"] += 1

    def full(image_name, widths, extra_widths=()):
        h, w = images[image_name][0].shape
        for name, (src, dst) in lines_for(h, w).items():
            for width in widths:
                add(image_name, name, src, dst, width, False)
        for name in ("diagonal", "subpixel", "border-crossing", "anti-diagonal", "45 degrees"):
            for width in extra_widths:
                add(image_name, name, *lines_for(h, w)[name], width, False)

    full("wave", (1, 2, 3, 4), extra_widths=(5, 25))
    for image_name in ("strip one row", "strip one column", "tiny 2 x 3"):
        full(image_name, (1, 3))
    for name in ("horizontal", "diagonal", "subpixel", "border-crossing"):
        h, w = images["wave"][0].shape
        for image_name in ("wave uncalibrated", "wave units differ"):
            add(image_name, name, *lines_for(h, w)[name], 3, False)
    # Analytic ramps: interior lines (the perpendicular stays inside, so no reflection), widths 1, 3, 4.
    for image_name in ("ramp", "planted-2d.dm4"):
        h, w = images[image_name][0].shape
        interior = {"horizontal": ((h // 2, 3), (h // 2, w - 4)), "vertical": ((3, w // 2), (h - 4, w // 2)),
                    "diagonal": ((4, 4), (h - 5, w - 6)), "subpixel": ((3.3, 7.8), (h - 6.7, w - 8.6)),
                    "3-4-5": ((10, 10), (13, 14)),
                    "anti-diagonal": ((h - 5, 4), (5, w - 6)), "45 degrees": ((4, 4), (4 + min(h, w) - 9, 4 + min(h, w) - 9))}
        for name, (src, dst) in interior.items():
            for width in (1, 2, 3, 4):
                add(image_name, name + " interior", src, dst, width, True)
    # the planted DM fixture on the lines that leave it, and the real images
    h, w = images["planted-2d.dm4"][0].shape
    for name, (src, dst) in lines_for(h, w).items():
        for width in (1, 3):
            add("planted-2d.dm4", name, src, dst, width, False)
    for image_name, _, _ in REAL_IMAGES:
        h, w = images[image_name][0].shape
        for name in ("horizontal", "vertical", "diagonal", "reverse diagonal", "subpixel", "border-crossing",
                     "along top edge", "zero length"):
            for width in (1, 3):
                add(image_name, name, *lines_for(h, w)[name], width, False)

    # ---- distances and angles
    distances, angles = [], []
    for name, a, b, x, y, hand in distance_cases():
        px, phys, unit = distance_truth(a, b, x, y)
        distances.append({"name": name, "a": list(map(float, a)), "b": list(map(float, b)), "x": x, "y": y,
                          "px": px, "physical": phys, "unit": unit})
    for name, a, b, c, x, y, hand in angle_cases():
        degrees, plane = angle_truth(a, b, c, x, y)
        angles.append({"name": name, "a": list(map(float, a)), "b": list(map(float, b)), "c": list(map(float, c)),
                       "x": x, "y": y, "degrees": degrees, "plane": plane})

    # ---- write the images and the manifest
    manifest_images = {}
    for name, (data, x, y, _) in images.items():
        fname = re.sub(r"[^A-Za-z0-9.-]+", "-", name) + ".f32"
        np.ascontiguousarray(data.astype("<f4")).tofile(os.path.join(out, fname))
        manifest_images[name] = {"width": int(data.shape[1]), "height": int(data.shape[0]), "x": x, "y": y,
                                 "pixels": fname, "maxabs": float(np.abs(data).max())}
    with open(os.path.join(out, "manifest.json"), "w") as fh:
        json.dump({"reference": versions, "images": manifest_images, "profiles": profiles,
                   "distances": distances, "angles": angles, "summary": summary}, fh)
    print(f"reference: {summary['lines']} profiles on {len(images)} images; skimage float64 vs the independent "
          f"interpolation, max {summary['indep_max']:.2e} of the image maximum; float32 vs float64, max "
          f"{summary['f32_max']:.2e}; ramps vs analytic, max {summary['ramp_max_rel']:.2e} relative")


if __name__ == "__main__":
    main()
