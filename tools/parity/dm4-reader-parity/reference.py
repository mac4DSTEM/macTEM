#!/usr/bin/env python3
"""Truth for tools/parity/dm4-reader-parity: ncempy's reading of every case.

    reference.py <planted.dm4> <planted.truth.json> <per-type-dir> <rsciio-root> <out-dir>

The reference is pinned: ncempy's installed version AND the sha256 of the ncempy/io/dm.py it imports, numpy's
version (dm.py decodes every pixel with numpy) equal to tools/lib/references-lock.txt's, and the Python minor the
lock was verified on — so a different reference (an override interpreter, an edited site-packages) is refused,
never compared against.

Case 1 — planted fixtures. Before ncempy is trusted, it must reproduce the PLANTED truth that make_fixture.py
wrote (shape, dtype, every pixel, each axis's float32 scale, origin and units): the comparator is checked before
the app is (mac4DSTEM tools/velox-parity/truth.py does the same). The committed fixture, then one fixture per pixel
type (make_fixture.py --types, written by run.sh at every run), each of whose values must discriminate its type's
sign and width (anti-vacuity, below) — RosettaSciIO's per-type GMS files hold only 1, 2, 3, 4.

Case 2 — GMS-written files from RosettaSciIO at its pinned commit (tools/lib/fetch-rsciio.sh). The registry.txt
read is pinned by sha256, and each file's sha256 must match that registry; then ncempy's reading is the truth.
The Format fixtures (V1-1b): ncempy must read the planted Meta Data.Format of each object.
Plus files macTEM must REFUSE by name: a line scan, a stack, a spectrum image, complex data.

Writes <out>/manifest.json and one <name>.f32 per image (row-major, little-endian float32 — what the Swift reader
decodes to, so the comparison is exact). Any disagreement exits 1; nothing unchecked is written.
"""
import hashlib
import importlib.metadata
import json
import os
import re
import sys

import numpy as np
from ncempy.io import dm

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = os.path.join(HERE, "..", "..", "lib", "references-lock.txt")
NCEMPY_VERSION = "1.16"
DM_PY_SHA256 = "09edae58936747ae5c01437f0afb3bbee177746e3e30040b90817e24a47daa75"
PYTHON_MINOR = "3.14"          # tools/lib/python.sh MACTEM_PYTHON_MINOR: the lock was verified on it
# rsciio/tests/registry.txt at the lock commit 049e7d7070e84779b499adaf3295beee9facb004 (the git blob's sha256):
# a clone whose data AND registry were edited consistently is refused here, not trusted.
REGISTRY_SHA256 = "31417482938f80160be2c03525ba58dd810c7f16b1790f597470ece8dd0b1bcb"

# make_fixture.py --types writes planted-<type>.dm4 and its truth for each of these, the eight types the reader decodes.
PER_TYPE = ("uint8", "int8", "int16", "uint16", "int32", "uint32", "float32", "float64")

# Paths under rsciio/tests/data. Real GMS-written 2D images: calibrated nm, 1/nm and µm, non-zero origins, and
# one 2x2 image per pixel type macTEM decodes (int16, float32, uint8, int32, int8, uint16, uint32, float64; values
# 1-4 only — the per-type planted fixtures carry the sign and width).
GMS_IMAGES = [
    "digitalmicrograph/2D/test_STEM_image.dm3",
    "digitalmicrograph/2D/test_diffraction_pattern.dm3",
    "digitalmicrograph/2D/multi_signal.dm3",
    "digitalmicrograph/2D/test-MonarcCL_mono-image.dm4",
    "tiff/test_dm_image_um_unit.dm3",
] + [f"digitalmicrograph/2D/test-{n}.dm4" for n in (1, 2, 6, 7, 9, 10, 11, 12)]

