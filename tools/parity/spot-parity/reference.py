#!/usr/bin/env python3
"""Truth for tools/parity/spot-parity: numpy's d-spacing estimator exactly as registered (archive: roadmap-registrations-2026-10-15.md V1-6 "Slice C").

    reference.py <planted-dir> <out-dir>

Reference = numpy 2.5.4 (pinned in tools/lib/references-lock.txt). For each case, from the float32 pixels cast to
float64: x - x.mean(); times np.outer(np.hanning(h), np.hanning(w)); P = |fftshift(fft2(.))|**2 (float64).
  snap     the largest P within +-2 bins of the click, every bin within 1e-6 (relative) of it counting as largest,
           the first of them in row-major order (slice C').
  centroid over the 5 x 5 window around the snapped bin: (sum P*row)/sum P, (sum P*col)/sum P (float64, no background).
  d        i = col_c - w//2, j = row_c - h//2; qx = i * (1/(w*dx)), qy = j * (1/(h*dy)); q = sqrt(qx^2 + qy^2); d = 1/q.
  nearDC   the snapped bin within Euclidean distance 3 bins of the centre (h//2, w//2) -> refusal, no centroid, no d.
  nearEdge the snapped bin within 2 bins of the spectrum's edge (the 5 x 5 window would leave it) -> refusal (C' review).
  neighbour  another local maximum (P above all 8 neighbours by more than 1e-6 relative, slice C') other than the 5 x 5 window's own maximum,
           within Euclidean distance 3 bins of the snapped bin, with P > 0.1 * P(the window's maximum).
Writes manifest.json: {"numpy", "cases": [{name, input (full path), width, height, scale_x, scale_y, units, click_row,
click_col, kind "spot"|"refusal", snapped_row, snapped_col, centroid_row, centroid_col (null for a refusal), d (null for
a refusal), d0, tier "clean"|"noisy", neighbour (bool), error null|"nearDC"}]}.

Before anything counts (exit 1, loudly, otherwise): numpy's snap returns the planted true maximum, with a margin of
>= 1e-10 (relative) over the runner-up in the click's +-2 window (a tie would let float rounding choose differently in
Swift); a spot case's |d - d0|/d0 is < 0.2 % (tier clean, P1) or < 0.5 % (tier noisy, P3), and the distribution is
printed; the refusal case is refused and no other case is; the neighbour flag is set exactly where the plant says;
and the registered mutations each move their target check beyond its band (the harness is not blind): see MUTATIONS.
"""
import json
import math
import os
import sys

import numpy as np

NUMPY = "2.5.4"
BAND = {"clean": 0.002, "noisy": 0.005}


