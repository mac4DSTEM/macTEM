#!/usr/bin/env python3
"""Truth for tools/parity/mrc-reader-parity: the reference's reading of every case.

    reference.py <planted-dir> <rsciio-root> <out-dir>

Reference = mrcfile 1.5.4 (pinned in tools/lib/references-lock.txt; BSD, pure Python): `MrcFile.data`, `voxel_size`,
`header`. Opened STRICT (`permissive=False`) for every file that must open; PERMISSIVE only where a defective file has
to be read to name its defect (a header field of a file mrcfile refuses). RosettaSciIO is NOT run (its rsciio/mrc
needs dask, reads mode 0 as uint8 and ignores the machine stamp: see README.md); only its tests/data/mrc files are
used, their sha256 checked against rsciio/tests/registry.txt.

Before any reading counts, the reference must reproduce every PLANTED truth that make_fixture.py wrote (dtype of the
mode, shape, every pixel bit for bit after the float32 cast, each axis's scale as float(voxel_size) and its
calibrated / uncalibrated verdict, the header words): a reference that disagrees with the plant exits 1, loudly.

Refusals. mrcfile does not name a refusal, and for several defects it reads without complaint (modes 4, mapc/mapr/maps,
nz > 1, nx = 0), so the CAUSE comes from the header bytes, decoded here (`refusal_cause`), in this order -- the first
that applies:
    notMRC     file < 1024 bytes, or bytes 208..211 are not "MAP "
    byteOrder  machine stamp (212..213) is not 44 44 / 44 41 (little) / 11 11 (big)
    notMRC     nx <= 0 or ny <= 0
    mode       mode not in {0, 1, 2, 6, 12}
    stack      nz > 1
    axisOrder  (mapc, mapr, maps) != (1, 2, 3)
    truncated  NSYMBT < 0, or the file is shorter than 1024 + NSYMBT + nx*ny*bytes(mode)
Each is then CONFIRMED against mrcfile where mrcfile has an opinion (strict open raises ValueError; or the data
shape / dtype / header / validate() say the same), and a disagreement exits 1.

Scale. x = {"scale": float(voxel_size.x), "origin": 0.0, "units": "Å"}; macTEM compares Double(float32 voxel size),
i.e. the same bits. null (both axes) with the note "uncalibrated: the cell length is not positive" when either scale
is <= 0 or not finite.
"""
import hashlib
import importlib.metadata
import io
import json
import math
import os
import re
import struct
import sys
import warnings

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = os.path.join(HERE, "..", "..", "lib", "references-lock.txt")
PYTHON_MINOR = "3.14"
MRCFILE = "1.5.4"
REGISTRY_SHA256 = "31417482938f80160be2c03525ba58dd810c7f16b1790f597470ece8dd0b1bcb"
RSCIIO_COMMIT = "049e7d70"
UNCAL = "uncalibrated: the cell length is not positive"
FEI = "uncalibrated: an FEI extended header holds the pixel size, not read"
FEI_NEXT = 128 * 1024   # RosettaSciIO 049e7d70 rsciio/mrc/_api.py: NEXT/1024 == 128 is an FEI extended header
DTYPE = {0: "int8", 1: "int16", 2: "float32", 6: "uint16", 12: "float16"}
BYTES = {0: 1, 1: 2, 2: 4, 6: 2, 12: 2}

# RosettaSciIO's tests/data/mrc: name -> (case, expected refusal or None)
RSCIIO_MRC = [
    ("HAADFscan.mrc", "rsciio-haadfscan", None),
    ("20241021_00405_final.mrc", "rsciio-de-final", None),
    ("ROI_Random_Scan_Sum.mrc", "rsciio-roi-random-scan-sum", None),
    ("20241021_00405_0_Virt 0_sum.mrc", "rsciio-de-virt0-sum", None),
    ("20241021_00405_1_Virt 1_sum.mrc", "rsciio-de-virt1-sum", None),
    ("20241021_00405_ext1_Ext 1.mrc", "rsciio-de-ext1", None),
    ("4DSTEMscan.mrc", "rsciio-4dstemscan", "stack"),
    ("Custom_movie.mrc", "rsciio-custom-movie", "stack"),
    ("20241021_00405_movie.mrc", "rsciio-de-movie", "stack"),
    ("ROI_Random_Scan_movie.mrc", "rsciio-roi-random-scan-movie", "stack"),
]
HAADF_NSYMBT = 909312

