#!/usr/bin/env python3
"""Planted rings, their truth, and scipy's optimum of the profile model, for tools/parity/ring-fit-parity (archive: roadmap-registrations-2026-10-15.md
"Diffraction S3, Camera length from one ring of known d", slice S3-b: the fit-driven calibration on planted rings).

    plants.py <out-dir>

Every case is a float32 image (raw little-endian, row-major, columns fastest: `<case>.in.f32`), rows H x columns W, the
centre (r0, c0) off the grid with r0 != c0. The fit's "qx" is the ROW and "qy" the COLUMN (py4DSTEM's order).

THE IN-FAMILY RING (the registered plant, tools/parity/ellipse-parity's, unchanged):
    I = exp(-((rho - 1) R)^2 / (2 s^2)),  rho^2 = u^2/a^2 + v^2/b^2,  u = dr cos t + dc sin t,  v = -dr sin t + dc cos t
the major axis a along (cos t, sin t) in (row, column), R = (a + b)/2 exactly (a/b = 1 + eps), s = 3 px. It is the
asymmetric-Gaussian model's own family (sigma_in = sigma_out = s, no central disc, no background).

TIERS (registered: archive: roadmap-registrations-2026-10-15.md's "Datasets", "Measure first" and P1/P2):
  clean    tools/parity/ellipse-parity's 84 noise-free plants, the same sizes, radii (80-200 px), eps 0/1/3 %, theta, 60-degree
           gaps and centres (the same generator): P1 is decided on the ACCEPTED ones.
  noisy    its 144 noisy plants (3 and 10 % of the peak, two seeded realisations): printed, never gated.
  printed  each a handful of plants, never gated (the registration bands no tier but clean before its distribution is
           read): width constant in px (out of family), constant / 1/r^2 / 1/r^3 / exponential backgrounds, a Lorentzian
           ring of the same FWHM, a skewed ring (gamma, k = 4, mode at R), a neighbour ring at 1.155 R, annulus half-widths
           10-40 px, R 40-250 px, s 1.5-8 px.
  refusal  P2, each registered refusal on the plant the registration names for it: the 120-degree gap (and
           ellipse-parity's 240/300-degree arcs and 80-degree gap) -> insufficientAngularCoverage; the empty pattern ->
           the fit's insufficientSignal (no ring at all); a two-ring annulus (the second at 1.13 R) -> the conic refused
           (modelNotAsymmetricGaussian); the 1/r^3 background at 1.0 of the peak -> calibrated (accepts; it was registered as sigmaAtAnnulusWidth); a clean ring
           without V -> noHighTension (Delta q still given); 12 % ellipticity -> excessiveEllipticity.

Every fit case also carries a (material, hkl, d, V) from the S3-a set (Au a = 4.0782 A, Al a = 4.0495 A; 80, 200, 300 kV),
cycled over the cases, so L is computed and checked as well as Delta q. The truth: Delta q = (1/d)/R, and L_px = R / tan 2theta
from the same closed forms as tools/parity/ring-calibration-parity's reference (numpy, float64; that harness holds them to 1e-12).

THE REFERENCE beside the plant (printed, not gated): scipy's optimum of the SAME 11-parameter model (py4DSTEM's
fit_ellipse_amorphous_ring as mac4DSTEM ports it: I0 exp(-r^2/2 s0^2) + I1 exp(-(r - R)^2 / 2 s1,2^2) + c, r the elliptical
radius scaled by R = (a + b)/2) over the same annulus pixels, started at the plant, on the clean tier: it separates the model
from the Swift optimiser.
"""
import json
import math
import os
import sys

import numpy as np
import scipy
from scipy.optimize import least_squares

SIGMA = 3.0
MARGIN = 20.0
GUESS = (1.3, -0.9)
THETAS = [0.0, 20.0, 45.0, 67.5, 90.0, 112.5, 135.0, 160.0, 179.0]
SIZES = [((512, 512), [80, 140, 200]), ((384, 512), [80, 120, 160])]
SEED0 = 20261012

# CODATA 2018 (as tools/parity/ring-calibration-parity/reference.py states them).
H, C, E, M0 = 6.62607015e-34, 299792458.0, 1.602176634e-19, 9.1093837015e-31
HC_EV_A = H * C / E * 1e10
M0C2_EV = M0 * C * C / E
LATTICE = {"Au": 4.0782, "Al": 4.0495}
REFLECTIONS = [("Au", (1, 1, 1)), ("Au", (2, 0, 0)), ("Au", (2, 2, 0)), ("Au", (3, 1, 1)), ("Au", (4, 2, 2)),
               ("Al", (1, 1, 1)), ("Al", (2, 0, 0)), ("Al", (2, 2, 0))]
