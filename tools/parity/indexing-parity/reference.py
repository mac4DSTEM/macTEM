#!/usr/bin/env python3
"""Truth for tools/parity/indexing-parity: indexing a measured |q| against the kinematic reflection list (V1-8 S2).

    reference.py <scattering_factors.txt> <out-dir> <beta_double_prime_Mg5Si6.cif>

Written from the registration text (archive: roadmap-registrations-2026-10-15.md V1-8 "S2, indexing a measured |q| against the kinematic list", ADR 022, and
"S2c, CIF import and monoclinic (unique axis b) cells", ADR 024), NOT from Sources/TEMCore/Analysis/DSpacingIndexing.swift
and not from the registration prototype. S2c adds: the monoclinic lattice (alpha = gamma = 90 deg within 1e-9 deg, beta off
90 deg by more than 1e-9 deg and in (0, 180); unique axis c, unique axis a, triclinic and orthorhombic stay refused), its
point group 2/m (generators (h,k,l) -> (-h,k,-l) and (h,k,l) -> (h,-k,l); orbit of 4, or 2 when k = 0 or h = l = 0; the
canonical form (|h|, |k|, L) with L = l if h > 0, -l if h < 0, |l| if h = 0), the family name "{h k l}" (a family's orbits
joined by " + "), and gemmi 0.7.5 as the independent reader of the beta'' CIF (cell, sites, space-group absences, orbits). The kinematic list is
S1's, as tools/parity/crystal-parity/reference.py defines it (lattice from the cell, B = inv(A).T, Lobato-Van Dyck f_e from
py4DSTEM's scattering_factors.txt held to its sha256, |F| > 1e-4, 0 < |g| <= kMax; the functions lattice, load_table,
f_e and the reflection sum are copied from there, the sum with one guard: a site whose Z is outside 1..103 scores
f = 0, as S1 would, so the element mutation can be evaluated).

Run with the lock's interpreter:  References/python-venv/bin/python -I -B reference.py <table> <out-dir>   (numpy 2.5.4)

THE DEFINITION IMPLEMENTED (k = 3, ln 19, kMax = 1.2 1/A unless a crystal says otherwise)
  list builder (DiffractoKit's kinematicReflections(kMax:) since ADR 025; was families(of:kMax:)), refusals in this
    order: unsupportedElement (a site Z outside 1..103), then invalidInput (kMax not finite or outside (0, 4]); there is no
    lattice refusal any more (every crystal system is indexed): a cell that is not cubic, hexagonal or monoclinic with unique
    axis b is "built" and has NO numpy list here (this reference orbits only those three: cubic = a=b=c and alpha=beta=gamma=90
    deg; hexagonal = a=b, alpha=beta=90, gamma=120; monoclinic b; lengths within 1e-9 relative, angles within 1e-9 deg).
  families: S1's list swept in |g| order; a reflection joins the current family while |g| <= g0 (1 + 1e-9), g0 the
    family's first (its smallest), else starts the next. family g = smallest member |g|; multiplicity = member count;
    intensity = sum |F|^2; orbits = canonical names of the holohedry orbits: cubic (|h|,|k|,|l|) sorted descending;
    hexagonal (H, K, -H-K, |l|) with i = -(h+k), the triple (h,k,i) negated when fewer than two entries are >= 0, H >= K
    its two largest. Orbits listed in descending lexicographic order. Families are in ascending g.
  index(q, sigma, k), first that applies: invalidInput (q, sigma, k not all finite and > 0); ambiguous (>= 2 families with
    z <= k: payload all of them in (z, g) order; or exactly one within whose margin (z_next^2 - z^2)/2 to the listed next
    (the 2nd candidate in (z, g) order) is < ln 19: payload [best, next]); beyondKMax (q + R > kMax, R = max(r sigma,
    |q - g| of every family the verdict names: best and next if accepted, the nearest if none), r = sqrt(k^2 + 2 ln 19));
    noneWithinTolerance (no family within k sigma; payload the nearest or none for an empty list); accepted (best, next
    (nil when the list holds no other family), margin = (z_next^2 - z^2)/2).  z = |q - g|/sigma, delta = g/q - 1.

OUTPUT (out-dir)
  manifest.json   (non-finite floats are written as the strings "NaN", "Infinity", "-Infinity"; everything else is
                  Python's json repr, round-trip exact)
    gemmi {version, cell, space_group, crystal_system (gemmi's crystal_system_str() of the beta'' CIF's space group), sites,
      rotations, allowed, below_cut, hand_d},
    numpy, python, table_sha256, kmax (1.2), k (3), ln19, cut (1e-4), group_tol (1e-9), seeds {t2, t3, t5},
    W (row width), pad (payload slots), columns [names in file order], rows, tiers {tier: count},
    verdict_codes {"0": accepted, "1": invalidInput, "2": unused (was unsupportedLattice), "3": unused (was unsupportedElement,
      list level), "4": ambiguous, "5": beyondKMax, "6": noneWithinTolerance, "-1": list refused (not computed)},
    crystals [{index, name, cell [a,b,c,alpha,beta,gamma], sites [[Z,x,y,z,occ]...], kmax (number or the strings above),
      expected_list_refusal (null | "invalidInput" | "unsupportedElement" | "built": the list is built and has no numpy
      reading here), lattice (the cell's classification: "cubic" | "hexagonal" | "monoclinic" | null, independent of the refusal),
      families [{g, members [[h,k,l]...] (lexicographic), orbits [[...]...] (descending lexicographic; 3 ints cubic,
        4 ints hexagonal), orbit_member_counts [n per orbit, parallel], multiplicity, intensity}]}]  (families is []
      when the list is refused)
    cells [{id, tier, crystal, u, f, sign_split, sigma_meas_kind ("zero"|"rel"|"abs"), sigma_meas, patterns}] (tiers 2, 3)
    t4 [{plant (row index), label, expect (verdict name or "listRefused")}]
    t1 {u: [...], s: [...]};  selfcheck {...}: the T1 counts and the redraw count.
  plants.f64     little-endian float64, rows of W values, in this column order (everything is a float64; integers are
                 exact; "-1" is the absent index; NaN the absent number):
    0 tier (1 T1, 2 T2, 3 T3, 4 T4, 5 T5)       1 crystal (index into crystals)
    2 q   3 sigma   4 k                            5 truth family index (-1 none)   6 truth z (NaN if none)
    7 verdict code (above; -1 = the crystal's list is refused: expected_list_refusal, nothing else to compare)
    8 best index   9 z   10 delta                  (verdict 0 only; else -1/NaN)
    11 next index (-1 if the list has no other family)  12 z_next  13 delta_next  14 margin (NaN if no next)   (verdict 0 only)
    15 nearest index (-1 if empty list or invalidInput)  16 z_nearest  17 delta_nearest   (verdicts 0, 4, 5, 6: the first
       candidate in (z, g) order)
    18 reach q + R (NaN unless the beyond test was reached: verdicts 0, 5, 6)
    19 payload count (verdict 4 only: the ambiguous families; 0 otherwise)   20 payload offset: the first of those family
       indices in payload.i32 (little-endian int32, written beside plants.f64; S2c, the beta'' list has up to 158 per verdict)
    then s, u, eps, n, pattern, plant, sigma_meas, cell   (the last 8 columns, in this order):
      s (T1), u (T1: sigma/q; T2: u_cal; T3: u_claimed; T5: sigma/q; T4: planted sigma/q or NaN),
      eps (T2/T3: the pattern's calibration error), n (T2/T3: the ring's measurement noise), pattern (global pattern id
      for T2/T3 rings, -1 else), plant (the row index), sigma_meas (T2/T3: the absolute sigma_meas used for the ring),
      cell (index into cells for T2/T3, -1 else).
  Rows: T1 (6 crystals x every family x 5 u x 9 s), T4 (labels in manifest t4), T2, T3, T5, in that order.
  Plants of a crystal whose list is refused are not generated, except the registered first-that-applies pairs (sigma = 0
  on a lattice/element-refused cell: the list builder refuses first); those rows carry verdict -1.

Before anything counts, the reference must agree with itself (FAILED.txt is written and the exit status is 1 if not): the
float grouping equals the exact-invariant grouping; orbits equal the closure of the point-group generators; the scalar
re-implementation of the decision equals the vectorised one; T1 counts equal the registered prediction; P1 on numpy; every
T4 plant is refused by its own name; every registered mutation moves at least one plant, family or crystal.
"""
import hashlib
import json
import math
import os
import sys
import time
from collections import Counter, defaultdict

from fractions import Fraction

import numpy as np

assert np.__version__ == "2.5.4", f"numpy {np.__version__}: the lock is 2.5.4"
import gemmi   # 0.7.5, tools/lib/references-lock.txt: the independent reader of the beta'' CIF (S2c)

assert gemmi.__version__ == "0.7.5", f"gemmi {gemmi.__version__}: the lock is 0.7.5"

TABLE_SHA256 = "be845d1d541cdb75ae16f8928cd9e56a9ea38af8a3cc43da9137e73cc72bb6f4"
KMAX = 1.2
K = 3.0
LN19 = math.log(19.0)
CUT = 1e-4
GROUP_TOL = 1e-9
SEED_T2 = 2026101402
SEED_T3 = 2026101403
SEED_T5 = 2026101405
SEED_T2M, SEED_T3M, SEED_T5M = 2026101601, 2026101602, 2026101603      # S2c's monoclinic tiers (fixed in the build commit)

U1 = (1e-4, 1e-3, 3e-3, 1e-2, 3e-2)
S1 = (-2.9, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 2.9)
U_CAL = (0.002, 0.005, 0.01)
SM2 = (("zero", 0.0), ("rel", 0.0005), ("rel", 0.002), ("abs", 0.001))
NPAT2 = 300
F3 = (2, 4, 6, 10)
UC3 = (0.002, 0.005)
NPAT3 = 50
SM3 = 0.0005
U5 = (1e-3, 3e-3, 1e-2, 3e-2)
N5 = 2000
HZ_Z, HZ_MARGIN, HZ_REACH = 1e-6, 1e-6, 1e-9

# the registered T1 prediction per u: (accepted as own, accepted as another family, ambiguous, beyondKMax, none)
T1_PREDICT = {
    1e-4: (711, 0, 0, 36, 0),
    1e-3: (691, 0, 20, 36, 0),
    3e-3: (647, 0, 64, 36, 0),
    1e-2: (408, 0, 309, 30, 0),
    3e-2: (131, 19, 572, 11, 14),
}

# S2c: T1 over the four monoclinic crystals (M-P, M-C, M-sq, beta''), 9810 plants per u: (accepted as own, accepted as
# another family, ambiguous, beyondKMax, none) and, per crystal, accepted in all (own + other), registered 2026-10-14.
T1M_PREDICT = {
    1e-4: (7486, 0, 2309, 15, 0),
    1e-3: (1870, 0, 7931, 9, 0),
    3e-3: (673, 0, 9130, 7, 0),
    1e-2: (204, 0, 9604, 2, 0),
    3e-2: (61, 10, 9729, 0, 10),
}
T1M_ACCEPTED = {                       # u: (M-P, M-C, M-sq, beta'')
    1e-4: (2625, 1547, 730, 2584), 1e-3: (445, 474, 443, 508), 3e-3: (159, 173, 157, 184),
    1e-2: (56, 54, 36, 58), 3e-2: (17, 17, 12, 25),
}
MONO_LIST = {"M-P": (392, 1384), "M-C": (198, 702), "M-sq": (83, 698), "beta''": (417, 1442)}   # families, reflections

VERDICT = {0: "accepted", 1: "invalidInput", 4: "ambiguous", 5: "beyondKMax", 6: "noneWithinTolerance",
           -1: "listRefused", -2: "listBuiltUnderMutant"}
ACC, INV, AMB, BEY, NON, REF = 0, 1, 4, 5, 6, -1

FCC = [(0, 0, 0), (.5, .5, 0), (.5, 0, .5), (0, .5, .5)]
DIAMOND = FCC + [(x + .25, y + .25, z + .25) for (x, y, z) in FCC]
HCP = [(0, 0, 0), (2 / 3, 1 / 3, .5)]

FAILURES = []


def fail(msg):
    FAILURES.append(msg)
    print(f"  SELF-CHECK FAILED: {msg}", flush=True)


def check(cond, msg):
    if not cond:
        fail(msg)
    return bool(cond)


# --------------------------------------------------------------------------------------------- S1's definitions (copied)
def sites(z, positions, occ=1.0):
    return [(z, p, occ) for p in positions]


def lattice(a, b, c, al, be, ga):
    ca, cb, cg = (math.cos(math.radians(x)) for x in (al, be, ga))
    sg = math.sin(math.radians(ga))
    vol = a * b * c * math.sqrt(1 - ca * ca - cb * cb - cg * cg + 2 * ca * cb * cg)
    A = np.array([[a, 0, 0],
                  [b * cg, b * sg, 0],
                  [c * cb, c * (ca - cb * cg) / sg, vol / (a * b * sg)]])
    return A, vol


def load_table(path):
    data = open(path, "rb").read()
    got = hashlib.sha256(data).hexdigest()
    if got != TABLE_SHA256:
        sys.exit(f"reference.py: {path} has sha256 {got}, the lock is {TABLE_SHA256}")
    t = np.loadtxt(path, dtype=np.float64)
    assert t.shape == (103, 10), t.shape
    return t


def f_e(table, z, g2):
    row = table[z - 1]
    a, b = row[0:10:2], row[1:10:2]
    g2 = np.asarray(g2, dtype=np.float64)
    return sum(a[i] * (2 + b[i] * g2) / (1 + b[i] * g2) ** 2 for i in range(5))


def site_fe(table, z, g2):
    if 1 <= z <= 103:
        return f_e(table, z, g2)
    return np.zeros_like(np.asarray(g2, dtype=np.float64))      # S1 scores an unknown element as f = 0