def fail(msg):
    print("reference.py: FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


def estimate(x32, click, dx, dy, mut=None):
    """The registered estimator on float32 pixels; `mut` swaps in one deliberate mistake (see MUTATIONS)."""
    h, w = x32.shape
    x = x32.astype(np.float64)
    if mut != "no-mean":
        x = x - x.mean()
    if mut != "no-hann":
        x = x * np.outer(np.hanning(h), np.hanning(w))
    P = np.abs(np.fft.fftshift(np.fft.fft2(x))) ** 2
    cr, cc = click
    if mut == "no-snap":
        sr, sc = cr, cc
    else:
        blk = P[cr - 2:cr + 3, cc - 2:cc + 3]
        # Slice C': every bin within 1e-6 (relative) of the largest counts as largest; the first in row-major order.
        a, b = np.unravel_index(int(np.flatnonzero(blk.ravel() >= blk.max() * (1 - 1e-6))[0]), blk.shape)
        sr, sc = cr - 2 + int(a), cc - 2 + int(b)
    near_dc = math.hypot(sr - h // 2, sc - w // 2) <= 3.0
    near_edge = not (2 <= sr < h - 2 and 2 <= sc < w - 2)   # slice C' review: the 5x5 window must stay inside
    if near_dc or near_edge:      # refused: no centroid, no d (as SpotMeasure throws before computing them)
        return {"snapped": (sr, sc), "centroid": (float("nan"), float("nan")), "d": float("nan"),
                "near_dc": near_dc, "near_edge": near_edge, "neighbour": False, "margin": 1.0}
    r = 1 if mut == "window-3x3" else 2
    win = P[sr - r:sr + r + 1, sc - r:sc + r + 1]
    if mut == "magnitude-weights":
        win = np.sqrt(win)
    rows = np.arange(sr - r, sr + r + 1, dtype=np.float64)[:, None]
    cols = np.arange(sc - r, sc + r + 1, dtype=np.float64)[None, :]
    s = win.sum()
    crow = float((win * rows).sum() / s)
    ccol = float((win * cols).sum() / s)
    i, j = ccol - w // 2, crow - h // 2
    dqx = 1.0 / (w * dx)
    dqy = 1.0 / ((h * dy) if mut != "one-spacing" else (h * dx))
    qx, qy = i * dqx, j * dqy
    q = abs(qx) if mut == "qx-only" else math.sqrt(qx * qx + qy * qy)
    d = 1.0 / q if q > 0 else float("nan")
    # neighbour flag (unmutated definition)
    wr, wc = np.unravel_index(int(np.argmax(P[sr - 2:sr + 3, sc - 2:sc + 3])), (5, 5))
    pr, pc = sr - 2 + int(wr), sc - 2 + int(wc)
    pmax = P[pr, pc]
    nb = False
    for rr in range(sr - 3, sr + 4):
        for c2 in range(sc - 3, sc + 4):
            if (rr, c2) == (pr, pc) or math.hypot(rr - sr, c2 - sc) > 3.0:
                continue
            v = P[rr, c2]
            loc = P[rr - 1:rr + 2, c2 - 1:c2 + 2].copy()
            loc[1, 1] = -np.inf
            if v > loc.max() * (1 + 1e-6) and v > 0.1 * pmax:     # slice C': a local maximum by more than 1e-6
                nb = True
    blk = P[cr - 2:cr + 3, cc - 2:cc + 3].ravel()
    srt = np.sort(blk)
    margin = float((srt[-1] - srt[-2]) / srt[-1])
    return {"snapped": (sr, sc), "centroid": (crow, ccol), "d": d, "near_dc": near_dc, "near_edge": near_edge,
            "neighbour": nb, "margin": margin}


# mutation -> (target case, kind of target): "centroid" must move by > 1e-3 px (Swift band is 1e-6); "d" must leave
# the clean band by > 5x. The Swift side implements the same mutations in main.swift; run.sh names the same targets.
MUTATIONS = {
    "no-mean": ("dc1000-128x128-k5", "d"),        # without the mean the spot is refused near DC: d is nan
    "no-hann": ("s128x128-k5-a70-o0.25_0.5", "centroid"),
    "window-3x3": ("s128x128-k5-a70-o0.25_0.5", "centroid"),
    "magnitude-weights": ("s128x128-k5-a70-o0.25_0.5", "centroid"),
    "no-snap": ("x128-k5-o0.25_0.25-c0_2", "centroid"),
    "one-spacing": ("s128x128-k5-a70-o0.25_0.5", "d"),
    "qx-only": ("s128x128-k5-a70-o0.25_0.5", "d"),
}


def main():
    pdir, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(pdir, "planted.json")) as f:
        planted = json.load(f)["cases"]
    if np.__version__ != NUMPY:
        fail("numpy %s, the lock pins %s" % (np.__version__, NUMPY))
    cases, errs = [], {"clean": [], "noisy": []}
    img = {}
    for c in planted:
        w, h = c["width"], c["height"]
        path = os.path.join(pdir, c["name"] + ".in.f32")
        x = np.fromfile(path, dtype="<f4").reshape(h, w)
        img[c["name"]] = x
        click = (c["click_row"], c["click_col"])
        e = estimate(x, click, c["scale_x"], c["scale_y"])
        if tuple(e["snapped"]) != (c["true_row"], c["true_col"]) and e["margin"] >= 1e-6:
            fail("%s: snap %s is not the planted maximum (%d, %d)" % (c["name"], e["snapped"], c["true_row"], c["true_col"]))
        # At an exact half-bin offset the planted maximum and its neighbour tie: slice C' takes the first; d still counts.
        if e["margin"] < 1e-6:
            print("  note  %s: runner-up within %.2e (relative) of the snapped bin: a tie, resolved by slice C's rule" % (c["name"], e["margin"]))
        want_nb = bool(c.get("neighbour_expected", False))
        if e["neighbour"] != want_nb:
            fail("%s: neighbour flag %s, the plant says %s" % (c["name"], e["neighbour"], want_nb))
        refusal = c["kind"] == "refusal"
        cause = "nearDC" if e["near_dc"] else ("nearEdge" if e["near_edge"] else None)
        if (cause is not None) != refusal or (refusal and c.get("error_expected", "nearDC") != cause):
            fail("%s: refusal cause %s but the plant says %s %s" % (c["name"], cause, c["kind"], c.get("error_expected", "")))
        rec = {"name": c["name"], "input": path, "width": w, "height": h, "scale_x": c["scale_x"],
               "scale_y": c["scale_y"], "units": c["units"], "click_row": c["click_row"], "click_col": c["click_col"],
               "kind": c["kind"], "snapped_row": int(e["snapped"][0]), "snapped_col": int(e["snapped"][1]),
               "d0": c["d0"], "tier": c["tier"], "neighbour": e["neighbour"], "click_offset": c["click_offset"]}
        if refusal:
            rec.update(centroid_row=None, centroid_col=None, d=None, error=cause)
        else:
            err = abs(e["d"] - c["d0"]) / c["d0"]
            if err >= BAND[c["tier"]]:
                fail("%s: |d - d0|/d0 = %.4f %% >= %.1f %% (%s tier)" % (c["name"], 100 * err, 100 * BAND[c["tier"]], c["tier"]))
            errs[c["tier"]].append((err, c["name"]))
            rec.update(centroid_row=e["centroid"][0], centroid_col=e["centroid"][1], d=e["d"], error=None)
        cases.append(rec)
    for tier in ("clean", "noisy"):
        v = sorted(errs[tier])
        if v:
            es = np.array([a for a, _ in v]) * 100
            print("reference: %s tier: %d cases, |d - d0|/d0 %% median %.4f, max %.4f (%s), band %.1f"
                  % (tier, len(v), float(np.median(es)), es.max(), v[-1][1], 100 * BAND[tier]))
    by = {c["name"]: c for c in planted}
    for mut, (target, kind) in MUTATIONS.items():
        c = by.get(target)
        if c is None:
            fail("mutation %s targets a case that does not exist: %s" % (mut, target))
        click = (c["click_row"], c["click_col"])
        a = estimate(img[target], click, c["scale_x"], c["scale_y"])
        b = estimate(img[target], click, c["scale_x"], c["scale_y"], mut)
        if kind == "centroid":
            moved = max(abs(a["centroid"][0] - b["centroid"][0]), abs(a["centroid"][1] - b["centroid"][1]))
            ok = moved > 1e-3
            what = "centroid moves %.4g px" % moved
        else:
            moved = abs(b["d"] - c["d0"]) / c["d0"]
            ok = math.isnan(moved) or moved > 5 * BAND["clean"]     # a refusal (nan) is moved too
            what = "d error %.2f %%" % (100 * moved)
        print("reference: mutation %-18s -> %-34s %s: %s" % (mut, target, kind, what))
        if not ok:
            fail("mutation %s does not move its target %s %s enough (%s)" % (mut, target, kind, what))
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump({"numpy": np.__version__, "cases": cases}, f, indent=1)
    print("reference: %d cases (%d refusal) in %s" % (len(cases), sum(c["kind"] == "refusal" for c in cases), out))


if __name__ == "__main__":
    main()