VOLTS = [80000.0, 200000.0, 300000.0]


def wavelength(volts):
    return HC_EV_A / math.sqrt(volts * (2.0 * M0C2_EV + volts))


def d_spacing(material, hkl):
    return LATTICE[material] / math.sqrt(sum(i * i for i in hkl))


def axes(R, eps):
    b = 2.0 * R / (2.0 + eps)
    return b * (1.0 + eps), b


def frame(Hh, W, r0, c0, a, b, theta):
    rr, cc = np.mgrid[0:Hh, 0:W].astype(np.float64)
    dr, dc = rr - r0, cc - c0
    s, c = math.sin(theta), math.cos(theta)
    u, v = dr * c + dc * s, -dr * s + dc * c
    rho = np.sqrt((u / a) ** 2 + (v / b) ** 2)
    return dr, dc, rho


def ring(profile, x, s):
    """The ring's radial profile at offset x (px) from its peak locus; every profile peaks at 1 at x = 0."""
    if profile == "gauss":
        return np.exp(-(x ** 2) / (2.0 * s ** 2))
    if profile == "lorentz":                       # the same FWHM as the Gaussian of sigma s
        g = s * math.sqrt(2.0 * math.log(2.0))     # half width at half maximum
        return 1.0 / (1.0 + (x / g) ** 2)
    if profile == "skew":                          # gamma, shape k = 4, scale chosen for sd s, mode at x = 0
        k = 4.0
        scale = s / math.sqrt(k)
        m = (k - 1.0) * scale
        y = np.clip(x + m, 0.0, None)
        out = (y / m) ** (k - 1.0) * np.exp(-(y - m) / scale)
        return np.where(x + m > 0, out, 0.0)
    raise ValueError(profile)


def render(Hh, W, r0, c0, a, b, theta, gap_deg=0.0, gap_start=0.0, s=SIGMA, profile="gauss", width_px=False,
           background=None, neighbour=None, second=None):
    dr, dc, rho = frame(Hh, W, r0, c0, a, b, theta)
    R = 0.5 * (a + b)
    if width_px:
        # Width constant in px along the true radius: the offset is r - r_e(phi), r_e the ellipse's radius in that
        # direction, not (rho - 1) R (out of the model's family for eps > 0).
        r = np.hypot(dr, dc)
        x = r - r / np.where(rho > 0, rho, 1.0)
    else:
        x = (rho - 1.0) * R
    img = ring(profile, x, s)
    if neighbour is not None:                      # (radius factor, amplitude): a second ring, same shape and width
        f, amp = neighbour
        img = img + amp * ring(profile, (rho - f) * R, s)
    if background is not None:
        kind, amp = background
        r = np.maximum(np.hypot(dr, dc), 1.0)
        if kind == "const":
            img = img + amp
        elif kind.startswith("r"):                 # amp (R / r)^n: amp of the ring's peak at the ring
            img = img + amp * (R / r) ** int(kind[1:])
        elif kind == "exp25":                      # amp exp(-(r - R)/25)
            img = img + amp * np.exp(-(r - R) / 25.0)
        else:
            raise ValueError(kind)
    if gap_deg > 0:
        ang = np.degrees(np.arctan2(dc, dr)) % 360.0
        img[((ang - gap_start) % 360.0) < gap_deg] = 0.0
    return img


def centre(Hh, W, k):
    return Hh / 2.0 + 0.31 + 5.0 * math.sin(1.7 * k + 0.4), W / 2.0 - 0.27 + 5.0 * math.cos(2.3 * k + 1.1)


# The 11-parameter model, written from mac4DSTEM's fitAmorphousRing (EllipseCalibration.swift `predictions`).
def model(p, x, y):
    I0, I1, s0, s1, s2, c, x0, y0, a, b, t = p
    st, ct = math.sin(t), math.cos(t)
    a2, b2 = a * a, b * b
    A = st * st / b2 + ct * ct / a2
    B = 2.0 * (b2 - a2) * st * ct / (a2 * b2)
    Cc = ct * ct / b2 + st * st / a2
    R = 0.5 * (a + b)
    A, B, Cc = A * R * R, B * R * R, Cc * R * R
    dx, dy = x - x0, y - y0
    e2 = np.maximum(0.0, A * dx * dx + B * dx * dy + Cc * dy * dy)
    delta = np.sqrt(e2) - R
    sig = np.where(delta < 0, 2.0 * s1 * s1, 2.0 * s2 * s2)
    return I0 * np.exp(-e2 / (2.0 * s0 * s0)) + I1 * np.exp(-delta * delta / sig) + c