warnings.filterwarnings("ignore", message="Setting the dtype on a NumPy array has been deprecated")


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def check_reference(root):
    import mrcfile
    python = "%d.%d" % sys.version_info[:2]
    if python != PYTHON_MINOR:
        fail(f"Python {python} is not the pinned {PYTHON_MINOR}")
    pins = {}
    for line in open(LOCK):
        m = re.match(r"^([A-Za-z0-9_.-]+)==(\S+)\s*$", line)
        if m:
            pins[m.group(1).lower()] = m.group(2)
    if pins.get("mrcfile") != MRCFILE or importlib.metadata.version("mrcfile") != MRCFILE or mrcfile.__version__ != MRCFILE:
        fail(f"mrcfile pinned {pins.get('mrcfile')}, imported {mrcfile.__version__}, expected {MRCFILE}")
    if importlib.metadata.version("numpy") != pins.get("numpy"):
        fail(f"numpy {importlib.metadata.version('numpy')} is not the pinned {pins.get('numpy')}")
    if sha256_file(os.path.join(root, "rsciio", "tests", "registry.txt")) != REGISTRY_SHA256:
        fail("rsciio/tests/registry.txt is not the pinned file (References/rosettasciio is not the lock)")
    return mrcfile


def registry(root):
    reg = {}
    for line in open(os.path.join(root, "rsciio", "tests", "registry.txt")):
        m = re.match(r"^'([^']+)'\s+([0-9a-f]{64})\s*$", line)
        if m:
            reg[m.group(1)] = m.group(2)
    return reg


# ---------------------------------------------------------------- the cause of a refusal, from the header bytes ----
def refusal_cause(path):
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        h = fh.read(1024)
    if len(h) < 1024 or h[208:212] != b"MAP ":
        return "notMRC"
    stamp = h[212:214]
    if stamp in (b"\x44\x44", b"\x44\x41"):
        end = "<"
    elif stamp == b"\x11\x11":
        end = ">"
    else:
        return "byteOrder"
    nx, ny, nz, mode = struct.unpack(end + "4i", h[0:16])
    mapc, mapr, maps = struct.unpack(end + "3i", h[64:76])
    nsymbt = struct.unpack(end + "i", h[92:96])[0]
    if nx <= 0 or ny <= 0 or nz <= 0:
        return "notMRC"
    if mode not in BYTES:
        return "mode"
    if nz > 1:
        return "stack"
    if (mapc, mapr, maps) != (1, 2, 3):
        return "axisOrder"
    if nsymbt < 0 or size < 1024 + nsymbt + nx * ny * BYTES[mode]:
        return "truncated"
    return None


def confirm_with_mrcfile(mrcfile, path, cause):
    """mrcfile's own opinion of a file whose refusal is `cause`. -> a problem string, or None when it agrees."""
    def strict():
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            return mrcfile.open(path, mode="r", permissive=False)
    with open(path, "rb") as fh:
        h = fh.read(1024)
    if cause in ("notMRC", "byteOrder", "mode", "truncated") and not (cause == "mode" and len(h) >= 16 and struct.unpack("<i", h[12:16])[0] == 4) \
            and not (cause == "notMRC" and len(h) >= 1024 and h[208:212] == b"MAP "):
        try:
            strict().close()
        except ValueError:
            return None
        return f"mrcfile opened a file refused as {cause}"
    if cause == "notMRC":                      # nx / ny <= 0: mrcfile has no opinion; its permissive header must agree
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            try:
                with mrcfile.open(path, mode="r", permissive=True) as m:
                    ok = m.header.nx <= 0 or m.header.ny <= 0 or m.header.nz <= 0
            except ValueError:
                return None
        return None if ok else "mrcfile's header has nx, ny, nz > 0"
    if cause == "mode":                        # mode 4: mrcfile reads complex64 -- a mode the app does not take
        with strict() as m:
            return None if m.data.dtype == np.complex64 else f"mrcfile reads mode 4 as {m.data.dtype}"
    if cause == "stack":
        with strict() as m:
            nz = int(m.header.nz)
            return None if m.data.ndim == 3 and m.data.shape[0] == nz and nz > 1 else f"mrcfile shapes it {m.data.shape}"
    if cause == "axisOrder":
        with strict() as m:
            axes = (int(m.header.mapc), int(m.header.mapr), int(m.header.maps))
            if axes == (1, 2, 3):
                return "mrcfile reads mapc/mapr/maps = 1 2 3"
        out = io.StringIO()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            valid = mrcfile.validate(path, print_file=out)
        return None if not valid else "mrcfile.validate() accepts the axis order"
    return f"no confirmation rule for {cause}"


