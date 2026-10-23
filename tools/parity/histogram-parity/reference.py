#!/usr/bin/env python3
"""Truth for tools/parity/histogram-parity: numpy's histogram of every case.

    reference.py planted <rsciio-root> <fixture.dm4> <fixture.truth.json> <owner-dir> <out-dir>
    reference.py real <out-dir>

The quantity (archive: roadmap-registrations-2026-10-15.md V1-4, "Completed at pickup"): `a` float32, `f = a[np.isfinite(a)]`,
`np.histogram(f, bins=96, range=(f.min(), f.max()))`, plus the finite count, f.min() and f.max() as float32 bits, and
`f.astype(np.float64).mean()`. numpy is pinned by version (tools/lib/references-lock.txt) and Python's minor; its
`bin_edges` must be float32 (a different dtype path is refused, never compared against).

`planted` writes every planted array as <out>/planted/<name>.f32 (little-endian float32, the bytes Swift reads),
writes <out>/plan.json (the real images the Swift side must open through `ImageOpening.openNow`: RosettaSciIO's files at
the pinned commit with their sha256 against its registry, the committed planted DM4, and the owner's Ceta TIFFs where
present), and <out>/planted.json (numpy's answer for every planted array). Before numpy counts as a comparator it must
agree with what was planted: the planted truth below (edge arrays binned by searchsorted on numpy's own edges, a
two-valued image, a constant widened to +-0.5, the pigeonhole bound on a narrow range, signed zeros) is asserted here,
and the planted edge arrays must make the UNCORRECTED index wrong in both directions (anti-vacuity: without it the
"edge corrections dropped" control could pass blind).

`real` reads the pixels Swift opened (<out>/opened/<name>.f32; numpy histograms the same float32 values the app
shows), asserts the planted DM4 equals value = row*1000 + col - 12000 (40 x 24), and writes <out>/manifest.json:
every case's pixels file, finite count, min/max bits, mean (+ the mean of |f|, the scale the 1e-9 is taken against),
numpy's counts and edge bits, or "refused" when numpy raises "Too many bins for data range".
"""
import glob
import hashlib
import importlib.metadata
import json
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = os.path.join(HERE, "..", "..", "lib", "references-lock.txt")
PYTHON_MINOR = "3.14"          # tools/lib/python.sh MACTEM_PYTHON_MINOR: the lock was verified on it
NUMPY_VERSION = "2.5.4"
# rsciio/tests/registry.txt at the lock commit 049e7d7070e84779b499adaf3295beee9facb004 (the git blob's sha256).
REGISTRY_SHA256 = "31417482938f80160be2c03525ba58dd810c7f16b1790f597470ece8dd0b1bcb"

BINS = 96
F32 = np.float32
F32_MAX = float(np.finfo(F32).max)

# The cases whose uncorrected index is wrong in both directions are named in run.sh as the "edge corrections dropped"
# control's target; reference.py asserts they really are.
CORRECTION_CASES = ("edges-tenth", "edges-sub-unit-neg")

