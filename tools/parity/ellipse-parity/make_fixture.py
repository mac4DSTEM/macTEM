#!/usr/bin/env python3
"""Planted rings and their truth for tools/parity/ellipse-parity (archive: roadmap-registrations-2026-10-15.md V1-7 "S2, the ring/ellipse fit").

    make_fixture.py <out-dir>

Each case is a float32 image (raw little-endian, row-major, columns fastest: `<case>.in.f32`), rows H x columns W:
    I(r, c) = exp(-((rho - 1) * R)^2 / (2 s^2))   rho^2 = u^2/a^2 + v^2/b^2   (the conic form of py4DSTEM / mac4DSTEM)
    dr = r - r0, dc = c - c0 (the plant's centre (r0, c0), off the grid);  u = dr cos t + dc sin t, v = -dr sin t + dc cos t
    [+ N(0, noise * 1.0), seeded]  (the ring's peak is 1)
so the major axis a lies along the direction (cos t, sin t) in (row, column); t = 0 puts a along the ROWS. R = (a + b)/2
exactly (a/b = 1 + eps), the ring's width s = 3 px at the mean radius. NAMING: the fit calls the row axis "qx" and the
column axis "qy" (py4DSTEM order); here the centre is (row, col) = (qx, qy).

Cases (name = tier-HxW-rR-eE-tT-gG-sS, `-pN` the realisation of a noisy one):
  clean   (noise 0, P1): 512x512 with R 80, 140, 200; 384x512 (384 rows, 512 columns) with R 80, 120, 160 (a ring of 200
          does not fit 384 rows without being cut by the edge, and a cut would be a second gap); eps 0, 1, 3 %; a missing
          arc of 0 or 60 degrees (a hard cut of the ring's signal over that azimuth about the plant's centre, starting at
          a varying angle); theta from {0, 20, 45, 67.5, 90, 112.5, 135, 160, 179} degrees, three per combination (none
          at eps 0, where theta is undefined).
  noisy   (noise 3 % and 10 % of the peak, two realisations, fixed seeds): the same sizes, radii, eps and gaps, one theta each.
  refusal (noise 0): arc120 (a 240-degree gap), arc60 (300), gap80 (an 80-degree gap starting at 5 degrees: 7 of 36 bins
          empty, 29 occupied, one under the bound of 30) -> insufficientAngularCoverage; empty (all zeros) -> insufficientSignal.
The fit's start centre is the plant's plus (+1.3, -0.9) px (a click's error); its annulus (b - 20, a + 20) px, about 6.7 s
either side of the ring, a circle about the START centre.
planted.json: per case the plant, the annulus, the start centre, the tier, kind and the expected error name.
"""
import json
import math
import os
import sys

import numpy as np

SIGMA = 3.0                     # ring width at the mean radius, px
MARGIN = 20.0                   # annulus half-margin beyond the semi-axes, px
GUESS = (1.3, -0.9)             # start-centre error, (row, col) px
THETAS = [0.0, 20.0, 45.0, 67.5, 90.0, 112.5, 135.0, 160.0, 179.0]
SIZES = [((512, 512), [80, 140, 200]), ((384, 512), [80, 120, 160])]       # (rows, cols), radii
SEED0 = 20261012


def axes(R, eps):
    b = 2.0 * R / (2.0 + eps)
    return b * (1.0 + eps), b


def render(H, W, r0, c0, a, b, theta, gap_deg=0.0, gap_start=0.0):
    """The noise-free ring, float64. Independent of the conic coefficients: the rotated-frame form."""
    rr, cc = np.mgrid[0:H, 0:W].astype(np.float64)
    dr, dc = rr - r0, cc - c0
    s, c = math.sin(theta), math.cos(theta)
    u, v = dr * c + dc * s, -dr * s + dc * c
    rho = np.sqrt((u / a) ** 2 + (v / b) ** 2)
    R = 0.5 * (a + b)
    img = np.exp(-(((rho - 1.0) * R) ** 2) / (2.0 * SIGMA ** 2))
    if gap_deg > 0:
        ang = np.degrees(np.arctan2(dc, dr)) % 360.0
        img[((ang - gap_start) % 360.0) < gap_deg] = 0.0
    return img


