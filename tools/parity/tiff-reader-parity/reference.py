#!/usr/bin/env python3
"""Truth for tools/parity/tiff-reader-parity: the reference's reading of every case.

    reference.py <planted-dir> <rsciio-root> <owner-dir-or-"-"> <out-dir>

Reference = RosettaSciIO 049e7d70 (`rsciio.tiff.file_reader`, References/rosettasciio put on sys.path) with tifffile
2026.9.20 (both pinned: versions against tools/lib/references-lock.txt, the commit by tools/lib/fetch-rsciio.sh and
the registry.txt sha256 below). Two kinds of case:

  "reference": "rsciio"        read by RosettaSciIO: the planted ImageJ / DM / plain files, RosettaSciIO's own
                               ImageJ, DM-saved and FEI Helios test files.
  "reference": "registration"  the Velox/Ceta convention (tag 34683), which no published reader reads: the
                               registration's rule (archive: roadmap-registrations-2026-10-15.md V1-3b) written here from the tags. Planted Velox files
                               and the owner's Ceta TIFFs (diagnostic, skipped when absent).

Registration also covers (a) the FEI SEM files, where macTEM's documented DEVIATION puts PixelWidth (and
HFW/ResolutionX) on x = width and RosettaSciIO puts them on the height axis: reference.py computes the registration's
axes from the file's own tifffile.fei_metadata and ASSERTS RosettaSciIO's reading equals them swapped (and fails
loudly if it ever stops swapping, or if the file is isotropic and so proves nothing); (b) Digital Micrograph files
whose scale is 0 or not finite: that axis is uncalibrated (RosettaSciIO keeps the 0, asserted).

Before any reading counts, the reference must reproduce every PLANTED truth that make_fixture.py wrote (shape,
pixels, each axis's scale / origin / units, the notes, the refusal's structural cause): a reference that disagrees with
the plant exits 1 here, loudly — that is a reference check, never a pass. Refusals are verified structurally with
tifffile (page count, compression, tiling, photometric, sample format, unequal channels).

Writes <out>/manifest.json (contract: see README.md) and one <case>.f32 per image (little-endian float32, row-major,
width fastest). A calibrated axis is {scale, origin, units}; origin = -offset/scale in pixels (+0.0 when the offset
is zero), compared exactly. An axis RosettaSciIO leaves without units is null (uncalibrated), even when it carries a
scale (it does for ImageJ units other than "micron"; that is printed, and not a case).
"""
import hashlib
import importlib.metadata
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
import zipfile

import numpy as np
import tifffile

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = os.path.join(HERE, "..", "..", "lib", "references-lock.txt")
PYTHON_MINOR = "3.14"
REGISTRY_SHA256 = "31417482938f80160be2c03525ba58dd810c7f16b1790f597470ece8dd0b1bcb"
RSCIIO_COMMIT = "049e7d70"
TIFFFILE = "2026.9.20"

RN = "8-bit render, not counts"
UV = "scale unvalidated (one acquisition)"
DIS = "uncalibrated: the Velox XML and the resolution tags disagree"

