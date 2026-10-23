#!/usr/bin/env python3
"""Reference for tools/parity/ellipse-parity: numpy/scipy written from the registered definition (archive: roadmap-registrations-2026-10-15.md V1-7 "S2").

    reference.py <planted-dir> <out-dir>

Reference = numpy 2.5.4 and scipy 1.18.1 (pinned in tools/lib/references-lock.txt); the TRUTH is the plant
(make_fixture.py). py4DSTEM is not run (its closure does not install on the lock's CPython 3.14; archive:
v17-plan-2026-10-12.md); agreement with its executed output is not claimed. The definition, from fit_ellipse_1D as
mac4DSTEM ported it at 7c180bce: the conic (A dx^2 + B dx dy + C dy^2 - 1) * I over the annulus pixels (hypot(dx, dy)
> inner and <= outer about the START centre, finite pixels, dx = row - c_row, dy = col - c_col), minimised over
(c_row, c_col, A, B, C) from [start centre, 1/Rm^2, 0, 1/Rm^2], Rm = (inner + outer)/2; (A, B, C) -> semi-axes by the
eigenvalues of [[A, B/2], [B/2, C]]: a = 1/sqrt(smaller), b = 1/sqrt(larger), theta the direction (cos t, sin t) in
(row, col) of the smaller-eigenvalue eigenvector, mod pi. Coverage: the pixels with I >= min + 0.2 (max - min) over
the annulus, binned by atan2(col - c_col, row - c_row) mod 2 pi into 36 bins about the START centre; occupied = bins
holding one; accepted when occupied >= 30.

What this script writes (manifest.json), per case: the planted record plus `input` (full path), `samples` (annulus
pixels), `occupied`, and for a fit case the numpy/scipy optimum `ref` = {row, col, a, b, theta, residual} from
scipy.optimize.least_squares (method "lm", tolerances 1e-15).

Before anything counts (exit 1 otherwise): the plant's (a, b, theta) survive the round trip through the conic
coefficients and the eigen decomposition (the convention is the one the fit inverts); the float32 image equals an
independent conic-form rendering of the plant (clean: within 1e-6; noisy: the residual's mean and standard deviation
match the planted noise); every fit case has occupied >= 30 and every refusal case < 30 (or is empty).
Printed, not gated: the scipy optimum against the plant on the clean tier.
"""
import json
import math
import os
import sys

import numpy as np
import scipy
from scipy.optimize import least_squares

NUMPY, SCIPY = "2.5.4", "1.18.1"


