#!/usr/bin/env python3
"""Truth and reader for tools/parity/fft-export-parity: macTEM's FFT-room export read back with Pillow, numpy and Python.

    reference.py plant <planted-dir>
    reference.py check <planted-dir> <out-dir> [<case,case...|all>]

`plant` writes two images with lattices planted at whole bins (so the spots' truth is known by construction: the spot (kx, ky) of
an N-wide, M-high transform sits at |q| = hypot(kx dq_x, ky dq_y)), their calibrations, regions, windows and clicks, and the grey
look-up table. The Swift harness (main.swift) transforms, measures and writes with the production code and dumps what it held in
memory; `check` reads it all back and prints one "  FAIL  <check>: <detail>" line per failure, then "fft-export-parity: N FAILURES
in M checks" (exit 1) or "fft-export-parity: all passed — ..." (exit 0). The checks:

  F-1  the radial profile CSV: every mean and centre re-reads bit-equal to the in-memory Double, the shown column is the unit
       column times the app's factor, the rows are the bins with a pixel, the header says unwindowed; and, from numpy's own
       FFT of the region, the same profile within float32's noise (counts exactly).
  F-2  the spots CSV: every number bit-equal to the in-memory one, the shown columns the
       conversion of the unit columns, the flags, the header; and |q| of each spot against the planted lattice.
  F-3  the transform PNG: W x H bins, RGB, sRGB; the Description's fft block and scales equal the plant's; without overlays every
       channel equals the shader's mapping of the dumped canvas (0 levels) AND of numpy's own log-power canvas (within 1 level);
       the DC bin is the masked grey.
  F-4  the reciprocal bar (on black): label, drawn length, and the longest run of exact white times the step in nm^-1 equals the
       label within one export pixel; the bar measures x.
  F-5  the spots' rings (on black): the yellow-weighted centroid of each ring within 0.15 export px of its centroid (+1/2), and its
       mean radius 7u within 3/4 px.
  F-6  the full export names the spots it drew.
"""
import csv
import importlib.metadata
import json
import math
import os
import re
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = os.path.join(HERE, "..", "..", "lib", "references-lock.txt")
PILLOW_VERSION = "12.3.0"
NUMPY_VERSION = "2.5.4"
PYTHON_MINOR = "3.14"
SOFTWARE = "macTEM 0.1.0 (1)"
MASKED_GREY = (82, 82, 87)
RECIP = "nm⁻¹"

TRANSFORM_NOTE = ("unnormalised forward FFT of the region's pixels as read: NO window, the mean NOT removed "
                  "(the DC bin is the region's sum and is not drawn); |F|^2 centred, the zero frequency at bin (height/2, width/2)")
DISPLAY_NOTE = ("picture: v = log10(|F|^2 / (W*H)^2) per bin, the DC bin masked, normalised over the finite range, "
                "then the window shown, grey, gamma 1")
SPOT_NOTE = ("spots: the centroid of |F|^2 (power weights) over the 5 x 5 bins around the largest power within "
             "2 bins of the click, measured on a Hann-windowed, mean-removed copy of the region (the transform above is not); "
             "d = 1/|q|; neighbour = another peak above 10 % of the spot's power within 3 bins (d may be off by up to 0.3 %); "
             "In Mask = the spot passes the masked inverse")
ASPECT_NOTE = ("the PNG is the bins, one square pixel each; the pane draws width*dq_x : height*dq_y (pane_aspect = "
               "the ratio); anisotropic compares dq_x with dq_y, which differ with the size alone")
VALIDATION_PNG = ("the transform compared with numpy 2.5.4 (ImagoKit's parity tests); display "
                  "rendering: log scaling, window, 8-bit grey, not intensities; the scale bar's length checked against its label (export-parity)")
VALIDATION_PROFILE = ("the radial profile compared with numpy 2.5.4 (ImagoKit's parity tests); "
                      "the calibration as the file states it")
VALIDATION_SPOTS = ("the spot centroid compared with planted spots (ImagoKit's parity tests); the "
                    "calibration as the file states it")