# RosettaSciIO's own files under rsciio/tests/data/tiff (sha256 against registry.txt), name -> (case, error)
RSCIIO_TIFFS = [
    ("test_loading_image_saved_with_imageJ.tif", "rsciio-imagej-float32-um", None),
    ("test_loading_image_saved_with_imageJ_no_scale.tif", "rsciio-imagej-float32-nocal", None),
    ("test_loading_image_saved_with_DM.tif", "rsciio-dm-int32-um", None),
    ("test_loading_image_saved_with_imageJ_stack.tif", "rsciio-imagej-stack", "multiPage"),
    ("test_loading_image_saved_with_DM_stack.tif", "rsciio-dm-stack", "multiPage"),
]
FEI_ZIP = "tiff_FEI_Helios.zip"
FEI = [   # member, case, diagnostic
    ("FEI-Helios-Ebeam-16bits.tif", "rsciio-fei-helios-ebeam-16bit", False),
    ("FEI-Helios-Ebeam-8bits.tif", "rsciio-fei-helios-ebeam-8bit", False),
    ("FEI-Helios-navcam-with-no-IRBeam.tif", "rsciio-fei-helios-navcam-no-irbeam", False),
    ("FEI-Helios-navcam-with-no-IRBeam-bad-floats.tif", "rsciio-fei-helios-navcam-no-irbeam-bad-floats", False),
    # RosettaSciIO assigns the IRBeam fallback scales to the WRONG axes (see README.md): diagnostic only.
    ("FEI-Helios-navcam.tif", "rsciio-fei-helios-navcam-irbeam", False),
]
OWNER = ["Camera Ceta 1305 17500 x 20260605 Ceta.tif", "Camera Ceta 1620 630 kx 20260605 Ceta.tif"]


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def check_reference(root):
    python = "%d.%d" % sys.version_info[:2]
    if python != PYTHON_MINOR:
        fail(f"Python {python} is not the pinned {PYTHON_MINOR}")
    pins = {}
    for line in open(LOCK):
        m = re.match(r"^([A-Za-z0-9_.-]+)==(\S+)\s*$", line)
        if m:
            pins[m.group(1).lower()] = m.group(2)
    if pins.get("tifffile") != TIFFFILE or tifffile.__version__ != TIFFFILE:
        fail(f"tifffile pinned {pins.get('tifffile')}, imported {tifffile.__version__}, expected {TIFFFILE}")
    for p in ("numpy", "python-box", "imagecodecs"):
        if importlib.metadata.version(p) != pins.get(p):
            fail(f"{p} {importlib.metadata.version(p)} is not the pinned {pins.get(p)}")
    if sha256_file(os.path.join(root, "rsciio", "tests", "registry.txt")) != REGISTRY_SHA256:
        fail("rsciio/tests/registry.txt is not the pinned file (References/rosettasciio is not the lock)")
    sys.path.insert(0, root)
    from rsciio.tiff import file_reader
    return file_reader


def registry(root):
    reg = {}
    for line in open(os.path.join(root, "rsciio", "tests", "registry.txt")):
        m = re.match(r"^'([^']+)'\s+([0-9a-f]{64})\s*$", line)
        if m:
            reg[m.group(1)] = m.group(2)
    return reg


# ---------------------------------------------------------------- RosettaSciIO's reading -------------------------
def axis_of(a, what):
    """RosettaSciIO axis dict -> {scale, origin, units} or None. origin = -offset/scale, +0.0 for a zero offset."""
    scale, off, unit = float(a["scale"]), float(a["offset"]), a["units"]
    if unit is None or unit == "":
        if scale != 1.0 or off != 0.0:
            print(f"  note  {what}: RosettaSciIO has scale {scale!r} offset {off!r} but no unit: read as uncalibrated")
        return None
    return {"scale": scale, "origin": 0.0 if off == 0.0 else -off / scale, "units": unit}


def read_rsciio(file_reader, path):
    """-> (kind, data2d, x, y, detail). kind 'image' | 'multi' | 'rgb' (data = channels (h,w,3))."""
    r = file_reader(path)
    if len(r) != 1:
        return "multi", None, None, None, f"{len(r)} series"
    d = r[0]
    axes = {a["name"]: a for a in d["axes"]}
    data = d["data"]
    if data.ndim != 2 or set(axes) != {"height", "width"}:
        return "multi", None, None, None, f"shape {data.shape} axes {list(axes)}"
    if data.dtype.names:
        data = np.stack([data[n] for n in data.dtype.names], axis=-1)
    return "image", data, axis_of(axes["width"], "x"), axis_of(axes["height"], "y"), ""


# ---------------------------------------------------------------- the registration's Velox rule -------------------
def f32_half_ulp(v):
    """Half the float32 spacing at v (Velox stores the per-cm count after a float32 rounding, as a RATIONAL n/1)."""
    return float(np.spacing(np.float32(v))) / 2