def scipy_optimum(img, case):
    Hh, W = img.shape
    rr, cc = np.mgrid[0:Hh, 0:W].astype(np.float64)
    rad = np.hypot(rr - case["guess_row"], cc - case["guess_col"])
    sel = (rad > case["inner"]) & (rad < case["outer"]) & np.isfinite(img)
    x, y, v = rr[sel], cc[sel], img[sel].astype(np.float64)
    theta = case["theta"] if case["theta"] is not None else 0.0
    p0 = [0.0, 1.0, max(1.0, case["inner"] / 2.0), SIGMA, SIGMA, 0.0, case["r0"], case["c0"], case["a"], case["b"], theta]
    lo = [0.0, 0.0, 0.25, 0.25, 0.25, -np.inf, -np.inf, -np.inf, 1.0, 1.0, -np.inf]
    hi = [np.inf] * 11
    res = least_squares(lambda p: model(p, x, y) - v, p0, bounds=(lo, hi), x_scale="jac", xtol=1e-12, ftol=1e-12,
                        gtol=1e-12, max_nfev=2000)
    p = res.x
    return dict(row=float(p[6]), col=float(p[7]), a=float(max(p[8], p[9])), b=float(min(p[8], p[9])),
                radius=float(0.5 * (p[8] + p[9])), samples=int(sel.sum()), status=int(res.status))


