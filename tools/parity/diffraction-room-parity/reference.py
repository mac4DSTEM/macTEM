#!/usr/bin/env python3
"""Truth for tools/parity/diffraction-room-parity (archive: roadmap-registrations-2026-10-15.md "Diffraction room, slice 1a: the core and tools/parity/diffraction-room-parity",
clauses R1, R3, R4, R5, R6, R7, R9): closed forms and tables from the definitions, in 60-digit decimal arithmetic where a
closed form is the quantity, numpy where a list is.

    reference.py <scattering_factors.txt> <out-dir> [--plants <plants-out-dir>] [--cif-dir <dir>]...
    reference.py --distance-check <in.json> <out.json>

Written from the definitions, NOT from any Swift. The one Swift file read is the kit's LengthUnit (ImagoCore/UnitConversion.swift),
only to list the unit SPELLINGS R5 must cover (the factors below are 1/nm -> 0.1, 1/A -> 1, mrad -> 1/(1000 lambda), stated
by the registration). Constants are CODATA 2018 exactly as tools/parity/ring-calibration-parity/reference.py states them (checked
equal to that file's decimal chain in the self-check). numpy 2.5.4 from tools/lib/references-lock.txt; run it with the
lock's interpreter and `-I`.

WRITES <out-dir>/reference.json (every float as %.17g, the round-trip-exact decimal; NaN / Infinity as strings), and
<out-dir>/r9/*.cif (the planted CIF byte files R9 needs). Sections:
  r3  "320 cases": ring-calibration-parity's cases (V 60-300 kV, Au {111} {200} {220} {311} {422} and Al {111} {200} {220}, R 40-250,
      p 0.014 / 0.05): lambda, L_px (float64 inputs, written), and per case the queries R in {40, 100, 250, 500, 1000, 2000} and R_cal:
        q(R) = 2 sin(1/2 atan(R / L_px)) / lambda       (decimal: sin(1/2 atan x) = sqrt((1 - 1/sqrt(1 + x^2)) / 2), no trig library)
        R(q) = L_px tan(2 asin(lambda q / 2))           (decimal: 2 s sqrt(1 - s^2) / (1 - 2 s^2), s = lambda q / 2), evaluated at the
                                                       float64 q written, so the round trip R -> q -> R is a property of the pair
        linear = dq * R (one IEEE multiply: the Swift product equals it bit for bit today; D12 would allow a written tolerance)
      Evaluated FROM the written float64 inputs: the Swift side feeds lambda and L_px as read from this file, so a band of 1e-12
      relative compares the function, not two roundings of the inputs. inv_d = 1/d: q(R_cal) must equal it to 1e-12.
      "invalid": inputs that are not finite and positive (R = 0 included): the answer is NaN.
  r4  "radii": R(g) for every 320 case and each family of its material (g = 1/d): the same closed form; "ellipses": with --plants, the
      scaled ellipse of every R4 plant: ring 1's b/a and theta, both axes times R(g2)/R1 (R1 = (a + b)/2), same centre.
  r5  "spellings", "rejects", "invalid_values", "fit_vs_file": the file's reciprocal scale in A^-1/px for every spelling
      (each base spelling and its case, space, decomposed-accent and padded variants), mrad with and without lambda, and
      the fit-vs-file difference dq_fit / dq_file - 1 (decimal, from the float64 pair).
  r6  "t1", "t4": indexing-parity's T1 rule on Au, Al, Si at k_max 1.2 and 2.0 (u 1e-3, 3e-3, 1e-2; s in -2.9..2.9; k = 3): per plant
      the verdict name, best / next family index, z, delta = g/q - 1 (and %), |dd|/d, margin, odds = exp(margin), sigma_q = q * tol / 100,
      and a T4 set (the refusals and edge lists).
  r7  "standards": Au 4.0782, Al 4.0495, Si 5.4309 (and Mg, Cu3Au-occ as extra controls) families at k_max 1.2 and 2.0: g, d (by
      the definition and by the closed form), multiplicity, name, family and reflection counts.
  r9  "files": SHA-256 of every CIF in --cif-dir and of the planted files in r9/.
  ellipse_distance_vectors: points and their exact distance to an ellipse (the R1 polyline check's own test).
  mutation_moves: for each registered mutation of R3-R7, the largest change it makes to the quantity it targets (> 1e-6 or
      the script exits 1: a mutation that moves nothing proves nothing).
The self-check (exit 1 when any fails) also holds the hand values: Au {111} d = 4.0782 / sqrt(3) = 2.3545498678091317, lambda at
200 kV equal to ring-calibration-parity's, and R -> q -> R.
"""
import hashlib
import importlib.util
import itertools
import json
import math
import os
import sys
import unicodedata
from collections import Counter, defaultdict
from decimal import Decimal, getcontext

import numpy as np

getcontext().prec = 60
HERE = os.path.dirname(os.path.abspath(__file__))
NUMPY = "2.5.4"
TABLE_SHA256 = "be845d1d541cdb75ae16f8928cd9e56a9ea38af8a3cc43da9137e73cc72bb6f4"
FAILURES = []

# CODATA 2018 (ring-calibration-parity/reference.py states them; compared there and in the self-check)
H_S, C_S, E_S, M0_S = "6.62607015E-34", "299792458", "1.602176634E-19", "9.1093837015E-31"
D_H, D_C, D_E, D_M0 = (Decimal(s) for s in (H_S, C_S, E_S, M0_S))
M_TO_A = Decimal(10) ** 10

VOLTAGES_KV = (60, 80, 120, 200, 300)
CAL_RADII_PX = (40.0, 80.0, 200.0, 250.0)
PITCHES_MM = (0.014, 0.05)
MATERIALS = (("Au", 4.0782, ((1, 1, 1), (2, 0, 0), (2, 2, 0), (3, 1, 1), (4, 2, 2))),
             ("Al", 4.0495, ((1, 1, 1), (2, 0, 0), (2, 2, 0))))
QUERY_RADII_PX = (40.0, 100.0, 250.0, 500.0, 1000.0, 2000.0)
K_SIGMA = 3.0
LN19 = math.log(19.0)
CUT = 1e-4
GROUP_TOL = 1e-9
S1 = (-2.9, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 2.9)
U1 = (1e-3, 3e-3, 1e-2)
TOL_PCT = {1e-3: 0.1, 3e-3: 0.3, 1e-2: 1.0}          # the user's stated total 1-sigma tolerance in %, as it is typed
KMAXES = (1.2, 2.0)
MAX_CIF_BYTES = 5 * 1024 * 1024


def fail(msg):
    FAILURES.append(msg)
    print("  SELF-CHECK FAILED: " + msg, flush=True)


def check(cond, msg):
    if not cond:
        fail(msg)
    return bool(cond)


# ------------------------------------------------------------------------------------------------------- JSON, %.17g
def jfloat(x):
    x = float(x)
    if math.isnan(x):
        return '"NaN"'
    if math.isinf(x):
        return '"Infinity"' if x > 0 else '"-Infinity"'
    return "%.17g" % x