def velox_registration(path):
    """V1-3b (b): scale from /Metadata/BinaryResult/PixelSize/X,Y (unit attribute), origin 0 (Offset is not read);
    cross-check only when 65452 == 3 and both units are "m", and only the axes whose tag is present (65450 for x,
    65451 for y; neither present: no check): an axis agrees iff abs(perCm - 0.01/scale) <= 0.5 +
    float32_half_ulp(perCm). Any checked axis disagreeing -> both null + the disagreement note."""
    with tifffile.TiffFile(path) as t:
        tags = t.pages[0].tags
        if 34683 not in tags:
            return None
        root = ET.fromstring(tags[34683].value.encode() if isinstance(tags[34683].value, str) else tags[34683].value)
        ps = root.find("./BinaryResult/PixelSize")
        if ps is None:
            return None            # no Velox calibration: the ImageJ / DM reading stands (not a Velox case)
        px, py = ps.find("X"), ps.find("Y")
        sx, sy = float(px.text), float(py.text)
        ux, uy = px.get("unit"), py.get("unit")
        def rat(code):
            if code not in tags:
                return None
            v = tags[code].value
            return float(v[0]) / float(v[1]) if isinstance(v, tuple) else float(v)
        cx, cy = rat(65450), rat(65451)
        checked = (cx is not None or cy is not None) and 65452 in tags and tags[65452].value == 3 \
            and ux == "m" and uy == "m"
        agree = True
        if checked:
            for per, s in ((cx, sx), (cy, sy)):
                if per is not None:
                    agree = agree and abs(per - 0.01 / s) <= 0.5 + f32_half_ulp(per)
        if not agree:
            return None, None, [DIS], checked
        return {"scale": sx, "origin": 0.0, "units": ux}, {"scale": sy, "origin": 0.0, "units": uy}, [UV], checked


def fei_registration(path):
    """The registration's FEI reading (macTEM's DEVIATION from RosettaSciIO): Scan/PixelWidth -> x (width),
    PixelHeight -> y; else IRBeam HFW / Image ResolutionX -> x, VFW / ResolutionY -> y; units "m", origin 0. Read from
    tifffile.fei_metadata (the same parser RosettaSciIO uses); (None, None) when neither block gives a scale."""
    with tifffile.TiffFile(path) as t:
        m = t.fei_metadata
    try:
        sx, sy = float(m["Scan"]["PixelWidth"]), float(m["Scan"]["PixelHeight"])
    except KeyError:
        try:
            sx = float(m["IRBeam"]["HFW"]) / float(m["Image"]["ResolutionX"])
            sy = float(m["IRBeam"]["VFW"]) / float(m["Image"]["ResolutionY"])
        except KeyError:
            return None, None
    return {"scale": sx, "origin": 0.0, "units": "m"}, {"scale": sy, "origin": 0.0, "units": "m"}


def sane(a):
    """Registration: an axis whose scale is not finite and > 0 is uncalibrated (never a 0 or inf pixel size)."""
    if a is None or not (np.isfinite(a["scale"]) and a["scale"] > 0):
        return None
    return a


def assert_fei_swap(name, got_x, got_y, reg_x, reg_y, problems):
    """RosettaSciIO's FEI reading must equal the registration's SWAPPED (and the file must be anisotropic, or the
    check proves nothing). Fails loudly the day RosettaSciIO stops swapping."""
    if reg_x is None:
        if got_x is not None or got_y is not None:
            problems.append(f"{name}: RosettaSciIO calibrated a file the registration reads as uncalibrated")
        return
    if reg_x["scale"] == reg_y["scale"]:
        problems.append(f"{name}: isotropic ({reg_x['scale']!r}) - the PixelWidth/PixelHeight swap is not exercised")
        return
    if not (same_axis(got_x, reg_y) and same_axis(got_y, reg_x)):
        problems.append(f"{name}: RosettaSciIO's axes x={got_x} y={got_y} are not the registration's SWAPPED "
                        f"(x={reg_x} y={reg_y}); the documented swap (README.md) no longer holds - revisit the DEVIATION")


def rgb_channels(path):
    with tifffile.TiffFile(path) as t:
        p = t.pages[0]
        return p, p.asarray()


# ---------------------------------------------------------------- structural truth of refusals --------------------
def refusal_cause(path):
    """The error name a file's own structure demands, from tifffile (independent of the planted label)."""
    with tifffile.TiffFile(path) as t:
        if len(t.pages) > 1:
            return "multiPage"
        p = t.pages[0]
        if p.is_imagej:
            ij = t.imagej_metadata or {}
            if int(np.prod([int(ij.get(k, 1)) for k in ("images", "slices", "frames", "channels")])) > 1:
                return "multiPage"
        if p.compression != tifffile.COMPRESSION.NONE:
            return "compressed"
        if p.is_tiled:
            return "tiled"
        needed = p.imagewidth * p.imagelength * p.samplesperpixel * p.bitspersample // 8     # Python ints: no overflow
        if needed > sum(p.databytecounts):
            return "truncated"
        a = p.asarray()
        if p.photometric == tifffile.PHOTOMETRIC.RGB and p.samplesperpixel == 3 and p.bitspersample == 8:
            if not (np.array_equal(a[..., 0], a[..., 1]) and np.array_equal(a[..., 1], a[..., 2])):
                return "unequalChannels"
            return None
        if p.photometric not in (tifffile.PHOTOMETRIC.MINISBLACK,):
            return "sampleFormat"
        if a.dtype not in (np.uint8, np.uint16, np.uint32, np.int16, np.int32, np.float32):
            return "sampleFormat"
        return None