# Real images by path under rsciio/tests/data: every single-image file the three reader harnesses open (the GMS
# DigitalMicrograph files of tools/parity/dm4-reader-parity, the ImageJ / DM-saved TIFFs of tools/parity/tiff-reader-parity, the
# single-image MRCs of tools/parity/mrc-reader-parity). Calibrated nm, 1/nm and um images, int and float types, 8 to 32 bit.
REAL_RSCIIO = [
    "digitalmicrograph/2D/test_STEM_image.dm3",
    "digitalmicrograph/2D/test_diffraction_pattern.dm3",
    "digitalmicrograph/2D/multi_signal.dm3",
    "digitalmicrograph/2D/test-MonarcCL_mono-image.dm4",
    "tiff/test_dm_image_um_unit.dm3",
] + [f"digitalmicrograph/2D/test-{n}.dm4" for n in (1, 2, 6, 7, 9, 10, 11, 12)] + [
    "tiff/test_loading_image_saved_with_imageJ.tif",
    "tiff/test_loading_image_saved_with_imageJ_no_scale.tif",
    "tiff/test_loading_image_saved_with_DM.tif",
    "mrc/HAADFscan.mrc",
    "mrc/20241021_00405_final.mrc",
    "mrc/ROI_Random_Scan_Sum.mrc",
    "mrc/20241021_00405_0_Virt 0_sum.mrc",
    "mrc/20241021_00405_1_Virt 1_sum.mrc",
    "mrc/20241021_00405_ext1_Ext 1.mrc",
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
    if pins.get("numpy") != NUMPY_VERSION:
        fail(f"tools/lib/references-lock.txt pins numpy {pins.get('numpy')}, reference.py expects {NUMPY_VERSION}")
    if importlib.metadata.version("numpy") != NUMPY_VERSION or np.__version__ != NUMPY_VERSION:
        fail(f"numpy {np.__version__} is not the pinned {NUMPY_VERSION} (tools/lib/references-lock.txt)")
    return f"numpy {np.__version__}, Python {python}"


def expected(a):
    """numpy's answer for the float32 array `a`: the dict written to the manifest."""
    a = np.ascontiguousarray(a, dtype="<f4").ravel()
    f = a[np.isfinite(a)]
    out = {"finite": int(f.size)}
    if f.size == 0:
        return out
    lo, hi = f.min(), f.max()
    if f.dtype != np.float32 or type(lo) is not np.float32:
        fail("the finite pixels or their extremes are not float32 — the registered dtype path would not be exercised")
    f64 = f.astype(np.float64)
    out.update(min_bits=int(lo.view(np.uint32)), max_bits=int(hi.view(np.uint32)),
               mean=float(f64.mean()), mean_scale=float(np.abs(f64).mean()))
    try:
        with np.errstate(all="ignore"):         # an overflowing range warns before numpy refuses it
            counts, edges = np.histogram(f, bins=BINS, range=(lo, hi))
    except ValueError as error:
        if "Too many bins for data range" not in str(error):
            fail(f"np.histogram raised something other than its narrow-range refusal: {error}")
        out["refused"] = True
        return out
    if edges.dtype != np.float32:
        fail(f"np.histogram's bin_edges are {edges.dtype}, not float32 — the registered dtype path was not taken")
    if int(counts.sum()) != f.size:
        fail("np.histogram's counts do not add up to the finite count")
    out.update(refused=False, counts=[int(c) for c in counts], edges_bits=[int(b) for b in edges.view(np.uint32)])
    return out


def ulps_above(x, n):
    """x, then its n successors in float32: a span of exactly n ulps."""
    out = [F32(x)]
    for _ in range(n):
        out.append(np.nextafter(out[-1], F32(np.inf)))
    return np.array(out, dtype=F32)


def edge_array(lo, hi):
    """Every float32 bin edge numpy computes for range (lo, hi), and one ulp either side of each (within the range, so
    the data's min and max stay lo and hi)."""
    lo, hi = F32(lo), F32(hi)
    _, edges = np.histogram(np.array([lo, hi], dtype=F32), bins=BINS, range=(lo, hi))
    values = np.concatenate([edges, np.nextafter(edges, F32(np.inf)), np.nextafter(edges, F32(-np.inf))])
    return values[(values >= lo) & (values <= hi)].astype(F32)


def planted_arrays():
    """name -> float32 array (any shape), in a fixed order. Everything seeded: the same arrays at every run."""
    rng = np.random.default_rng(20261013)
    cases = {}

    # Values on every edge numpy computes and one ulp either side, at assorted ranges (the registration's first dataset).
    for label, lo, hi in [
        ("unit", 0.0, 1.0), ("signed-5", -1.234, 5.678), ("camera-16bit", 0.0, 65535.0), ("dm-int16", -12000.0, 11019.0),
        ("high-offset", 1e6, 1e6 + 37.0), ("tiny", 1e-3, 1.1e-3), ("symmetric", -5e5, 5e5), ("tenth", 0.1, 0.7),
        ("wide-positive", 3.3, 97.1), ("sub-unit-neg", -0.3, 0.3), ("huge", 1e30, 2e30),
        ("ulps-1000", 1.0, float(F32(1.0) + F32(1000 * 2.0 ** -23))),
    ]:
        cases[f"edges-{label}"] = edge_array(lo, hi)
    for k in range(24):
        lo = float(rng.normal() * 10.0 ** float(rng.uniform(-3, 5)))
        hi = lo + max(float(10.0 ** rng.uniform(-3, 5)), abs(lo) * 1e-3)   # thousands of ulps wide: numpy bins it
        cases[f"edges-random-{k:02d}"] = edge_array(lo, hi)

    # Constant images: widened to +-0.5 in float32, or refused where +-0.5 is lost to rounding.
    for label, x in [("7.25", 7.25), ("zero", 0.0), ("negative", -3.5), ("large-3e7", 3e7), ("1e8", 1e8)]:
        cases[f"constant-{label}"] = np.full(1000, x, dtype=F32)

    # Non-finite pixels: never counted, never in the range.
    cases["single-finite-among-nonfinite"] = np.array([np.nan, np.inf, 42.5, -np.inf, np.nan], dtype=F32)
    mixed = np.concatenate([rng.normal(100, 30, 5000), np.full(100, np.nan), np.full(40, np.inf), np.full(40, -np.inf)])
    rng.shuffle(mixed)
    cases["mixed-nonfinite"] = mixed.astype(F32)
    cases["no-finite"] = np.array([np.nan, np.inf, -np.inf, np.nan], dtype=F32)
    cases["empty"] = np.zeros(0, dtype=F32)

    # Two values, and spans of a few ulps.
    cases["two-valued"] = np.array([0.0] * 600 + [1.0] * 400, dtype=F32)
    cases["two-valued-signed"] = np.array([-3.5] * 10 + [8.25] * 90, dtype=F32)
    cases["two-valued-one-ulp"] = np.array([1.0] * 5 + [float(np.nextafter(F32(1.0), F32(2.0)))] * 3, dtype=F32)
    for n in (1, 2, 50, 95, 96, 97, 98, 100, 200, 1000):
        cases[f"span-{n}-ulps-at-1"] = ulps_above(1.0, n)
    for label, base in (("1e-3", 1e-3), ("1e6", 1e6), ("minus-1", -1.0), ("zero", 0.0)):
        cases[f"span-200-ulps-at-{label}"] = ulps_above(base, 200)
        cases[f"span-95-ulps-at-{label}"] = ulps_above(base, 95)

    # Denormals, and the largest float32 range (last - first overflows, or does not).
    cases["denormal-one-ulp"] = np.array([0.0, 1e-45], dtype=F32)
    cases["denormal-1e-40"] = np.array([0.0, 1e-40, 5e-41, 2e-41], dtype=F32)
    cases["denormal-1e-38"] = np.array([0.0, 1e-38, 3e-39], dtype=F32)
    cases["denormal-span-357"] = np.array([1e-45, 5e-43], dtype=F32)
    cases["full-range-overflows"] = np.array([-F32_MAX, F32_MAX, 0.0, 1.0], dtype=F32)
    cases["zero-to-max"] = np.array([0.0, F32_MAX, 1.0, 3.0], dtype=F32)
    cases["negative-max-to-zero"] = np.array([-F32_MAX, 0.0, -1.0], dtype=F32)

    # Signed zeros: numpy's min is -0.0 and its max +0.0 whenever the array holds both, in any order.
    zeros = np.zeros(1000, dtype=F32)
    zeros[777] = F32(-0.0)
    cases["signed-zeros-min"] = np.concatenate([zeros, np.array([1.0, 2.0], dtype=F32)])
    cases["signed-zeros-min-first"] = np.concatenate([np.array([F32(-0.0)]), np.zeros(999, dtype=F32), np.array([5.0], dtype=F32)])
    neg = np.full(1000, F32(-0.0), dtype=F32)
    neg[3] = F32(0.0)
    cases["signed-zeros-max"] = np.concatenate([np.array([-4.0, -1.0], dtype=F32), neg])
    cases["signed-zeros-max-last"] = np.concatenate([np.array([-2.0], dtype=F32), np.full(999, F32(-0.0), dtype=F32), np.array([F32(0.0)])])

    # Large images (the registered 2048^2): noisy with hot and dead pixels; every integer; Poisson counts with a saturated pixel.
    noisy = rng.normal(1000.0, 50.0, (2048, 2048)).astype(F32)
    noisy.reshape(-1)[rng.choice(noisy.size, 60, replace=False)] = F32(65535.0)
    noisy.reshape(-1)[rng.choice(noisy.size, 20, replace=False)] = F32(4e6)
    noisy.reshape(-1)[rng.choice(noisy.size, 30, replace=False)] = F32(0.0)
    cases["noisy-2048"] = noisy
    cases["integers-2048"] = np.arange(2048 * 2048, dtype=np.int64).astype(F32).reshape(2048, 2048)
    poisson = rng.poisson(300, (2048, 2048)).astype(F32)
    poisson[17, 1999] = F32(65535.0)
    cases["poisson-2048"] = poisson
    cases["lognormal-1M"] = np.exp(rng.normal(0.0, 5.0, 1 << 20)).astype(F32)
    return cases


def true_bins(values, edges):
    """The bin of every value by the definition: the last k with edges[k] <= v, the last bin closed."""
    return np.minimum(np.searchsorted(edges, values, side="right") - 1, BINS - 1)


def check_planted_truth(name, array, answer, tally):
    """numpy must agree with what was planted, before it is trusted as the comparator."""
    f = array[np.isfinite(array)]
    if name.startswith("edges-"):
        if answer.get("refused", True):
            fail(f"{name}: numpy refused (or has no histogram) for a planted edge array")
        edges = np.array(answer["edges_bits"], dtype=np.uint32).view(np.float32)
        if not (edges[:-1] < edges[1:]).all():
            fail(f"{name}: numpy's edges are not strictly increasing")
        # Every planted edge is in the data (and the range is the data's), and no value lies outside it.
        if edges[0] != f.min() or edges[-1] != f.max():
            fail(f"{name}: numpy's edges do not span the data's range")
        if not np.isin(edges, f).all():
            fail(f"{name}: a planted bin edge is missing from the array")
        by_definition = np.bincount(true_bins(f, edges), minlength=BINS)
        if by_definition.tolist() != answer["counts"]:
            fail(f"{name}: numpy's counts are not the definition's (last edge <= value, last bin closed)")
        # The uncorrected index: what numpy computes before it corrects against the edges.
        lo, hi = f.min(), f.max()
        naive = (((f - lo) / (hi - lo)) * F32(BINS)).astype(np.intp)
        naive[naive == BINS] -= 1
        right = true_bins(f, edges)
        tally["low"] += int((naive < right).sum())      # needs the increment
        tally["high"] += int((naive > right).sum())     # needs the decrement
        if name in CORRECTION_CASES and ((naive < right).sum() == 0 or (naive > right).sum() == 0):
            fail(f"{name}: the uncorrected index is not wrong in both directions here — the named control would be vacuous")
    elif name == "two-valued":
        want = [600] + [0] * 94 + [400]
        if answer["counts"] != want or answer["refused"]:
            fail(f"{name}: numpy's counts are not the planted {want[0]} / {want[-1]} in the first and last bins")
    elif name.startswith("constant-"):
        x = f.min()
        widened = answer["refused"] is False
        if name in ("constant-7.25", "constant-zero", "constant-negative"):
            edges = np.array(answer["edges_bits"], dtype=np.uint32).view(np.float32)
            if not widened or edges[0] != x - F32(0.5) or edges[-1] != x + F32(0.5) or answer["counts"][48] != 1000:
                fail(f"{name}: numpy did not widen the constant to +-0.5 with every pixel in bin 48")
        else:
            if widened:
                fail(f"{name}: numpy binned a constant whose +-0.5 is lost to float32 rounding")
    elif name == "single-finite-among-nonfinite":
        if answer["finite"] != 1 or answer["counts"][48] != 1 or sum(answer["counts"]) != 1:
            fail(f"{name}: numpy did not count exactly the one finite pixel in bin 48")
    elif name in ("no-finite", "empty"):
        if answer["finite"] != 0:
            fail(f"{name}: numpy found finite pixels")
    elif name.startswith("span-") and "-ulps-at-" in name:
        n = int(name.split("-")[1])
        if n < BINS and not answer["refused"]:
            fail(f"{name}: {BINS + 1} strictly increasing float32 edges cannot fit in {n} ulps, yet numpy binned it")
    elif name == "two-valued-one-ulp":
        if not answer["refused"]:
            fail(f"{name}: numpy binned a span of one ulp")
    elif name.startswith("signed-zeros-"):
        if "min" in name and answer["min_bits"] != 0x80000000:
            fail(f"{name}: numpy's min is not -0.0")
        if "max" in name and answer["max_bits"] != 0:
            fail(f"{name}: numpy's max is not +0.0")


def plan_real(rsciio, fixture, owner_dir):
    """The real images the Swift side opens: [{name, path, machine_local}], their sha256 checked against the registry."""
    rsciio = os.path.abspath(rsciio)
    data_root = os.path.join(rsciio, "rsciio", "tests", "data")
    registry_path = os.path.join(rsciio, "rsciio", "tests", "registry.txt")
    if sha256(registry_path) != REGISTRY_SHA256:
        fail(f"{registry_path} is not RosettaSciIO's registry at the lock (sha256 {REGISTRY_SHA256[:16]}...)")
    registry = {}
    with open(registry_path) as fh:
        for line in fh:
            parts = line.rsplit(" ", 1)
            if len(parts) == 2:
                registry[parts[0].strip().strip("'\"")] = parts[1].strip()
    real = [{"name": "real-" + os.path.basename(fixture), "path": os.path.abspath(fixture), "machine_local": False}]
    for rel in REAL_RSCIIO:
        path = os.path.join(data_root, rel)
        if registry.get(rel) != sha256(path):
            fail(f"{rel}: sha256 differs from RosettaSciIO's registry")
        real.append({"name": "real-" + os.path.basename(rel), "path": path, "machine_local": False})
    owner = sorted(glob.glob(os.path.join(owner_dir, "*.tif"))) if owner_dir != "-" else []
    for path in owner:      # the owner's Ceta TIFFs: gitignored, machine-local; the summary says how many were gated
        real.append({"name": "real-owner-" + os.path.basename(path), "path": os.path.abspath(path), "machine_local": True})
    names = [r["name"] for r in real]
    if len(set(names)) != len(names):
        fail("two real images share a case name")
    return real


def read_f32(path):
    with open(path, "rb") as fh:
        data = np.frombuffer(fh.read(), dtype="<f4")
    return data


def stage_planted(rsciio, fixture, truth_path, owner_dir, out):
    stack = check_reference()
    os.makedirs(os.path.join(out, "planted"), exist_ok=True)
    with open(truth_path) as fh:
        truth = json.load(fh)
    if sha256(fixture) != truth["file_sha256"]:
        fail("the planted fixture's sha256 differs from its truth file — regenerate both (dm4-reader-parity run.sh --make-fixture)")
    cases = []
    tally = {"low": 0, "high": 0}
    arrays = planted_arrays()
    for name, array in arrays.items():
        array = np.ascontiguousarray(array, dtype="<f4")
        file = os.path.join("planted", f"{name}.f32")
        array.tofile(os.path.join(out, file))
        answer = expected(array)
        check_planted_truth(name, array, answer, tally)
        cases.append({"name": name, "pixels": file, **answer})
    if tally["low"] == 0 or tally["high"] == 0:
        fail(f"the planted edge arrays never make the uncorrected index wrong in both directions ({tally})")
    real = plan_real(rsciio, fixture, owner_dir)
    with open(os.path.join(out, "planted.json"), "w") as fh:
        json.dump({"cases": cases, "tally": tally}, fh)
    with open(os.path.join(out, "plan.json"), "w") as fh:
        json.dump({"real": real, "planted_dm4": "real-" + os.path.basename(fixture)}, fh, indent=1)
    refused = sum(1 for c in cases if c.get("refused"))
    print(f"reference: {stack}; {len(cases)} planted arrays ({refused} that numpy refuses, "
          f"{sum(1 for c in cases if c['finite'] == 0)} with no finite pixel); the uncorrected index is wrong "
          f"for {tally['low']} pixels too low and {tally['high']} too high; {len(real)} real images to open")


def stage_real(out):
    check_reference()
    with open(os.path.join(out, "planted.json")) as fh:
        cases = json.load(fh)["cases"]
    with open(os.path.join(out, "plan.json")) as fh:
        plan = json.load(fh)
    opened = 0
    for r in plan["real"]:
        path = os.path.join(out, "opened", f"{r['name']}.f32")
        if not os.path.exists(path):
            fail(f"{r['name']}: Swift did not write the pixels it opened")
        pixels = read_f32(path)
        if r["name"] == plan["planted_dm4"]:      # the committed planted fixture: value = row*1000 + col - 12000, 40 x 24
            want = (np.arange(24)[:, None] * 1000 + np.arange(40)[None, :] - 12000).astype(F32).ravel()
            if pixels.shape != want.shape or not (pixels == want).all():
                fail(f"{r['name']}: the opened pixels are not the planted row*1000 + col - 12000")
        answer = expected(pixels)
        if answer["finite"] == 0:
            fail(f"{r['name']}: no finite pixel in a real image")
        cases.append({"name": r["name"], "pixels": os.path.join("opened", f"{r['name']}.f32"),
                      "machine_local": r["machine_local"], **answer})
        opened += 1
    with open(os.path.join(out, "manifest.json"), "w") as fh:
        json.dump({"numpy": NUMPY_VERSION, "cases": cases}, fh)
    local = sum(1 for r in plan["real"] if r["machine_local"])
    print(f"reference: numpy histograms of {opened} opened images ({local} of them the owner's machine-local files)")


def main():
    if len(sys.argv) == 7 and sys.argv[1] == "planted":
        stage_planted(*sys.argv[2:7])
    elif len(sys.argv) == 3 and sys.argv[1] == "real":
        stage_real(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(64)


if __name__ == "__main__":
    main()