def dumps(o, indent=0):
    pad = "  " * indent
    if isinstance(o, dict):
        if not o:
            return "{}"
        return "{\n" + ",\n".join("%s  %s: %s" % (pad, json.dumps(str(k)), dumps(v, indent + 1)) for k, v in o.items()) + "\n" + pad + "}"
    if isinstance(o, (list, tuple)):
        if not o:
            return "[]"
        if all(isinstance(v, (int, float, np.floating, np.integer)) and not isinstance(v, bool) for v in o):
            return "[" + ", ".join(dumps(v) for v in o) + "]"
        return "[\n" + ",\n".join(pad + "  " + dumps(v, indent + 1) for v in o) + "\n" + pad + "]"
    if isinstance(o, (bool, np.bool_)):
        return "true" if o else "false"
    if isinstance(o, np.integer) or (isinstance(o, int) and not isinstance(o, bool)):
        return str(int(o))
    if isinstance(o, (float, np.floating)):
        return jfloat(o)
    if o is None:
        return "null"
    return json.dumps(o)


# ------------------------------------------------------------------------------------------------- decimal closed forms
def D(x):
    return Decimal(x)          # of a float64: exact


def dec_wavelength_a(volts):
    ev = D_E * D(volts)
    return D_H * D_C / (ev * (2 * D_M0 * D_C * D_C + ev)).sqrt() * M_TO_A


def dec_q(r, l_px, lam):
    """|q| = 2 sin(1/2 atan(R / L)) / lambda; sin(1/2 atan x) = sqrt((1 - cos atan x) / 2), cos atan x = 1 / sqrt(1 + x^2)."""
    x = D(r) / D(l_px)
    c = 1 / (1 + x * x).sqrt()
    return 2 * ((1 - c) / 2).sqrt() / D(lam)


def dec_r(q, l_px, lam):
    """R = L tan(2 asin s), s = lambda q / 2; tan(2 asin s) = 2 s sqrt(1 - s^2) / (1 - 2 s^2)."""
    s = D(lam) * D(q) / 2
    return D(l_px) * 2 * s * (1 - s * s).sqrt() / (1 - 2 * s * s)


def dec_arcsin(x):
    total, term, x2 = Decimal(0), x, x * x
    for n in range(80):
        total += term / (2 * n + 1)
        term = term * x2 * (2 * n + 1) / (2 * n + 2)
    return total


def dec_l_px(volts, d, r):
    """L_px = R / tan(2 theta), sin theta = lambda / 2d (the registered exact form of ring-calibration-parity)."""
    lam = dec_wavelength_a(volts)
    s = lam / (2 * D(d))
    return D(r) * (1 - 2 * s * s) / (2 * s * (1 - s * s).sqrt()), lam, 2 * dec_arcsin(s)


def np_q(r, l_px, lam):
    return 2.0 * math.sin(0.5 * math.atan(r / l_px)) / lam


def np_r(q, l_px, lam):
    return l_px * math.tan(2.0 * math.asin(lam * q / 2.0))


def rel(a, b):
    return abs(a - b) / abs(b) if b != 0 else abs(a - b)


# ----------------------------------------------------------------------------------------------------------------- R3
def make_r3():
    cases = []
    worst = {"q": 0.0, "r": 0.0}
    for material, a_cell, hkls in MATERIALS:
        for (h, k, l) in hkls:
            n = h * h + k * k + l * l
            d = float(Decimal(str(a_cell)) / Decimal(n).sqrt())
            inv_d = float(1 / Decimal(d))
            for kv in VOLTAGES_KV:
                volts = kv * 1000.0
                for r_cal in CAL_RADII_PX:
                    l_dec, lam_dec, two_theta = dec_l_px(volts, d, r_cal)
                    l_px, lam = float(l_dec), float(lam_dec)
                    dq = float((1 / D(d)) / D(r_cal))
                    q_cal = float(dec_q(r_cal, l_px, lam))
                    check(rel(q_cal, inv_d) < 1e-14, "R3 %s%d%d%d %g kV R %g: q(R_cal) %r vs 1/d %r" % (material, h, k, l, kv, r_cal, q_cal, inv_d))
                    queries = []
                    for r in QUERY_RADII_PX + (r_cal,):
                        q = float(dec_q(r, l_px, lam))
                        qn = np_q(r, l_px, lam)
                        worst["q"] = max(worst["q"], rel(qn, q))
                        r_back = float(dec_r(q, l_px, lam))
                        worst["r"] = max(worst["r"], rel(np_r(q, l_px, lam), r_back))
                        queries.append(dict(r_px=r, q=q, r_from_q=r_back, linear=dq * r))
                    for p in PITCHES_MM:
                        cases.append(dict(name="%s%d%d%d-%dkV-R%g-p%g" % (material, h, k, l, kv, r_cal, p), material=material,
                                          hkl="%d%d%d" % (h, k, l), d_A=d, inv_d=inv_d, kv=kv, volts=volts, r_cal_px=r_cal,
                                          pitch_mm=p, lambda_A=lam, l_px=l_px, dq=dq, l_mm=p * l_px, queries=queries))
    check(len(cases) == 320 and len({c["name"] for c in cases}) == 320, "R3 has %d cases, expected 320 distinct" % len(cases))
    check(worst["q"] < 1e-13 and worst["r"] < 1e-13, "R3 numpy route vs decimal: %s" % worst)
    bad = []
    valid = dict(r=250.0, l=14000.0, lam=0.0251)
    for key in ("r", "l", "lam"):
        for v in (0.0, -1.0, float("nan"), float("inf"), float("-inf")):
            bad.append(dict(fn="q", **dict(valid, **{key: v}), expect="NaN"))
    qv = dict(q=0.4, l=14000.0, lam=0.0251)
    for key in ("q", "l", "lam"):
        for v in (0.0, -1.0, float("nan"), float("inf"), float("-inf")):
            bad.append(dict(fn="radius", **dict(qv, **{key: v}), expect="NaN"))
    return cases, bad, worst


# ----------------------------------------------------------------------------------------------------------------- R4
def make_r4_radii(r3_cases):
    out = []
    for c in r3_cases:
        if c["pitch_mm"] != PITCHES_MM[0]:
            continue                                        # R(g) does not depend on the pitch
        for material, a_cell, hkls in MATERIALS:
            if material != c["material"]:
                continue
            for (h, k, l) in hkls:
                n = h * h + k * k + l * l
                d = float(Decimal(str(a_cell)) / Decimal(n).sqrt())
                g = float(1 / D(d))
                out.append(dict(case=c["name"], family="%d%d%d" % (h, k, l), g=g, l_px=c["l_px"], lambda_A=c["lambda_A"],
                                r_px=float(dec_r(g, c["l_px"], c["lambda_A"]))))
    return out