LINEAGE = ("none — the FFT room's state carries no lineage id; the region, spots and parameters "
           "above stand in")


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def check_reference():
    python = "%d.%d" % sys.version_info[:2]
    if python != PYTHON_MINOR:
        fail(f"Python {python} is not the pinned {PYTHON_MINOR} (tools/lib/python.sh)")
    pins = {}
    with open(LOCK) as fh:
        for line in fh:
            m = re.match(r"^([A-Za-z0-9_.-]+)==(\S+)\s*$", line)
            if m:
                pins[m.group(1).lower()] = m.group(2)
    for package, want in (("pillow", PILLOW_VERSION), ("numpy", NUMPY_VERSION)):
        have = importlib.metadata.version(package)
        if have != want or pins.get(package) != want:
            fail(f"{package} {have} (lock {pins.get(package)}) is not the pinned {want}")
    return f"Pillow {PILLOW_VERSION}, numpy {NUMPY_VERSION}, Python {python}"


def g17(v):
    """%.17g, with the spellings ProfileCSV.number gives non-finite values."""
    if math.isnan(v):
        return "nan"
    if math.isinf(v):
        return "-inf" if v < 0 else "inf"
    return "%.17g" % v


# ---------------------------------------------------------------------------------------------------------------------
# Plant

CASES = [
    # whole image, metres (the Velox case: the shown unit is nm^-1 by a factor), default window.
    dict(name="whole", w=256, h=200, x=(5e-11, "m"), y=(8e-11, "m"), crop=None, window=(None, None),
         spots=[(20, 12, 8.0), (35, -18, 5.0)], extra_clicks=[("centre", None)], in_mask=[True, False, False],
         mask=(3.0, 2.0)),
    # a region of an anisotropic nm image, an explicit window.
    dict(name="region", w=256, h=200, x=(0.05, "nm"), y=(0.08, "nm"), crop=(8, 16, 160, 192), window=(-6.0, 1.0),
         spots=[(14, -10, 8.0), (-30, 22, 5.0)], extra_clicks=[("corner", None)], in_mask=[True, True, False],
         mask=(5.0, 1.0)),
]