# What macTEM must refuse, and with which error — never read as something else.
REFUSED = [
    ("digitalmicrograph/1D/test-MonarcCL_spectrum-pmt.dm4", "noImage"),           # [170, 1]: a line, not an image
    ("digitalmicrograph/test_stackbuilder_imagestack.dm3", "noImage"),           # [16, 2, 3]: a stack, not read yet
    ("digitalmicrograph/2D/test-MonoCL_spectrum-SI.dm4", "noImage"),             # 1336 x 67, x nm (wavelength) and
                                                                                 # y µm: a CL spectrum image
    ("digitalmicrograph/2D/test-3.dm4", "unsupportedDataType"),                  # complex64
    ("digitalmicrograph/2D/test_fft_packed_complex8.dm4", "unsupportedDataType"),  # packed complex FFT
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
    for package, want in (("ncempy", NCEMPY_VERSION), ("numpy", pins.get("numpy"))):
        if want is None or pins.get(package) != want:
            fail(f"tools/lib/references-lock.txt pins {package} {pins.get(package)}, reference.py expects {want}")
        have = importlib.metadata.version(package)
        if have != want:
            fail(f"{package} {have} is not the pinned {want} (tools/lib/references-lock.txt)")
    if np.__version__ != pins["numpy"]:
        fail(f"the numpy imported is {np.__version__}, its metadata says {pins['numpy']}")
    if sha256(dm.__file__) != DM_PY_SHA256:
        fail(f"{dm.__file__} is not the pinned ncempy/io/dm.py (sha256 {DM_PY_SHA256[:16]}…)")
    return f"ncempy {NCEMPY_VERSION} (dm.py pinned), numpy {np.__version__}, Python {python}"


def read_ncempy(path, index=0):
    """ncempy's own reading. getDataset(0) is ImageList.2 only when ImageList.1 is the thumbnail: assert it;
    getDataset(i) is then ImageList.(i + 2)."""
    with dm.fileDM(path, on_memory=True) as f:
        if not (f.numObjects == 1 or f.thumbnail):
            fail(f"{path}: {f.numObjects} objects and no thumbnail — ncempy's getDataset(0) would skip an image")
        d = f.getDataset(index)
    data = np.asarray(d["data"])
    if data.ndim != 2:
        fail(f"{path}: ncempy read {data.shape}, not a 2D image")
    # ncempy lists calibrations in C order: index 0 is y (rows), index 1 is x (columns).
    (sy, sx), (uy, ux), (oy, ox) = d["pixelSize"], d["pixelUnit"], d["pixelOrigin"]
    axis = lambda s, u, o: {"scale": float(np.float32(s)), "scale_bits": int(np.float32(s).view(np.uint32)),
                            "origin": float(np.float32(o)), "units": u}
    return data, axis(sx, ux, ox), axis(sy, uy, oy)


def write_image(out, name, path, data, x, y):
    pixels = f"{name}.f32"
    np.ascontiguousarray(data.astype("<f4")).tofile(os.path.join(out, pixels))
    return {"name": name, "path": path, "kind": "image", "width": int(data.shape[1]), "height": int(data.shape[0]),
            "x": x, "y": y, "pixels": pixels}


def check_planted(dm4, truth_path):
    """ncempy's reading of a planted fixture, after it reproduces every planted number."""
    with open(truth_path) as fh:
        truth = json.load(fh)
    name = os.path.basename(dm4)
    if sha256(dm4) != truth["file_sha256"]:
        fail(f"{name}: sha256 differs from its truth file — regenerate both (run.sh --make-fixture)")
    data, x, y = read_ncempy(dm4)
    if data.shape != (truth["height"], truth["width"]) or str(data.dtype) != truth["dtype"]:
        fail(f"ncempy read {name} as {data.shape} {data.dtype}, planted {truth['height']} x {truth['width']} "
             f"{truth['dtype']}")
    if data.reshape(-1).tolist() != truth["pixels_row_major"]:
        fail(f"ncempy's {name} pixels differ from the planted truth")
    for axis_name, got in (("x", x), ("y", y)):
        want = truth[axis_name]
        if (got["scale_bits"], got["origin"], got["units"]) != (int(want["scale_f32_bits"], 16), want["origin"], want["units"]):
            fail(f"ncempy's {name} {axis_name} axis {got} differs from the planted truth {want}")
    return data, x, y


FORMAT_CASES = ("planted-si", "planted-si-then-image", "planted-diffraction")


def format_tags(path):
    """ncempy's allTags: {ImageList object number: Meta Data.Format}, for every object that has the tag."""
    with dm.fileDM(path, on_memory=True) as f:
        tags = dict(f.allTags)
    found = {}
    for key, value in tags.items():
        m = re.search(r"ImageList\.(\d+)\.ImageTags\.Meta Data\.Format$", key)
        if m:
            found[int(m.group(1))] = value if isinstance(value, str) else str(value)
    return found


def check_format_case(per_type_dir, stem, out):
    """V1-1b: ncempy reads the planted Format tag of every object (the comparator, checked before the app is), and the
    case is a refusal (the only object is a spectrum image) or an image (the object after it)."""
    dm4 = os.path.join(per_type_dir, f"{stem}.dm4")
    with open(os.path.join(per_type_dir, f"{stem}.truth.json")) as fh:
        truth = json.load(fh)
    if sha256(dm4) != truth["file_sha256"]:
        fail(f"{stem}.dm4: sha256 differs from its truth file")
    got = format_tags(dm4)
    want = {o["object_index"]: o["format"] for o in truth["objects"]}
    if got != want:
        fail(f"ncempy reads Meta Data.Format {got} in {stem}.dm4, planted {want}")
    if stem == "planted-si":
        return {"name": stem, "path": dm4, "kind": "refused", "error": "noImage"}
    target = truth["objects"][-1]                       # the image: the last object (not a "Spectrum image")
    data, x, y = read_ncempy(dm4, index=target["object_index"] - 2)
    if data.shape != (target["height"], target["width"]) or data.reshape(-1).tolist() != target["pixels_row_major"]:
        fail(f"ncempy's {stem}.dm4 object {target['object_index']} differs from the planted truth")
    for axis_name, got_axis in (("x", x), ("y", y)):
        w = truth[axis_name]
        if (got_axis["scale_bits"], got_axis["origin"], got_axis["units"]) != (int(w["scale_f32_bits"], 16), w["origin"], w["units"]):
            fail(f"ncempy's {stem}.dm4 {axis_name} axis {got_axis} differs from the planted truth {w}")
    case = write_image(out, stem, dm4, data, x, y)
    case["source"] = f"ImageList.{target['object_index']} · {target['object_name']}"
    return case


def discriminates(dtype, values):
    """Why `values` cannot be decoded right with the wrong sign or width of `dtype`; a failure names what is missing."""
    t = np.dtype(dtype)
    missing = []
    if t.kind == "i":
        if not any(v < 0 for v in values):
            missing.append("a negative value (unsigned decoding reads it)")
    if t.kind == "u":
        signed_max = np.iinfo(np.dtype(f"i{t.itemsize}")).max
        if not any(v > signed_max for v in values):
            missing.append(f"a value above the signed maximum {signed_max} (signed decoding reads it)")
    if t.kind in "iu" and t.itemsize > 1:
        narrow = np.iinfo(np.dtype(f"{t.kind}{t.itemsize // 2}"))
        if not any(v < narrow.min or v > narrow.max for v in values):
            missing.append(f"a value outside {narrow.dtype}'s range (a narrower decoding reads it)")
    if t.kind == "f":
        if not any(v != int(v) for v in values):
            missing.append("a non-integer value (decoding through an integer reads it)")
        if not any(v < 0 for v in values):
            missing.append("a negative value")
        if t.itemsize == 8 and not any(float(np.float32(v)) != v for v in values):
            missing.append("a value float32 cannot hold exactly (the file is not float64 in name only)")
    return missing


def main():
    planted_dm4, planted_truth, per_type_dir, rsciio, out = sys.argv[1:6]
    stack = check_reference()
    os.makedirs(out, exist_ok=True)
    cases = []

    # Case 1: ncempy against the planted truth first — the committed fixture, then one per pixel type.
    data, x, y = check_planted(planted_dm4, planted_truth)
    cases.append(write_image(out, "planted", planted_dm4, data, x, y))
    for dtype in PER_TYPE:
        dm4 = os.path.join(per_type_dir, f"planted-{dtype}.dm4")
        data, x, y = check_planted(dm4, os.path.join(per_type_dir, f"planted-{dtype}.truth.json"))
        if str(data.dtype) != dtype:
            fail(f"{dm4}: ncempy read {data.dtype}, the case is {dtype}")
        missing = discriminates(dtype, data.reshape(-1).tolist())
        if missing:
            fail(f"planted-{dtype} is vacuous — it lacks {'; and '.join(missing)}")
        cases.append(write_image(out, f"planted-{dtype}", dm4, data, x, y))

    # Format fixtures (V1-1b): a spectrum image named only by its tag, refused; the image after it; another Format.
    for stem in FORMAT_CASES:
        cases.append(check_format_case(per_type_dir, stem, out))

    # Case 2: GMS-written files, bytes pinned by RosettaSciIO's registry, the registry pinned here.
    data_root = os.path.join(rsciio, "rsciio", "tests", "data")
    registry_path = os.path.join(rsciio, "rsciio", "tests", "registry.txt")
    if sha256(registry_path) != REGISTRY_SHA256:
        fail(f"{registry_path} is not RosettaSciIO's registry at the lock (sha256 {REGISTRY_SHA256[:16]}…)")
    registry = {}
    with open(registry_path) as fh:
        for line in fh:
            parts = line.rsplit(" ", 1)
            if len(parts) == 2:
                registry[parts[0].strip().strip("'\"")] = parts[1].strip()
    for rel in GMS_IMAGES + [r for r, _ in REFUSED]:
        path = os.path.join(data_root, rel)
        if registry.get(rel) != sha256(path):
            fail(f"{rel}: sha256 differs from RosettaSciIO's registry")
    for rel in GMS_IMAGES:
        data, x, y = read_ncempy(os.path.join(data_root, rel))
        cases.append(write_image(out, rel.replace("/", "_"), os.path.join(data_root, rel), data, x, y))
    for rel, error in REFUSED:
        cases.append({"name": rel.replace("/", "_"), "path": os.path.join(data_root, rel), "kind": "refused",
                      "error": error})

    with open(os.path.join(out, "manifest.json"), "w") as fh:
        json.dump({"ncempy": NCEMPY_VERSION, "cases": cases}, fh, indent=1)
    images = sum(c["kind"] == "image" for c in cases)
    print(f"reference: {stack} reproduces the planted truth of 1 + {len(PER_TYPE)} fixtures and reads the Format tag of {len(FORMAT_CASES)} more; {images} images and "
          f"{len(cases) - images} refusals written")


if __name__ == "__main__":
    main()