def make_r4_ellipses(plants_dir):
    manifest = json.load(open(os.path.join(plants_dir, "manifest.json")))
    out = []
    worst = 0.0
    for c in manifest["r4"]:
        g2 = float(1 / D(c["d2"]))
        r2 = dec_r(g2, c["length_px"], c["lambda_A"])
        r1 = (D(c["a"]) + D(c["b"])) / 2
        a2, b2 = D(c["a"]) * r2 / r1, D(c["b"]) * r2 / r1
        worst = max(worst, float(abs(a2 - D(c["ring2_a"])) / a2), float(abs(b2 - D(c["ring2_b"])) / b2), float(abs(r2 - D(c["ring2_R"])) / r2))
        out.append(dict(name=c["name"], g=g2, l_px=c["length_px"], lambda_A=c["lambda_A"], r1_px=float(r1), r_px=float(r2),
                        a=float(a2), b=float(b2), theta=c["theta"], centre_row=c["r0"], centre_col=c["c0"],
                        b_over_a=float(D(c["b"]) / D(c["a"])), planted_a=c["ring2_a"], planted_b=c["ring2_b"],
                        planted_R=c["ring2_R"]))
    check(worst < 1e-12, "R4: plants.py's ring 2 differs from the decimal scaled ellipse by %.2e" % worst)
    return out, worst


# ----------------------------------------------------------------------------------------------------------------- R5
ANGSTROM_SPELLINGS = ["1/a", "1/å", "a^-1", "å^-1", "a⁻¹", "å⁻¹", "angstrom^-1", "angstrom⁻¹", "1/angstrom", "ang^-1", "ang⁻¹"]
NM_SPELLINGS = ["1/nm", "nm^-1", "nm⁻¹", "1/nanometer", "1/nanometre", "nanometer^-1", "nanometer⁻¹", "nanometre^-1", "nanometre⁻¹"]
MRAD_SPELLINGS = ["mrad"]
REJECTS = ["", "px", "pixel", "pixels", "1/px", "nm", "Å", "pm", "1/pm", "rad", "mm", "1/mm", "Å⁻²", "1/nm²", "nm^-2", "um^-1", "?", "A"]
R5_VALUES = (1e-4, 3.7e-4, 2.831e-3, 1e-2, 0.25, 1.0)
R5_LAMBDAS_KV = (80, 200, 300)


def normalize(u):
    """The contract's normalisation, from its description: canonical composition, trim whitespace and newlines, lower case,
    drop spaces, 'angstrom' for the accented spelling."""
    return unicodedata.normalize("NFC", u).strip().lower().replace(" ", "").replace("ångström", "angstrom")


def variants(base):
    v = {base, base.upper(), " " + base + " ", "\n" + base + "\t", base.replace("/", " / "), base.replace("å", "å"),
         base.replace("å", "Å").replace("ngström", "ngström")}
    if "å" in base:
        v.add(base.replace("å", "Å").upper())
    if "angstrom" in base:
        v.add(base.replace("angstrom", "ångström"))
        v.add(base.replace("angstrom", "Ångström"))
        v.add(base.replace("angstrom", "Ångström"))
    return sorted(v)


def make_r5():
    spell = []
    for fam, bases, factor in (("A", ANGSTROM_SPELLINGS, Decimal(1)), ("nm", NM_SPELLINGS, Decimal("0.1"))):
        for base in bases:
            for u in variants(base):
                check(normalize(u) in bases, "R5: variant %r normalises to %r, not a listed spelling" % (u, normalize(u)))
                for v in R5_VALUES:
                    spell.append(dict(unit=u, base=base, family=fam, value=v, lambda_A=None, expect=float(D(v) * factor)))
    for u in ("mrad", "MRAD", " mrad ", "Mrad"):
        for kv in R5_LAMBDAS_KV:
            lam = float(dec_wavelength_a(kv * 1000.0))
            for v in (0.01, 0.1, 1.0, 10.0):
                spell.append(dict(unit=u, base="mrad", family="mrad", value=v, lambda_A=lam, expect=float(D(v) / (1000 * D(lam)))))
        for v in (0.1, 1.0):
            spell.append(dict(unit=u, base="mrad", family="mrad", value=v, lambda_A=None, expect=None))
            for lam in (0.0, -0.02, float("nan"), float("inf")):
                spell.append(dict(unit=u, base="mrad", family="mrad", value=v, lambda_A=lam, expect=None))
    rejects = [dict(unit=u, value=0.25, lambda_A=0.0251, expect=None) for u in REJECTS]
    rejects.append(dict(unit=None, value=0.25, lambda_A=0.0251, expect=None))
    invalid = [dict(unit=u, value=v, lambda_A=0.0251, expect=None)
               for u in ("1/nm", "Å⁻¹", "mrad") for v in (0.0, -1.0, float("nan"), float("inf"), float("-inf"))]
    pairs = []
    for fam, unit, factor in (("A", "Å⁻¹", Decimal(1)), ("nm", "1/nm", Decimal("0.1")), ("nm", "nm^-1", Decimal("0.1"))):
        for v in (1e-4, 2.831e-3, 0.25, 1.0):
            for diff in (-0.3, -0.05, -0.004, -0.0012, 0.0013, 0.004, 0.05, 0.3):
                file_conv = D(v) * factor
                fit = float(file_conv * (1 + Decimal(str(diff))))
                ratio = D(fit) / (D(float(file_conv)))
                pairs.append(dict(unit=unit, file_value=v, fit_dq=fit, file_dq=float(file_conv), diff=float(ratio - 1), diff_pct=float((ratio - 1) * 100)))
    return dict(spellings=spell, rejects=rejects, invalid_values=invalid, fit_vs_file=pairs,
                spellings_listed=dict(angstrom=ANGSTROM_SPELLINGS, nm=NM_SPELLINGS, mrad=MRAD_SPELLINGS))


# --------------------------------------------------------------------------------------------- kinematic lists (R6, R7)
FCC = [(0, 0, 0), (.5, .5, 0), (.5, 0, .5), (0, .5, .5)]
DIAMOND = FCC + [(x + .25, y + .25, z + .25) for (x, y, z) in FCC]
HCP = [(0, 0, 0), (2 / 3, 1 / 3, .5)]


def sites(z, positions, occ=1.0):
    return [(z, p, occ) for p in positions]


STANDARDS = {
    "Au": dict(cell=(4.0782,) * 3 + (90, 90, 90), sites=sites(79, FCC), lattice="cubic"),
    "Al": dict(cell=(4.0495,) * 3 + (90, 90, 90), sites=sites(13, FCC), lattice="cubic"),
    "Si": dict(cell=(5.4309,) * 3 + (90, 90, 90), sites=sites(14, DIAMOND), lattice="cubic"),
    "Mg": dict(cell=(3.2094, 3.2094, 5.2108, 90, 90, 120), sites=sites(12, HCP), lattice="hexagonal"),
    "Cu3Au-occ": dict(cell=(3.75,) * 3 + (90, 90, 90), lattice="cubic",
                      sites=sites(79, [(0, 0, 0)], 0.6) + sites(29, [(0, 0, 0)], 0.4) + sites(29, FCC[1:])),
}


