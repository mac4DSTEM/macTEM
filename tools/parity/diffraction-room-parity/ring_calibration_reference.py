#!/usr/bin/env python3
"""Truth of the retired ring-calibration harness, kept here because reference.py beside it loads it: the closed forms of archive: roadmap-registrations-2026-10-15.md "Diffraction S3, Camera length from one ring of
known d" (slice S3-a: no fit), and the registered refusals as plain thresholds, from the definitions.

    reference.py <out-dir>

Written from the definitions, NOT from DiffractoKit's RingCalibration (nothing of the Swift code is read; the
refusal NAMES below are the Swift enum's, because the harness compares names).

Constants, CODATA 2018 (Tiesinga, Mohr, Newell, Taylor, Rev. Mod. Phys. 93, 025010 (2021); physics.nist.gov/cuu/Constants):
  h  = 6.626 070 15e-34 J s       exact (the SI 2019 definition)
  c  = 299 792 458 m/s            exact
  e  = 1.602 176 634e-19 C        exact
  m0 = 9.109 383 7015(28)e-31 kg  recommended value, relative standard uncertainty 3.0e-10
Stated here once; the harness compares the Swift constants to these as written (check `constants`) and through the wavelength.

The closed forms (the registration's), every length in Å, every angle in rad:
  lambda(V) = h c / sqrt(e V (2 m0 c^2 + e V))                 the relativistic electron wavelength, V in volts
            = h / sqrt(2 m0 e V (1 + e V / (2 m0 c^2)))        the same quantity by de Broglie's form (cross-checked)
  2 theta   = 2 arcsin(lambda / 2d)                            Bragg's law, first order
  L_px      = R / tan(2 theta)                                 the flat detector perpendicular to the beam: R = L tan 2 theta
  dq        = (1/d) / R                                        Å^-1 per pixel, needs no wavelength
  L_mm      = p * L_px                                         p the detector pixel pitch in mm
All of them evaluated in decimal arithmetic (60 digits; arcsin by its power series, tan 2 theta by the algebraic identity
2 s sqrt(1 - s^2) / (1 - 2 s^2) with s = lambda / 2d, so no trigonometric library is trusted) from the exact float64 inputs,
then rounded once to float64. numpy's own arcsin/tan route is computed beside it and must agree to 1e-14 relative.

Cases (320): V in {60, 80, 120, 200, 300} kV; the d of Au {111} {200} {220} {311} {422} (a = 4.0782 Å) and Al {111} {200}
{220} (a = 4.0495 Å), d = a / sqrt(h^2 + k^2 + l^2) for the cubic cell; R in {40, 80, 200, 250} px; p in {0.014, 0.05} mm.
The lattice constants are the ones Diffraction S1 uses and names as the reference until a CIF is pinned (archive: roadmap-registrations-2026-10-15.md V1-8
"S1"; mac4DSTEM's presets, Sources/TEMCore/Crystal/Crystal.swift `gold`, `aluminum`).
A reflection must be fcc-allowed (h, k, l all odd or all even).

Refusals (refusal_table): each registered refusal planted alone, on its own boundary, just inside (accepted) and just outside
(refused), the other inputs clean; plus plants with several faults at once (the whole list, in the order model, coverage,
sigma, residual, ellipticity, high tension) and plants with a number that is not finite and positive (invalidInput: a NaN
passes every comparison). The decision is a plain Python function of the registered thresholds, so the table says what the
registration says and nothing the Swift code says. The Bragg limit (domain_table) is geometric: a flat detector perpendicular
to the beam shows no ring at 2 theta >= 90 degrees, i.e. lambda / 2d >= 1/sqrt(2), decided in decimal arithmetic.

Radius (radius_table): FitReport.radius = (a + b)/2, py4DSTEM's `R = np.mean((a, b))`, on axes planted with 3 % ellipticity
(a/b - 1 = 0.03), the major axis either way, at a minor axis of 40, 80, 100, 200 and 250 px; the expected radius is numpy's mean,
checked against the decimal sum of the two float64 axes. The planted ellipticity lies under the 0.093 cap, so the radius is held
where the arithmetic mean differs from the larger and from the smaller axis by 1.5 %.

Writes manifest.json: {"numpy", "tolerance", "constants": {h_Js, c_ms, e_C, m0_kg, hc_over_e_eV_A, m0c2_over_e_eV}, "wavelengths": [{kv, volts, lambda_A}],
"cases": [{name, d_A, kv, volts, r_px, pitch_mm, lambda_A, two_theta_rad, l_px, dq_per_A_per_px, l_mm}], "refusals": [{name,
check, model, a_px, b_px, occupied_bins, sparse_coverage, residual, inner_sigma, outer_sigma, annulus_width_px, volts,
expect_names, expect_values, withholds_dq}], "radius": [{name, a_px, b_px, radius_px}], "domain": [{name, volts, d_A, r_px,
pitch_mm, inside, lambda_over_2d}]}. A number
that is not finite is written as the string "nan" / "inf" / "-inf"; null means absent.

Before anything counts (exit 1, loudly, otherwise): the three evaluations of lambda agree (decimal, numpy sqrt form, numpy
de Broglie form: 1e-14) and agree with the 3-digit textbook values; numpy's arcsin/tan agree with the decimal chain; Bragg's law
and R = L tan 2 theta close on the expected numbers; the ellipticity cap is derived (the root of the registration's
(2 + e) / (2 sqrt(1 + e)) - 1 = 1e-3 lies just above 0.093); named plants are accepted or refused as their names say, and every
single-fault plant is refused one way only; and every closed-form mutation MOVES its target quantity here (relative change
> 1e-6, against the 1e-12 band): a mutation that moves nothing proves nothing.
"""
import json
import math
import os
import sys
from decimal import Decimal, getcontext