def weak_cut_occupancy(table):
    a = 3.0
    return 1 - 2.5e-4 * a**3 / float(f_e(table, 29, (1 / a) ** 2))


def raw_reflections(table, c):
    """S1's reflections(kMax) before the cut: (hkl int64, |g|, F) for every hkl != 0 with |g| <= kMax."""
    import itertools
    A, vol = lattice(*c["cell"])
    B = np.linalg.inv(A).T
    kmax = c["kmax"]
    n = [int(math.ceil(kmax * np.linalg.norm(A[i]))) + 1 for i in range(3)]
    hkl = np.array([p for p in itertools.product(*(range(-m, m + 1) for m in n)) if p != (0, 0, 0)], dtype=np.float64)
    g = hkl @ B
    glen = np.linalg.norm(g, axis=1)
    keep = glen <= kmax
    hkl, glen = hkl[keep], glen[keep]
    F = np.zeros(len(hkl), dtype=np.complex128)
    for (z, pos, occ) in c["sites"]:
        F += site_fe(table, z, glen ** 2) * occ * np.exp(2j * np.pi * (hkl @ np.array(pos)))
    F /= vol
    return hkl.astype(np.int64), glen, F


# ------------------------------------------------------------------------------------------------------------ crystals
def beta_from_cif(cif_path):
    """The beta'' CIF read by gemmi, not by CIFImport: its cell, the 22 unit-cell sites (the symmetry operations expanded)."""
    st = gemmi.read_small_structure(cif_path)
    cell = (st.cell.a, st.cell.b, st.cell.c, st.cell.alpha, st.cell.beta, st.cell.gamma)
    sites_ = [(s.element.atomic_number, (s.fract.x, s.fract.y, s.fract.z), s.occ) for s in st.get_all_unit_cell_sites()]
    return st, cell, sites_


def make_crystals(table, cif_path):
    wq = weak_cut_occupancy(table)
    a_au, a_mg, c_mg = 4.0782, 3.2094, 5.2108
    cs = []

    def add(name, cell, site_list, kmax=KMAX, ideal=False, role=""):
        cs.append(dict(name=name, cell=tuple(float(x) for x in cell), sites=site_list, kmax=float(kmax),
                       ideal=ideal, role=role))
    add("Au", (a_au,) * 3 + (90, 90, 90), sites(79, FCC), role="base")
    add("Al", (4.0495,) * 3 + (90, 90, 90), sites(13, FCC), role="base")
    add("Si", (5.4309,) * 3 + (90, 90, 90), sites(14, DIAMOND), role="base")
    add("Mg", (a_mg, a_mg, c_mg, 90, 90, 120), sites(12, HCP), role="base")
    add("Mg-ideal", (a_mg, a_mg, a_mg * math.sqrt(8 / 3), 90, 90, 120), sites(12, HCP), ideal=True, role="base")
    add("Weak-cut", (3.0,) * 3 + (90, 90, 90), sites(29, [(0, 0, 0)]) + sites(29, [(.5, .5, .5)], wq), role="base")
    add("Tetragonal", (4.0, 4.0, 5.0, 90, 90, 90), sites(29, [(0, 0, 0)]), role="T4")
    add("Orthorhombic", (3.0, 4.0, 5.0, 90, 90, 90), sites(29, [(0, 0, 0)]), role="T4")
    add("Au-b+1e-6", (a_au, a_au * (1 + 1e-6), a_au, 90, 90, 90), sites(79, FCC), role="T4")
    add("Au-b+1e-11", (a_au, a_au * (1 + 1e-11), a_au, 90, 90, 90), sites(79, FCC), role="T4")
    add("Mg-gamma+1e-10", (a_mg, a_mg, c_mg, 90, 90, 120 + 1e-10), sites(12, HCP), role="T4")
    add("Au-Z104", (a_au,) * 3 + (90, 90, 90), sites(79, FCC) + [(104, (.5, .5, .5), 1.0)], role="T4")
    add("Au-kmax0.45", (a_au,) * 3 + (90, 90, 90), sites(79, FCC), kmax=0.45, role="T4")
    add("Au-kmax0.3", (a_au,) * 3 + (90, 90, 90), sites(79, FCC), kmax=0.3, role="T4")
    for km in (0.0, -1.0, float("nan"), float("inf"), float("-inf"), 5.0, 1e6, 1e19):
        add(f"Au-kmax{km!r}", (a_au,) * 3 + (90, 90, 90), sites(79, FCC), kmax=km, role="T4")
    add("Tetragonal-kmax0", (4.0, 4.0, 5.0, 90, 90, 90), sites(29, [(0, 0, 0)]), kmax=0.0, role="T4")
    add("Tetragonal-Z104", (4.0, 4.0, 5.0, 90, 90, 90), sites(29, [(0, 0, 0)]) + [(104, (.5, .5, .5), 1.0)], role="T4")
    # S2c: the monoclinic (unique axis b) crystals, then their T4 cells. Al, Z = 13, one atom at the origin (+ the C centring).
    al, alc = sites(13, [(0, 0, 0)]), sites(13, [(0, 0, 0), (.5, .5, 0)])
    pcell = (7.2, 4.9, 5.6, 90, 104.0, 90)
    add("M-P", pcell, al, role="mono")
    add("M-C", pcell, alc, role="mono")
    add("M-sq", (5.0, 4.0, 5.0, 90, math.degrees(math.acos(-0.25)), 90), al, role="mono")
    _, bcell, bsites = beta_from_cif(cif_path)
    add("beta''", bcell, bsites, role="mono")
    add("M-P-b+1e-4", (7.2, 4.9, 5.6, 90, 90 + 1e-4, 90), al, role="T4")
    add("M-P-b+1e-8", (7.2, 4.9, 5.6, 90, 90 + 1e-8, 90), al, role="T4")
    add("M-P-b90", (7.2, 4.9, 5.6, 90, 90, 90), al, role="T4")
    add("M-P-b+1e-10", (7.2, 4.9, 5.6, 90, 90 + 1e-10, 90), al, role="T4")
    add("UniqueC", (7.2, 4.9, 5.6, 90, 90, 100), al, role="T4")
    add("UniqueA", (7.2, 4.9, 5.6, 100, 90, 90), al, role="T4")
    add("Triclinic", (7.2, 4.9, 5.6, 92, 95, 101), al, role="T4")
    add("M-P-g+1e-8", (7.2, 4.9, 5.6, 90, 104.0, 90 + 1e-8), al, role="T4")
    add("M-P-a-1e-8", (7.2, 4.9, 5.6, 90 - 1e-8, 104.0, 90), al, role="T4")
    add("beta''-Z104", bcell, bsites + [(104, (.5, .5, .5), 1.0)], role="T4")
    add("Triclinic-Z104", (7.2, 4.9, 5.6, 92, 95, 101), al + [(104, (.5, .5, .5), 1.0)], role="T4")
    add("beta''-kmax0", bcell, bsites, kmax=0.0, role="T4")
    # Added after Gate B (F1), last so no earlier crystal index moves: M-P at beta 76 deg, the mirror of beta 104 deg.
    add("M-P-acute", (7.2, 4.9, 5.6, 90, 76.0, 90), al, role="acute")
    return cs


def lattice_class(cell, exact=False, mut=frozenset()):
    a, b, c, al, be, ga = cell
    tl, ta = (0.0, 0.0) if exact else ((1e-7, 1e-7) if "lattice_tol_1e-7" in mut else (1e-9, 1e-9))

    def rel(x, y):
        return abs(x - y) <= tl * max(abs(x), abs(y))
    if rel(a, b) and rel(a, c) and all(abs(x - 90.0) <= ta for x in (al, be, ga)):
        return "cubic"
    if rel(a, b) and abs(al - 90.0) <= ta and abs(be - 90.0) <= ta and abs(ga - 120.0) <= ta:
        return "hexagonal"
    # S2c: monoclinic, unique axis b: alpha = gamma = 90 (within ta), beta off 90 by more than ta, 0 < beta < 180.
    a90, b90, g90 = abs(al - 90.0) <= ta, abs(be - 90.0) <= ta, abs(ga - 90.0) <= ta
    if "mono_at_beta90" in mut:
        b90 = False
    if "mono_no_alpha_gamma" in mut:
        a90 = g90 = True
    if "mono_unique_c" in mut:
        ok = a90 and (g90 != b90)
    else:
        ok = a90 and g90 and not b90
    if ok and 0.0 < be < 180.0:
        return "monoclinic"
    return None


def kmax_valid(km, mut=frozenset()):
    if not math.isfinite(km) or km <= 0:
        return False
    return km <= 4.0 or "kmax_bound_dropped" in mut


def refusal(c, mut=frozenset()):
    """DiffractoKit's list builder: the element first, then k_max. No lattice refusal (ADR 025)."""
    bad_z = "unsupported_elements_ignored" not in mut and any(not (1 <= z <= 103) for (z, _, _) in c["sites"])
    if bad_z:
        return "unsupportedElement"
    if not kmax_valid(c["kmax"], mut):
        return "invalidInput"
    return None


# ------------------------------------------------------------------------------------------------------ orbits, families
def cubic_name(h, k, l):
    return tuple(sorted((abs(h), abs(k), abs(l)), reverse=True))


def hex_name(h, k, l, negate=True):
    t = [h, k, -(h + k)]
    if negate and sum(1 for x in t if x >= 0) < 2:
        t = [-x for x in t]
    t.sort(reverse=True)
    return (t[0], t[1], -t[0] - t[1], abs(l))


def mono_name(h, k, l, mut=frozenset()):
    """S2c: the canonical form of the 2/m orbit (unique axis b): (|h|, |k|, L), L = l (h > 0), -l (h < 0), |l| (h = 0)."""
    if "mono_cubic_rule" in mut:
        return cubic_name(h, k, l)
    kk = k if "mono_mirror_missing" in mut else abs(k)
    if h > 0:
        return (h, kk, l)
    if h < 0:
        return (-h, (k if "mono_k_signed_negh" in mut else kk), (l if "mono_no_flip" in mut else -l))
    return (0, abs(k), l if "mono_h0_l_signed" in mut else abs(l))


MONO_GENS = [lambda t: (-t[0], t[1], -t[2]), lambda t: (t[0], -t[1], t[2])]
# DiffractoKit 0.3.0: the a<->c mirror is a true symmetry of M-sq (one atom at the origin, a = c); 0.1.0 read 2/m.
# M-sq's orbits are the closures under the 2/m generators plus the swap (h, k, l) -> (l, k, h) (the metric is C-centred
# orthorhombic mmm); its name is the kit's rule: the orbit member greatest under (number of non-negative indices, h, k, l).
SQ_GENS = MONO_GENS + [lambda t: (t[2], t[1], t[0])]


def sq_name(h, k, l, mut=frozenset()):
    orb = closure((h, k, l), SQ_GENS)
    return max(orb, key=lambda t: (sum(1 for x in t if x >= 0),) + t)
CUBIC_GENS = [lambda t: (t[1], t[0], t[2]), lambda t: (t[1], t[2], t[0]), lambda t: (-t[0], t[1], t[2])]
HEX_GENS = [lambda t: (-t[1], t[0] + t[1], t[2]), lambda t: (t[1], t[0], t[2]),
            lambda t: (t[0], t[1], -t[2]), lambda t: (-t[0], -t[1], -t[2])]


def closure(t, gens):
    seen = {t}
    stack = [t]
    while stack:
        x = stack.pop()
        for f in gens:
            y = f(x)
            if y not in seen:
                seen.add(y)
                stack.append(y)
    return frozenset(seen)


class FamList:
    def __init__(self, fams, lat):
        self.fams = fams
        self.lat = lat
        self.g = np.array([f["g"] for f in fams], dtype=np.float64)
        self.mult = np.array([f["multiplicity"] for f in fams], dtype=np.int64)
        for f in fams:
            f["set"] = {tuple(m) for m in f["members"]}


def build_families(raw, lat, mut=frozenset(), sq=False):
    hkl, glen, F = raw
    cut = -1.0 if "absences_kept" in mut else (1e-2 if "cut_1e-2" in mut else CUT)
    tol = (0.0 if "group_tol_0" in mut else (1e-2 if "group_tol_1e-2" in mut else
           (1e-4 if "group_tol_1e-4" in mut else (0.3 if "group_tol_0.3" in mut else GROUP_TOL))))
    aF = np.abs(F)
    keep = aF > cut
    hk, g, aFk = hkl[keep], glen[keep], aF[keep]
    order = np.argsort(g, kind="stable")
    fam_id = np.empty(len(g), dtype=np.int64)
    cur, g0 = -1, 0.0
    for idx in order:
        if cur >= 0 and g[idx] <= g0 * (1 + tol):
            fam_id[idx] = cur
        else:
            cur += 1
            g0 = g[idx]
            fam_id[idx] = cur
    if lat == "monoclinic" and sq:
        namef = lambda h, k, l: sq_name(h, k, l, mut)
    elif lat == "monoclinic":
        namef = lambda h, k, l: mono_name(h, k, l, mut)
    elif "hex_cubic_rule" in mut and lat == "hexagonal":
        namef = cubic_name
    elif lat == "hexagonal":
        namef = (lambda h, k, l: hex_name(h, k, l, negate=False)) if "hex_no_negation" in mut else hex_name
    else:
        namef = cubic_name
    groups = defaultdict(list)
    for i in range(len(g)):
        groups[fam_id[i]].append(i)
    fams = []
    for fid in range(cur + 1):
        ids = groups[fid]
        g_first = g[min(ids, key=lambda i: (g[i], i))]
        mem = sorted(tuple(int(x) for x in hk[i]) for i in ids)
        cnt = Counter(namef(*m) for m in mem)
        names = sorted(cnt, reverse=True)
        mult = len(names) if "mult_orbit_count" in mut else len(mem)
        braces = ["{" + " ".join(str(x) for x in n) + "}" for n in names]
        fams.append(dict(g=float(g_first), members=[list(m) for m in mem], orbits=[list(n) for n in names],
                         orbit_member_counts=[cnt[n] for n in names], multiplicity=mult,
                         name=" + ".join(braces[:1] if "name_first_orbit" in mut else braces),
                         intensity=float(np.sum(aFk[ids] ** 2))))
    return FamList(fams, lat)