def lattice(a, b, c, al, be, ga):
    ca, cb, cg = (math.cos(math.radians(x)) for x in (al, be, ga))
    sg = math.sin(math.radians(ga))
    vol = a * b * c * math.sqrt(1 - ca * ca - cb * cb - cg * cg + 2 * ca * cb * cg)
    A = np.array([[a, 0, 0], [b * cg, b * sg, 0], [c * cb, c * (ca - cb * cg) / sg, vol / (a * b * sg)]])
    return A, vol


def load_table(path):
    data = open(path, "rb").read()
    got = hashlib.sha256(data).hexdigest()
    if got != TABLE_SHA256:
        sys.exit("reference.py: %s has sha256 %s, the lock is %s" % (path, got, TABLE_SHA256))
    t = np.loadtxt(path, dtype=np.float64)
    assert t.shape == (103, 10), t.shape
    return t


def f_e(table, z, g2):
    row = table[z - 1]
    a, b = row[0:10:2], row[1:10:2]
    g2 = np.asarray(g2, dtype=np.float64)
    return sum(a[i] * (2 + b[i] * g2) / (1 + b[i] * g2) ** 2 for i in range(5))


def raw_reflections(table, cell, site_list, kmax, occ_on=True):
    A, vol = lattice(*cell)
    B = np.linalg.inv(A).T
    n = [int(math.ceil(kmax * np.linalg.norm(A[i]))) + 1 for i in range(3)]
    hkl = np.array([p for p in itertools.product(*(range(-m, m + 1) for m in n)) if p != (0, 0, 0)], dtype=np.float64)
    glen = np.linalg.norm(hkl @ B, axis=1)
    keep = glen <= kmax
    hkl, glen = hkl[keep], glen[keep]
    F = np.zeros(len(hkl), dtype=np.complex128)
    for (z, pos, occ) in site_list:
        F += f_e(table, z, glen ** 2) * (occ if occ_on else 1.0) * np.exp(2j * np.pi * (hkl @ np.array(pos)))
    return hkl.astype(np.int64), glen, F / vol


def cubic_name(h, k, l):
    return tuple(sorted((abs(h), abs(k), abs(l)), reverse=True))


def hex_name(h, k, l):
    t = [h, k, -(h + k)]
    if sum(1 for x in t if x >= 0) < 2:
        t = [-x for x in t]
    t.sort(reverse=True)
    return (t[0], t[1], -t[0] - t[1], abs(l))


def families(table, std, kmax, occ_on=True):
    """S1's list swept in |g| order: a reflection joins the current family while |g| <= g0 (1 + 1e-9), g0 its smallest. The
    family g is its smallest member; multiplicity its member count; name its orbits (holohedry) joined by ' + '."""
    hkl, glen, F = raw_reflections(table, std["cell"], std["sites"], kmax, occ_on)
    aF = np.abs(F)
    keep = aF > CUT
    hk, g, aFk = hkl[keep], glen[keep], aF[keep]
    order = np.argsort(g, kind="stable")
    fam_id = np.empty(len(g), dtype=np.int64)
    cur, g0 = -1, 0.0
    for idx in order:
        if cur >= 0 and g[idx] <= g0 * (1 + GROUP_TOL):
            fam_id[idx] = cur
        else:
            cur += 1
            g0 = g[idx]
            fam_id[idx] = cur
    namef = cubic_name if std["lattice"] == "cubic" else hex_name
    groups = defaultdict(list)
    for i in range(len(g)):
        groups[fam_id[i]].append(i)
    fams = []
    for fid in range(cur + 1):
        ids = groups[fid]
        g_first = float(g[min(ids, key=lambda i: (g[i], i))])
        mem = sorted(tuple(int(x) for x in hk[i]) for i in ids)
        cnt = Counter(namef(*m) for m in mem)
        names = sorted(cnt, reverse=True)
        fams.append(dict(g=g_first, members=[list(m) for m in mem], multiplicity=len(mem), orbits=[list(n) for n in names],
                         name=" + ".join("{" + " ".join(str(x) for x in n) + "}" for n in names),
                         intensity=float(np.sum(aFk[ids] ** 2))))
    return fams, int(keep.sum())


def closed_form_d(std, orbit):
    """d of a family by the definition of the lattice, in decimal: cubic a / sqrt(h^2 + k^2 + l^2); hexagonal
    1 / sqrt(4 (h^2 + h k + k^2) / (3 a^2) + l^2 / c^2) with the orbit (H, K, -H-K, |l|)."""
    cell = std["cell"]
    if std["lattice"] == "cubic":
        h, k, l = orbit
        return Decimal(str(cell[0])) / Decimal(h * h + k * k + l * l).sqrt()
    h, k, _, l = orbit
    a, c = Decimal(str(cell[0])), Decimal(str(cell[2]))
    return 1 / (4 * Decimal(h * h + h * k + k * k) / (3 * a * a) + Decimal(l * l) / (c * c)).sqrt()


# ----------------------------------------------------------------------------------------------------------------- R7
def make_r7(table):
    out, counts = [], {}
    for name, std in STANDARDS.items():
        for kmax in KMAXES:
            fams, nrefl = families(table, std, kmax)
            rows = []
            worst = 0.0
            for i, f in enumerate(fams):
                orbit = tuple(f["orbits"][0])
                dc = closed_form_d(std, orbit)
                d_def = 1 / D(f["g"])
                worst = max(worst, float(abs(dc - d_def) / dc))
                rows.append(dict(index=i, g=f["g"], d=float(d_def), d_closed=float(dc), multiplicity=f["multiplicity"],
                                 name=f["name"], orbits=f["orbits"], intensity=f["intensity"]))
            check(worst < 1e-13, "R7 %s k_max %g: matrix |g| vs the closed form of d differs by %.2e" % (name, kmax, worst))
            counts[(name, kmax)] = (len(fams), nrefl)
            out.append(dict(name=name, kmax=kmax, cell=list(std["cell"]), lattice=std["lattice"], families=len(fams),
                            reflections=nrefl, rows=rows))
    return out, counts


# ----------------------------------------------------------------------------------------------------------------- R6
def decide_scalar(g, q, sigma, k, kmax):
    """The rule of tools/parity/indexing-parity/reference.py, one plant at a time: (name, best, next, payload, z_best, margin, nearest)."""
    def ok(x):
        return math.isfinite(x) and x > 0
    if not (ok(q) and ok(sigma) and ok(k)):
        return ("invalidInput", -1, -1, [], math.nan, math.nan, -1)
    cands = sorted(((abs(q - gj) / sigma, gj, j) for j, gj in enumerate(g)))
    within = [c for c in cands if c[0] <= k]
    nxt = cands[1] if len(cands) > 1 else None
    near = cands[0][2] if cands else -1
    if len(within) >= 2:
        return ("ambiguous", -1, -1, [c[2] for c in within], math.nan, math.nan, near)
    if len(within) == 1 and nxt is not None:
        m = (nxt[0] * nxt[0] - within[0][0] * within[0][0]) / 2
        if m < LN19:
            return ("ambiguous", -1, -1, [within[0][2], nxt[2]], math.nan, math.nan, near)
    r = math.sqrt(k * k + 2 * LN19)
    named = []
    if cands:
        named.append(cands[0])
        if len(within) == 1 and nxt is not None:
            named.append(nxt)
    R = max([r * sigma] + [abs(q - c[1]) for c in named])
    if q + R > kmax:
        return ("beyondKMax", -1, -1, [], math.nan, math.nan, near)
    if not within:
        return ("noneWithinTolerance", -1, -1, [], math.nan, math.nan, near)
    best = within[0]
    if nxt is None:
        return ("accepted", best[2], -1, [], best[0], math.nan, near)
    return ("accepted", best[2], nxt[2], [], best[0], (nxt[0] * nxt[0] - best[0] * best[0]) / 2, near)