def centre(H, W, k):
    """Off-grid, deterministic: within +-6 px of the middle, never an integer or a half."""
    return H / 2.0 + 0.31 + 5.0 * math.sin(1.7 * k + 0.4), W / 2.0 - 0.27 + 5.0 * math.cos(2.3 * k + 1.1)


def main(out):
    os.makedirs(out, exist_ok=True)
    cases = []
    k = 0

    def add(tier, H, W, R, eps, theta_deg, gap, noise, rep, kind="fit", error=None, gap_start=None, empty=False, label=None):
        nonlocal k
        a, b = axes(R, eps)
        theta = None if eps == 0 else math.radians(theta_deg)
        r0, c0 = centre(H, W, k)
        gs = (47.0 * k) % 360.0 if gap_start is None else gap_start
        name = "%s-%dx%d-r%d-e%g-t%s-g%d-s%g" % (tier if label is None else label, H, W, R, eps * 100,
                                                 "NA" if theta is None else ("%g" % theta_deg), gap, noise * 100)
        if rep is not None:
            name += "-p%d" % rep
        if empty:
            img = np.zeros((H, W))
        else:
            img = render(H, W, r0, c0, a, b, theta or 0.0, gap, gs)
            if noise > 0:
                img = img + np.random.default_rng(SEED0 + k).normal(0.0, noise, img.shape)
        img.astype("<f4").tofile(os.path.join(out, name + ".in.f32"))
        cases.append(dict(name=name, file=name + ".in.f32", tier=tier, kind=kind, error=error, rows=H, cols=W,
                          r0=r0, c0=c0, R=R, a=a, b=b, theta=theta, eps=eps, noise=noise, seed=(SEED0 + k) if noise > 0 else None,
                          gap_deg=float(gap), gap_start=gs, sigma=SIGMA, inner=b - MARGIN, outer=a + MARGIN,
                          guess_row=r0 + GUESS[0], guess_col=c0 + GUESS[1], empty=empty))
        k += 1

    # Clean tier (P1).
    combo = 0
    for (H, W), radii in SIZES:
        for R in radii:
            for eps in (0.0, 0.01, 0.03):
                for gap in (0, 60):
                    if eps == 0.0:
                        add("clean", H, W, R, eps, 0.0, gap, 0.0, None)
                    else:
                        for i in range(3):
                            add("clean", H, W, R, eps, THETAS[(3 * combo + i) % 9], gap, 0.0, None)
                    combo += 1
    # Noisy tier: distribution only.
    combo = 0
    for (H, W), radii in SIZES:
        for R in radii:
            for eps in (0.0, 0.01, 0.03):
                for gap in (0, 60):
                    for noise in (0.03, 0.10):
                        for rep in (1, 2):
                            add("noisy", H, W, R, eps, THETAS[(combo * 2 + rep) % 9], gap, noise, rep)
                    combo += 1
    # Refusals (P2).
    add("refusal", 512, 512, 120, 0.03, 45.0, 240, 0.0, None, kind="refusal", error="insufficientAngularCoverage", label="refuse-arc120")
    add("refusal", 512, 512, 120, 0.03, 45.0, 300, 0.0, None, kind="refusal", error="insufficientAngularCoverage", label="refuse-arc60")
    add("refusal", 384, 512, 100, 0.01, 135.0, 80, 0.0, None, kind="refusal", error="insufficientAngularCoverage", gap_start=5.0, label="refuse-gap80")
    add("refusal", 512, 512, 120, 0.03, 45.0, 0, 0.0, None, kind="refusal", error="insufficientSignal", empty=True, label="refuse-empty")

    with open(os.path.join(out, "planted.json"), "w") as f:
        json.dump({"sigma": SIGMA, "margin": MARGIN, "guess": GUESS, "cases": cases}, f, indent=1)
    n = {t: sum(1 for c in cases if c["tier"] == t) for t in ("clean", "noisy", "refusal")}
    print("make_fixture: %d cases (%s) in %s" % (len(cases), ", ".join("%s %d" % kv for kv in n.items()), out))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(64)
    main(sys.argv[1])