import numpy as np

NUMPY = "2.5.4"
TOL = 1e-12            # the registration's P1: the formula and lambda to 1e-12 relative
getcontext().prec = 60

# CODATA 2018, as exact decimal strings (see the docstring)
H_S, C_S, E_S, M0_S = "6.62607015E-34", "299792458", "1.602176634E-19", "9.1093837015E-31"
H, C, E, M0 = (float(Decimal(s)) for s in (H_S, C_S, E_S, M0_S))
D_H, D_C, D_E, D_M0 = (Decimal(s) for s in (H_S, C_S, E_S, M0_S))
M_TO_A = Decimal(10) ** 10

VOLTAGES_KV = [60, 80, 120, 200, 300]
RADII_PX = [40.0, 80.0, 200.0, 250.0]
PITCHES_MM = [0.014, 0.05]
MATERIALS = [("Au", 4.0782, [(1, 1, 1), (2, 0, 0), (2, 2, 0), (3, 1, 1), (4, 2, 2)]),
             ("Al", 4.0495, [(1, 1, 1), (2, 0, 0), (2, 2, 0)])]

# The registered refusal thresholds (archive: roadmap-registrations-2026-10-15.md "Refused, each by its own error")
ANGULAR_BINS = 36
MIN_BINS = 30            # fewer than 30 of 36 azimuthal bins
RESIDUAL_CAP = 0.22      # mac4DSTEM's cap, inherited
ELLIPTICITY_CAP = 0.093  # a/b - 1; derived in main()
REFERENCE_HT_V = 200000.0
NAN, INF = float("nan"), float("inf")

# the refusal names (the Swift enum's `name`) and the check each is held under (the registration's mutation names)
CHECK_OF = {"accepted": "accept", "modelNotAsymmetricGaussian": "refuse-conic", "insufficientAngularCoverage": "refuse-bins",
            "sparseCoverage": "refuse-gap", "sigmaAtAnnulusWidth": "refuse-bound", "excessiveResidual": "refuse-residual",
            "excessiveEllipticity": "refuse-ellipticity", "noHighTension": "refuse-noV", "invalidInput": "refuse-invalid",
            "several": "refuse-several"}

# mutation -> (check, target case, quantity); the Swift side implements the same mutations, run.sh names the same targets
TARGET_CASE = "Au422-80kV-R200-p0.014"
MUTATIONS = {
    "q-two-over-d": ("formula", TARGET_CASE, "dq"),
    "a-for-nm": ("formula", TARGET_CASE, "dq"),
    "small-angle": ("formula", TARGET_CASE, "l_px"),
    "pitch-um": ("formula", TARGET_CASE, "l_mm"),
    "non-relativistic": ("wavelength", "lambda-80kV", "lambda"),
    "kv-as-v": ("wavelength", "lambda-80kV", "lambda"),
    "v-default": ("refuse-noV", "noV-missing", "refusal"),
    "radius-a": ("radius", "ellipse-3pct-minor100-a-major", "radius"),
}
RADIUS_PLANT_ELLIPTICITY = 0.03      # a/b - 1 of the planted axes
RADIUS_PLANT_MINOR_PX = [40.0, 80.0, 100.0, 200.0, 250.0]