def hazard(g, q, sigma, k, kmax):
    """min distance of the plant to a decision boundary (z = k, margin = ln 19, q + R = kMax): the plant is dropped under 1e-6."""
    if not (q > 0 and sigma > 0 and k > 0 and math.isfinite(q) and math.isfinite(sigma)):
        return math.inf
    z = sorted(abs(q - gj) / sigma for gj in g)
    h = min([abs(v - k) for v in z] or [math.inf])
    if len(z) > 1 and z[0] <= k < z[1]:
        h = min(h, abs((z[1] ** 2 - z[0] ** 2) / 2 - LN19))
    return h


def displayed(verdict_row, g, q, tol_pct):
    """The numbers a ring row shows, from the definitions (fields of RingIndexing.Assignment): delta = g/q - 1 and in %, |dd|/d with
    d the listed family's, z, odds = exp(margin), sigma_q = q * tol / 100, in 60-digit decimal and rounded once."""
    name, best, nxt, payload, zb, margin, near = verdict_row
    sigma_q = float(D(q) * D(tol_pct) / 100)
    rec = dict(verdict=name, best=best, next=nxt, payload=payload, nearest=near, sigma_q=sigma_q)
    if best >= 0:
        gb = D(g[best])
        delta = gb / D(q) - 1
        d_listed, d_meas = 1 / gb, 1 / D(q)
        rec.update(delta=float(delta), delta_pct=float(delta * 100), d_listed=float(d_listed), d_measured=float(d_meas),
                   delta_d=float(d_meas - d_listed), abs_dd_over_d=float(abs(d_meas - d_listed) / d_listed),
                   z=float(abs(D(q) - gb) / D(sigma_q)))
        if nxt >= 0:
            gn = D(g[nxt])
            zn = abs(D(q) - gn) / D(sigma_q)
            zb_dec = abs(D(q) - gb) / D(sigma_q)
            mg = (zn * zn - zb_dec * zb_dec) / 2
            rec.update(z_next=float(zn), margin=float(mg), delta_next=float(gn / D(q) - 1),
                       odds=(float(mg.exp()) if mg < 700 else math.inf), odds_beyond_1e6=bool(mg.exp() > 10 ** 6))
    return rec


def make_r6(table):
    t1, hazards = [], 0
    for cname in ("Au", "Al", "Si"):
        for kmax in KMAXES:
            fams, _ = families(table, STANDARDS[cname], kmax)
            g = [f["g"] for f in fams]
            for j, gj in enumerate(g):
                for u in U1:
                    for s in S1:
                        q = gj * (1 + s * u)
                        tol = TOL_PCT[u]
                        sigma = float(D(q) * D(tol) / 100)
                        if hazard(g, q, sigma, K_SIGMA, kmax) < 1e-6:
                            hazards += 1
                            continue
                        row = decide_scalar(g, q, sigma, K_SIGMA, kmax)
                        rec = displayed(row, g, q, tol)
                        rec.update(crystal=cname, kmax=kmax, family=j, family_name=fams[j]["name"], u=u, s=s, q=q, tol_pct=tol, k=K_SIGMA)
                        t1.append(rec)
    # T4: the refusals and the edge lists (indexing-parity's plants that apply to a displayed verdict), on Au / Si
    t4 = []
    au12, _ = families(table, STANDARDS["Au"], 1.2)
    g12 = [f["g"] for f in au12]

    def add(label, g, q, tol, k, kmax, expect):
        sigma = q * tol / 100 if all(math.isfinite(x) for x in (q, tol)) else math.nan
        sigma = float(D(q) * D(tol) / 100) if math.isfinite(q) and math.isfinite(tol) else math.nan
        if tol == 0.0:
            sigma = 0.0
        row = decide_scalar(g, q, sigma, k, kmax)
        check(row[0] == expect, "R6 T4 %r: the rule gives %s, expected %s" % (label, row[0], expect))
        rec = displayed(row, g, q, tol) if math.isfinite(q) and q > 0 and math.isfinite(tol) else dict(verdict=row[0], best=-1, next=-1, payload=[], nearest=row[6], sigma_q=sigma)
        rec.update(label=label, crystal="Au", kmax=kmax, q=q, tol_pct=tol, k=k, expect=expect, g=list(g))
        t4.append(rec)

    g111 = g12[0]
    for nm, bad in (("0", 0.0), ("-1", -1.0), ("NaN", math.nan), ("+inf", math.inf), ("-inf", -math.inf)):
        add("invalid q = " + nm, g12, bad, 0.1, K_SIGMA, 1.2, "invalidInput")
        add("invalid tolerance = " + nm, g12, g111, bad, K_SIGMA, 1.2, "invalidInput")
        add("invalid k = " + nm, g12, g111, 0.1, bad, 1.2, "invalidInput")
    add("beyond: q = 1.25 on Au, k_max 1.2", g12, 1.25, 0.1, K_SIGMA, 1.2, "beyondKMax")
    add("none: Au {100} (forbidden) at 1/a", g12, 1 / 4.0782, 0.1, K_SIGMA, 1.2, "noneWithinTolerance")
    j331 = next(i for i, f in enumerate(au12) if f["orbits"][0] == [3, 3, 1])
    j420 = next(i for i, f in enumerate(au12) if f["orbits"][0] == [4, 2, 0])
    g331, g420 = g12[j331], g12[j420]
    add("ambiguous: Au {331} at its own g, tolerance 1 % ({420} 2.6 % away)", g12, g331, 1.0, K_SIGMA, 1.2, "ambiguous")
    sg = (g420 - g331) / 5.7
    qm = g331 + 2.5 * sg
    add("ambiguous: the margin plant, Au {331} -> {420}, sigma = gap / 5.7, z = 2.5", g12, qm, 100.0 * sg / qm, K_SIGMA, 1.2, "ambiguous")
    add("accepted: Au {111} at its own g, tolerance 0.1 %", g12, g111, 0.1, K_SIGMA, 1.2, "accepted")
    one = [g111]
    add("one-family list: {111} at its own g -> accepted, next none", one, g111, 0.1, K_SIGMA, 0.45, "accepted")
    add("one-family list: q = 0.3 -> none", one, 0.3, 0.1, K_SIGMA, 0.45, "noneWithinTolerance")
    add("one-family list: q = 0.449 -> beyond", one, 0.449, 0.1, K_SIGMA, 0.45, "beyondKMax")
    add("empty list: q = 0.2 -> none", [], 0.2, 0.1, K_SIGMA, 0.3, "noneWithinTolerance")
    add("empty list: q = 0.299 -> beyond", [], 0.299, 0.1, K_SIGMA, 0.3, "beyondKMax")
    return t1, t4, hazards