# ---------------------------------------------------------------------------------------------------------- the decision
def decide(fl, q, sigma, k, kmax, mut=frozenset()):
    """Vectorised index(): the registered rule, one crystal's list, arrays of plants. Returns a dict of arrays.
    The mut set holds registered mutations (self-check only)."""
    q = np.asarray(q, dtype=np.float64)
    sigma = np.asarray(sigma, dtype=np.float64)
    k = np.broadcast_to(np.asarray(k, dtype=np.float64), q.shape).copy()
    P = q.shape[0]
    g, F = fl.g, fl.g.shape[0]
    nan = np.nan
    out = dict(verdict=np.full(P, -9, np.int64), best=np.full(P, -1, np.int64), z=np.full(P, nan),
               delta=np.full(P, nan), next=np.full(P, -1, np.int64), z_next=np.full(P, nan),
               delta_next=np.full(P, nan), margin=np.full(P, nan), nearest=np.full(P, -1, np.int64),
               z_nearest=np.full(P, nan), delta_nearest=np.full(P, nan), reach=np.full(P, nan),
               pay_count=np.zeros(P, np.int64), hz_k=np.full(P, np.inf), hz_margin=np.full(P, np.inf),
               hz_reach=np.full(P, np.inf))
    with np.errstate(all="ignore"):
        sig_ok = (sigma >= 0) if "sigma0_accepted" in mut else (sigma > 0)
        valid = np.isfinite(q) & (q > 0) & np.isfinite(sigma) & sig_ok & np.isfinite(k) & (k > 0)
        r = np.sqrt(k * k + 2 * LN19)
        rs = (k if "reach_k_sigma" in mut else r) * sigma
        if F == 0:
            reach = q + rs
            beyond = valid & (reach > kmax)
            out["verdict"][:] = np.where(valid, np.where(beyond, BEY, NON), INV)
            out["reach"] = np.where(valid, reach, nan)
            out["hz_reach"] = np.where(valid, np.abs(reach - kmax), np.inf)
            out["payload"] = np.full((P, 0), -1, np.int64)
            return out
        rows = np.arange(P)
        dist = np.abs(q[:, None] - g[None, :])
        z = dist / (sigma * q)[:, None] if "z_over_sigma_q" in mut else dist / sigma[:, None]
        within = (z * z <= k[:, None]) if "z2_le_k" in mut else (z <= k[:, None])
        nw = within.sum(axis=1)
        order = np.argsort(z, axis=1, kind="stable")
        first = order[:, 0]
        if "next_upper" in mut:
            second = np.where(first + 1 < F, first + 1, -1)
        elif F >= 2:
            second = order[:, 1]
        else:
            second = np.full(P, -1)
        has2 = second >= 0
        sec0 = np.maximum(second, 0)
        z1 = z[rows, first]
        z2 = np.where(has2, z[rows, sec0], nan)
        margin = (z2 - z1) if "margin_z_diff" in mut else 0.5 * (z2 * z2 - z1 * z1)
        amb1 = np.zeros(P, bool) if "second_within_dropped" in mut else (nw >= 2)
        if "margin_clause_dropped" in mut:
            amb2 = np.zeros(P, bool)
        else:
            cnt_ok = (nw >= 1) if "second_within_dropped" in mut else (nw == 1)
            amb2 = cnt_ok & has2 & (margin < LN19)
        amb = valid & (amb1 | amb2)
        near = first
        if "nearest_first_ge" in mut:
            near = np.minimum(np.searchsorted(g, q, side="left"), F - 1)
        acc_path = valid & ~amb & (nw == 1)
        none_path = valid & ~amb & (nw == 0)
        if "second_within_dropped" in mut:           # >= 2 within is no longer refused: the best is accepted
            acc_path = valid & ~amb & (nw >= 1)
        if "nearest_first_ge" in mut:
            sw = acc_path & (near != first)
            acc_path, none_path = acc_path & ~sw, none_path | sw
        d1 = np.abs(q - g[first])
        d2 = np.where(has2, np.abs(q - g[sec0]), 0.0)
        dn = np.abs(q - g[near])
        if "reach_k_sigma" in mut:
            R_acc = R_none = rs
        else:
            R_acc = np.maximum(np.maximum(rs, d1), d2)
            R_none = np.maximum(rs, dn)
        reach = np.where(acc_path, q + R_acc, np.where(none_path, q + R_none, nan))
        beyond = (acc_path | none_path) & (reach > kmax)
        verdict = np.full(P, -9, np.int64)
        verdict[~valid] = INV
        verdict[amb] = AMB
        verdict[beyond] = BEY
        verdict[none_path & ~beyond] = NON
        verdict[acc_path & ~beyond] = ACC
        isacc = verdict == ACC

        def dev(gg):
            return (1 - q / gg) if "deviation_over_measured" in mut else (gg / q - 1)
        out["verdict"] = verdict
        out["best"] = np.where(isacc, first, -1)
        out["z"] = np.where(isacc, z1, nan)
        out["delta"] = np.where(isacc, dev(g[first]), nan)
        out["next"] = np.where(isacc & has2, second, -1)
        out["z_next"] = np.where(isacc & has2, z2, nan)
        out["delta_next"] = np.where(isacc & has2, dev(g[sec0]), nan)
        out["margin"] = np.where(isacc & has2, margin, nan)
        has_near = np.isin(verdict, (ACC, AMB, BEY, NON))
        out["nearest"] = np.where(has_near, near, -1)
        out["z_nearest"] = np.where(has_near, z[rows, near], nan)
        out["delta_nearest"] = np.where(has_near, dev(g[near]), nan)
        out["reach"] = np.where(np.isin(verdict, (ACC, BEY, NON)), reach, nan)
        # hazards: any z within 1e-6 of k; the decision-relevant margin within 1e-6 of ln 19; q + R within 1e-9 of kMax
        out["hz_k"] = np.where(valid, np.min(np.abs(z - k[:, None]), axis=1), np.inf)
        out["hz_margin"] = np.where(valid & (nw == 1) & has2, np.abs(margin - LN19), np.inf)
        out["hz_reach"] = np.where(np.isfinite(reach), np.abs(reach - kmax), np.inf)
        cnt = np.where(amb & amb1, nw, np.where(amb, 2, 0))
        out["pay_count"] = cnt
        pm = int(cnt.max()) if P else 0
        pay = np.full((P, pm), -1, np.int64)
        if pm:
            pm_ = min(pm, F)
            sel = order[:, :pm_]
            pay[:, :pm_] = np.where(np.arange(pm_)[None, :] < cnt[:, None], sel, -1)
            m2 = amb & ~amb1
            if m2.any():
                pay[m2, 0] = first[m2]
                pay[m2, 1] = second[m2]
        out["payload"] = pay
    return out


def decide_scalar(g, q, sigma, k, kmax):
    """The text, one plant at a time, in plain Python: (verdict, best, next, payload, z_best, margin)."""
    def ok(x):
        return math.isfinite(x) and x > 0
    if not (ok(q) and ok(sigma) and ok(k)):
        return (INV, -1, -1, [], math.nan, math.nan)
    cands = sorted(((abs(q - gj) / sigma, gj, j) for j, gj in enumerate(g)))
    within = [c for c in cands if c[0] <= k]
    nxt = cands[1] if len(cands) > 1 else None
    if len(within) >= 2:
        return (AMB, -1, -1, [c[2] for c in within], math.nan, math.nan)
    if len(within) == 1 and nxt is not None:
        m = (nxt[0] * nxt[0] - within[0][0] * within[0][0]) / 2
        if m < LN19:
            return (AMB, -1, -1, [within[0][2], nxt[2]], math.nan, math.nan)
    r = math.sqrt(k * k + 2 * LN19)
    named = []
    if cands:
        named.append(cands[0])
        if len(within) == 1 and nxt is not None:
            named.append(nxt)
    R = max([r * sigma] + [abs(q - c[1]) for c in named])
    if q + R > kmax:
        return (BEY, -1, -1, [], math.nan, math.nan)
    if not within:
        return (NON, -1, -1, [], math.nan, math.nan)
    best = within[0]
    if nxt is None:
        return (ACC, best[2], -1, [], best[0], math.nan)
    return (ACC, best[2], nxt[2], [], best[0], (nxt[0] * nxt[0] - best[0] * best[0]) / 2)


# ------------------------------------------------------------------------------------------------------------- plants
FIELDS = ["tier", "crystal", "q", "sigma", "k", "truth_family", "truth_z", "s", "u", "eps", "n", "pattern", "cell",
          "sigma_meas"]


class Acc:
    def __init__(self):
        self.parts = []
        self.t4 = []

    def add(self, N, **kw):
        part = {}
        for f in FIELDS:
            v = kw.get(f, -1.0 if f in ("pattern", "cell", "truth_family") else np.nan)
            part[f] = np.broadcast_to(np.asarray(v, dtype=np.float64), (N,)).copy()
        self.parts.append(part)

    def cat(self):
        return {f: np.concatenate([p[f] for p in self.parts]) for f in FIELDS}


def hazard_rows(fl, kmax, q, sigma):
    r = decide(fl, q, sigma, K, kmax)
    return (r["hz_k"] < HZ_Z) | (r["hz_margin"] < HZ_MARGIN) | (r["hz_reach"] < HZ_REACH)


def draw_patterns(rng, fl, kmax, npat, eps_fn, eps_fixed, sm_abs, uc, stats):
    """npat patterns over the list's rings: one eps per pattern, one n per ring; redraw patterns with a hazard."""
    g = fl.g
    F = len(g)
    eps = eps_fn(npat).copy()
    zn = rng.standard_normal((npat, F))
    while True:
        n = zn * sm_abs[None, :]
        q = g[None, :] * (1 + eps[:, None]) + n
        sigma = np.sqrt((q * uc) ** 2 + sm_abs[None, :] ** 2)
        bad = hazard_rows(fl, kmax, q.ravel(), sigma.ravel()).reshape(npat, F).any(axis=1)
        if not bad.any():
            return eps, n, q, sigma
        nb = int(bad.sum())
        stats["redraws"] += nb
        if not eps_fixed:
            eps[bad] = eps_fn(nb)
        zn[bad] = rng.standard_normal((nb, F))


# ----------------------------------------------------------------------------------------------------- manifest helpers
def jnum(x):
    x = float(x)
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    return x