def sha_le(a):
    return hashlib.sha256(np.ascontiguousarray(a.astype(a.dtype.newbyteorder("<"))).tobytes()).hexdigest()


def same_axis(a, b):
    if a is None or b is None:
        return a is None and b is None
    return a["units"] == b["units"] and a["scale"].hex() == b["scale"].hex() and a["origin"].hex() == b["origin"].hex()


def main(planted_dir, root, owner_dir, out):
    file_reader = check_reference(root)
    os.makedirs(out, exist_ok=True)
    planted = json.load(open(os.path.join(planted_dir, "planted.json")))
    problems, cases = [], []

    def write_pixels(name, data):
        p = os.path.abspath(os.path.join(out, name + ".f32"))
        np.ascontiguousarray(data.astype("<f4")).tofile(p)
        return p

    def entry(name, path, ref, data, x, y, notes, diagnostic=False):
        return {"name": name, "path": os.path.abspath(path), "kind": "image", "reference": ref,
                "width": int(data.shape[1]), "height": int(data.shape[0]), "x": x, "y": y,
                "pixels": write_pixels(name, data), "notes": notes, "error": None, "diagnostic": diagnostic}

    def refusal(name, path, ref, error, diagnostic=False):
        return {"name": name, "path": os.path.abspath(path), "kind": "refusal", "reference": ref,
                "width": None, "height": None, "x": None, "y": None, "pixels": None, "notes": [], "error": error,
                "diagnostic": diagnostic}

    # ---------------- planted: the reference must reproduce the plant ----------------
    for c in planted["cases"]:
        name, path = c["name"], os.path.join(planted_dir, c["file"])
        bad = lambda msg: problems.append(f"planted {name}: {msg}")
        is_velox = name.startswith("velox-")
        if c["kind"] == "refusal":
            cause = refusal_cause(path)
            if cause != c["error"]:
                bad(f"tifffile's structure says {cause!r}, planted {c['error']!r}")
            if name.startswith("ijstack-"):
                kind = read_rsciio(file_reader, path)[0]
                if kind != "multi":
                    bad(f"RosettaSciIO reads the single-IFD ImageJ stack as {kind}, not a stack")
            cases.append(refusal(name, path, "registration" if is_velox else "rsciio", c["error"]))
            continue
        p, arr = rgb_channels(path)
        is_rgb = arr.ndim == 3
        if is_rgb:
            if not (np.array_equal(arr[..., 0], arr[..., 1]) and np.array_equal(arr[..., 1], arr[..., 2])):
                bad("RGB planted equal but tifffile reads unequal channels")
                continue
            arr = arr[..., 0]
        if sha_le(arr) != c["pixels_sha256"]:
            bad("the pixels tifffile reads are not the planted pixels")
        ref = c.get("reference") or ("registration" if is_velox else "rsciio")
        if is_velox:
            vx, vy, vnotes, _ = velox_registration(path)
            x, y, notes = vx, vy, vnotes
            if is_rgb:
                notes = [RN] + notes
        else:
            kind, data, rx, ry, detail = read_rsciio(file_reader, path)
            if kind != "image":
                bad(f"RosettaSciIO read {detail}")
                continue
            if is_rgb:
                data = data[..., 0]
                if not np.array_equal(data, arr):
                    bad("RosettaSciIO's R channel is not tifffile's")
            if sha_le(data) != c["pixels_sha256"] or data.shape != (c["height"], c["width"]):
                bad(f"RosettaSciIO's pixels/shape {data.shape} are not the planted ones")
            notes = [RN] if is_rgb else []
            x, y = rx, ry
            if c.get("rsciio") is not None:       # the planted EXPECTATION of RosettaSciIO's own (deviating) reading
                if not (same_axis(rx, c["rsciio"]["x"]) and same_axis(ry, c["rsciio"]["y"])):
                    bad(f"RosettaSciIO read x={rx} y={ry}, expected {c['rsciio']['x']} / {c['rsciio']['y']}")
            if name.startswith("fei-"):
                x, y = fei_registration(path)
                assert_fei_swap(name, rx, ry, x, y, problems)
            elif ref == "registration":
                x, y = sane(rx), sane(ry)
        if not (same_axis(x, c["x"]) and same_axis(y, c["y"])):
            bad(f"axes {x} / {y} are not the planted {c['x']} / {c['y']}")
        if notes != c["notes"]:
            bad(f"notes {notes} are not the planted {c['notes']}")
        cases.append(entry(name, path, ref, arr, x, y, notes))

    # ---------------- RosettaSciIO's own test files (hash against its registry) ----------------
    reg = registry(root)
    tdir = os.path.join(root, "rsciio", "tests", "data", "tiff")
    def trusted(rel):
        if sha256_file(os.path.join(root, "rsciio", "tests", "data", rel)) != reg["%s" % rel]:
            fail(f"{rel} does not match rsciio/tests/registry.txt")
    for fname, name, err in RSCIIO_TIFFS:
        trusted("tiff/" + fname)
        path = os.path.join(tdir, fname)
        cause = refusal_cause(path)
        if err:
            if cause != err:
                problems.append(f"{name}: structure says {cause!r}, expected {err!r}")
            cases.append(refusal(name, path, "rsciio", err))
            continue
        kind, data, x, y, detail = read_rsciio(file_reader, path)
        if kind != "image" or cause is not None:
            problems.append(f"{name}: RosettaSciIO {kind} {detail}, structure {cause}")
            continue
        with tifffile.TiffFile(path) as t:
            if not np.array_equal(t.pages[0].asarray(), data):
                problems.append(f"{name}: RosettaSciIO's pixels differ from tifffile's")
        cases.append(entry(name, path, "rsciio", data, x, y, []))

    work = os.path.join(out, "work")
    os.makedirs(work, exist_ok=True)
    trusted("tiff/" + FEI_ZIP)
    with zipfile.ZipFile(os.path.join(tdir, FEI_ZIP)) as z:
        z.extractall(work)
    for member, name, diag in FEI:
        path = os.path.join(work, member)
        kind, data, x, y, detail = read_rsciio(file_reader, path)
        if kind != "image":
            problems.append(f"{name}: {kind} {detail}")
            continue
        reg_x, reg_y = fei_registration(path)
        if diag or reg_x is None or reg_x["scale"] != reg_y["scale"]:
            assert_fei_swap(name, x, y, reg_x, reg_y, problems)
        elif not (same_axis(x, reg_x) and same_axis(y, reg_y)):        # isotropic: no swap to see, the readings agree
            problems.append(f"{name}: RosettaSciIO {x} / {y} differs from the registration's {reg_x} / {reg_y}")
        if diag and reg_x is not None:
            print(f"  note  {name}: RosettaSciIO's x scale {y and y['scale']!r} sits on the HEIGHT axis (swap asserted)")
        cases.append(entry(name, path, "registration", data, reg_x, reg_y, [], diag))

    # ---------------- the owner's Ceta TIFFs (diagnostic) ----------------
    for fname in OWNER:
        path = os.path.join(owner_dir, fname) if owner_dir != "-" else ""
        name = "owner-" + re.sub(r"[^A-Za-z0-9]+", "-", fname.replace(" Ceta.tif", "")).strip("-").lower()
        if not path or not os.path.isfile(path):
            print(f"  skip  {name}: {fname} not found; supply it in References/example_files/ (gitignored) to run this diagnostic")
            continue
        p, arr = rgb_channels(path)
        if arr.ndim != 3 or not (np.array_equal(arr[..., 0], arr[..., 1]) and np.array_equal(arr[..., 1], arr[..., 2])):
            problems.append(f"{name}: not an R=G=B RGB file")
            continue
        x, y, notes, _ = velox_registration(path)
        cases.append(entry(name, path, "registration", arr[..., 0], x, y, [RN] + notes, True))

    if problems:
        print("reference.py: THE REFERENCE DISAGREES WITH THE PLANT / ITS OWN CHECKS:", file=sys.stderr)
        for m in problems:
            print("  - " + m, file=sys.stderr)
        sys.exit(1)

    with open(os.path.join(out, "manifest.json"), "w") as fh:
        json.dump({"rsciio": RSCIIO_COMMIT, "tifffile": TIFFFILE, "cases": cases}, fh, indent=1, ensure_ascii=False)
    print(f"reference.py: {len(cases)} cases, the reference reproduces every planted truth")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