def fail(msg):
    print("reference.py: FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


def abc_of(a, b, theta):
    s2, c2 = math.sin(theta) ** 2, math.cos(theta) ** 2
    return (s2 / b ** 2 + c2 / a ** 2,
            2 * (b ** 2 - a ** 2) * math.sin(theta) * math.cos(theta) / (a ** 2 * b ** 2),
            c2 / b ** 2 + s2 / a ** 2)


def user_of(A, B, C):
    """(a, b, theta) from the quadratic form, by numpy's symmetric eigensolver (not the closed form the fit uses)."""
    w, v = np.linalg.eigh(np.array([[A, B / 2.0], [B / 2.0, C]]))
    major = v[:, 0]                                 # smaller eigenvalue -> the longer semi-axis, along (row, col) = major
    return 1.0 / math.sqrt(w[0]), 1.0 / math.sqrt(w[1]), math.atan2(major[1], major[0]) % math.pi


def ang_err(x, y):
    d = abs(x - y) % math.pi
    return min(d, math.pi - d)


def conic_render(c):
    """An independent rendering of the plant: the conic coefficients, not the rotated frame."""
    rr, cc = np.mgrid[0:c["rows"], 0:c["cols"]].astype(np.float64)
    dr, dc = rr - c["r0"], cc - c["c0"]
    th = c["theta"] or 0.0
    A, B, C = abc_of(c["a"], c["b"], th)
    R = 0.5 * (c["a"] + c["b"])
    rho = np.sqrt(A * dr * dr + B * dr * dc + C * dc * dc)
    img = np.exp(-(((rho - 1.0) * R) ** 2) / (2.0 * c["sigma"] ** 2))
    if c["gap_deg"] > 0:
        ang = np.degrees(np.arctan2(dc, dr)) % 360.0
        img[((ang - c["gap_start"]) % 360.0) < c["gap_deg"]] = 0.0
    return img


def annulus(img, c):
    rows, cols = img.shape
    dr = np.arange(rows, dtype=np.float64)[:, None] - c["guess_row"]
    dc = np.arange(cols, dtype=np.float64)[None, :] - c["guess_col"]
    rad = np.hypot(dr, dc)
    m = (rad > c["inner"]) & (rad <= c["outer"]) & np.isfinite(img)
    return np.broadcast_to(dr, img.shape)[m], np.broadcast_to(dc, img.shape)[m], img[m]


def coverage(dx, dy, v):
    if len(v) == 0:
        return 0
    lo, hi = v.min(), v.max()
    strong = v >= lo + 0.2 * (hi - lo)
    ang = np.arctan2(dy[strong], dx[strong]) % (2 * math.pi)
    idx = np.minimum(35, (ang / (2 * math.pi) * 36).astype(int))
    return int(len(np.unique(idx)))


def ref_fit(dx0, dy0, v, c):
    """The weighted conic least squares, from the registered start."""
    x = dx0 + c["guess_row"]
    y = dy0 + c["guess_col"]

    def res(p):
        dx, dy = x - p[0], y - p[1]
        return (p[2] * dx * dx + p[3] * dx * dy + p[4] * dy * dy - 1.0) * v

    rm = 0.5 * (c["inner"] + c["outer"])
    p0 = [c["guess_row"], c["guess_col"], 1 / rm ** 2, 0.0, 1 / rm ** 2]
    # x_scale keeps the unit-less conic coefficients (~1e-5) and the pixel coordinates (~1e2) on one footing.
    r = least_squares(res, p0, method="lm", xtol=1e-15, ftol=1e-15, gtol=1e-15, x_scale=[1, 1, 1e-5, 1e-5, 1e-5], max_nfev=2000)
    a, b, th = user_of(r.x[2], r.x[3], r.x[4])
    resid = math.sqrt(float(np.sum(r.fun ** 2)) / float(np.sum(v ** 2)))
    return dict(row=float(r.x[0]), col=float(r.x[1]), a=a, b=b, theta=th, residual=resid)


def main(planted, out):
    if np.__version__ != NUMPY or scipy.__version__ != SCIPY:
        fail("numpy %s / scipy %s, locked %s / %s" % (np.__version__, scipy.__version__, NUMPY, SCIPY))
    os.makedirs(out, exist_ok=True)
    plan = json.load(open(os.path.join(planted, "planted.json")))
    cases = []
    clean_err = []
    for c in plan["cases"]:
        path = os.path.abspath(os.path.join(planted, c["file"]))
        img32 = np.fromfile(path, dtype="<f4").reshape(c["rows"], c["cols"])
        img = img32.astype(np.float64)
        n = c["name"]
        # The convention round trip.
        if c["theta"] is not None:
            a, b, th = user_of(*abc_of(c["a"], c["b"], c["theta"]))
            if abs(a - c["a"]) > 1e-9 or abs(b - c["b"]) > 1e-9 or ang_err(th, c["theta"]) > 1e-9:
                fail("%s: (a, b, theta) do not survive the conic round trip: (%g, %g, %g) vs (%g, %g, %g)" % (n, a, b, th, c["a"], c["b"], c["theta"]))
        if abs(0.5 * (c["a"] + c["b"]) - c["R"]) > 1e-9:
            fail("%s: (a + b)/2 != R" % n)
        # The image is the plant.
        if not c["empty"]:
            diff = img - conic_render(c)
            if c["noise"] == 0:
                if np.abs(diff).max() > 1e-6:
                    fail("%s: image differs from the conic rendering by %g" % (n, np.abs(diff).max()))
            else:
                sd = diff.std()
                if abs(diff.mean()) > 0.01 * c["noise"] or abs(sd / c["noise"] - 1) > 0.02:
                    fail("%s: planted noise mean %g sd %g, wanted 0 / %g" % (n, diff.mean(), sd, c["noise"]))
        elif np.any(img != 0):
            fail("%s: the empty case is not all zeros" % n)
        dx, dy, v = annulus(img, c)
        occ = coverage(dx, dy, v) if not c["empty"] else 0
        entry = dict(c, input=path, samples=int(len(v)), occupied=occ)
        if c["kind"] == "fit":
            if occ < 30:
                fail("%s: a fit case with %d occupied bins (< 30); the plant is wrong" % (n, occ))
            entry["ref"] = ref_fit(dx, dy, v, c)
            if c["tier"] == "clean":
                r = entry["ref"]
                clean_err.append((math.hypot(r["row"] - c["r0"], r["col"] - c["c0"]), abs(0.5 * (r["a"] + r["b"]) - c["R"]) / c["R"], n))
        else:
            if c["empty"]:
                if occ != 0:
                    fail("%s: empty case has coverage" % n)
            elif occ >= 30:
                fail("%s: a refusal case with %d occupied bins (>= 30); the plant is wrong" % (n, occ))
        cases.append(entry)
    ce = np.array([e[0] for e in clean_err]); re_ = np.array([e[1] for e in clean_err])
    print("reference.py: scipy optimum against the plant, clean tier (%d cases): centre max %.3g px, mean radius max %.3g %%" % (len(ce), ce.max(), 100 * re_.max()))
    json.dump({"numpy": NUMPY, "scipy": SCIPY, "cases": cases}, open(os.path.join(out, "manifest.json"), "w"))
    print("reference.py: %d cases, numpy %s scipy %s" % (len(cases), NUMPY, SCIPY))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(64)
    main(sys.argv[1], sys.argv[2])