def main():
    t_start = time.time()
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    table_path, out, cif_path = sys.argv[1], sys.argv[2], os.path.abspath(sys.argv[3])
    os.makedirs(out, exist_ok=True)
    failed_path = os.path.join(out, "FAILED.txt")
    if os.path.exists(failed_path):
        os.remove(failed_path)
    table = load_table(table_path)
    print(f"reference.py: numpy {np.__version__}, table sha256 {TABLE_SHA256[:12]}...")

    CR = make_crystals(table, cif_path)
    NAME = {c["name"]: i for i, c in enumerate(CR)}
    lat_of = [lattice_class(c["cell"]) for c in CR]
    # A cell with no numpy reading (not cubic, hexagonal or monoclinic b) is built by the kit and compared with nothing here:
    # "built", a non-null status, so every place that skips a refused crystal skips it (ADR 025).
    ref_of = [refusal(c) or ("built" if lat_of[i] is None else None) for i, c in enumerate(CR)]
    NMONO = ["M-P", "M-C", "M-sq", "beta''"]
    expected_refusal = {"Tetragonal": "built", "Orthorhombic": "built",
                        "Au-b+1e-6": "built", "Au-b+1e-11": None, "Mg-gamma+1e-10": None,
                        "Au-Z104": "unsupportedElement", "Au-kmax0.45": None, "Au-kmax0.3": None,
                        "Au-kmax0.0": "invalidInput", "Au-kmax-1.0": "invalidInput", "Au-kmaxnan": "invalidInput",
                        "Au-kmaxinf": "invalidInput", "Au-kmax-inf": "invalidInput", "Au-kmax5.0": "invalidInput",
                        "Au-kmax1000000.0": "invalidInput", "Au-kmax1e+19": "invalidInput",
                        "Tetragonal-kmax0": "invalidInput", "Tetragonal-Z104": "unsupportedElement",
                        "M-P-b+1e-4": None, "M-P-b+1e-8": None, "M-P-b90": "built",
                        "M-P-b+1e-10": "built", "UniqueC": "built",
                        "UniqueA": "built", "Triclinic": "built", "M-P-g+1e-8": "built",
                        "M-P-a-1e-8": "built", "beta''-Z104": "unsupportedElement",
                        "Triclinic-Z104": "unsupportedElement", "beta''-kmax0": "invalidInput"}
    for i, c in enumerate(CR):
        want = expected_refusal.get(c["name"], None)
        check(ref_of[i] == want, f"{c['name']}: list refusal {ref_of[i]} but registered {want}")
    check(lat_of[NAME["Au-b+1e-11"]] == "cubic" and lat_of[NAME["Mg-gamma+1e-10"]] == "hexagonal"
          and lat_of[NAME["Au-b+1e-6"]] is None, "lattice classification of the near cells")
    check(all(lat_of[NAME[n]] == "monoclinic" for n in NMONO + ["M-P-acute", "M-P-b+1e-4", "M-P-b+1e-8"])
          and all(lat_of[NAME[n]] is None for n in ("M-P-b90", "M-P-b+1e-10", "UniqueC", "UniqueA", "Triclinic", "M-P-g+1e-8",
                                                    "M-P-a-1e-8")), "lattice classification of the monoclinic cells")

    RAW = {}
    LISTS = {}
    for i, c in enumerate(CR):
        if kmax_valid(c["kmax"]):
            RAW[i] = raw_reflections(table, c)
            if ref_of[i] is None:
                LISTS[i] = build_families(RAW[i], lat_of[i], sq=(CR[i]["name"] == "M-sq"))

    # ---------------------------------------------------------------- the list: facts, grouping, orbits, anchors
    print("== lists ==")
    base = [NAME[n] for n in ("Au", "Al", "Si", "Mg", "Mg-ideal", "Weak-cut")]
    for i in base + [NAME[n] for n in ("Au-b+1e-11", "Mg-gamma+1e-10", "Au-kmax0.45", "Au-kmax0.3")]:
        fl = LISTS[i]
        print(f"  {CR[i]['name']:16s} {len(fl.fams):3d} families, {sum(f['multiplicity'] for f in fl.fams):5d} reflections, "
              f"g {fl.g.min() if len(fl.g) else float('nan'):.5f}..{fl.g.max() if len(fl.g) else float('nan'):.5f}")
    mono = [NAME[n] for n in NMONO]
    for i in mono + [NAME["M-P-b+1e-4"], NAME["M-P-b+1e-8"]]:
        fl = LISTS[i]
        print(f"  {CR[i]['name']:16s} {len(fl.fams):3d} families, {sum(f['multiplicity'] for f in fl.fams):5d} reflections, "
              f"{sum(1 for f in fl.fams if len(f['orbits']) > 1)} with several orbits, "
              f"g {fl.g.min():.5f}..{fl.g.max():.5f}")
    for n, (nf, nr) in MONO_LIST.items():
        fl = LISTS[NAME[n]]
        check(len(fl.fams) == nf and sum(f["multiplicity"] for f in fl.fams) == nr,
              f"{n}: {len(fl.fams)} families / {sum(f['multiplicity'] for f in fl.fams)} reflections, registered {nf} / {nr}")
    # Added after Gate B (F1): M-P at beta 76 deg is M-P at 104 deg with the sign of l mirrored (same d, (h k l) <-> (h k -l)), so
    # the two lists hold the same g's, the member sets are the mirror images, and {1 0 1} / {1 0 -1} swap their d.
    def fam_of_l(fl, hkl):
        h, nh = tuple(hkl), tuple(-x for x in hkl)
        for j, f in enumerate(fl.fams):
            if h in f["set"] or nh in f["set"]:
                return j
        raise KeyError(hkl)

    pa, pm = LISTS[NAME["M-P-acute"]], LISTS[NAME["M-P"]]
    check(len(pa.fams) == len(pm.fams) and all(abs(x["g"] - y["g"]) <= 1e-12 * y["g"] and
                                                {(h, k, -l) for h, k, l in y["set"]} == x["set"]
                                                for x, y in zip(pa.fams, pm.fams)),
          "M-P-acute: the mirror image of M-P's list (same g, members (h k -l))")
    check(pa.fams[fam_of_l(pa, (1, 0, 1))]["name"] == "{1 0 1}" and pa.fams[fam_of_l(pa, (1, 0, -1))]["name"] == "{1 0 -1}"
          and abs(pa.fams[fam_of_l(pa, (1, 0, 1))]["g"] - pm.fams[fam_of_l(pm, (1, 0, -1))]["g"]) <= 1e-12
          and abs(pa.fams[fam_of_l(pa, (1, 0, -1))]["g"] - pm.fams[fam_of_l(pm, (1, 0, 1))]["g"]) <= 1e-12
          and abs(pa.fams[fam_of_l(pa, (1, 0, 1))]["g"] - pa.fams[fam_of_l(pa, (1, 0, -1))]["g"]) > 1e-3,
          "M-P-acute: {1 0 1} has the g of 104 deg's {1 0 -1} and the other way round")
    # DiffractoKit 0.3.0: the a<->c mirror is a true symmetry of M-sq (one atom at the origin, a = c); 0.1.0 read 2/m
    # and 62 families held several orbits; under mmm (2/m plus the swap) 28 still do (accidental coincidences).
    check(sum(1 for f in LISTS[NAME["M-sq"]].fams if len(f["orbits"]) > 1) == 28, "M-sq: 28 several-orbit families")
    for n, h2 in (("M-P-b+1e-4", (402, 0)), ("M-P-b+1e-8", (239, 163))):
        fl = LISTS[NAME[n]]
        check((len(fl.fams), sum(1 for f in fl.fams if len(f["orbits"]) > 1)) == h2, f"{n}: families / two-orbit families {h2}")
    bm = LISTS[NAME["beta''"]]
    check(sum(1 for f in bm.fams if f["multiplicity"] == 2) == 113 and sum(1 for f in bm.fams if f["multiplicity"] == 4) == 304
          and not any(len(f["orbits"]) > 1 for f in bm.fams), "beta'': 113 of multiplicity 2, 304 of 4, none with several orbits")
    nfam_base = sum(len(LISTS[i].fams) for i in base)
    check(nfam_base == 83, f"six crystals hold {nfam_base} families, T1's 747 = 83 x 9 needs 83")
    check(len(LISTS[NAME["Au"]].fams) == 8, "Au 8 families")
    f_au = LISTS[NAME["Au"]]
    check(f_au.fams[0]["multiplicity"] == 8, "Au {111} multiplicity 8")
    check(len(LISTS[NAME["Au-kmax0.45"]].fams) == 1 and len(LISTS[NAME["Au-kmax0.3"]].fams) == 0, "Au kmax 0.45 one family, 0.3 none")

    def fam_of(ci, hkl):
        h, nh = tuple(hkl), tuple(-x for x in hkl)
        for j, f in enumerate(LISTS[ci].fams):
            if h in f["set"] or nh in f["set"]:
                return j
        raise KeyError((CR[ci]["name"], hkl))

    mg, mgi, si = NAME["Mg"], NAME["Mg-ideal"], NAME["Si"]
    check(LISTS[mg].fams[fam_of(mg, (1, 0, 0))]["multiplicity"] == 6, "Mg {10-10} multiplicity 6")
    check(LISTS[mg].fams[fam_of(mg, (0, 0, 2))]["multiplicity"] == 2, "Mg {0002} multiplicity 2")
    f333 = LISTS[si].fams[fam_of(si, (3, 3, 3))]
    check(f333["multiplicity"] == 32 and f333 is LISTS[si].fams[fam_of(si, (5, 1, 1))], "Si {333}+{511} one family of 32")
    fid = LISTS[mgi].fams[fam_of(mgi, (3, 0, 2))]
    check(fid is LISTS[mgi].fams[fam_of(mgi, (0, 0, 6))] and fid["multiplicity"] == 14 and len(fid["orbits"]) == 2,
          "ideal hcp {30-32}+{0006} one family of 14 with two orbits")
    check(fam_of(mg, (3, 0, 2)) != fam_of(mg, (0, 0, 6)), "real Mg {30-32} and {0006} are two families")
    check([1, 0, -1, 1] in LISTS[mg].fams[fam_of(mg, (1, 0, 1))]["orbits"] and
          [1, 1, -2, 0] in LISTS[mg].fams[fam_of(mg, (1, 1, 0))]["orbits"], "Mg {10-11} and {11-20} named so")
    # hand anchors: d = 1/g
    d_au = 1 / LISTS[NAME["Au"]].fams[0]["g"]
    d_si = 1 / LISTS[si].fams[0]["g"]
    d_mg = 1 / LISTS[mg].fams[fam_of(mg, (1, 0, 0))]["g"]
    check(abs(d_au - 4.0782 / math.sqrt(3)) < 1e-12 * d_au, "Au {111} d = a/sqrt(3)")
    check(abs(d_si - 5.4309 / math.sqrt(3)) < 1e-12 * d_si, "Si {111} d = a/sqrt(3)")
    check(abs(d_mg - 3.2094 * math.sqrt(3) / 2) < 1e-12 * d_mg, "Mg {10-10} d = a sqrt(3)/2")

    def invariant(i, m):
        h, k, l = m
        if lat_of[i] == "cubic":
            return h * h + k * k + l * l
        mm = h * h + h * k + k * k
        return (32 * mm + 9 * l * l) if CR[i]["ideal"] else (mm, l * l)
    inv_checked = [NAME[n] for n in ("Au", "Al", "Si", "Mg", "Mg-ideal", "Weak-cut", "Au-b+1e-11", "Mg-gamma+1e-10",
                                     "Au-kmax0.45")]
    for i in inv_checked:
        fl = LISTS[i]
        by_inv = defaultdict(set)
        for f in fl.fams:
            for m in f["set"]:
                by_inv[invariant(i, m)].add(m)
        part_inv = {frozenset(v) for v in by_inv.values()}
        part_float = {frozenset(f["set"]) for f in fl.fams}
        check(part_inv == part_float, f"{CR[i]['name']}: float grouping != exact-invariant grouping")
        # orbits: closure of the generators, name constant on an orbit, distinct between orbits
        gens, namef, gsize = (CUBIC_GENS, cubic_name, 48) if lat_of[i] == "cubic" else (HEX_GENS, hex_name, 24)
        sizes = {len(closure((1, 2, 3), gens))}
        check(sizes == {gsize}, f"{CR[i]['name']}: generator closure of (1,2,3) has {sizes} elements, not {gsize}")
        orbit_of, name_to_orbit = {}, {}
        for f in fl.fams:
            for m in f["set"]:
                if m in orbit_of:
                    continue
                orb = closure(m, gens)
                for x in orb:
                    orbit_of[x] = orb
                names = {namef(*x) for x in orb}
                if not check(len(names) == 1, f"{CR[i]['name']}: canonical name not constant on the orbit of {m}: {names}"):
                    continue
                nm = names.pop()
                if nm in name_to_orbit:
                    fail(f"{CR[i]['name']}: orbits of {m} and {sorted(name_to_orbit[nm])[0]} share the name {nm}")
                name_to_orbit[nm] = orb
        for f in fl.fams:
            got = sorted({namef(*orbit_of[m] and m) for m in f["set"]}, reverse=True)
            check([list(x) for x in got] == f["orbits"], f"{CR[i]['name']}: family orbits != recomputed")
            check(sum(f["orbit_member_counts"]) == f["multiplicity"], f"{CR[i]['name']}: orbit counts do not sum to multiplicity")
    # S2c: the monoclinic invariants and orbits (the integer vector (h^2, k^2, l^2, hl) for a generic cell; the exact g^2 as a
    # Fraction for M-sq, whose a, b, c and cos(beta) = -1/4 are rational), and the closure of the two generators.
    def mono_invariant(i, m):
        h, k, l = m
        if CR[i]["name"] != "M-sq":
            return (h * h, k * k, l * l, h * l)
        a_, b_, c_, cb = Fraction(5), Fraction(4), Fraction(5), Fraction(-1, 4)
        return (Fraction(h * h) / (a_ * a_) + Fraction(l * l) / (c_ * c_) - 2 * h * l * cb / (a_ * c_)) / (1 - cb * cb) + Fraction(k * k) / (b_ * b_)
    check(len(closure((1, 2, 3), MONO_GENS)) == 4 and len(closure((2, 0, 1), MONO_GENS)) == 2
          and len(closure((0, 3, 0), MONO_GENS)) == 2 and len(closure((0, 0, 4), MONO_GENS)) == 2
          and len(closure((1, 0, 0), MONO_GENS)) == 2, "2/m orbit sizes 4, 2, 2, 2, 2")
    for n in NMONO + ["M-P-b+1e-4", "M-P-acute"]:
        i = NAME[n]
        fl = LISTS[i]
        by_inv = defaultdict(set)
        for f in fl.fams:
            for m in f["set"]:
                by_inv[mono_invariant(i, m)].add(m)
        check({frozenset(v) for v in by_inv.values()} == {frozenset(f["set"]) for f in fl.fams},
              f"{n}: float grouping != exact-invariant grouping")
        orbit_of, name_to_orbit = {}, {}
        for f in fl.fams:
            for m in f["set"]:
                if m in orbit_of:
                    continue
                gens_, nf_ = (SQ_GENS, sq_name) if n == "M-sq" else (MONO_GENS, mono_name)
                orb = closure(m, gens_)
                for x in orb:
                    orbit_of[x] = orb
                names = {nf_(*x) for x in orb}
                if not check(len(names) == 1, f"{n}: canonical name not constant on the orbit of {m}: {names}"):
                    continue
                nm = names.pop()
                if nm in name_to_orbit:
                    fail(f"{n}: orbits of {m} and {sorted(name_to_orbit[nm])[0]} share the name {nm}")
                name_to_orbit[nm] = orb
        for f in fl.fams:
            nf_ = sq_name if n == "M-sq" else mono_name
            got = sorted({nf_(*m) for m in f["set"]}, reverse=True)
            check([list(x) for x in got] == f["orbits"], f"{n}: family orbits != recomputed")
            check(all(orbit_of[m] <= f["set"] for m in f["set"]), f"{n}: an orbit is only partly present in family g {f['g']}")
    # the beta'' CIF, read by gemmi: |g| of every reflection, the space-group absences, the orbits, what S1's cut removes
    st_, bcell_, bsites_ = beta_from_cif(cif_path)
    sg_ops = st_.spacegroup.operations()
    check(st_.spacegroup.number == 12 and len(bsites_) == 22 and len(sg_ops.sym_ops) == 4, "gemmi: C2/m, 22 sites, 4 rotation parts")
    rots = sorted({tuple(tuple(int(x) // 24 for x in row) for row in op.rot) for op in sg_ops.sym_ops})
    check(len(rots) == 4, "gemmi: 4 distinct rotation parts")
    bi = NAME["beta''"]
    hk_, gl_, F_ = RAW[bi]
    kept_ = np.abs(F_) > CUT
    gem_g = {}
    worst = 0.0
    for (h_, k_, l_), g_ in zip(hk_[kept_], gl_[kept_]):
        t_ = (int(h_), int(k_), int(l_))
        gg_ = 1.0 / st_.cell.calculate_d(list(t_))
        gem_g[t_] = gg_
        worst = max(worst, abs(gg_ - g_) / g_)
    check(worst < 1e-12, f"gemmi |g| differs from the numpy list by {worst:.2e} relative")
    absent_in_list = [t_ for t_ in gem_g if sg_ops.is_systematically_absent(list(t_))]
    check(not absent_in_list, f"gemmi: {len(absent_in_list)} listed reflections are systematically absent")
    allowed = []
    nmax = [int(math.ceil(KMAX * x)) + 1 for x in (bcell_[0], bcell_[1], bcell_[2])]
    for h_ in range(-nmax[0], nmax[0] + 1):
        for k_ in range(-nmax[1], nmax[1] + 1):
            for l_ in range(-nmax[2], nmax[2] + 1):
                if (h_, k_, l_) == (0, 0, 0):
                    continue
                gg_ = 1.0 / st_.cell.calculate_d([h_, k_, l_])
                if gg_ <= KMAX and not sg_ops.is_systematically_absent([h_, k_, l_]):
                    allowed.append(((h_, k_, l_), gg_))
    below_cut = sorted(t_ for (t_, _) in allowed if t_ not in gem_g)
    print(f"  gemmi: {len(allowed)} space-group-allowed reflections with |g| <= {KMAX}, the numpy list has {len(gem_g)}; "
          f"worst |g| difference {worst:.2e} relative; allowed but under the 1e-4 cut: {len(below_cut)}")
    check(len(allowed) == 1448 and len(gem_g) == 1442 and len(below_cut) == 6, "gemmi: 1448 allowed, 1442 listed, 6 under the cut")
    check(sorted({mono_name(*t_) for t_ in below_cut}) == [(3, 3, 3), (14, 0, 1)], "gemmi: the six under the cut are {3 3 3} and {14 0 1}")
    gem_family_ok = 0
    for f in bm.fams:
        h0 = np.array(f["members"][0])
        orb = {tuple(int(x) for x in (h0 @ np.array(R))) for R in rots}
        orb |= {tuple(-x for x in t_) for t_ in orb}
        gem_family_ok += int(orb == f["set"])
    check(gem_family_ok == len(bm.fams), f"gemmi point-group orbit (+ Friedel) equals the family in {gem_family_ok} of {len(bm.fams)}")
    # closed forms by hand (no list, no reference code)
    a_, b_, c_, be_ = 15.16, 4.05, 6.74, math.radians(105.3)
    def d_hand(h_, k_, l_, a_=a_, b_=b_, c_=c_, be_=be_):
        return ((h_ * h_ / a_ ** 2 + l_ * l_ / c_ ** 2 - 2 * h_ * l_ * math.cos(be_) / (a_ * c_)) / math.sin(be_) ** 2 + k_ * k_ / b_ ** 2) ** -0.5
    def d_fam(n, m):
        fl = LISTS[NAME[n]]
        for f in fl.fams:
            if tuple(m) in f["set"] or tuple(-x for x in m) in f["set"]:
                return 1 / f["g"]
        raise KeyError((n, m))
    hand = [(d_fam("beta''", (2, 0, 0)), a_ * math.sin(be_) / 2), (d_fam("beta''", (0, 0, 1)), c_ * math.sin(be_)),
            (d_fam("beta''", (0, 2, 0)), b_ / 2), (d_fam("beta''", (1, 1, 0)), d_hand(1, 1, 0)),
            (d_fam("beta''", (2, 0, 1)), d_hand(2, 0, 1)), (d_fam("beta''", (2, 0, -1)), d_hand(2, 0, -1)),
            (d_fam("M-P", (1, 0, 0)), 7.2 * math.sin(math.radians(104))), (d_fam("M-P", (0, 1, 0)), 4.9),
            (d_fam("M-P", (0, 0, 1)), 5.6 * math.sin(math.radians(104))),
            (d_fam("M-P", (1, 0, 1)), d_hand(1, 0, 1, 7.2, 4.9, 5.6, math.radians(104))),
            (d_fam("M-P", (1, 0, -1)), d_hand(1, 0, -1, 7.2, 4.9, 5.6, math.radians(104)))]
    check(all(abs(x - y) <= 1e-12 * y for x, y in hand), "monoclinic hand anchors (closed forms)")
    check(abs(hand[0][1] - 7.31135) < 1e-5 and abs(hand[1][1] - 6.50112) < 1e-5 and abs(hand[4][1] - 4.32457) < 1e-5
          and abs(hand[5][1] - 5.65554) < 1e-5, "beta'' registered d values 7.31135, 6.50112, 4.32457, 5.65554")
    # beta'' at larger k_max, and without S1's cut (registered counts)
    for km, nf in ((1.6, 953), (2.0, 1805), (2.5, 3450), (4.0, 13472)):
        c2 = dict(CR[bi], kmax=km)
        fl2 = build_families(raw_reflections(table, c2), "monoclinic")
        gaps2 = np.diff(fl2.g) / fl2.g[:-1]
        print(f"  beta'' at k_max {km}: {len(fl2.fams)} families, smallest relative gap {gaps2.min():.3e}")
        check(len(fl2.fams) == nf, f"beta'' at k_max {km}: {len(fl2.fams)} families, registered {nf}")
        if km == 1.2:
            pass
    check(len(build_families(RAW[bi], "monoclinic", frozenset(["absences_kept"])).fams) == 834, "beta'' without S1's cut: 834 families")
    # strictly ascending g, gaps, spread within a family, edge hazards
    mingap = (math.inf, "")
    for i in base:
        fl = LISTS[i]
        check(bool(np.all(np.diff(fl.g) > 0)), f"{CR[i]['name']}: family g not strictly ascending")
        if len(fl.g) > 1:
            gaps = np.diff(fl.g) / fl.g[:-1]
            j = int(np.argmin(gaps))
            if gaps[j] < mingap[0]:
                mingap = (float(gaps[j]), f"{CR[i]['name']} families {j}/{j + 1}")
        hkl, glen, F = RAW[i]
        aF = np.abs(F)
        kept = aF > CUT
        edge = float(np.min(np.abs(glen[kept] - CR[i]["kmax"]) / CR[i]["kmax"]))
        cutd = float(np.min(np.abs(aF - CUT) / CUT))
        print(f"  {CR[i]['name']:10s} nearest kept |g| to kMax {edge:.3e} relative, nearest |F| to the cut {cutd:.3e} relative")
        check(edge > 1e-9 and cutd > 1e-9, f"{CR[i]['name']}: a reflection within 1e-9 of the kMax edge or the |F| cut")
        for f in fl.fams:       # spread within a family
            gg = np.array([np.linalg.norm(np.array(m, float) @ np.linalg.inv(lattice(*CR[i]["cell"])[0]).T) for m in f["members"]])
            check(float(gg.max() / gg.min() - 1) < 1e-12, f"{CR[i]['name']}: spread within a family {gg.max() / gg.min() - 1:.2e}")
    print(f"  smallest relative gap between adjacent families: {mingap[0]:.4e} ({mingap[1]})")
    check(1.5e-3 < mingap[0] < 1.6e-3, f"smallest gap {mingap[0]} is not the registered 1.55e-3")

    # ------------------------------------------------------------------------------------------------ build the plants
    acc = Acc()
    # T1
    t1_info = []
    for ci in base:
        fl = LISTS[ci]
        for j, g in enumerate(fl.g):
            uu, ss = np.meshgrid(np.array(U1), np.array(S1), indexing="ij")
            uu, ss = uu.ravel(), ss.ravel()
            q = g * (1 + ss * uu)
            acc.add(len(q), tier=1, crystal=ci, q=q, sigma=uu * q, k=K, truth_family=j,
                    truth_z=np.abs(ss) / (1 + ss * uu), s=ss, u=uu)
    n_t1 = sum(len(p["q"]) for p in acc.parts)
    check(n_t1 == 83 * 45, f"T1 has {n_t1} rows")
    for ci in mono:                              # S2c: T1 over the monoclinic crystals, the same u and s
        fl = LISTS[ci]
        for j, g in enumerate(fl.g):
            uu, ss = np.meshgrid(np.array(U1), np.array(S1), indexing="ij")
            uu, ss = uu.ravel(), ss.ravel()
            q = g * (1 + ss * uu)
            acc.add(len(q), tier=1, crystal=ci, q=q, sigma=uu * q, k=K, truth_family=j,
                    truth_z=np.abs(ss) / (1 + ss * uu), s=ss, u=uu)
    n_t1m = sum(len(p["q"]) for p in acc.parts) - n_t1
    check(n_t1m == (392 + 198 + 83 + 417) * 45, f"monoclinic T1 has {n_t1m} rows")

    # T4
    def t4(label, ci, q, sigma, k, expect, truth=-1, u=None):
        if u is None:
            u = sigma / q if (math.isfinite(sigma) and math.isfinite(q) and q != 0) else math.nan
        acc.t4.append(label)
        acc.add(1, tier=4, crystal=ci, q=q, sigma=sigma, k=k, truth_family=truth, u=u)
        acc.t4_expect = getattr(acc, "t4_expect", []) + [expect]
        acc.t4_truth_g = getattr(acc, "t4_truth_g", []) + [truth]

    au = NAME["Au"]
    g111 = LISTS[au].g[0]
    for badname, bad in (("0", 0.0), ("-1", -1.0), ("NaN", math.nan), ("+inf", math.inf), ("-inf", -math.inf)):
        t4(f"invalid q = {badname}", au, bad, 1e-3 * g111, K, "invalidInput")
        t4(f"invalid sigma = {badname}", au, g111, bad, K, "invalidInput")
        t4(f"invalid k = {badname}", au, g111, 1e-3 * g111, bad, "invalidInput")
    # first-that-applies pairs: the list builder refuses before sigma / k can
    for nm, exp in (("Tetragonal", "built"), ("Orthorhombic", "built"),
                    ("Au-b+1e-6", "built"), ("Au-Z104", "unsupportedElement"),
                    ("Tetragonal-kmax0", "invalidInput"), ("Tetragonal-Z104", "unsupportedElement")):
        t4(f"pair: {nm} with sigma = 0 -> the list builder's {exp}, the list never compared", NAME[nm], 0.3, 0.0, K,
           "listRefused")
    # the lattice / element near-misses that are accepted get ordinary plants (their lists are real)
    for nm in ("Au-b+1e-11", "Mg-gamma+1e-10"):
        ci = NAME[nm]
        t4(f"{nm}: family 0 at its own g, u = 1e-3 (accepted: the near cell is classified cubic/hexagonal)", ci,
           LISTS[ci].g[0], 1e-3 * LISTS[ci].g[0], K, "accepted", truth=0)
    # beyondKMax
    j = fam_of(mg, (2, 0, 5))
    t4("beyond: Mg {20-25} at its own g, u = 1e-3", mg, LISTS[mg].g[j], 1e-3 * LISTS[mg].g[j], K, "beyondKMax", truth=j)
    j = fam_of(si, (6, 2, 0))
    t4("beyond: Si {620} at its own g, u = 1e-3", si, LISTS[si].g[j], 1e-3 * LISTS[si].g[j], K, "beyondKMax", truth=j)
    t4("beyond: q = 1.25 on Au, u = 1e-3", au, 1.25, 1.25e-3, K, "beyondKMax")
    # a one-family list and an empty one
    a45, a30 = NAME["Au-kmax0.45"], NAME["Au-kmax0.3"]
    g0 = LISTS[a45].g[0]
    t4("one-family list (Au, kMax 0.45): {111} at its own g, u = 1e-3 -> accepted, next nil", a45, g0, 1e-3 * g0, K, "accepted", truth=0)
    t4("one-family list: q = 0.3, u = 1e-3 -> none, nearest {111}", a45, 0.3, 3e-4, K, "noneWithinTolerance")
    t4("one-family list: q = 0.449, u = 1e-3 -> beyond", a45, 0.449, 0.449e-3, K, "beyondKMax")
    t4("empty list (Au, kMax 0.3): q = 0.2, u = 1e-3 -> none, no nearest", a30, 0.2, 2e-4, K, "noneWithinTolerance")
    t4("empty list: q = 0.299, u = 1e-3 -> beyond (q + r sigma > kMax)", a30, 0.299, 0.299e-3, K, "beyondKMax")
    # noneWithinTolerance
    a_si, c_mg = 5.4309, 5.2108
    sii = si
    t4("none: Si {200} (forbidden) at 2/a", sii, 2 / a_si, 1e-3 * 2 / a_si, K, "noneWithinTolerance")
    t4("none: Si {222} (forbidden) at sqrt(12)/a", sii, math.sqrt(12) / a_si, 1e-3 * math.sqrt(12) / a_si, K, "noneWithinTolerance")
    t4("none: Mg {0001} (forbidden) at 1/c", mg, 1 / c_mg, 1e-3 / c_mg, K, "noneWithinTolerance")
    Amg = lattice(*CR[mg]["cell"])[0]
    g1121 = float(np.linalg.norm(np.array([1.0, 1.0, 1.0]) @ np.linalg.inv(Amg).T))
    t4("none: Mg {11-21} (forbidden)", mg, g1121, 1e-3 * g1121, K, "noneWithinTolerance")
    t4("none: Au {100} (forbidden) at 1/a", au, 1 / 4.0782, 1e-3 / 4.0782, K, "noneWithinTolerance")
    t4("none: Au {111} position measured against Al's list", NAME["Al"], g111, 1e-3 * g111, K, "noneWithinTolerance")
    # ambiguous
    ja, jb = fam_of(mg, (1, 0, 5)), fam_of(mg, (2, 1, 2))
    qa = LISTS[mg].g[ja] + 0.4 * (LISTS[mg].g[jb] - LISTS[mg].g[ja])
    t4("ambiguous: Mg {10-15}/{21-32}, 40 % of the way, u = 1e-3", mg, qa, 1e-3 * qa, K, "ambiguous")
    ja, jb = fam_of(mg, (3, 0, 2)), fam_of(mg, (0, 0, 6))
    qa = LISTS[mg].g[ja] + 0.4 * (LISTS[mg].g[jb] - LISTS[mg].g[ja])
    t4("ambiguous: Mg {30-32}/{0006}, 40 % of the way, u = 3e-3", mg, qa, 3e-3 * qa, K, "ambiguous")
    j331, j420 = fam_of(au, (3, 3, 1)), fam_of(au, (4, 2, 0))
    g331, g420 = LISTS[au].g[j331], LISTS[au].g[j420]
    t4("ambiguous: Au {331} at its own g, u = 1e-2 ({420} 2.6 % away)", au, g331, 1e-2 * g331, K, "ambiguous", truth=j331)
    sg = (g420 - g331) / 5.7
    qm = g331 + 2.5 * sg
    t4("ambiguous: the margin plant, Au {331} -> {420}, sigma = gap/5.7, z = 2.5 (next 3.2, margin 2.0 < ln 19)", au, qm, sg, K,
       "ambiguous", truth=j331)
    # S2c: the monoclinic cells. Accepted lists get an ordinary plant; the refused ones the first-that-applies pair (sigma = 0).
    for nm in ("M-P-b+1e-4", "M-P-b+1e-8"):
        ci = NAME[nm]
        t4(f"{nm}: family 0 at its own g, u = 1e-3 (accepted: the cell is monoclinic, beta past 1e-9 deg from 90)", ci,
           LISTS[ci].g[0], 1e-3 * LISTS[ci].g[0], K, "accepted", truth=0)
    for nm, exp in (("M-P-b90", "built"), ("M-P-b+1e-10", "built"), ("UniqueC", "built"),
                    ("UniqueA", "built"), ("Triclinic", "built"), ("M-P-g+1e-8", "built"),
                    ("M-P-a-1e-8", "built"), ("beta''-Z104", "unsupportedElement"),
                    ("Triclinic-Z104", "unsupportedElement"), ("beta''-kmax0", "invalidInput")):
        t4(f"pair: {nm} with sigma = 0 -> the list builder's {exp}, the list never compared", NAME[nm], 0.3, 0.0, K, "listRefused")
    bq = NAME["beta''"]
    gp, gr = LISTS[bq].g[fam_of(bq, (3, 1, 5))], LISTS[bq].g[fam_of(bq, (7, 3, 0))]
    qm_ = (gp + gr) / 2
    t4("ambiguous: beta'' {3 1 5}/{7 3 0} (1.03e-5 apart), midway, u = 1e-3", bq, qm_, 1e-3 * qm_, K, "ambiguous")
    jf = fam_of(bq, (2, 0, 0))
    t4("accepted: beta'' {2 0 0} at its own g, u = 1e-3, next {0 0 1}", bq, LISTS[bq].g[jf], 1e-3 * LISTS[bq].g[jf], K, "accepted", truth=jf)
    t4_labels = list(acc.t4)
    t4_expect = list(acc.t4_expect)
    t4_truth_fam = list(acc.t4_truth_g)

    # T2 and T3
    stats = {"redraws": 0}
    cells = []
    pat_id = 0
    rng2 = np.random.default_rng(SEED_T2)
    t23 = [NAME[n] for n in ("Au", "Al", "Si", "Mg")]
    for ci in t23:
        fl = LISTS[ci]
        g, F = fl.g, len(fl.g)
        for uc in U_CAL:
            for kind, val in SM2:
                sm_abs = np.zeros(F) if kind == "zero" else (val * g if kind == "rel" else np.full(F, val))
                eps, n, q, sigma = draw_patterns(rng2, fl, KMAX, NPAT2, lambda m, uc=uc: rng2.normal(0.0, uc, m),
                                                 False, sm_abs, uc, stats)
                cid = len(cells)
                cells.append(dict(id=cid, tier=2, crystal=ci, u=uc, f=None, sign_split=False, sigma_meas_kind=kind,
                                  sigma_meas=val, patterns=NPAT2))
                pat = pat_id + np.repeat(np.arange(NPAT2), F)
                pat_id += NPAT2
                tz = np.abs(g[None, :] * eps[:, None] + n) / sigma
                acc.add(NPAT2 * F, tier=2, crystal=ci, q=q.ravel(), sigma=sigma.ravel(), k=K,
                        truth_family=np.tile(np.arange(F), NPAT2), truth_z=tz.ravel(), u=uc,
                        eps=np.repeat(eps, F), n=n.ravel(), pattern=pat, cell=cid,
                        sigma_meas=np.broadcast_to(sm_abs[None, :], (NPAT2, F)).ravel())
    rng3 = np.random.default_rng(SEED_T3)
    for ci in t23:
        fl = LISTS[ci]
        g, F = fl.g, len(fl.g)
        for f in F3:
            for uc in UC3:
                eps0 = np.concatenate([np.full(NPAT3, f * uc), np.full(NPAT3, -f * uc)])
                sm_abs = SM3 * g
                eps, n, q, sigma = draw_patterns(rng3, fl, KMAX, 2 * NPAT3, lambda m, e=eps0: e, True, sm_abs, uc, stats)
                cid = len(cells)
                cells.append(dict(id=cid, tier=3, crystal=ci, u=uc, f=f, sign_split=True, sigma_meas_kind="rel",
                                  sigma_meas=SM3, patterns=2 * NPAT3))
                pat = pat_id + np.repeat(np.arange(2 * NPAT3), F)
                pat_id += 2 * NPAT3
                tz = np.abs(g[None, :] * eps[:, None] + n) / sigma
                acc.add(2 * NPAT3 * F, tier=3, crystal=ci, q=q.ravel(), sigma=sigma.ravel(), k=K,
                        truth_family=np.tile(np.arange(F), 2 * NPAT3), truth_z=tz.ravel(), u=uc,
                        eps=np.repeat(eps, F), n=n.ravel(), pattern=pat, cell=cid,
                        sigma_meas=np.broadcast_to(sm_abs[None, :], (2 * NPAT3, F)).ravel())
    # T5
    rng5 = np.random.default_rng(SEED_T5)
    for ci in base:
        fl = LISTS[ci]
        for u in U5:
            q = rng5.uniform(0.2, KMAX, N5)
            while True:
                bad = hazard_rows(fl, KMAX, q, u * q)
                if not bad.any():
                    break
                stats["redraws"] += int(bad.sum())
                q[bad] = rng5.uniform(0.2, KMAX, int(bad.sum()))
            acc.add(N5, tier=5, crystal=ci, q=q, sigma=u * q, k=K, u=u)

    # S2c: T2 on M-C and beta'' (new seed), T3 and T5 on beta'' and M-sq, appended after the base tiers so those are unchanged.
    rng2m = np.random.default_rng(SEED_T2M)
    for ci in (NAME["M-C"], NAME["beta''"]):
        fl = LISTS[ci]
        g, F = fl.g, len(fl.g)
        for uc in U_CAL:
            for kind, val in SM2:
                sm_abs = np.zeros(F) if kind == "zero" else (val * g if kind == "rel" else np.full(F, val))
                eps, n, q, sigma = draw_patterns(rng2m, fl, KMAX, NPAT2, lambda m, uc=uc: rng2m.normal(0.0, uc, m),
                                                 False, sm_abs, uc, stats)
                cid = len(cells)
                cells.append(dict(id=cid, tier=2, crystal=ci, u=uc, f=None, sign_split=False, sigma_meas_kind=kind,
                                  sigma_meas=val, patterns=NPAT2))
                pat = pat_id + np.repeat(np.arange(NPAT2), F)
                pat_id += NPAT2
                tz = np.abs(g[None, :] * eps[:, None] + n) / sigma
                acc.add(NPAT2 * F, tier=2, crystal=ci, q=q.ravel(), sigma=sigma.ravel(), k=K,
                        truth_family=np.tile(np.arange(F), NPAT2), truth_z=tz.ravel(), u=uc,
                        eps=np.repeat(eps, F), n=n.ravel(), pattern=pat, cell=cid,
                        sigma_meas=np.broadcast_to(sm_abs[None, :], (NPAT2, F)).ravel())
    rng3m = np.random.default_rng(SEED_T3M)
    for ci in (NAME["beta''"], NAME["M-sq"]):
        fl = LISTS[ci]
        g, F = fl.g, len(fl.g)
        for f in F3:
            for uc in UC3:
                eps0 = np.concatenate([np.full(NPAT3, f * uc), np.full(NPAT3, -f * uc)])
                sm_abs = SM3 * g
                eps, n, q, sigma = draw_patterns(rng3m, fl, KMAX, 2 * NPAT3, lambda m, e=eps0: e, True, sm_abs, uc, stats)
                cid = len(cells)
                cells.append(dict(id=cid, tier=3, crystal=ci, u=uc, f=f, sign_split=True, sigma_meas_kind="rel",
                                  sigma_meas=SM3, patterns=2 * NPAT3))
                pat = pat_id + np.repeat(np.arange(2 * NPAT3), F)
                pat_id += 2 * NPAT3
                tz = np.abs(g[None, :] * eps[:, None] + n) / sigma
                acc.add(2 * NPAT3 * F, tier=3, crystal=ci, q=q.ravel(), sigma=sigma.ravel(), k=K,
                        truth_family=np.tile(np.arange(F), 2 * NPAT3), truth_z=tz.ravel(), u=uc,
                        eps=np.repeat(eps, F), n=n.ravel(), pattern=pat, cell=cid,
                        sigma_meas=np.broadcast_to(sm_abs[None, :], (2 * NPAT3, F)).ravel())
    rng5m = np.random.default_rng(SEED_T5M)
    for ci in (NAME["beta''"], NAME["M-sq"]):
        fl = LISTS[ci]
        for u in U5:
            q = rng5m.uniform(0.2, KMAX, N5)
            while True:
                bad = hazard_rows(fl, KMAX, q, u * q)
                if not bad.any():
                    break
                stats["redraws"] += int(bad.sum())
                q[bad] = rng5m.uniform(0.2, KMAX, int(bad.sum()))
            acc.add(N5, tier=5, crystal=ci, q=q, sigma=u * q, k=K, u=u)

    PL = acc.cat()
    N = len(PL["q"])
    tier = PL["tier"].astype(int)
    crys = PL["crystal"].astype(int)
    print(f"== plants: {N} rows; T1 {int((tier == 1).sum())}, T2 {int((tier == 2).sum())}, T3 {int((tier == 3).sum())}, "
          f"T4 {int((tier == 4).sum())}, T5 {int((tier == 5).sum())}; redraws {stats['redraws']} ==")

    # ----------------------------------------------------------------------------------------------- decide everything
    RES = dict(verdict=np.full(N, -9, np.int64), best=np.full(N, -1, np.int64), z=np.full(N, np.nan),
               delta=np.full(N, np.nan), next=np.full(N, -1, np.int64), z_next=np.full(N, np.nan),
               delta_next=np.full(N, np.nan), margin=np.full(N, np.nan), nearest=np.full(N, -1, np.int64),
               z_nearest=np.full(N, np.nan), delta_nearest=np.full(N, np.nan), reach=np.full(N, np.nan),
               pay_count=np.zeros(N, np.int64), hz_k=np.full(N, np.inf), hz_margin=np.full(N, np.inf),
               hz_reach=np.full(N, np.inf))
    # S2c: the ambiguous families of a verdict (up to 158 on the dense beta'' list) go to a side file, payload.i32, with an
    # offset per row, instead of one padded column each (that would be 4 GB): PAY_OFF[row] is the start in PAYBUF.
    PAY_OFF = np.zeros(N, np.int64)
    PAYBUF = []
    pay_len = 0
    for ci in np.unique(crys):
        idx = np.where(crys == ci)[0]
        if ref_of[ci] is not None:
            RES["verdict"][idx] = REF
            continue
        r = decide(LISTS[ci], PL["q"][idx], PL["sigma"][idx], PL["k"][idx], CR[ci]["kmax"])
        pay = r.pop("payload")
        for key, v in r.items():
            RES[key][idx] = v
        cnt_c = RES["pay_count"][idx]
        if pay.shape[1]:
            flat = pay[np.arange(pay.shape[1])[None, :] < cnt_c[:, None]]
            PAY_OFF[idx] = pay_len + np.cumsum(cnt_c) - cnt_c
            PAYBUF.append(flat.astype("<i4"))
            pay_len += len(flat)
    PAYFLAT = np.concatenate(PAYBUF) if PAYBUF else np.zeros(0, "<i4")

    def pay_of(p):
        return [int(x) for x in PAYFLAT[PAY_OFF[p]:PAY_OFF[p] + RES["pay_count"][p]]]
    check(not (RES["verdict"] == -9).any(), "a plant was left undecided")
    pad = int(RES["pay_count"].max())
    print(f"  payload pad = {pad} (max ambiguous families in one verdict)")

    # scalar cross-check of the vectorised decision
    rs = np.random.default_rng(7)
    sel = np.concatenate([np.where(tier == 4)[0], rs.choice(np.where(tier != 4)[0], 20000, replace=False)])
    bad = 0
    for p in sel:
        ci = crys[p]
        if ref_of[ci] is not None:
            continue
        v, b, nx, pl, zb, mg_ = decide_scalar(LISTS[ci].g, PL["q"][p], PL["sigma"][p], PL["k"][p], CR[ci]["kmax"])
        vv = RES["verdict"][p]
        okp = (v == vv)
        if v == ACC:
            okp &= (b == RES["best"][p]) and (nx == RES["next"][p]) and abs(zb - RES["z"][p]) <= 1e-12 * max(1, zb)
            okp &= (math.isnan(mg_) and math.isnan(RES["margin"][p])) or abs(mg_ - RES["margin"][p]) <= 1e-12 * max(1, abs(mg_))
        if v == AMB:
            okp &= pl == pay_of(p)
        bad += 0 if okp else 1
    check(bad == 0, f"scalar vs vectorised decision differ on {bad} of {len(sel)} plants")
    print(f"  scalar re-implementation agrees with the vectorised decision on {len(sel)} plants ({bad} differ)")

    # ----------------------------------------------------------------------------------------------------- T1 / P1
    print("== T1 ==")
    m1 = tier == 1
    hz = np.minimum.reduce([np.abs(RES["hz_k"][m1]) * 1.0, np.full(m1.sum(), np.inf)])
    print(f"  closest z to k over all T1 plants: {RES['hz_k'][m1].min():.3e} (registered 3.7e-3); "
          f"closest relevant margin to ln 19: {RES['hz_margin'][m1].min():.3e}; closest reach to kMax: {RES['hz_reach'][m1].min():.3e}")
    check(RES["hz_k"][m1].min() > HZ_Z and RES["hz_margin"][m1].min() > HZ_MARGIN and RES["hz_reach"][m1].min() > HZ_REACH,
          "a T1 plant within the redraw distances of k, ln 19 or kMax")
    tru = PL["truth_family"].astype(int)
    u_col = PL["u"]
    counts_ok = True
    print("  u      accepted-own  accepted-other  ambiguous  beyond  none | registered")
    bmask = np.isin(crys, base)
    for u in U1:
        mk = m1 & (u_col == u) & bmask
        v = RES["verdict"][mk]
        own = (v == ACC) & (RES["best"][mk] == tru[mk])
        got = (int(own.sum()), int(((v == ACC) & ~own).sum()), int((v == AMB).sum()), int((v == BEY).sum()),
               int((v == NON).sum()))
        want = T1_PREDICT[u]
        same = got == want and int(mk.sum()) == 747 and int((v == INV).sum()) == 0
        counts_ok &= same
        print(f"  {u:<6g} {got[0]:12d} {got[1]:15d} {got[2]:10d} {got[3]:7d} {got[4]:5d} | {want}  {'EQUAL' if same else 'DIFFERENT'}")
    check(counts_ok, "T1 counts differ from the registered prediction")
    print("  S2c monoclinic T1 (M-P, M-C, M-sq, beta''): u  accepted-own  accepted-other  ambiguous  beyond  none | registered")
    mmask = np.isin(crys, mono)
    cm_ok = True
    for u in U1:
        mk = m1 & (u_col == u) & mmask
        v = RES["verdict"][mk]
        own = (v == ACC) & (RES["best"][mk] == tru[mk])
        got = (int(own.sum()), int(((v == ACC) & ~own).sum()), int((v == AMB).sum()), int((v == BEY).sum()), int((v == NON).sum()))
        per = tuple(int(((RES["verdict"] == ACC) & m1 & (u_col == u) & (crys == c_)).sum()) for c_ in mono)
        same = got == T1M_PREDICT[u] and per == T1M_ACCEPTED[u] and int(mk.sum()) == 9810
        cm_ok &= same
        print(f"  {u:<6g} {got[0]:12d} {got[1]:15d} {got[2]:10d} {got[3]:7d} {got[4]:5d} | {T1M_PREDICT[u]} {per}  {'EQUAL' if same else 'DIFFERENT'}")
    check(cm_ok, "monoclinic T1 counts differ from the registered prediction")
    mz = m1 & mmask
    print(f"  monoclinic T1 hazards: min |z-k| {RES['hz_k'][mz].min():.2e}, min |margin-ln19| {RES['hz_margin'][mz].min():.2e}, "
          f"min |q+R-kmax| {RES['hz_reach'][mz].min():.2e}")
    check(RES["hz_k"][mz].min() > HZ_Z and RES["hz_margin"][mz].min() > HZ_MARGIN and RES["hz_reach"][mz].min() > HZ_REACH,
          "a monoclinic T1 plant within the redraw distances")
    # identifiable families at s = 0 on beta'': the registered 298 / 54 / 23 / 8 / 4
    ident = {}
    for u in U1:
        mk = m1 & (u_col == u) & (crys == NAME["beta''"]) & (PL["s"] == 0.0)
        ident[u] = int(((RES["verdict"][mk] == ACC) & (RES["best"][mk] == tru[mk])).sum())
    print(f"  beta'' families named at s = 0, per u: {ident}")
    check(ident == {1e-4: 298, 1e-3: 54, 3e-3: 23, 1e-2: 8, 3e-2: 4}, "beta'' identifiable families 298/54/23/8/4")
    # closed forms for every accepted T1 plant
    ia_all = np.where(m1 & (RES["verdict"] == ACC))[0]
    ia = ia_all[RES["best"][ia_all] == tru[ia_all]]
    oth = ia_all[RES["best"][ia_all] != tru[ia_all]]
    # the registered prediction has 19 accepted-as-another-family plants, all at s = -2.9, u = 3e-2 (own z > k there)
    check(bool(np.all(PL["s"][oth] == -2.9) and np.all(PL["u"][oth] == 3e-2) and np.all(PL["truth_z"][oth] > K)),
          "an accepted T1 plant that is not its own family lies outside the registered (s = -2.9, u = 3e-2, own z > k) case")
    s_, u_ = PL["s"][ia], PL["u"][ia]
    zc = np.abs(s_) / (1 + s_ * u_)
    dc = -s_ * u_ / (1 + s_ * u_)
    check(float(np.max(np.abs(RES["z"][ia] - zc) / np.maximum(1, zc))) < 1e-10, "accepted T1 z != closed form")
    check(float(np.max(np.abs(RES["delta"][ia] - dc))) < 1e-14, "accepted T1 delta != closed form")
    print(f"  accepted T1 plants: {len(ia)}; worst |z - closed form| {np.max(np.abs(RES['z'][ia] - zc)):.2e}, "
          f"worst |delta - closed form| {np.max(np.abs(RES['delta'][ia] - dc)):.2e}")
    # P1 on numpy
    p1 = 0
    for t in (1, 2):
        mt = (tier == t) & (tru >= 0) & (PL["truth_z"] <= K)
        v = RES["verdict"][mt]
        badp = ((v == ACC) & (RES["best"][mt] != tru[mt])) | (v == NON)
        p1 += int(badp.sum())
        print(f"  P1 tier {t}: {int(mt.sum())} plants with own z <= k, {int(badp.sum())} assigned another family or refused none")
    check(p1 == 0, f"P1 violated by {p1} plants")

    # ------------------------------------------------------------------------------------------------------------ T4
    print("== T4 ==")
    idx4 = np.where(tier == 4)[0]
    for r_, p in enumerate(idx4):
        v = int(RES["verdict"][p])
        got = VERDICT[v]
        want = t4_expect[r_]
        ci = crys[p]
        extra = ""
        if v == ACC:
            extra = f" best {RES['best'][p]} z {RES['z'][p]:.3f} next {RES['next'][p]} margin {RES['margin'][p]:.3f}"
        elif v == AMB:
            extra = f" payload {pay_of(p)}"
        elif v in (NON, BEY):
            extra = f" nearest {RES['nearest'][p]} z {RES['z_nearest'][p]:.3g} reach {RES['reach'][p]:.5f}"
        elif v == REF:
            extra = f" ({ref_of[ci]})"
        print(f"  [{r_:2d}] {'ok ' if got == want else 'BAD'} {got:20s} {t4_labels[r_]}{extra}")
        check(got == want, f"T4 plant '{t4_labels[r_]}': {got}, registered {want}")
        # the pair plants: the crystal-level refusal must be the one in the label
    # ------------------------------------------------------------------------------------------------ T2, T3, T5 prints
    print("== T2 == (per u_cal x sigma_meas, over the four crystals)")
    m2 = tier == 2
    print("  u_cal  sigma_meas   rings  outside-k(%)  accepted-own  wrong-family  ambiguous  beyond  none")
    for uc in U_CAL:
        for kind, val in SM2:
            cids = [c["id"] for c in cells if c["tier"] == 2 and c["u"] == uc and c["sigma_meas_kind"] == kind and c["sigma_meas"] == val]
            mk = m2 & np.isin(PL["cell"].astype(int), cids)
            v = RES["verdict"][mk]
            own = (v == ACC) & (RES["best"][mk] == tru[mk])
            wrong = (v == ACC) & ~own
            outside = float(np.mean(PL["truth_z"][mk] > K)) * 100
            print(f"  {uc:<6g} {kind + ('' if kind == 'zero' else str(val)):10s} {int(mk.sum()):7d} {outside:11.3f}  {int(own.sum()):12d} "
                  f"{int(wrong.sum()):12d} {int((v == AMB).sum()):10d} {int((v == BEY).sum()):7d} {int((v == NON).sum()):5d}")
    mk = m2
    v = RES["verdict"][mk]
    own = (v == ACC) & (RES["best"][mk] == tru[mk])
    print(f"  all T2: {int(mk.sum())} rings, true family outside k sigma {float(np.mean(PL['truth_z'][mk] > K)) * 100:.3f} % "
          f"(nominal 0.27 %, clustered by pattern), wrong-family accepts {int(((v == ACC) & ~own).sum())} "
          f"({float(np.mean((v == ACC) & ~own)) * 100:.4f} %), accepted-own {int(own.sum())}, ambiguous {int((v == AMB).sum())}, "
          f"beyond {int((v == BEY).sum())}, none {int((v == NON).sum())}")
    print("== T3 == (per crystal x f x u_claimed x sign: rings own/other/none/ambiguous/beyond, mean delta of accepted)")
    m3 = tier == 3
    for c in cells:
        if c["tier"] != 3:
            continue
        mk0 = m3 & (PL["cell"].astype(int) == c["id"])
        line = f"  {CR[c['crystal']]['name']:3s} f={c['f']:<2d} u={c['u']:<5g}"
        for sgn in (1, -1):
            mk = mk0 & (np.sign(PL["eps"]) == sgn)
            v = RES["verdict"][mk]
            own = (v == ACC) & (RES["best"][mk] == tru[mk])
            oth = (v == ACC) & ~own
            md = float(np.mean(RES["delta"][mk][v == ACC])) if (v == ACC).any() else float("nan")
            line += f" | {'+' if sgn > 0 else '-'} {int(own.sum()):3d}/{int(oth.sum()):3d}/{int((v == NON).sum()):3d}/{int((v == AMB).sum()):3d}/{int((v == BEY).sum()):2d} d={md:+.5f}"
        print(line)
    print("== T5 ==")
    m5 = tier == 5
    print("  crystal    u      accepted  ambiguous  beyond   none | share of [0.2,1.2) inside any +-k sigma window")
    for ci in base + [NAME["beta''"], NAME["M-sq"]]:
        fl = LISTS[ci]
        for u in U5:
            mk = m5 & (crys == ci) & (u_col == u)
            v = RES["verdict"][mk]
            iv = sorted((gg / (1 + K * u), min(gg / (1 - K * u), 1e9)) for gg in fl.g)
            tot, cur_lo, cur_hi = 0.0, None, None
            for lo, hi in iv:
                lo, hi = max(lo, 0.2), min(hi, KMAX)
                if hi <= lo:
                    continue
                if cur_hi is None or lo > cur_hi:
                    if cur_hi is not None:
                        tot += cur_hi - cur_lo
                    cur_lo, cur_hi = lo, hi
                else:
                    cur_hi = max(cur_hi, hi)
            if cur_hi is not None:
                tot += cur_hi - cur_lo
            print(f"  {CR[ci]['name']:9s} {u:<6g} {float(np.mean(v == ACC)):8.4f} {float(np.mean(v == AMB)):9.4f} {float(np.mean(v == BEY)):7.4f} "
                  f"{float(np.mean(v == NON)):6.4f} | {tot / (KMAX - 0.2):.4f}")

    # --------------------------------------------------------------------------------------------- mutation moves
    print("== mutation moves (T1 + T4 plants, and the lists) ==")
    ptr = np.where((tier == 1) | (tier == 4))[0]

    def signature(lists_by_ci, ref_by_ci, mut):
        WPAY = 300
        S = np.full((len(ptr), 13 + WPAY), np.nan)
        for ci in np.unique(crys[ptr]):
            rows = np.where(crys[ptr] == ci)[0]
            pp = ptr[rows]
            if ref_by_ci[ci] is not None:
                S[rows, 0] = REF
                continue
            fl = lists_by_ci.get(ci)
            if fl is None:
                S[rows, 0] = -2
                continue
            r = decide(fl, PL["q"][pp], PL["sigma"][pp], PL["k"][pp], CR[ci]["kmax"], mut)
            pay = r.pop("payload")
            gg = np.append(fl.g, np.nan) if len(fl.g) else np.array([np.nan])
            mu = np.append(fl.mult.astype(float), np.nan) if len(fl.g) else np.array([np.nan])
            S[rows, 0] = r["verdict"]
            S[rows, 1] = gg[r["best"]]
            S[rows, 2] = mu[r["best"]]
            S[rows, 3] = r["z"]
            S[rows, 4] = r["delta"]
            S[rows, 5] = gg[r["next"]]
            S[rows, 6] = r["z_next"]
            S[rows, 7] = r["delta_next"]
            S[rows, 8] = r["margin"]
            S[rows, 9] = gg[r["nearest"]]
            S[rows, 10] = r["z_nearest"]
            S[rows, 11] = r["delta_nearest"]
            S[rows, 12] = r["reach"]
            for c_ in range(min(pay.shape[1], WPAY)):
                S[rows, 13 + c_] = np.where(pay[:, c_] >= 0, gg[pay[:, c_]], np.nan)
        return S

    def lists_under(mut):
        refs, lists = [], {}
        for i, c in enumerate(CR):
            r_ = refusal(c, mut)
            lat = "cubic" if "any_cell_cubic" in mut else lattice_class(CR[i]["cell"], "lattice_exact" in mut, mut)
            refs.append(r_ or ("built" if lat is None else None))
            if refs[-1] is None and i in RAW:
                lists[i] = build_families(RAW[i], lat, mut, sq=(c["name"] == "M-sq"))
        return refs, lists

    S_ref = signature(LISTS, ref_of, frozenset())
    fkey = lambda f: (f["g"], tuple(map(tuple, f["members"])), tuple(map(tuple, f["orbits"])), f["multiplicity"], f["name"])

    MUTS = [
        ("deviation", "delta over the measured d (1 - q/g)", "deviation_over_measured", ("plants",)),
        ("families", "absences kept (cut at -1)", "absences_kept", ("families",)),
        ("families", "grouping tolerance 0", "group_tol_0", ("families",)),
        ("families", "grouping tolerance 1e-2", "group_tol_1e-2", ("families",)),
        ("orbits", "hexagonal orbits by the cubic rule", "hex_cubic_rule", ("families",)),
        ("orbits", "hexagonal without the negation", "hex_no_negation", ("families",)),
        ("multiplicity", "multiplicity as the orbit count", "mult_orbit_count", ("families",)),
        ("ambiguous", "second-within check dropped", "second_within_dropped", ("plants",)),
        ("ambiguous", "margin clause dropped", "margin_clause_dropped", ("plants",)),
        ("margin", "margin as z2 - z1", "margin_z_diff", ("plants",)),
        ("beyond", "reach at k sigma alone", "reach_k_sigma", ("plants",)),
        ("z", "z as |q-g|/(sigma q)", "z_over_sigma_q", ("plants",)),
        ("P1", "z^2 <= k", "z2_le_k", ("plants",)),
        ("P1", "nearest as the first g >= q", "nearest_first_ge", ("plants",)),
        ("next", "next as the upper neighbour", "next_upper", ("plants",)),
        ("unsupportedLattice", "any cell taken as cubic", "any_cell_cubic", ("crystals",)),
        ("unsupportedLattice", "lattice tolerance 0 (exact equality)", "lattice_exact", ("crystals",)),
        ("unsupportedElement", "unsupported elements ignored", "unsupported_elements_ignored", ("crystals",)),
        ("invalidInput", "sigma = 0 accepted", "sigma0_accepted", ("plants",)),
        ("invalidInput", "kMax bound dropped (kMax = 5 accepted)", "kmax_bound_dropped", ("crystals",)),
        ("families", "S1's cut raised to 1e-2", "cut_1e-2", ("families",)),
        # S2c (m1-m15 of archive: roadmap-registrations-2026-10-15.md "S2c"; m5, m7 and the cut reuse S2's edits)
        ("orbits", "m1 monoclinic orbits by the cubic rule", "mono_cubic_rule", ("families",)),
        ("orbits", "m2 monoclinic: no sign flip with h", "mono_no_flip", ("families",)),
        ("orbits", "m3 monoclinic: K = k for h < 0", "mono_k_signed_negh", ("families",)),
        ("orbits", "m4 monoclinic: h = 0 without |l|", "mono_h0_l_signed", ("families",)),
        ("multiplicity", "m5 monoclinic multiplicity as the orbit count", "mult_orbit_count", ("families",)),
        ("families", "m6 grouping tolerance 1e-4", "group_tol_1e-4", ("families",)),
        ("families", "m7 grouping tolerance 0", "group_tol_0", ("families",)),
        ("unsupportedLattice", "m8 monoclinic accepted at beta = 90", "mono_at_beta90", ("crystals",)),
        ("unsupportedLattice", "m9 monoclinic: alpha and gamma unchecked", "mono_no_alpha_gamma", ("crystals",)),
        ("unsupportedLattice", "m10 unique axis c accepted", "mono_unique_c", ("crystals",)),
        ("unsupportedLattice", "m11 lattice tolerance 1e-7", "lattice_tol_1e-7", ("crystals",)),
        ("orbits", "m12 monoclinic: the mirror missing", "mono_mirror_missing", ("families",)),
        ("names", "m14 the name lists the first orbit only", "name_first_orbit", ("families",)),
        ("families", "m15 grouping tolerance 30 %", "group_tol_0.3", ("families",)),
    ]
    mut_rows = []
    for check_name, desc, mname, expects in MUTS:
        mut = frozenset([mname])
        refs, lists = lists_under(mut)
        S_m = signature(lists, refs, mut)
        mv = ~(((S_ref == S_m) | (np.isnan(S_ref) & np.isnan(S_m))).all(axis=1))
        t1m, t4m = int((mv & (tier[ptr] == 1)).sum()), int((mv & (tier[ptr] == 4)).sum())
        crys_moved = [CR[i]["name"] for i in range(len(CR)) if ref_of[i] != refs[i]]
        fam_lost = fam_new = 0
        fam_note = []
        for i in LISTS:
            if i in lists:
                a = {fkey(f) for f in LISTS[i].fams}
                b = {fkey(f) for f in lists[i].fams}
                if a != b:
                    fam_lost += len(a - b)
                    fam_new += len(b - a)
                    fam_note.append(f"{CR[i]['name']} {len(LISTS[i].fams)}->{len(lists[i].fams)}")
        # P1 under the mutant (same family indices are only comparable when the lists are unchanged)
        p1m = 0
        if mname in ("z2_le_k", "nearest_first_ge"):
            for jj, p in enumerate(ptr):
                if tier[p] == 1 and tru[p] >= 0 and PL["truth_z"][p] <= K:
                    g_true = LISTS[crys[p]].g[tru[p]]
                    if (S_m[jj, 0] == ACC and S_m[jj, 1] != g_true) or S_m[jj, 0] == NON:
                        p1m += 1
        moved = {"plants": int(mv.sum()), "families": fam_lost + fam_new, "crystals": len(crys_moved)}
        okm = any(moved[e] > 0 for e in expects)
        if mname in ("z2_le_k", "nearest_first_ge"):
            okm &= p1m > 0
        mut_rows.append((check_name, desc, mname, t1m, t4m, fam_lost, fam_new, crys_moved, fam_note, p1m, okm))
        print(f"  {'ok ' if okm else 'BAD'} {desc:42s} -> check '{check_name}': plants moved T1 {t1m}, T4 {t4m}; families -{fam_lost}/+{fam_new} "
              f"{fam_note if fam_note else ''}; crystals {crys_moved if crys_moved else '-'}{'; P1 violations ' + str(p1m) if mname in ('z2_le_k', 'nearest_first_ge') else ''}")
        check(okm, f"mutation '{desc}' does not move its target ({expects})")
    # the specific registered numbers the mutations are named for
    refs, lists = lists_under(frozenset(["absences_kept"]))
    # registration's 19 was the advisor's |F|>0 figure; at the registered cut -1 it is 20 (N <= 23 minus {7,15,23}); ADR 022 addendum (2026-10-14)
    check(len(lists[au].fams) == 20, f"absences kept: Au has {len(lists[au].fams)} families, expected 20")
    print(f"  absences kept: Au {len(LISTS[au].fams)} -> {len(lists[au].fams)} families (cut -1: 20; the registration's 19 was the advisor's |F|>0 figure)")
    refs, lists = lists_under(frozenset(["group_tol_1e-2"]))
    ja, jb = fam_of(mg, (1, 0, 5)), fam_of(mg, (2, 1, 2))
    merged = any(((1, 0, 5) in f["set"] or (-1, 0, -5) in f["set"]) and ((2, 1, 2) in f["set"] or (-2, -1, -2) in f["set"]) for f in lists[mg].fams)
    check(merged, "tolerance 1e-2 does not merge Mg {10-15} + {21-32}")
    refs, lists = lists_under(frozenset(["hex_no_negation"]))
    nm11 = [f for f in lists[mg].fams if (1, 1, 0) in f["set"]][0]
    check(len(nm11["orbits"]) == 2, "hex without negation: Mg {11-20} not split in two names")
    refs, lists = lists_under(frozenset(["cut_1e-2"]))
    wc = NAME["Weak-cut"]
    check(len(lists[wc].fams) < len(LISTS[wc].fams), "cut 1e-2 does not change Weak-cut")
    print(f"  cut 1e-2: Weak-cut {len(LISTS[wc].fams)} -> {len(lists[wc].fams)} families")

    # ------------------------------------------------------------------------------------------------- write the files
    W = 21 + 8
    cols = (["tier", "crystal", "q", "sigma", "k", "truth_family", "truth_z", "verdict", "best", "z", "delta", "next",
             "z_next", "delta_next", "margin", "nearest", "z_nearest", "delta_nearest", "reach", "payload_count"]
            + ["payload_offset"] + ["s", "u", "eps", "n", "pattern", "plant", "sigma_meas", "cell"])
    assert len(cols) == W
    M = np.empty((N, W), dtype="<f8")
    M[:, 0], M[:, 1] = PL["tier"], PL["crystal"]
    M[:, 2], M[:, 3], M[:, 4] = PL["q"], PL["sigma"], PL["k"]
    M[:, 5], M[:, 6] = PL["truth_family"], PL["truth_z"]
    for c_, key in enumerate(["verdict", "best", "z", "delta", "next", "z_next", "delta_next", "margin", "nearest",
                              "z_nearest", "delta_nearest", "reach", "pay_count"], start=7):
        M[:, c_] = RES[key]
    M[:, 20] = PAY_OFF
    o = 21
    M[:, o], M[:, o + 1], M[:, o + 2], M[:, o + 3], M[:, o + 4] = PL["s"], PL["u"], PL["eps"], PL["n"], PL["pattern"]
    M[:, o + 5] = np.arange(N)
    M[:, o + 6], M[:, o + 7] = PL["sigma_meas"], PL["cell"]
    M.tofile(os.path.join(out, "plants.f64"))
    PAYFLAT.tofile(os.path.join(out, "payload.i32"))

    crystals_json = []
    for i, c in enumerate(CR):
        fams = []
        if i in LISTS:
            for f in LISTS[i].fams:
                fams.append(dict(g=f["g"], members=f["members"], orbits=f["orbits"],
                                 orbit_member_counts=f["orbit_member_counts"], multiplicity=f["multiplicity"],
                                 name=f["name"], intensity=f["intensity"]))
        crystals_json.append(dict(index=i, name=c["name"], cell=list(c["cell"]),
                                  sites=[[z, *pos, occ] for (z, pos, occ) in c["sites"]], kmax=jnum(c["kmax"]),
                                  expected_list_refusal=ref_of[i], lattice=lat_of[i], role=c["role"], families=fams))
    t1_counts = {}
    for u in U1:
        mk = m1 & (u_col == u) & bmask
        v = RES["verdict"][mk]
        own = (v == ACC) & (RES["best"][mk] == tru[mk])
        t1_counts[str(u)] = dict(accepted_own=int(own.sum()), accepted_other=int(((v == ACC) & ~own).sum()),
                                 ambiguous=int((v == AMB).sum()), beyondKMax=int((v == BEY).sum()),
                                 noneWithinTolerance=int((v == NON).sum()))
    manifest = dict(
        numpy=np.__version__, python=sys.version.split()[0], table_sha256=TABLE_SHA256, kmax=KMAX, k=K, ln19=LN19,
        cut=CUT, group_tol=GROUP_TOL, seeds=dict(t2=SEED_T2, t3=SEED_T3, t5=SEED_T5, t2m=SEED_T2M, t3m=SEED_T3M, t5m=SEED_T5M), W=W, pad=pad, columns=cols,
        rows=N, tiers={str(t): int((tier == t).sum()) for t in (1, 2, 3, 4, 5)},
        verdict_codes={"0": "accepted", "1": "invalidInput", "2": "unused (was unsupportedLattice)",
                       "3": "unused (was unsupportedElement, list level)", "4": "ambiguous", "5": "beyondKMax",
                       "6": "noneWithinTolerance", "-1": "list refused (not computed)"},
        crystals=crystals_json,
        cells=[dict(c, u=jnum(c["u"]), f=c["f"]) for c in cells],
        t4=[dict(plant=int(p), label=t4_labels[r_], expect=t4_expect[r_]) for r_, p in enumerate(idx4)],
        t1=dict(u=list(U1), s=list(S1)),
        beta_cif=cif_path,
        gemmi=dict(version=gemmi.__version__, cell=list(bcell_), space_group=st_.spacegroup.number,
                   crystal_system=st_.spacegroup.crystal_system_str(),
                   sites=[[z, *pos, occ] for (z, pos, occ) in bsites_],
                   rotations=[[list(r) for r in R] for R in rots],
                   allowed=[[*t_, g_] for (t_, g_) in allowed], below_cut=[list(t_) for t_ in below_cut],
                   hand_d=[[x, y] for x, y in hand]),
        seeds_mono=dict(t2=SEED_T2M, t3=SEED_T3M, t5=SEED_T5M),
        selfcheck=dict(t1_counts=t1_counts, redraws=stats["redraws"], payload_pad=pad),
    )
    with open(os.path.join(out, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=1, allow_nan=False)
    size = os.path.getsize(os.path.join(out, "plants.f64")) + os.path.getsize(os.path.join(out, "manifest.json"))
    print(f"== wrote {N} rows x W={W} ({os.path.getsize(os.path.join(out, 'plants.f64')) / 1e6:.1f} MB) + manifest.json "
          f"({os.path.getsize(os.path.join(out, 'manifest.json')) / 1e6:.2f} MB); total {size / 1e6:.1f} MB ==")
    print(f"reference.py: {time.time() - t_start:.1f} s")
    if FAILURES:
        with open(failed_path, "w") as fh:
            fh.write("\n".join(FAILURES) + "\n")
        print(f"\nreference.py: {len(FAILURES)} SELF-CHECK(S) FAILED (see {failed_path}); exit 1", flush=True)
        sys.exit(1)
    print("reference.py: all self-checks passed")


if __name__ == "__main__":
    main()