def plant(planted):
    os.makedirs(planted, exist_ok=True)
    lut = bytearray()
    for i in range(256):
        lut += bytes((i, i, i, 255))
    with open(os.path.join(planted, "gray.lut"), "wb") as fh:
        fh.write(bytes(lut))
    rng = np.random.default_rng(20261014)
    manifest = {"lut": "gray.lut", "cases": []}
    for c in CASES:
        w, h = c["w"], c["h"]
        rr, cc = np.mgrid[0:h, 0:w].astype(np.float64)
        if c["crop"]:
            r0, c0, ch, cw = c["crop"]
            fr, fc = (rr - r0) / ch, (cc - c0) / cw          # the lattices are periodic in the region
        else:
            ch, cw = h, w
            fr, fc = rr / h, cc / w
        img = np.full((h, w), 100.0)
        for kx, ky, amp in c["spots"]:
            img += amp * np.cos(2 * math.pi * (kx * fc + ky * fr) + 0.3)
        img += rng.normal(0.0, 0.5, (h, w))
        px = img.astype(np.float32)
        with open(os.path.join(planted, c["name"] + ".f32"), "wb") as fh:
            fh.write(px.tobytes())
        clicks = [[ch // 2 + ky, cw // 2 + kx] for kx, ky, _ in c["spots"]]
        for kind, _ in c["extra_clicks"]:
            clicks.append([ch // 2, cw // 2] if kind == "centre" else [2, 2])     # refused: within 3 bins of the DC / of an edge
        manifest["cases"].append(dict(
            name=c["name"], width=w, height=h, pixels=c["name"] + ".f32",
            x=dict(scale=c["x"][0], units=c["x"][1], origin=0.0), y=dict(scale=c["y"][0], units=c["y"][1], origin=0.0),
            fileName=c["name"] + ".dm4",
            crop=None if not c["crop"] else dict(row=c["crop"][0], col=c["crop"][1], height=c["crop"][2], width=c["crop"][3]),
            windowLow=c["window"][0], windowHigh=c["window"][1], clicks=clicks, inMask=c["in_mask"],
            maskRadius=c["mask"][0], maskEdge=c["mask"][1]))
    with open(os.path.join(planted, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=1)


# ---------------------------------------------------------------------------------------------------------------------
# The arithmetic, restated from the registration (never read off the Swift)

def overlay_scale(w, h):
    return max(1, int(math.floor(min(w, h) / 512 + 0.5)))


def nice125(v):
    if not (v > 0 and math.isfinite(v)):
        return 1.0
    base = 10.0 ** math.floor(math.log10(v))
    mant = v / base
    return (1 if mant < 1.5 else 2 if mant < 3.5 else 5 if mant < 7.5 else 10) * base


def bar_number(v):
    return "%.0f" % v if v >= 10 else ("%g" % v if v >= 1 else "%.3g" % v)


def unit_factor(units):
    """FFTUnits.spectrumUnit for the two spectrum units used here: ('1/m' -> 1/1e9, '1/nm' -> 1/1)."""
    return {"1/m": 1.0 / 1e9, "1/nm": 1.0 / 1.0}[units]


def window_fractions(low, high, rng):
    """DisplayWindow.fractions in Float32."""
    if rng is None or not rng[1] > rng[0]:
        return np.float32(0), np.float32(1)
    lo_r, hi_r = np.float32(rng[0]), np.float32(rng[1])
    span = np.float32(hi_r - lo_r)

    def frac(v, default):
        x = np.float32(np.float32(default if v is None else v) - lo_r) / span
        return np.float32(min(max(x, np.float32(0)), np.float32(1)))
    lo, hi = frac(low, lo_r), frac(high, hi_r)
    return (lo, hi) if lo < hi else (np.float32(0), np.float32(1))


def grey_levels(canvas, low, high):
    """The shader's mapping through the identity grey LUT, gamma 1, in Double, round half up; masked (-1) -> MASKED_GREY."""
    flat = canvas.reshape(-1)
    uniq, inverse = np.unique(flat, return_inverse=True)
    lo = float(low)
    width = float(high) - float(low)
    span = width if width > 1e-6 else 1e-6
    table = np.empty((len(uniq), 3), np.uint8)
    for k, n in enumerate(uniq.tolist()):
        if not n >= 0:
            table[k] = MASKED_GREY
            continue
        v = min(max(n, 0.0), 1.0)
        v = min(max((v - lo) / span, 0.0), 1.0)
        v = math.pow(v, 1.0)
        p = min(max(v * 256.0 - 0.5, 0.0), 255.0)
        i0 = int(math.floor(p))
        i1 = min(i0 + 1, 255)
        t = p - i0
        x = float(i0) + (float(i1) - float(i0)) * t
        fl = math.floor(x)
        c = min(max(fl + (1 if x - fl >= 0.5 else 0), 0), 255)
        table[k] = (int(c), int(c), int(c))
    return table[inverse].reshape(canvas.shape + (3,))


# ---------------------------------------------------------------------------------------------------------------------

class Report:
    def __init__(self):
        self.checks = 0
        self.failures = 0
        self.notes = []

    def ok(self, name, condition, detail=""):
        self.checks += 1
        if not condition:
            self.failures += 1
            print(f"  FAIL  {name}: {detail}")


def read_csv(path):
    with open(path, encoding="utf-8", newline="") as fh:
        text = fh.read()
    assert "\r" not in text and text.endswith("\n")
    lines = text.split("\n")[:-1]
    comments = [l for l in lines if l.startswith("#")]
    data = [l for l in lines if not l.startswith("#")]
    rows = list(csv.reader(data))
    return text, comments, rows[0], rows[1:]


def f64(path):
    with open(path, "rb") as fh:
        return np.frombuffer(fh.read(), dtype="<f8")


def bits(x):
    return np.float64(x).view(np.uint64)


def common_comments(rep, tag, comments, c, win, subject, kind):
    spec = f"{win['width']} x {win['height']} bins"
    dqx, dqy = win["spacingX"], win["spacingY"]
    fx, fy = unit_factor(win["unitsX"]), unit_factor(win["unitsY"])
    want = [f"# macTEM {kind}",
            f"# software: {SOFTWARE}",
            f"# file: {c['fileName']}",
            "# object: ImageList.1",
            f"# subject: {subject}",
            f"# image: {c['width']} x {c['height']} px",
            f"# x scale: {c['x']['scale']!r} {c['x']['units']} per px, origin 0.0 px",
            f"# y scale: {c['y']['scale']!r} {c['y']['units']} per px, origin 0.0 px",
            f"# spectrum: {spec}",
            f"# dq x: {g17(dqx)} {win['unitsX']} per bin ({g17(dqx * fx)} {RECIP})",
            f"# dq y: {g17(dqy)} {win['unitsY']} per bin ({g17(dqy * fy)} {RECIP})",
            "# notes: none"]
    rep.ok(f"{tag}-header", comments[1:1 + len(want) - 1] == want[1:] and comments[0] == want[0],
           f"\n  want {want}\n  have {comments[:len(want)]}")
    rep.ok(f"{tag}-header/transform", f"# transform: {TRANSFORM_NOTE}" in comments and not any("Hann" in l for l in comments if l.startswith("# transform")),
           "the transform's note")


def check(planted, out, only):
    versions = check_reference()
    man = json.load(open(os.path.join(planted, "manifest.json")))
    lut = open(os.path.join(planted, "gray.lut"), "rb").read()
    assert all(lut[4 * i + k] == i for i in range(256) for k in range(3))
    rep = Report()
    stats = dict(profile_rel=0.0, grey_diff=0, q_rel=0.0, ring_centroid=0.0, ring_radius=0.0, bar_run=0.0)
    for c in man["cases"]:
        if only and c["name"] not in only:
            continue
        n = c["name"]
        win = json.load(open(os.path.join(out, f"{n}.window.json")))
        for key in ("spacingX", "spacingY"):
            win[key] = float(win[key])             # JSON writes 78125000.0 as 78125000
        W, H = win["width"], win["height"]
        crop = c["crop"]
        subject = (f"region {crop['width']} x {crop['height']} px at ({crop['col']}, {crop['row']}) (column, row of its top-left pixel)"
                   if crop else f"the whole image, {c['width']} x {c['height']} px")
        fx = unit_factor(win["unitsX"])
        raw = np.frombuffer(open(os.path.join(planted, c["pixels"]), "rb").read(), dtype="<f4").reshape(c["height"], c["width"])
        region = raw[crop["row"]:crop["row"] + crop["height"], crop["col"]:crop["col"] + crop["width"]] if crop else raw
        assert region.shape == (H, W)

        # ---- F-1, the radial profile
        mean = f64(os.path.join(out, f"{n}.profile.f64"))
        prof = json.load(open(os.path.join(out, f"{n}.profile.json")))
        counts = prof["count"]
        text, comments, header, rows = read_csv(os.path.join(out, f"{n}.radial.csv"))
        common_comments(rep, f"F-1", comments, c, win, subject, "radial profile")
        rep.ok(f"F-1-header/{n}/columns", header == ["bin", f"|q| centre ({RECIP})", f"|q| centre ({win['unitsX']})", "mean |F|^2", "count"], str(header))
        rep.ok(f"F-1-header/{n}/sentences", f"# validation: {VALIDATION_PROFILE}" in comments and f"# lineage: {LINEAGE}" in comments, "validation/lineage")
        populated = [k for k, cnt in enumerate(counts) if cnt > 0 and k >= 1]   # the room's chart draws k >= 1: bin 0 (the DC) is not written
        rep.ok(f"F-1-rows/{n}", [int(r[0]) for r in rows] == populated, f"{len(rows)} rows, {len(populated)} populated bins")
        rep.ok(f"F-1-rows/{n}/dc", bool(rows) and counts[0] > 0 and "0" not in [r[0] for r in rows], "bin 0 (populated in memory) has no row")
        rep.ok(f"F-1-rows/{n}/omitted-line", any(l.startswith("# omitted: bin 0, the DC bin") for l in comments), "the omitted line names bin 0")
        w = prof["width"]
        bad = []
        for r, k in zip(rows, populated):
            centre = (k + 0.5) * w
            if bits(float(r[2])) != bits(centre) or bits(float(r[1])) != bits(centre * fx):
                bad.append(("centre", k))
            if bits(float(r[3])) != bits(mean[k]) or int(r[4]) != counts[k]:
                bad.append(("value", k))
        rep.ok(f"F-1-values/{n}", not bad, f"{len(bad)} cells differ, first {bad[:3]}")
        rep.ok(f"F-1-centres/{n}", not [b for b in bad if b[0] == "centre"], "centres")
        # numpy's own profile of the region
        P = np.abs(np.fft.fft2(region.astype(np.float64))) ** 2
        P = np.fft.fftshift(P)
        qy = (np.arange(H) - H // 2) * win["spacingY"]
        qx = (np.arange(W) - W // 2) * win["spacingX"]
        wb = max(win["spacingX"], win["spacingY"])
        k = np.floor(np.sqrt(qx[None, :] ** 2 + qy[:, None] ** 2) / wb).astype(int)
        sums = np.bincount(k.ravel(), weights=P.ravel())
        cnts = np.bincount(k.ravel())
        rep.ok(f"F-1-independent/{n}/counts", list(cnts) == list(counts) and wb == w, "counts / bin width")
        top = float(np.max(mean))
        rel = 0.0
        for kk in populated:
            ref = sums[kk] / cnts[kk]
            rel = max(rel, abs(mean[kk] - ref) / max(abs(ref), 1e-6 * top))
        stats["profile_rel"] = max(stats["profile_rel"], rel)
        rep.ok(f"F-1-independent/{n}/means", rel < 1e-4, f"largest relative difference {rel:.3g}")

        # ---- F-2, the spots
        spots = json.load(open(os.path.join(out, f"{n}.spots.json")))
        text, comments, header, rows = read_csv(os.path.join(out, f"{n}.spots.csv"))
        common_comments(rep, "F-2", comments, c, win, subject, "spots")
        s0 = spots["spots"][0]
        u, ru = s0["units"], s0["reciprocalUnits"]
        want_header = ["spot", "d (nm)", f"|q| ({RECIP})", "in mask", "neighbour", f"d ({u})", f"|q| ({ru})",
                       f"qx ({ru})", f"qy ({ru})", "centroid col", "centroid row", "click col", "click row"]
        rep.ok(f"F-2-header/{n}/columns", header == want_header, f"{header}")
        rep.ok(f"F-2-header/{n}/sentences",
               f"# {SPOT_NOTE}" in comments and f"# validation: {VALIDATION_SPOTS}" in comments and f"# lineage: {LINEAGE}" in comments
               and f"# listed: {len(spots['spots'])} measured spots; not listed: {spots['omitted']} (measuring, refused, no peak, or of another region)" in comments
               and f"# mask: radius {g17(c['maskRadius'])} bins, edge {g17(c['maskEdge'])} bins (the masked inverse)" in comments
               and "# note: a note, verbatim" in comments,
               f"{[l[:60] for l in comments]}")
        rep.ok(f"F-2-rows/{n}", [int(r[0]) for r in rows] == [s["number"] for s in spots["spots"]] and spots["omitted"] == 1,
               f"rows {[r[0] for r in rows]}, omitted {spots['omitted']}")
        nm = {"m": 1e9, "nm": 1.0}[u]
        bad = []
        for r, s in zip(rows, spots["spots"]):
            native = [("d", 5, s["d"]), ("q", 6, s["q"]), ("qx", 7, s["qx"]), ("qy", 8, s["qy"]),
                      ("ccol", 9, s["centroidCol"]), ("crow", 10, s["centroidRow"])]
            for name, col, v in native:
                if bits(float(r[col])) != bits(v):
                    bad.append((s["number"], name))
            if bits(float(r[1])) != bits(s["d"] * nm) or bits(float(r[2])) != bits(s["q"] / nm):
                bad.append((s["number"], "shown"))
            if r[3] != ("1" if s["inMask"] else "0") or r[4] != ("1" if s["neighbour"] else "0"):
                bad.append((s["number"], "flags"))
            if int(r[11]) != s["clickedCol"] or int(r[12]) != s["clickedRow"]:
                bad.append((s["number"], "click"))
        rep.ok(f"F-2-values/{n}", not [b for b in bad if b[1] in ("d", "q", "qx", "qy", "ccol", "crow")], f"{bad[:4]}")
        rep.ok(f"F-2-shown/{n}", not [b for b in bad if b[1] == "shown"], f"{bad[:4]}")
        rep.ok(f"F-2-flags/{n}", not [b for b in bad if b[1] in ("flags", "click")], f"{bad[:4]}")
        # the planted truth
        planted_spots = [s for s in CASES if s["name"] == n][0]["spots"]
        dqx, dqy = win["spacingX"], win["spacingY"]
        for r, (kx, ky, _) in zip(rows, planted_spots):
            q_true = math.hypot(kx * dqx, ky * dqy)
            q_rel = abs(float(r[6]) - q_true) / q_true
            stats["q_rel"] = max(stats["q_rel"], q_rel)
            rep.ok(f"F-2-truth/{n}/q{r[0]}", q_rel < 2e-3, f"|q| {float(r[6])} vs planted {q_true} (relative {q_rel:.3g})")

        # ---- F-3, the transform PNG
        im = Image.open(os.path.join(out, f"{n}.plain.png"))
        rep.ok(f"F-3-format/{n}", im.size == (W, H) and im.mode == "RGB", f"{im.size} {im.mode}")
        rawbytes = open(os.path.join(out, f"{n}.plain.png"), "rb").read()
        rep.ok(f"F-3-format/{n}/srgb", rawbytes.find(b"sRGB") in range(8, rawbytes.find(b"IDAT")) or b"iCCP" in rawbytes[:rawbytes.find(b"IDAT")], "sRGB tag")
        d = json.loads(im.text["Description"])
        fft = d.get("fft")
        want_fft = {
            "subject": subject, "space": "reciprocal", "image": f"{c['width']} x {c['height']} px",
            "file_x_scale": f"{c['x']['scale']!r} {c['x']['units']} per px", "file_y_scale": f"{c['y']['scale']!r} {c['y']['units']} per px",
            "dq_x": f"{g17(win['spacingX'])} {win['unitsX']} per bin", "dq_y": f"{g17(win['spacingY'])} {win['unitsY']} per bin",
            "transform": TRANSFORM_NOTE, "display": DISPLAY_NOTE, "pane_aspect": g17((W * win["spacingX"]) / (H * win["spacingY"])),
            "aspect_note": ASPECT_NOTE, "spots_drawn": "0"}
        rep.ok(f"F-3-meta/{n}/fft", fft == want_fft, f"\n  want {want_fft}\n  have {fft}")
        rep.ok(f"F-3-meta/{n}/sentences", d["validation"] == VALIDATION_PNG and d["lineage"] == LINEAGE, f"{d['validation'][:40]} / {d['lineage'][:40]}")
        sx, sy = unit_factor(win["unitsX"]), unit_factor(win["unitsY"])
        rep.ok(f"F-3-meta/{n}/scales",
               d["x_scale"] == {"scale": win["spacingX"] * sx, "units": RECIP, "origin": 0.0}
               and d["y_scale"] == {"scale": win["spacingY"] * sy, "units": RECIP, "origin": 0.0}
               and d["width"] == W and d["height"] == H and d["colormap"] == "gray" and d["gamma"] == 1.0 and d["software"] == SOFTWARE
               and d["file"] == c["fileName"], f"{d['x_scale']} {d['y_scale']}")
        canvas = np.frombuffer(open(os.path.join(out, f"{n}.canvas.f32"), "rb").read(), dtype="<f4").reshape(H, W)
        rep.ok(f"F-3-meta/{n}/masked", d["masked_pixels"] == int((canvas < 0).sum()) and d["masked_pixels"] >= 1, f"{d['masked_pixels']}")
        rng = (np.float32(win["rangeLow"]), np.float32(win["rangeHigh"]))
        fl, fh = window_fractions(win["rawLow"], win["rawHigh"], rng)
        rep.ok(f"F-3-window/{n}", np.float32(win["low"]) == fl and np.float32(win["high"]) == fh
               and d["window"]["fractions"] == [float(fl), float(fh)] and d["window"]["low"] == win["rawLow"] and d["window"]["high"] == win["rawHigh"],
               f"{win['low']},{win['high']} vs {fl},{fh}; {d['window']}")
        if c["windowLow"] is not None:
            rep.ok(f"F-3-window/{n}/explicit", win["rawLow"] == c["windowLow"] and win["rawHigh"] == c["windowHigh"], "the owner's window")
        pixels = np.asarray(im, dtype=np.uint8)
        expect = grey_levels(canvas, fl, fh)
        diff = np.abs(pixels.astype(int) - expect.astype(int))
        rep.ok(f"F-3-pixels/{n}", int(diff.max()) == 0, f"{int((diff > 0).sum())} channels differ, largest {int(diff.max())}")
        rep.ok(f"F-3-pixels/{n}/dc", tuple(pixels[H // 2, W // 2]) == MASKED_GREY, f"{tuple(pixels[H // 2, W // 2])}")
        # numpy's own log-power canvas
        scale = float(W * H) ** 2
        with np.errstate(divide="ignore", invalid="ignore"):
            v = np.log10(P / scale)
        v[H // 2, W // 2] = np.nan
        v[~(P > 0)] = np.nan
        finite = np.isfinite(v)
        v32 = v.astype(np.float32)
        lo32, hi32 = np.float32(v32[finite].min()), np.float32(v32[finite].max())
        own = np.full(v.shape, -1.0, np.float32)
        own[finite] = ((v32[finite] - lo32) / np.float32(hi32 - lo32)).astype(np.float32)
        # the window in raw v is the owner's / the product's; numpy's range is its own
        ofl, ofh = window_fractions(win["rawLow"], win["rawHigh"], (lo32, hi32))
        mine = grey_levels(own, ofl, ofh)
        gd = np.abs(pixels.astype(int) - mine.astype(int)).max()
        stats["grey_diff"] = max(stats["grey_diff"], int(gd))
        rep.ok(f"F-3-independent/{n}", gd <= 1, f"largest difference from numpy's own transform {int(gd)} levels")

        # ---- F-4, the bar (on black)
        bar_png = np.asarray(Image.open(os.path.join(out, f"{n}.bar.png")), dtype=np.uint8)
        bd = json.load(open(os.path.join(out, f"{n}.bar.rendered.json")))
        meta = json.loads(Image.open(os.path.join(out, f"{n}.bar.png")).text["Description"])
        u_ = overlay_scale(W, H)
        per_px = win["spacingX"] * fx
        target = min(70 * u_, W / 4)
        nice = nice125(per_px * target)
        length = nice / per_px
        drawn = int(math.floor(length + 0.5))
        label = f"{bar_number(nice)} {RECIP}"
        plan = bd["bar"]
        rep.ok(f"F-4-plan/{n}", plan is not None and plan["label"] == label and plan["drawnPixels"] == drawn and plan["overlayScale"] == u_
               and plan["unit"] == RECIP and plan["labelUnit"] == RECIP and abs(plan["perPixel"] - per_px) <= 1e-12 * per_px
               and abs(plan["lengthPixels"] - length) <= 1e-9, f"{plan} vs {label} {drawn} {per_px}")
        sb = meta["scale_bar"]
        rep.ok(f"F-4-plan/{n}/meta", sb["label"] == label and sb["drawn_px"] == drawn and sb["measures"] == "x"
               and abs(sb["per_pixel"] - per_px) <= 1e-12 * per_px, f"{sb}")
        white = (bar_png[:, :, 0] == 255) & (bar_png[:, :, 1] == 255) & (bar_png[:, :, 2] == 255)
        region_w = white[H - H // 3:, :W // 2]
        best, rows_with = 0, 0
        for row in region_w:
            run = longest = 0
            for p in row:
                run = run + 1 if p else 0
                longest = max(longest, run)
            if longest:
                rows_with += 1
            best = max(best, longest)
        stats["bar_run"] = max(stats["bar_run"], abs(best * per_px - nice) / per_px)
        rep.ok(f"F-4-length/{n}", abs(best * per_px - nice) <= per_px, f"run {best} px x {per_px} = {best * per_px}, label {nice}")
        rep.ok(f"F-4-drawn/{n}", best == drawn == sb["drawn_px"], f"run {best}, drawn {drawn}")

        # ---- F-5, the rings (on black)
        rings = np.asarray(Image.open(os.path.join(out, f"{n}.rings.png")), dtype=np.int32)
        R, G, B = rings[:, :, 0], rings[:, :, 1], rings[:, :, 2]
        yellow = np.where((R > 100) & (B < 0.5 * R), R, 0).astype(np.float64)
        rep.ok(f"F-5-rings/{n}/drawn", yellow.sum() > 0, "no ring is drawn")
        for s in spots["spots"]:
            ex, ey = s["centroidCol"] + 0.5, s["centroidRow"] + 0.5
            half = 7 * u_ + 3
            x0, x1 = int(max(0, math.floor(ex - half))), int(min(W, math.ceil(ex + half)))
            y0, y1 = int(max(0, math.floor(ey - half))), int(min(H, math.ceil(ey + half)))
            wgt = yellow[y0:y1, x0:x1]
            yy, xx = np.mgrid[y0:y1, x0:x1]
            tot = wgt.sum()
            if tot == 0:
                rep.ok(f"F-5-rings/{n}/spot{s['number']}", False, "no yellow in the ring's box")
                continue
            cx, cy = (wgt * (xx + 0.5)).sum() / tot, (wgt * (yy + 0.5)).sum() / tot
            err = math.hypot(cx - ex, cy - ey)
            radius = (wgt * np.hypot(xx + 0.5 - ex, yy + 0.5 - ey)).sum() / tot
            stats["ring_centroid"] = max(stats["ring_centroid"], err)
            stats["ring_radius"] = max(stats["ring_radius"], abs(radius - 7 * u_))
            rep.ok(f"F-5-rings/{n}/spot{s['number']}/centre", err <= 0.15, f"centroid ({cx:.3f}, {cy:.3f}) vs ({ex:.3f}, {ey:.3f})")
            rep.ok(f"F-5-rings/{n}/spot{s['number']}/radius", abs(radius - 7 * u_) <= 0.75, f"mean radius {radius:.3f} vs {7 * u_}")

        # ---- F-6, the full export
        full = json.loads(Image.open(os.path.join(out, f"{n}.full.png")).text["Description"])
        rep.ok(f"F-6-full/{n}", full["fft"]["spots_drawn"] == str(len(spots["spots"]))
               and [m["label"] for m in full["marks"]] == [str(s["number"]) for s in spots["spots"]]
               and all(m["kind"] == "spot" for m in full["marks"]) and full["scale_bar"]["label"] == label,
               f"{full['fft']['spots_drawn']} {full['marks']}")

    if rep.failures:
        print(f"fft-export-parity: {rep.failures} FAILURES in {rep.checks} checks")
        sys.exit(1)
    print(f"ok  F-1 profile: means within {stats['profile_rel']:.2g} relative of numpy's, centres and values bit-equal")
    print(f"ok  F-2 spots: |q| within {stats['q_rel']:.2g} relative of the planted lattice, every cell bit-equal")
    print(f"ok  F-3 transform: pixels equal the shader's mapping exactly; within {stats['grey_diff']} level of numpy's own transform")
    print(f"ok  F-4 bar: the white run within {stats['bar_run']:.3g} px of its label's length")
    print(f"ok  F-5 rings: centroid within {stats['ring_centroid']:.3g} px, mean radius within {stats['ring_radius']:.3g} px of 7u")
    print(f"fft-export-parity: all passed — {rep.checks} checks ({versions})")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "plant":
        check_reference()
        plant(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "check":
        only = set(sys.argv[4].split(",")) if len(sys.argv) > 4 and sys.argv[4] != "all" else None
        check(sys.argv[2], sys.argv[3], only)
    else:
        fail("usage: reference.py plant <dir> | check <planted> <out> [cases]")