# ---------------------------------------------------------------------------------------------------------- R1 helpers
def ellipse_distances(points_xy, cx, cy, a, b, theta):
    """Orthogonal distance from each point (x = column, y = row) to the ellipse with centre (cx, cy) and the plants' axes: the major
    axis a along (cos t, sin t) in (row, column), u = dr cos t + dc sin t, v = -dr sin t + dc cos t, u^2/a^2 + v^2/b^2 = 1.
    Newton on the nearest-point condition from the best of 3600 samples; machine-precision exact for any point."""
    pts = np.asarray(points_xy, dtype=np.float64).reshape(-1, 2)
    dr, dc = pts[:, 1] - cy, pts[:, 0] - cx
    ct, st = math.cos(theta), math.sin(theta)
    u, v = dr * ct + dc * st, -dr * st + dc * ct
    phi = np.linspace(0.0, 2 * math.pi, 3600, endpoint=False)
    ex, ey = a * np.cos(phi), b * np.sin(phi)
    out = np.empty(len(pts))
    for i in range(len(pts)):
        d2 = (ex - u[i]) ** 2 + (ey - v[i]) ** 2
        t = phi[int(np.argmin(d2))]
        for _ in range(60):
            x, y = a * math.cos(t), b * math.sin(t)
            dx, dy = -a * math.sin(t), b * math.cos(t)
            g1 = (x - u[i]) * dx + (y - v[i]) * dy
            g2 = dx * dx + dy * dy + (x - u[i]) * (-x) + (y - v[i]) * (-y)
            if g2 <= 0:
                g2 = dx * dx + dy * dy
            step = g1 / g2
            t -= step
            if abs(step) < 1e-15:
                break
        out[i] = math.hypot(a * math.cos(t) - u[i], b * math.sin(t) - v[i])
    return out


def distance_vectors():
    vec = []
    for (cx, cy, a, b, th) in ((320.4, 256.3, 140.7, 138.2, 0.0), (310.0, 250.5, 160.0, 150.0, math.radians(30)),
                               (300.25, 200.75, 90.0, 87.4, math.radians(90)), (333.3, 222.2, 199.0, 193.2, math.radians(135))):
        ct, st = math.cos(th), math.sin(th)
        pts, want = [], []
        for phi in np.linspace(0.0, 2 * math.pi, 37)[:-1]:
            x, y = a * math.cos(phi), b * math.sin(phi)
            nx, ny = b * math.cos(phi), a * math.sin(phi)          # the outward normal direction
            nn = math.hypot(nx, ny)
            for off in (0.0, 0.3, -0.3, 0.5):
                u, v = x + off * nx / nn, y + off * ny / nn
                dr, dc = u * ct - v * st, u * st + v * ct
                pts.append([cx + dc, cy + dr])
                want.append(abs(off))
        vec.append(dict(cx=cx, cy=cy, a=a, b=b, theta=th, points=pts, distance=want))
    return vec


def distance_check(path_in, path_out):
    items = json.load(open(path_in))["items"]
    res = []
    for it in items:
        d = ellipse_distances(it["points"], it["cx"], it["cy"], it["a"], it["b"], it["theta"])
        res.append(dict(name=it["name"], max_distance=float(d.max()), distances=[float(x) for x in d]))
    with open(path_out, "w") as fh:
        fh.write(dumps({"items": res}) + "\n")


# ----------------------------------------------------------------------------------------------------------------- R9
def make_r9(out, cif_dirs):
    files = []
    base = None
    for d in cif_dirs:
        for fn in sorted(os.listdir(d)):
            if fn.lower().endswith(".cif"):
                data = open(os.path.join(d, fn), "rb").read()
                files.append(dict(name=fn, dir=os.path.abspath(d), planted=False, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                                  expect="read"))
                if fn == "beta_double_prime_Mg5Si6.cif":
                    base = data
    if base is None:
        fail("R9: no beta_double_prime_Mg5Si6.cif in --cif-dir; the planted files need a valid CIF as their base")
        return files
    os.makedirs(os.path.join(out, "r9"), exist_ok=True)

    def padded(total):
        body = base if base.endswith(b"\n") else base + b"\n"
        line = b"# " + b"-" * 76 + b"\n"
        need = total - len(body)
        assert need >= 0
        n_full, rem = divmod(need, len(line))
        tail = b""
        if rem == 1:
            tail = b"\n"
        elif rem > 1:
            tail = b"#" + b"-" * (rem - 2) + b"\n"
        data = body + line * n_full + tail
        assert len(data) == total, (len(data), total)
        return data

    nl = base if base.endswith(b"\n") else base + b"\n"
    planted = {
        "cap-exact-5MiB.cif": (padded(MAX_CIF_BYTES), "read-at-cap"),
        "cap-plus-1.cif": (padded(MAX_CIF_BYTES + 1), "refuse-size"),
        "invalid-utf8.cif": (b"# \xc3\x28 invalid UTF-8 (a lead byte then a non-continuation)\n" + nl, "refuse-utf8"),
        "utf8-bom.cif": (b"\xef\xbb\xbf" + nl, "read"),
        "crlf.cif": (nl.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"), "read"),
        "nfd-comment.cif": (("# café Ångström\n").encode() + nl, "read"),
        "empty.cif": (b"", "refuse-any"),
        "garbage.cif": (b"this is not a cif\n", "refuse-any"),
    }
    for fn, (data, expect) in planted.items():
        with open(os.path.join(out, "r9", fn), "wb") as fh:
            fh.write(data)
        files.append(dict(name=fn, dir="r9", planted=True, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), expect=expect))
    check(len(planted["cap-exact-5MiB.cif"][0]) == MAX_CIF_BYTES and len(planted["cap-plus-1.cif"][0]) == MAX_CIF_BYTES + 1, "R9: cap files are not 5 MiB and 5 MiB + 1")
    try:
        planted["invalid-utf8.cif"][0].decode("utf-8")
        fail("R9: the invalid-UTF-8 plant decodes")
    except UnicodeDecodeError:
        pass
    return files