def fail(msg):
    print("reference.py: FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


# ---- decimal closed forms ------------------------------------------------------------------------------------------

def dec_wavelength_a(volts):
    ev = D_E * Decimal(volts)
    return D_H * D_C / (ev * (2 * D_M0 * D_C * D_C + ev)).sqrt() * M_TO_A


def dec_arcsin(x):
    """arcsin x = sum (2n)! / (4^n (n!)^2 (2n+1)) x^(2n+1); |x| < 0.05 here, 60 terms are far beyond 60 digits."""
    total, term, x2 = Decimal(0), x, x * x
    for n in range(60):
        total += term / (2 * n + 1)
        term = term * x2 * (2 * n + 1) / (2 * n + 2)
    return total


def dec_chain(volts, d, r, p):
    """lambda, 2 theta, L_px, dq, L_mm from exact float64 inputs, in 60-digit decimal."""
    lam = dec_wavelength_a(volts)
    s = lam / (2 * Decimal(d))
    if not (Decimal(0) < s < Decimal("0.5")):
        fail("sin(theta) = %s out of range for the closed form (V=%s, d=%s)" % (s, volts, d))
    two_theta = 2 * dec_arcsin(s)
    tan_2t = 2 * s * (1 - s * s).sqrt() / (1 - 2 * s * s)
    l_px = Decimal(r) / tan_2t
    dq = (1 / Decimal(d)) / Decimal(r)
    l_mm = Decimal(p) * l_px
    return lam, two_theta, l_px, dq, l_mm


# ---- numpy closed forms (the second route) -------------------------------------------------------------------------

def np_wavelength_a(volts):
    ev = E * volts
    return H * C / math.sqrt(ev * (2 * M0 * C * C + ev)) * 1e10


def np_wavelength_debroglie_a(volts):
    ev = E * volts
    return H / math.sqrt(2 * M0 * ev * (1 + ev / (2 * M0 * C * C))) * 1e10


def np_chain(volts, d, r, p):
    lam = np_wavelength_a(volts)
    two_theta = 2 * float(np.arcsin(lam / (2 * d)))
    l_px = r / float(np.tan(two_theta))
    return lam, two_theta, l_px, (1 / d) / r, p * l_px


def rel(a, b):
    return abs(a - b) / abs(b)


# ---- mutations, emulated in numpy (what the broken code would return) ----------------------------------------------

def mutated(mut, volts, d, r, p, lam, l_px):
    if mut == "q-two-over-d":
        return {"dq": (2 / d) / r}
    if mut == "a-for-nm":          # d in Å read as nm: 1 / (d / 10), reported as Å^-1
        return {"dq": (1 / (d / 10)) / r}
    if mut == "small-angle":       # lambda L = R d
        return {"l_px": r * d / lam}
    if mut == "pitch-um":          # the pitch in µm read as mm
        return {"l_mm": (p * 1000) * l_px}
    if mut == "non-relativistic":  # lambda = h / sqrt(2 m0 e V)
        return {"lambda": H / math.sqrt(2 * M0 * E * volts) * 1e10}
    if mut == "kv-as-v":           # the kV number read as volts
        return {"lambda": np_wavelength_a(volts / 1000)}
    raise KeyError(mut)


# ---- the refusal decision, from the registered thresholds ----------------------------------------------------------

def finite_positive(x):
    return math.isfinite(x) and x > 0


def decide(c):
    """The ordered list of (name, value) the registration's thresholds give: model, coverage, sigma, residual, ellipticity,
    high tension. `value` is the number the refusal reports (bins, widest sigma, residual, a/b - 1), None where it has none.
    A number that is not finite and positive, or a bin count out of range, is invalidInput alone."""
    sigmas = [s for s in (c["inner_sigma"], c["outer_sigma"]) if s is not None]
    valid = (finite_positive(c["a_px"]) and finite_positive(c["b_px"]) and 0 <= c["occupied_bins"] <= ANGULAR_BINS
             and math.isfinite(c["residual"]) and c["residual"] >= 0 and all(finite_positive(s) for s in sigmas)
             and finite_positive(c["annulus_width_px"]) and (c["volts"] is None or finite_positive(c["volts"])))
    if not valid:
        return [("invalidInput", None)]
    out = []
    if c["model"] != "asymmetricGaussian":
        out.append(("modelNotAsymmetricGaussian", None))
    if c["occupied_bins"] < MIN_BINS or c["sparse_coverage"]:
        out.append(("insufficientAngularCoverage", float(c["occupied_bins"])))
    if sigmas and max(sigmas) >= c["annulus_width_px"]:
        out.append(("sigmaAtAnnulusWidth", max(sigmas)))
    if c["residual"] > RESIDUAL_CAP:
        out.append(("excessiveResidual", c["residual"]))
    ell = max(c["a_px"], c["b_px"]) / min(c["a_px"], c["b_px"]) - 1
    if ell > ELLIPTICITY_CAP:
        out.append(("excessiveEllipticity", ell))
    if c["volts"] is None:
        out.append(("noHighTension", None))
    return out


def refusal_table():
    base = {"model": "asymmetricGaussian", "occupied_bins": ANGULAR_BINS, "sparse_coverage": False, "inner_sigma": 3.0,
            "outer_sigma": 3.0, "annulus_width_px": 40.0, "residual": 0.05, "a_px": 120.3, "b_px": 120.0,
            "volts": REFERENCE_HT_V}
    table, eps = [], 1e-9

    def add(name, group, **kw):
        c = dict(base, name=name, **kw)
        found = decide(c)
        c["group"] = group
        c["check"] = CHECK_OF[group]
        c["expect_names"] = [n for n, _ in found]
        c["expect_values"] = [v for _, v in found]
        c["withholds_dq"] = any(n not in ("noHighTension", "braggLimit") for n, _ in found)
        table.append(c)

    add("accept-clean", "accepted")
    add("model-asymmetricGaussian", "modelNotAsymmetricGaussian")
    add("model-conic", "modelNotAsymmetricGaussian", model="conic", inner_sigma=None, outer_sigma=None)
    add("model-conic-with-sigmas", "modelNotAsymmetricGaussian", model="conic")
    for bins in (36, 31, 30):
        add("bins-%d-inside" % bins, "insufficientAngularCoverage", occupied_bins=bins)
    for bins in (29, 12, 0):
        add("bins-%d-outside" % bins, "insufficientAngularCoverage", occupied_bins=bins)
    add("gap-clear", "sparseCoverage", sparse_coverage=False)
    add("gap-flagged", "sparseCoverage", sparse_coverage=True)                       # reported as the coverage refusal
    add("gap-flagged-30-bins", "sparseCoverage", sparse_coverage=True, occupied_bins=30)
    w = base["annulus_width_px"]
    for side, key in (("inner", "inner_sigma"), ("outer", "outer_sigma")):
        add("bound-%s-below-ulp" % side, "sigmaAtAnnulusWidth", **{key: float(np.nextafter(w, 0))})
        add("bound-%s-below-1e-9" % side, "sigmaAtAnnulusWidth", **{key: w * (1 - eps)})
        add("bound-%s-at" % side, "sigmaAtAnnulusWidth", **{key: w})
        add("bound-%s-above-ulp" % side, "sigmaAtAnnulusWidth", **{key: float(np.nextafter(w, 1e9))})
        add("bound-%s-above-1e-9" % side, "sigmaAtAnnulusWidth", **{key: w * (1 + eps)})
    add("bound-inner-243", "sigmaAtAnnulusWidth", inner_sigma=243.0)         # the study's 1/r^3-background plant sits at its sigma bound
    add("bound-both-at", "sigmaAtAnnulusWidth", inner_sigma=w, outer_sigma=w)
    add("bound-larger-of-two", "sigmaAtAnnulusWidth", inner_sigma=w * (1 - eps), outer_sigma=w * (1 + eps))
    add("residual-at-cap", "excessiveResidual", residual=RESIDUAL_CAP)
    add("residual-below-1e-9", "excessiveResidual", residual=RESIDUAL_CAP - eps)
    add("residual-above-ulp", "excessiveResidual", residual=float(np.nextafter(RESIDUAL_CAP, 1.0)))
    add("residual-above-1e-9", "excessiveResidual", residual=RESIDUAL_CAP + eps)
    add("residual-0.336", "excessiveResidual", residual=0.336)                       # mac4DSTEM's largest conic-fallback residual
    add("residual-zero", "excessiveResidual", residual=0.0)
    for tag, ell in (("below-1e-9", ELLIPTICITY_CAP - eps), ("above-1e-9", ELLIPTICITY_CAP + eps),
                     ("below-1e-6", ELLIPTICITY_CAP - 1e-6), ("above-1e-6", ELLIPTICITY_CAP + 1e-6), ("0.2", 0.2)):
        add("ellipticity-a-major-" + tag, "excessiveEllipticity", a_px=100.0 * (1 + ell), b_px=100.0)
        add("ellipticity-b-major-" + tag, "excessiveEllipticity", a_px=100.0, b_px=100.0 * (1 + ell))
    add("ellipticity-circle", "excessiveEllipticity", a_px=100.0, b_px=100.0)
    add("noV-missing", "noHighTension", volts=None)
    add("noV-present", "noHighTension", volts=REFERENCE_HT_V)
    # several at once: the list holds every refusal that applies, in the documented order
    add("all-six", "several", model="conic", occupied_bins=12, sparse_coverage=True, inner_sigma=50.0, outer_sigma=3.0,
        residual=0.3, a_px=130.0, b_px=100.0, volts=None)
    add("sigma-residual-ellipticity", "several", inner_sigma=3.0, outer_sigma=41.0, residual=0.25, a_px=100.0, b_px=112.0)
    add("coverage-by-bins-and-flag", "several", occupied_bins=12, sparse_coverage=True)     # one entry, not two
    add("model-and-noV", "several", model="conic", inner_sigma=None, outer_sigma=None, volts=None)
    # a number that is not finite and positive is the caller's mistake, never data: invalidInput alone
    for tag, kw in (("residual-nan", {"residual": NAN}), ("residual-negative", {"residual": -0.1}), ("residual-inf", {"residual": INF}),
                    ("a-zero", {"a_px": 0.0}), ("b-negative", {"b_px": -1.0}), ("a-inf", {"a_px": INF}), ("b-nan", {"b_px": NAN}),
                    ("bins-37", {"occupied_bins": 37}), ("bins-negative", {"occupied_bins": -1}),
                    ("inner-nan", {"inner_sigma": NAN}), ("outer-zero", {"outer_sigma": 0.0}), ("inner-negative", {"inner_sigma": -3.0}),
                    ("width-zero", {"annulus_width_px": 0.0}), ("width-nan", {"annulus_width_px": NAN}),
                    ("volts-nan", {"volts": NAN}), ("volts-zero", {"volts": 0.0}), ("volts-negative", {"volts": -200000.0}),
                    ("volts-inf", {"volts": INF}), ("beats-conic", {"model": "conic", "residual": NAN})):
        add("invalid-" + tag, "invalidInput", **kw)
    return table


def radius_table():
    """FitReport.radius = (a + b)/2 on planted axes with 3 % ellipticity: b the minor axis, a = b (1 + 0.03), and the same two
    with the axes swapped. The expected radius is numpy's mean of the two float64 axes (`np.mean((a, b))`, py4DSTEM's
    convention), checked against the decimal sum of the same two numbers. Each plant is below the ellipticity cap, so the
    refusal decision accepts it, and the mean differs from the larger and from the smaller axis by 1.5 %."""
    out = []
    for minor in RADIUS_PLANT_MINOR_PX:
        major = minor * (1 + RADIUS_PLANT_ELLIPTICITY)
        for tag, (a, b) in (("a-major", (major, minor)), ("b-major", (minor, major))):
            mean = float(np.mean((a, b)))
            exact = float((Decimal(a) + Decimal(b)) / 2)
            ellipticity = max(a, b) / min(a, b) - 1
            if rel(mean, exact) > 1e-15:
                fail("radius plant minor axis %g %s: numpy mean %r, decimal %r" % (minor, tag, mean, exact))
            if abs(ellipticity - RADIUS_PLANT_ELLIPTICITY) > 1e-13:
                fail("radius plant minor axis %g %s: ellipticity %r, planted %g" % (minor, tag, ellipticity, RADIUS_PLANT_ELLIPTICITY))
            if not (ellipticity < ELLIPTICITY_CAP) or min(rel(mean, a), rel(mean, b)) < 0.01:
                fail("radius plant minor axis %g %s: the mean is not distinct from both axes, or the plant is over the cap" % (minor, tag))
            out.append({"name": "ellipse-3pct-minor%g-%s" % (minor, tag), "a_px": a, "b_px": b, "radius_px": mean})
    return out


def domain_table():
    """The Bragg limit: no ring at 2 theta >= 90 degrees on a flat detector, i.e. lambda / 2d >= 1/sqrt(2). d_edge = lambda / sqrt(2)."""
    out, edge_ratio = [], Decimal("0.5").sqrt()
    for kv in (60, 200, 300):
        volts = kv * 1000.0
        lam = dec_wavelength_a(volts)
        d_edge = lam / (2 * edge_ratio)
        for tag, factor, inside in (("inside-1e-9", 1 + Decimal("1e-9"), True), ("outside-1e-9", 1 - Decimal("1e-9"), False),
                                    ("inside-1e-6", 1 + Decimal("1e-6"), True), ("outside-1e-6", 1 - Decimal("1e-6"), False),
                                    ("inside-2x", Decimal(2), True), ("outside-half", Decimal("0.5"), False)):
            d = float(d_edge * factor)
            s = lam / (2 * Decimal(d))
            if (s < edge_ratio) != inside:
                fail("domain plant %s at %d kV is on the wrong side of lambda/2d = 1/sqrt(2) (%s)" % (tag, kv, s))
            out.append({"name": "bragg-%dkV-%s" % (kv, tag), "volts": volts, "d_A": d, "r_px": 100.0, "pitch_mm": 0.014,
                        "inside": inside, "lambda_over_2d": float(s)})
    return out


def jsonable(x):
    if isinstance(x, float) and not math.isfinite(x):
        return "nan" if math.isnan(x) else ("inf" if x > 0 else "-inf")
    if isinstance(x, dict):
        return {k: jsonable(v) for k, v in x.items()}
    if isinstance(x, list):
        return [jsonable(v) for v in x]
    return x


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    if np.__version__ != NUMPY:
        fail("numpy %s, the lock pins %s" % (np.__version__, NUMPY))

    # ---- wavelengths ----
    textbook = {100: 0.0370, 120: 0.0335, 200: 0.0251, 300: 0.0197}   # Å, the usual 3-digit tabulation (Williams and Carter, TEM)
    waves = []
    for kv in sorted(set(VOLTAGES_KV) | set(textbook)):
        volts = kv * 1000.0
        dec = dec_wavelength_a(volts)
        a, b = np_wavelength_a(volts), np_wavelength_debroglie_a(volts)
        if rel(a, float(dec)) > 1e-14 or rel(b, float(dec)) > 1e-14:
            fail("lambda(%g kV): decimal %s, numpy %r, de Broglie form %r" % (kv, dec, a, b))
        if kv in textbook and abs(float(dec) - textbook[kv]) > 0.00005:
            fail("lambda(%g kV) = %.6f Å, the 3-digit textbook value is %.4f" % (kv, float(dec), textbook[kv]))
        if kv in VOLTAGES_KV:
            waves.append({"kv": kv, "volts": volts, "lambda_A": float(dec)})
    print("reference: lambda (Å) " + ", ".join("%g kV %.8f" % (w["kv"], w["lambda_A"]) for w in waves))

    # ---- the derived ellipticity cap ----
    def mean_gap(eps):     # (a + b)/2 over sqrt(ab) - 1 at b = 1, a = 1 + eps
        return (2 + eps) / (2 * math.sqrt(1 + eps)) - 1
    if not (mean_gap(ELLIPTICITY_CAP) < 1e-3 < mean_gap(ELLIPTICITY_CAP + 1e-3)):
        fail("the ellipticity cap %g is not the registered derivation's: the arithmetic and geometric mean radii differ by "
             "%.3g at the cap and %.3g at +0.001" % (ELLIPTICITY_CAP, mean_gap(ELLIPTICITY_CAP), mean_gap(ELLIPTICITY_CAP + 1e-3)))
    lo, hi = 0.0, 0.5
    for _ in range(80):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if mean_gap(mid) < 1e-3 else (lo, mid)
    print("reference: (a+b)/2 and sqrt(ab) differ by 0.1 %% at a/b - 1 = %.5f; the registered cap is %g" % (lo, ELLIPTICITY_CAP))

    # ---- cases ----
    cases, worst = [], {"lambda": 0.0, "two_theta": 0.0, "l_px": 0.0, "dq": 0.0, "l_mm": 0.0}
    for material, a_cell, hkls in MATERIALS:
        for (h, k, l) in hkls:
            if len({h % 2, k % 2, l % 2}) != 1:
                fail("%s {%d%d%d} is not fcc-allowed" % (material, h, k, l))
            n = h * h + k * k + l * l
            d = float(Decimal(str(a_cell)) / Decimal(n).sqrt())
            if rel(d, a_cell / math.sqrt(n)) > 1e-15:
                fail("d of %s {%d%d%d}: %r" % (material, h, k, l, d))
            for kv in VOLTAGES_KV:
                for r in RADII_PX:
                    for p in PITCHES_MM:
                        volts = kv * 1000.0
                        dec = dec_chain(volts, d, r, p)
                        npy = np_chain(volts, d, r, p)
                        expected = [float(x) for x in dec]
                        for key, x, y in zip(worst, npy, expected):
                            err = rel(x, y)
                            worst[key] = max(worst[key], err)
                            if err > 1e-14:
                                fail("%s {%d%d%d} %g kV R %g p %g: numpy %s %r vs decimal %r (%.2e)" % (material, h, k, l, kv, r, p, key, x, y, err))
                        # physical sanity: Bragg's law and the detector geometry recovered from the expected numbers
                        if rel(2 * d * math.sin(expected[1] / 2), expected[0]) > 1e-13 or rel(expected[2] * math.tan(expected[1]), r) > 1e-13:
                            fail("%s {%d%d%d} %g kV: the expected values do not close Bragg's law / R = L tan 2 theta" % (material, h, k, l, kv))
                        cases.append({"name": "%s%d%d%d-%dkV-R%g-p%g" % (material, h, k, l, kv, r, p), "d_A": d, "kv": kv,
                                      "volts": volts, "r_px": r, "pitch_mm": p, "lambda_A": expected[0],
                                      "two_theta_rad": expected[1], "l_px": expected[2], "dq_per_A_per_px": expected[3],
                                      "l_mm": expected[4]})
    if len(cases) != 320 or len({c["name"] for c in cases}) != 320:
        fail("%d cases, expected 320 distinct" % len(cases))
    print("reference: %d cases; numpy arcsin/tan route against the decimal chain, worst relative: " % len(cases)
          + ", ".join("%s %.1e" % (k, v) for k, v in worst.items()))
    print("reference: L_px spans %.1f to %.4g (L_mm %.3g to %.3g)" % (min(c["l_px"] for c in cases), max(c["l_px"] for c in cases),
                                                                     min(c["l_mm"] for c in cases), max(c["l_mm"] for c in cases)))

    # ---- refusals ----
    table = refusal_table()
    if len({c["name"] for c in table}) != len(table):
        fail("duplicate refusal plant names")
    if table[0]["expect_names"] != []:
        fail("the clean base plant is refused: %s" % table[0]["expect_names"])
    # Plants named for a side of a boundary are on that side (a mistake in the table would otherwise pass as truth).
    must_accept = ("model-asymmetricGaussian", "bins-36-inside", "bins-31-inside", "bins-30-inside", "gap-clear",
                   "bound-inner-below-ulp", "bound-inner-below-1e-9", "bound-outer-below-ulp", "bound-outer-below-1e-9",
                   "residual-at-cap", "residual-below-1e-9", "residual-zero", "ellipticity-a-major-below-1e-9",
                   "ellipticity-b-major-below-1e-9", "ellipticity-a-major-below-1e-6", "ellipticity-b-major-below-1e-6",
                   "ellipticity-circle", "noV-present")
    must_refuse_once = ("model-conic", "model-conic-with-sigmas", "bins-29-outside", "bins-12-outside", "bins-0-outside",
                        "gap-flagged", "gap-flagged-30-bins", "bound-inner-at", "bound-outer-at", "bound-inner-above-ulp",
                        "bound-outer-above-ulp", "bound-inner-above-1e-9", "bound-outer-above-1e-9", "bound-inner-243",
                        "bound-both-at", "bound-larger-of-two", "residual-above-ulp", "residual-above-1e-9", "residual-0.336",
                        "ellipticity-a-major-above-1e-9", "ellipticity-b-major-above-1e-9", "ellipticity-a-major-above-1e-6",
                        "ellipticity-b-major-above-1e-6", "ellipticity-a-major-0.2", "ellipticity-b-major-0.2", "noV-missing")
    by_plant = {c["name"]: c for c in table}
    for name in must_accept:
        if by_plant[name]["expect_names"] != []:
            fail("%s must be accepted, got %s" % (name, by_plant[name]["expect_names"]))
    for name in must_refuse_once:
        if len(by_plant[name]["expect_names"]) != 1:
            fail("%s must be refused one way only, got %s" % (name, by_plant[name]["expect_names"]))
    for c in table:
        if c["name"] == "residual-zero" or c["group"] in ("several", "invalidInput", "accepted"):
            continue
        if len(c["expect_names"]) > 1:
            fail("%s: a single-fault plant is refused %d ways: %s" % (c["name"], len(c["expect_names"]), c["expect_names"]))
    for g in ("modelNotAsymmetricGaussian", "insufficientAngularCoverage", "sparseCoverage", "sigmaAtAnnulusWidth",
              "excessiveResidual", "excessiveEllipticity", "noHighTension"):
        members = [c for c in table if c["group"] == g]
        if not any(c["expect_names"] for c in members) or not any(not c["expect_names"] for c in members):
            fail("refusal %s must be planted both refused and accepted" % g)
    if by_plant["all-six"]["expect_names"] != ["modelNotAsymmetricGaussian", "insufficientAngularCoverage", "sigmaAtAnnulusWidth",
                                               "excessiveResidual", "excessiveEllipticity", "noHighTension"]:
        fail("all-six does not hold six refusals: %s" % by_plant["all-six"]["expect_names"])
    if by_plant["coverage-by-bins-and-flag"]["expect_names"] != ["insufficientAngularCoverage"]:
        fail("bins and the flag together must be one coverage refusal")
    n_refused = sum(1 for c in table if c["expect_names"])
    print("reference: %d refusal plants (%d refused, %d accepted); several at once: %d, invalidInput: %d"
          % (len(table), n_refused, len(table) - n_refused, sum(c["group"] == "several" for c in table),
             sum(c["group"] == "invalidInput" for c in table)))
    radii = radius_table()
    if len({r["name"] for r in radii}) != len(radii):
        fail("duplicate radius plant names")
    print("reference: %d radius plants (a/b - 1 = %g, the major axis either way; R = np.mean((a, b)))" % (len(radii), RADIUS_PLANT_ELLIPTICITY))
    domain = domain_table()
    print("reference: %d Bragg-limit plants (lambda/2d = 1/sqrt(2); 60 / 200 / 300 kV; both sides at 1e-9, 1e-6 and a factor 2)" % len(domain))

    # ---- every mutation moves its target ----
    by_name = {c["name"]: c for c in cases}
    for mut, (check, target, qty) in MUTATIONS.items():
        if check == "refuse-noV":
            c = by_plant[target]
            moved = decide(dict(c, volts=REFERENCE_HT_V))
            ok = c["expect_names"] == ["noHighTension"] and moved == []
            what = "refused as %s without V, accepted with V defaulted" % c["expect_names"]
        elif check == "radius":
            c = next((x for x in radii if x["name"] == target), None)
            if c is None:
                fail("mutation %s targets a plant that does not exist: %s" % (mut, target))
            moved = rel(c["a_px"], c["radius_px"])      # radius = a
            ok = moved > 1e-6
            what = "radius moves %.3g relative" % moved
        elif check == "wavelength":
            kv = int(target.split("-")[1][:-2])
            c = next(x for x in cases if x["kv"] == kv)
            m = mutated(mut, c["volts"], c["d_A"], c["r_px"], c["pitch_mm"], c["lambda_A"], c["l_px"])[qty]
            moved = rel(m, c["lambda_A"])
            ok = moved > 1e-6
            what = "lambda moves %.3g relative" % moved
        else:
            c = by_name.get(target)
            if c is None:
                fail("mutation %s targets a case that does not exist: %s" % (mut, target))
            m = mutated(mut, c["volts"], c["d_A"], c["r_px"], c["pitch_mm"], c["lambda_A"], c["l_px"])[qty]
            truth = {"dq": c["dq_per_A_per_px"], "l_px": c["l_px"], "l_mm": c["l_mm"]}[qty]
            moved = rel(m, truth)
            ok = moved > 1e-6
            what = "%s moves %.3g relative" % (qty, moved)
        print("reference: mutation %-17s -> %-22s %-10s %s" % (mut, target, check, what))
        if not ok:
            fail("mutation %s does not move its target %s %s enough (%s)" % (mut, target, check, what))
    # the small-angle error the registration quotes, as a printed fact
    for name in ("Au111-200kV-R200-p0.014", "Au422-80kV-R200-p0.014"):
        c = by_name[name]
        print("reference: small-angle L = R d / lambda is off by %.2e at %s (registration: 4e-5 at 200 kV {111}, 9.5e-4 at 80 kV {422})"
              % (rel(c["r_px"] * c["d_A"] / c["lambda_A"], c["l_px"]), name))

    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(jsonable({"numpy": np.__version__, "tolerance": TOL,
                            "constants": {"h_Js": H, "c_ms": C, "e_C": E, "m0_kg": M0, "source": "CODATA 2018",
                                          "hc_over_e_eV_A": float(D_H * D_C / D_E * M_TO_A),
                                          "m0c2_over_e_eV": float(D_M0 * D_C * D_C / D_E)},
                            "wavelengths": waves, "cases": cases, "refusals": table, "radius": radii, "domain": domain}), f, indent=1)
    print("reference: %d cases, %d wavelengths, %d refusal plants, %d radius plants, %d Bragg plants in %s"
          % (len(cases), len(waves), len(table), len(radii), len(domain), out))


if __name__ == "__main__":
    main()