# ---------------------------------------------------------------- mrcfile's reading of an image ------------------
def read_image(mrcfile, path):
    """Strict read. -> dict(data (ny, nx) in the file's dtype, raw shape, x, y raw scales (float of float32), header)."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        with mrcfile.open(path, mode="r", permissive=False) as m:
            raw = m.data
            hd = m.header
            vs = m.voxel_size
            sx, sy = float(vs.x), float(vs.y)
            data = np.array(raw)
            return {"data": data, "raw_shape": raw.shape, "sx": sx, "sy": sy, "mode": int(hd.mode),
                    "nx": int(hd.nx), "ny": int(hd.ny), "nz": int(hd.nz), "ispg": int(hd.ispg),
                    "nsymbt": int(hd.nsymbt), "axes": (int(hd.mapc), int(hd.mapr), int(hd.maps))}


def axes_of(sx, sy, nsymbt=0):
    """-> (x, y, notes): both null + the FEI note for an FEI extended header (its pixel size, in metres, is in that
    header, and cella/mx is not it); both null + the note when either scale is not finite and > 0."""
    if nsymbt == FEI_NEXT:
        return None, None, [FEI]
    if all(math.isfinite(s) and s > 0 for s in (sx, sy)):
        return ({"scale": sx, "origin": 0.0, "units": "Å"}, {"scale": sy, "origin": 0.0, "units": "Å"}, [])
    return None, None, [UNCAL]


def same_axis(a, b):
    if a is None or b is None:
        return a is None and b is None
    return a["scale"].hex() == b["scale"].hex() and a["origin"].hex() == b["origin"].hex() and a["units"] == b["units"]


def sha_f32(a):
    return hashlib.sha256(np.ascontiguousarray(a.astype("<f4")).tobytes()).hexdigest()


def main(planted_dir, root, out):
    mrcfile = check_reference(root)
    os.makedirs(out, exist_ok=True)
    planted = json.load(open(os.path.join(planted_dir, "planted.json")))
    problems, cases = [], []

    def write_pixels(name, data):
        p = os.path.abspath(os.path.join(out, name + ".f32"))
        np.ascontiguousarray(data.astype("<f4")).tofile(p)
        return p

    def entry(name, path, data, x, y, notes, diagnostic=False):
        return {"name": name, "path": os.path.abspath(path), "kind": "image", "reference": "mrcfile",
                "width": int(data.shape[1]), "height": int(data.shape[0]), "x": x, "y": y,
                "pixels": write_pixels(name, data), "notes": notes, "error": None, "diagnostic": diagnostic}

    def refusal(name, path, error, diagnostic=False):
        return {"name": name, "path": os.path.abspath(path), "kind": "refusal", "reference": "mrcfile",
                "width": None, "height": None, "x": None, "y": None, "pixels": None, "notes": [], "error": error,
                "diagnostic": diagnostic}

    # ---------------- planted: the reference must reproduce the plant ----------------
    for c in planted["cases"]:
        name, path = c["name"], os.path.join(planted_dir, c["file"])
        bad = lambda msg: problems.append(f"planted {name}: {msg}")
        if c["kind"] == "refusal":
            cause = refusal_cause(path)
            if cause != c["error"]:
                bad(f"the header bytes say {cause!r}, planted {c['error']!r}")
                continue
            why = confirm_with_mrcfile(mrcfile, path, cause)
            if why:
                bad(f"mrcfile disagrees with the refusal {cause!r}: {why}")
            cases.append(refusal(name, path, c["error"]))
            continue
        if refusal_cause(path) is not None:
            bad(f"the header bytes refuse a planted image as {refusal_cause(path)!r}")
            continue
        try:
            r = read_image(mrcfile, path)
        except Exception as e:
            bad(f"mrcfile (strict) cannot read it: {e}")
            continue
        if r["mode"] != c["mode"] or r["data"].dtype.name != DTYPE[c["mode"]]:
            bad(f"mrcfile reads mode {r['mode']} as {r['data'].dtype}, planted mode {c['mode']} = {DTYPE[c['mode']]}")
        want_shape = (1, c["height"], c["width"]) if c["ispg"] == 1 else (c["height"], c["width"])
        if r["raw_shape"] != want_shape:
            bad(f"mrcfile shapes it {r['raw_shape']}, expected {want_shape}")
        if r["nsymbt"] != c["ext"] or r["axes"] != (1, 2, 3) or r["nz"] != 1:
            bad(f"header nsymbt {r['nsymbt']} / axes {r['axes']} / nz {r['nz']} are not the plant")
        data = r["data"].reshape(c["height"], c["width"])
        if sha_f32(data) != c["pixels_sha256"]:
            bad("the pixels mrcfile reads are not the planted pixels")
        if data.dtype.kind in "iu" and not np.array_equal(data.astype("<f4").astype(np.int64), data.astype(np.int64)):
            bad("a float32 cast is not exact for this integer mode")
        x, y, notes = axes_of(r["sx"], r["sy"], r["nsymbt"])
        if not (same_axis(x, c["x"]) and same_axis(y, c["y"])):
            bad(f"axes {x} / {y} are not the planted {c['x']} / {c['y']}")
        if notes != c["notes"]:
            bad(f"notes {notes} are not the planted {c['notes']}")
        cases.append(entry(name, path, data, x, y, notes))

    # ---------------- RosettaSciIO's own test files (hash against its registry) ----------------
    reg = registry(root)
    mdir = os.path.join(root, "rsciio", "tests", "data", "mrc")
    for fname, name, err in RSCIIO_MRC:
        rel = "mrc/" + fname
        path = os.path.join(mdir, fname)
        if sha256_file(path) != reg[rel]:
            fail(f"{rel} does not match rsciio/tests/registry.txt")
        cause = refusal_cause(path)
        if err:
            if cause != err:
                problems.append(f"{name}: the header bytes say {cause!r}, expected {err!r}")
                continue
            why = confirm_with_mrcfile(mrcfile, path, cause)
            if why:
                problems.append(f"{name}: mrcfile disagrees with the refusal {cause!r}: {why}")
            cases.append(refusal(name, path, err))
            continue
        if cause is not None:
            problems.append(f"{name}: the header bytes refuse it as {cause!r}")
            continue
        r = read_image(mrcfile, path)
        if r["nz"] != 1 or r["raw_shape"] not in ((r["ny"], r["nx"]), (1, r["ny"], r["nx"])):
            problems.append(f"{name}: mrcfile shapes it {r['raw_shape']}")
            continue
        r["data"] = r["data"].reshape(r["ny"], r["nx"])
        if name == "rsciio-haadfscan" and (r["nsymbt"] != HAADF_NSYMBT or r["mode"] != 6 or r["data"].shape != (16, 16)):
            problems.append(f"{name}: expected a 16 x 16 uint16 image behind NSYMBT {HAADF_NSYMBT}, got {r['data'].shape} "
                            f"mode {r['mode']} NSYMBT {r['nsymbt']}")
        x, y, notes = axes_of(r["sx"], r["sy"], r["nsymbt"])
        if name == "rsciio-haadfscan" and x is None:
            problems.append(f"{name}: expected a calibrated image")
        if name.startswith("rsciio-de-") or name == "rsciio-roi-random-scan-sum":
            if x is not None:
                problems.append(f"{name}: expected the negative cell length to be uncalibrated")
        cases.append(entry(name, path, r["data"], x, y, notes))

    if problems:
        print("reference.py: THE REFERENCE DISAGREES WITH THE PLANT / ITS OWN CHECKS:", file=sys.stderr)
        for m in problems:
            print("  - " + m, file=sys.stderr)
        sys.exit(1)

    with open(os.path.join(out, "manifest.json"), "w") as fh:
        json.dump({"mrcfile": MRCFILE, "cases": cases}, fh, indent=1, ensure_ascii=False)
    print(f"reference.py: {len(cases)} cases, the reference reproduces every planted truth")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