# -------------------------------------------------------------------------------------------------- self-check / mutations
def sibling_decimal_wavelength(volts):
    path = os.path.join(HERE, "ring_calibration_reference.py")
    spec = importlib.util.spec_from_file_location("ring_calibration_reference", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.dec_wavelength_a(volts), mod


def mutation_moves(r3, r4, r5, r6, r7, counts, table):
    mm = {}
    # R3
    mm["R3 small-angle R/L"] = max(abs((q["r_px"] / c["l_px"]) / c["lambda_A"] - q["q"]) / q["q"] for c in r3 for q in c["queries"])
    mm["R3 no half"] = max(abs(2 * math.sin(math.atan(q["r_px"] / c["l_px"])) / c["lambda_A"] - q["q"]) / q["q"] for c in r3 for q in c["queries"])
    mm["R3 V in kV"] = max(abs(np_q(q["r_px"], c["l_px"], float(dec_wavelength_a(c["volts"] / 1000))) - q["q"]) / q["q"] for c in r3 for q in c["queries"])
    mm["R3 2 pi"] = 2 * math.pi - 1
    mm["R3 linear used though V is known"] = max(abs(q["linear"] - q["q"]) / q["q"] for c in r3 for q in c["queries"])
    # R4
    by_name = {c["name"]: c for c in r3}
    mm["R4 g/dq with V known"] = max(abs(x["g"] / by_name[x["case"]]["dq"] - x["r_px"]) / x["r_px"] for x in r4["radii"])
    # R5
    mm["R5 x10"] = 9.0
    mm["R5 x2pi"] = 2 * math.pi - 1
    mm["R5 mrad accepted without lambda"] = 1.0
    mm["R5 ratio inverted"] = max(abs(1 / (1 + p["diff"]) - 1 - p["diff"]) / abs(p["diff"]) for p in r5["fit_vs_file"])
    # R6
    acc = [r for r in r6[0] if r["verdict"] == "accepted"]
    mm["R6 delta over the measured d"] = max(abs((1 - 1 / (1 + r["delta"])) - r["delta"]) / abs(r["delta"]) for r in acc if r["delta"] != 0)
    mm["R6 percent x10"] = 9.0
    mm["R6 tolerance as a fraction"] = 1.0 - 1e-2
    mm["R6 odds = margin"] = max(abs(r["margin"] - r["odds"]) / r["odds"] for r in acc if "odds" in r and math.isfinite(r["odds"]))
    mm["R6 z without the tolerance"] = max(abs(abs(r["q"] - 1 / r["d_listed"]) / r["q"] - r["z"]) / r["z"] for r in acc if r["z"] > 0)
    mm["R6 sigma_q in %"] = 99.0
    # R7
    au = next(s for s in r7 if s["name"] == "Au" and s["kmax"] == 1.2)
    mm["R7 Au 4.0872"] = abs(float(closed_form_d(dict(STANDARDS["Au"], cell=(4.0872,) * 3 + (90, 90, 90)), (1, 1, 1))) / au["rows"][0]["d"] - 1)
    fams_nodiamond, _ = families(table, dict(STANDARDS["Si"], sites=sites(14, FCC)), 1.2)
    mm["R7 diamond basis dropped (Si families at 1.2: %d -> %d)" % (counts[("Si", 1.2)][0], len(fams_nodiamond))] = abs(len(fams_nodiamond) - counts[("Si", 1.2)][0])
    fams_noocc, _ = families(table, STANDARDS["Cu3Au-occ"], 1.2, occ_on=False)
    inten_a = [f["intensity"] for f in families(table, STANDARDS["Cu3Au-occ"], 1.2)[0]]
    mm["R7 occupancy ignored (Cu3Au-occ, families %d -> %d)" % (counts[("Cu3Au-occ", 1.2)][0], len(fams_noocc))] = max(
        abs(len(fams_noocc) - counts[("Cu3Au-occ", 1.2)][0]),
        max(abs(x - y) / y for x, y in zip([f["intensity"] for f in fams_noocc], inten_a)) if len(fams_noocc) == len(inten_a) else 1.0)
    return mm


def main():
    args = sys.argv[1:]
    if args and args[0] == "--distance-check":
        if len(args) != 3:
            sys.exit(__doc__)
        distance_check(args[1], args[2])
        return
    plants_dir, cif_dirs = None, []
    while "--plants" in args:
        i = args.index("--plants")
        plants_dir = args[i + 1]
        del args[i:i + 2]
    while "--cif-dir" in args:
        i = args.index("--cif-dir")
        cif_dirs.append(args[i + 1])
        del args[i:i + 2]
    if len(args) != 2:
        sys.exit(__doc__)
    table_path, out = args
    os.makedirs(out, exist_ok=True)
    if np.__version__ != NUMPY:
        sys.exit("reference.py: numpy %s, the lock pins %s" % (np.__version__, NUMPY))
    table = load_table(table_path)

    print("== hand values")
    au_d = float(Decimal("4.0782") / Decimal(3).sqrt())
    print("  Au {111} d = 4.0782 / sqrt(3) = %r (decimal, rounded once); float division %r" % (au_d, 4.0782 / math.sqrt(3)))
    check(au_d == 2.3545498678091317, "Au {111} d is %r, not 2.3545498678091317" % au_d)
    lam200 = dec_wavelength_a(200000.0)
    sib, sib_mod = sibling_decimal_wavelength(200000.0)
    print("  lambda(200 kV) = %s A; ring-calibration-parity's decimal chain %s; equal: %s" % (str(lam200)[:24], str(sib)[:24], lam200 == sib))
    check(lam200 == sib, "lambda(200 kV) differs from ring-calibration-parity's")
    check((D_H, D_C, D_E, D_M0) == tuple(Decimal(s) for s in (sib_mod.H_S, sib_mod.C_S, sib_mod.E_S, sib_mod.M0_S)), "constants differ from ring-calibration-parity's")
    check(abs(float(lam200) - 0.0251) < 5e-5, "lambda(200 kV) is not the 3-digit textbook 0.0251")
    r3, r3_bad, worst3 = make_r3()
    c0 = r3[0]
    q = c0["queries"][-1]
    print("  round trip R -> q -> R on %s: R %g -> q %r -> R %r (rel %.1e)" % (c0["name"], q["r_px"], q["q"], q["r_from_q"], rel(q["r_from_q"], q["r_px"])))
    worst_rt = max(rel(qq["r_from_q"], qq["r_px"]) for c in r3 for qq in c["queries"])
    print("  all %d cases x 7 radii: worst |R -> q -> R| %.2e relative (%.2e px at R 2000); numpy vs decimal q %.2e, R %.2e"
          % (len(r3), worst_rt, worst_rt * 2000, worst3["q"], worst3["r"]))
    check(worst_rt * 2000 < 1e-9, "round trip exceeds 1e-9 px")
    # exact vs linear at Au {200} from {111} (the registration's probe: 9.0e-6 "at 200 kV")
    d111, d200 = 4.0782 / math.sqrt(3), 4.0782 / 2
    for volts in (200000.0, 300000.0):
        l_dec, lam_dec, _ = dec_l_px(volts, d111, 250.0)
        dq = float((1 / D(d111)) / D(250.0))
        r200 = float(dec_r(1 / d200, float(l_dec), float(lam_dec)))
        q_exact = float(dec_q(r200, float(l_dec), float(lam_dec)))
        print("  Au {200} from {111} at %g kV: R200 %.6f px; exact q %.12f, linear dq*R %.12f, differ %.2e relative"
              % (volts / 1000, r200, q_exact, dq * r200, abs(dq * r200 - q_exact) / q_exact))
    print("  (the registration's probe reads 9.0e-6 at 200 kV; the closed form gives the 200 kV figure above, and 8.7e-6 at 300 kV)")

    print("== R3 / R4")
    r4_rad = make_r4_radii(r3)
    cal_ok = all(rel(x["r_px"], next(c["r_cal_px"] for c in r3 if c["name"] == x["case"])) < 1e-12 for x in r4_rad
                 if x["g"] == next(c["inv_d"] for c in r3 if c["name"] == x["case"]))
    check(cal_ok, "R4: R(1/d) differs from R_cal for a calibration family")
    print("  %d radius records (every case x each family of its material)" % len(r4_rad))
    r4_ell, w4 = ([], None)
    if plants_dir:
        r4_ell, w4 = make_r4_ellipses(plants_dir)
        print("  %d scaled-ellipse records; plants.py's ring 2 vs the decimal scaling: worst %.1e relative" % (len(r4_ell), w4))
    else:
        print("  no --plants: the scaled ellipses of the R4 plants are not written")
    r4 = dict(radii=r4_rad, ellipses=r4_ell)
    if r4_ell:
        mv_off = max(abs((e["a"] - e["r_px"] + e["r1_px"]) - e["a"]) for e in r4_ell)           # offsets kept: a + (R2 - R1)
        mv_ctr = max(abs(e["centre_row"] - 256.0) for e in r4_ell)
        print("  mutation moves: offsets kept instead of scaled -> a off by up to %.3f px; image centre for centre -> %.3f px" % (mv_off, mv_ctr))

    print("== R5")
    r5 = make_r5()
    print("  %d spelling records (%d + %d listed spellings + mrad), %d rejects, %d invalid values, %d fit-vs-file pairs; worst |diff| %.4f, least %.2e"
          % (len(r5["spellings"]), len(ANGSTROM_SPELLINGS), len(NM_SPELLINGS), len(r5["rejects"]), len(r5["invalid_values"]), len(r5["fit_vs_file"]),
             max(abs(p["diff"]) for p in r5["fit_vs_file"]), min(abs(p["diff"]) for p in r5["fit_vs_file"])))

    print("== R7")
    r7, counts = make_r7(table)
    for (name, kmax), (nf, nr) in counts.items():
        print("  %-10s k_max %.1f: %3d families, %4d reflections above the cut" % (name, kmax, nf, nr))
    check(counts[("Au", 1.2)][0] == 8, "Au has %d families at 1.2, the kit's note says 8" % counts[("Au", 1.2)][0])
    check(counts[("Au", 2.0)][0] == 22, "Au has %d families at 2.0, the probe says 22" % counts[("Au", 2.0)][0])
    check(counts[("Si", 1.2)][0] == 10, "Si has %d families at 1.2, the kit's note says 10" % counts[("Si", 1.2)][0])
    check(counts[("Al", 1.2)] == counts[("Au", 1.2)][:1] + counts[("Al", 1.2)][1:] and counts[("Al", 1.2)][0] == counts[("Au", 1.2)][0]
          and counts[("Al", 2.0)][0] == counts[("Au", 2.0)][0], "Al's family counts are predicted equal to Au's")
    print("  Au {111} d from the list: %r (definition), %r (closed form a/sqrt(3))" % (r7[0]["rows"][0]["d"], r7[0]["rows"][0]["d_closed"]))

    print("== R6")
    r6_t1, r6_t4, hz = make_r6(table)
    tot = Counter(r["verdict"] for r in r6_t1)
    print("  T1: %d plants (Au, Al, Si x k_max 1.2, 2.0), %d dropped as hazards (within 1e-6 of a decision boundary); verdicts %s"
          % (len(r6_t1), hz, dict(tot)))
    print("  T4: %d plants, every verdict equals the rule's expectation" % len(r6_t4))
    for r in r6_t1:                              # own family back: delta consistent with the construction
        if r["verdict"] == "accepted" and r["best"] == r["family"]:
            want = 1 / (1 + r["s"] * r["u"]) - 1
            check(abs(r["delta"] - want) < 1e-14, "R6 delta of an accepted own-family plant is not 1/(1 + s u) - 1")
    odds_beyond = sum(1 for r in r6_t1 if r.get("odds_beyond_1e6"))
    print("  %d accepted plants with odds beyond 10^6 : 1" % odds_beyond)

    print("== R9")
    files = make_r9(out, cif_dirs)
    for f in files:
        print("  %-34s %8d B  sha256 %s...  %s" % (f["name"], f["bytes"], f["sha256"][:16], f["expect"]))

    print("== ellipse distance helper")
    dv = distance_vectors()
    worst_d = 0.0
    for v in dv:
        d = ellipse_distances(v["points"], v["cx"], v["cy"], v["a"], v["b"], v["theta"])
        worst_d = max(worst_d, float(np.max(np.abs(d - np.array(v["distance"])))))
    print("  %d ellipses, %d points: worst |distance - planted offset| %.2e px" % (len(dv), sum(len(v["points"]) for v in dv), worst_d))
    check(worst_d < 1e-9, "the ellipse distance helper is off by %.2e px" % worst_d)

    print("== mutation moves (each must exceed 1e-6)")
    mm = mutation_moves(r3, r4, r5, (r6_t1, r6_t4), r7, counts, table)
    for k, v in mm.items():
        check(v > 1e-6, "mutation '%s' moves its target by only %.2e" % (k, v))
        print("  %-62s %.3e" % (k, v))

    ref = dict(numpy=np.__version__, table_sha256=TABLE_SHA256, tolerance=1e-12,
               constants=dict(h_Js=H_S, c_ms=C_S, e_C=E_S, m0_kg=M0_S), lambda_200kV=float(lam200), au_111_d=au_d,
               r3=dict(cases=r3, invalid=r3_bad, query_radii=list(QUERY_RADII_PX)), r4=r4, r5=r5,
               r6=dict(t1=r6_t1, t4=r6_t4, t1_dropped_hazards=hz, k=K_SIGMA, ln19=LN19, s=list(S1), u=list(U1), tol_pct=[TOL_PCT[u] for u in U1]),
               r7=dict(standards=r7, note="counts at k_max 1.2 and 2.0; Mg and Cu3Au-occ are extra controls (the occupancy mutation needs one)"),
               r9=dict(files=files, max_bytes=MAX_CIF_BYTES), ellipse_distance_vectors=dv, mutation_moves=mm)
    if FAILURES:
        with open(os.path.join(out, "FAILED.txt"), "w") as fh:
            fh.write("\n".join(FAILURES) + "\n")
        print("reference.py: %d self-check failure(s)" % len(FAILURES))
        sys.exit(1)
    with open(os.path.join(out, "reference.json"), "w") as fh:
        fh.write(dumps(ref) + "\n")
    print("reference.py: all self-checks pass; wrote %s" % os.path.join(out, "reference.json"))


if __name__ == "__main__":
    main()