def main(out):
    os.makedirs(out, exist_ok=True)
    cases = []
    k = 0

    def add(tier, Hh, W, R, eps, theta_deg, gap, noise=0.0, rep=None, kind="fit", error=None, gap_start=None,
            empty=False, label=None, s=SIGMA, margin=MARGIN, volts="cycle", gated=False, **shape):
        nonlocal k
        a, b = axes(R, eps)
        theta = None if eps == 0 else math.radians(theta_deg)
        r0, c0 = centre(Hh, W, k)
        gs = (47.0 * k) % 360.0 if gap_start is None else gap_start
        base = label if label is not None else tier
        name = "%s-%dx%d-r%g-e%g-t%s-g%d-s%g" % (base, Hh, W, R, eps * 100,
                                                 "NA" if theta is None else ("%g" % theta_deg), gap, noise * 100)
        if rep is not None:
            name += "-p%d" % rep
        if empty:
            img = np.zeros((Hh, W))
        else:
            img = render(Hh, W, r0, c0, a, b, theta or 0.0, gap, gs, s=s, **shape)
            if noise > 0:
                img = img + np.random.default_rng(SEED0 + k).normal(0.0, noise, img.shape)
        img.astype("<f4").tofile(os.path.join(out, name + ".in.f32"))
        material, hkl = REFLECTIONS[k % len(REFLECTIONS)]
        d = d_spacing(material, hkl)
        v = VOLTS[(k // len(REFLECTIONS)) % len(VOLTS)] if volts == "cycle" else volts
        lam = wavelength(v) if v is not None else None
        two_theta = 2.0 * math.asin(lam / (2.0 * d)) if v is not None else None
        cases.append(dict(name=name, file=name + ".in.f32", tier=tier, kind=kind, error=error, gated=gated,
                          rows=Hh, cols=W, r0=r0, c0=c0, R=float(R), a=a, b=b, theta=theta, eps=eps, noise=noise,
                          gap_deg=float(gap), gap_start=gs, sigma=s, inner=b - margin, outer=a + margin,
                          guess_row=r0 + GUESS[0], guess_col=c0 + GUESS[1], empty=empty,
                          material=material, hkl="%d%d%d" % hkl, d=d, volts=v, pitch_mm=0.014,
                          dq=(1.0 / d) / R, length_px=(R / math.tan(two_theta)) if v is not None else None,
                          shape={key: (list(val) if isinstance(val, tuple) else val) for key, val in shape.items()},
                          ref=None))
        k += 1

    # clean (P1, gated) and noisy (printed): tools/parity/ellipse-parity's generator, the same loops in the same order.
    combo = 0
    for (Hh, W), radii in SIZES:
        for R in radii:
            for eps in (0.0, 0.01, 0.03):
                for gap in (0, 60):
                    if eps == 0.0:
                        add("clean", Hh, W, R, eps, 0.0, gap, gated=True)
                    else:
                        for i in range(3):
                            add("clean", Hh, W, R, eps, THETAS[(3 * combo + i) % 9], gap, gated=True)
                    combo += 1
    combo = 0
    for (Hh, W), radii in SIZES:
        for R in radii:
            for eps in (0.0, 0.01, 0.03):
                for gap in (0, 60):
                    for noise in (0.03, 0.10):
                        for rep in (1, 2):
                            add("noisy", Hh, W, R, eps, THETAS[(combo * 2 + rep) % 9], gap, noise, rep)
                    combo += 1

    # printed tiers: 512 x 512 unless the radius needs more, R 120, eps 1 or 3 %, no gap, two thetas each.
    for t in (20.0, 112.5):
        add("width-px", 512, 512, 120, 0.03, t, 0, width_px=True)
        add("bg-const-0.3", 512, 512, 120, 0.01, t, 0, background=("const", 0.3))
        add("bg-r2-0.3", 512, 512, 120, 0.01, t, 0, background=("r2", 0.3))
        add("bg-r2-1.0", 512, 512, 120, 0.01, t, 0, background=("r2", 1.0))
        add("bg-r3-1.0", 512, 512, 120, 0.01, t, 0, background=("r3", 1.0))
        add("bg-exp25-1.0", 512, 512, 120, 0.01, t, 0, background=("exp25", 1.0))
        add("lorentz", 512, 512, 120, 0.01, t, 0, profile="lorentz")
        add("skew", 512, 512, 120, 0.01, t, 0, profile="skew")
        add("neighbour-1.155", 512, 512, 120, 0.01, t, 0, neighbour=(1.155, 0.5))
        for m in (10.0, 20.0, 30.0, 40.0):
            add("annulus-%g" % m, 512, 512, 120, 0.01, t, 0, margin=m, label="annulus-%g" % m)
        for R, size in ((40, 256), (60, 256), (250, 640)):
            add("radius-%d" % R, size, size, R, 0.01, t, 0, label="radius-%d" % R)
        for s in (1.5, 5.0, 8.0):
            add("sigma-%g" % s, 512, 512, 120, 0.01, t, 0, s=s, label="sigma-%g" % s)

    # refusals (P2): each registered refusal on the plant the registration names.
    add("refusal", 512, 512, 120, 0.03, 45.0, 120, kind="refusal", error="insufficientAngularCoverage", gap_start=10.0, label="refuse-gap120")
    add("refusal", 512, 512, 120, 0.03, 45.0, 240, kind="refusal", error="insufficientAngularCoverage", label="refuse-arc120")
    add("refusal", 512, 512, 120, 0.03, 45.0, 300, kind="refusal", error="insufficientAngularCoverage", label="refuse-arc60")
    add("refusal", 384, 512, 100, 0.01, 135.0, 80, kind="refusal", error="insufficientAngularCoverage", gap_start=5.0, label="refuse-gap80")
    add("refusal", 512, 512, 120, 0.03, 45.0, 0, kind="throws", error="insufficientSignal", empty=True, label="refuse-empty")
    add("refusal", 512, 512, 120, 0.01, 30.0, 0, kind="refusal", error="modelNotAsymmetricGaussian", neighbour=(1.13, 1.0), label="refuse-conic")
    # DiffractoKit 0.1.0: this plant was registered to be refused for its sigma (sigmaAtAnnulusWidth) and never was; the kit
    # calibrates it (archive: roadmap-registrations-2026-10-15.md "DiffractoKit 0.1.0: the re-pin"), so it is an accepted plant now, gated like a clean ring.
    add("refusal", 512, 512, 120, 0.01, 20.0, 0, kind="accepts", gated=True, background=("r3", 1.0), label="accept-bound")
    add("refusal", 512, 512, 120, 0.01, 60.0, 0, kind="refusal", error="noHighTension", volts=None, label="refuse-noV")
    add("refusal", 512, 512, 120, 0.12, 60.0, 0, kind="refusal", error="excessiveEllipticity", label="refuse-ellipticity")

    # scipy's optimum of the model, the clean tier.
    for case in cases:
        if case["tier"] != "clean":
            continue
        img = np.fromfile(os.path.join(out, case["file"]), dtype="<f4").reshape(case["rows"], case["cols"])
        case["ref"] = scipy_optimum(img, case)

    with open(os.path.join(out, "planted.json"), "w") as f:
        json.dump({"numpy": np.__version__, "scipy": scipy.__version__, "sigma": SIGMA, "margin": MARGIN,
                   "guess": GUESS, "cases": cases}, f, indent=1)
    tiers = {}
    for case in cases:
        tiers[case["tier"]] = tiers.get(case["tier"], 0) + 1
    print("plants: %d cases (%s) in %s" % (len(cases), ", ".join("%s %d" % kv for kv in tiers.items()), out))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(64)
    main(sys.argv[1])
