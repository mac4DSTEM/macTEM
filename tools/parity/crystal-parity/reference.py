#!/usr/bin/env python3
"""Truth for tools/parity/crystal-parity: the kinematic reflection list of a crystal, from the definitions.

    reference.py <scattering_factors.txt> <out-dir>

Written from the definitions, NOT from Sources/TEMCore/Crystal (nothing of the Swift code is read):
  - real lattice from a, b, c, alpha, beta, gamma (a along x, b in the xy plane); reciprocal lattice B = inv(A).T, so
    a_i . b_j = delta_ij and g = h b1 + k b2 + l b3 (no 2 pi: |g| in 1/A, d = 1/|g| in A); V = |det A|, checked against
    V = abc sqrt(1 - cos2a - cos2b - cos2g + 2 cos a cos b cos g);
  - f_e(Z, g) = sum_{i<5} a_i (2 + b_i g^2) / (1 + b_i g^2)^2, Lobato and Van Dyck, Acta Cryst. A70 (2014) 636, with
    (a_i, b_i) = row Z-1 of py4DSTEM's scattering_factors.txt (columns 0:10:2 and 1:10:2, as its single_atom_scatter.py
    reads them), the file fetched by tools/lib/fetch-py4dstem-scattering.sh and held to its sha256 here;
  - F(hkl) = (1/V) sum_sites f_e(Z, |g|^2) occ exp(2 pi i (h x + k y + l z)); intensity |F|^2; a reflection is kept
    when |F| > 1e-4 and 0 < |g| <= kMax.
The structures are named here by their own definitions (fcc 4-atom cell, diamond = fcc + (1/4,1/4,1/4), hcp with
sites (0,0,0) and (2/3,1/3,1/2) in the 120 degree cell) and the lattice constants of archive: roadmap-registrations-2026-10-15.md S1 (Au 4.0782, Al 4.0495,
Si 5.4309, Mg 3.2094 / 5.2108 A), named as the reference until a CIF is pinned.

Writes table.f64 (py4DSTEM's 103 x 10 table), <case>.ref.f64 (rows of 9 float64: h k l |g| d Re(F) Im(F) |F| |F|^2 for every reflection with |F| > 1e-6 and
|g| <= kMax (1 + 1e-6), so the harness can find the ones near the 1e-4 and kMax edges) and manifest.json.

Before anything counts, the reference must agree with itself (exit 1, loudly): the table's sha256, f_e positive and
monotone decreasing in g, V by both formulas, the extinction rules of fcc and diamond exact in numpy (|F| < 1e-9 where
the rule says absent, > 1e-4 on the cut where it says present), and every harness mutation must MOVE its target
quantity here (relative change > 1e-6) -- a mutation that moves nothing proves nothing.
"""
import hashlib
import itertools
import json
import math
import os
import sys

import numpy as np

TABLE_SHA256 = "be845d1d541cdb75ae16f8928cd9e56a9ea38af8a3cc43da9137e73cc72bb6f4"
KMAX = 1.2          # 1/A
CUT = 1e-4          # |F| cut-off, A (the registration's)
LISTED = 1e-6       # the reference lists everything above this so the edge band is visible

FCC = [(0, 0, 0), (.5, .5, 0), (.5, 0, .5), (0, .5, .5)]
DIAMOND = FCC + [(x + .25, y + .25, z + .25) for (x, y, z) in FCC]
HCP = [(0, 0, 0), (2 / 3, 1 / 3, .5)]


def sites(z, positions, occ=1.0):
    return [(z, p, occ) for p in positions]


# name -> (cell (a, b, c, alpha, beta, gamma), sites [(Z, (x, y, z), occ)], extinction rule or None)
CASES = {
    "Au": ((4.0782,) * 3 + (90, 90, 90), sites(79, FCC), "fcc"),
    "Al": ((4.0495,) * 3 + (90, 90, 90), sites(13, FCC), "fcc"),
    "Si": ((5.4309,) * 3 + (90, 90, 90), sites(14, DIAMOND), "diamond"),
    "Mg": ((3.2094, 3.2094, 5.2108, 90, 90, 120), sites(12, HCP), None),
    # occupancy: a disordered Au(0.6)/Cu(0.4) origin site and Cu on the face centres (an L1_2-like cell, a = 3.75 A);
    # its superlattice reflections (mixed parity) exist only through the occupancies.
    "Weak-cut": None,            # filled in by main(): its occupancy comes from the table
    "Cu3Au-occ": ((3.75,) * 3 + (90, 90, 90),
                  sites(79, [(0, 0, 0)], 0.6) + sites(29, [(0, 0, 0)], 0.4) + sites(29, FCC[1:]), None),
}


def weak_cut_occupancy(table):
    """CsCl-like cell, one element (Cu) on (0,0,0) and (1/2,1/2,1/2), a = 3 A, the second site at occupancy q. For h+k+l
    odd F = (1 - q) f_e(Z, g) / V, which falls with g; q is solved so that the lowest such reflection, (100) at
    |g| = 1/3 A^-1, has |F| = 2.5e-4, putting the odd-sum reflections on both sides of the 1e-4 cut (the weakest near 8e-5)."""
    a = 3.0
    return 1 - 2.5e-4 * a**3 / float(f_e(table, 29, (1 / a) ** 2))


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


def reflections(table, cell, site_list, kmax=KMAX * (1 + 1e-6), z_shift=0, power=2, inv_v=True, occ_on=True,
                sites_override=None):
    """All (hkl) != 0 with |g| <= kmax: (hkl, |g|, F) with F including every |F| (the caller applies the cut).
    The keyword arguments exist only for the mutation-moves self-check."""
    A, vol = lattice(*cell)
    B = np.linalg.inv(A).T
    n = [int(math.ceil(kmax * np.linalg.norm(A[i]))) + 1 for i in range(3)]
    hkl = np.array([p for p in itertools.product(*(range(-m, m + 1) for m in n)) if p != (0, 0, 0)], dtype=np.float64)
    g = hkl @ B
    glen = np.linalg.norm(g, axis=1)
    keep = glen <= kmax
    hkl, glen = hkl[keep], glen[keep]
    F = np.zeros(len(hkl), dtype=np.complex128)
    for (z, pos, occ) in (sites_override or site_list):
        fe = f_e(table, z + z_shift, glen ** power)
        F += fe * (occ if occ_on else 1.0) * np.exp(2j * np.pi * (hkl @ np.array(pos)))
    if inv_v:
        F /= vol
    return hkl, glen, F


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    table_path, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    table = load_table(table_path)

    # f_e sanity: positive, decreasing in g on [0, 1.2] for every element used.
    gs = np.linspace(0, KMAX, 241) ** 2
    for z in (12, 13, 14, 29, 78, 79):
        fe = f_e(table, z, gs)
        assert (fe > 0).all() and (np.diff(fe) < 0).all(), f"f_e(Z={z}) is not positive and decreasing"

    q = weak_cut_occupancy(table)
    CASES["Weak-cut"] = ((3.0,) * 3 + (90, 90, 90), sites(29, [(0, 0, 0)]) + sites(29, [(.5, .5, .5)], q), None)

    manifest = {"numpy": np.__version__, "table_sha256": TABLE_SHA256, "kmax": KMAX, "cut": CUT, "cases": []}
    for name, (cell, site_list, rule) in CASES.items():
        A, vol = lattice(*cell)
        a, b, c, al, be, ga = cell
        ca, cb, cg = (math.cos(math.radians(x)) for x in (al, be, ga))
        v2 = a * b * c * math.sqrt(1 - ca**2 - cb**2 - cg**2 + 2 * ca * cb * cg)
        assert abs(abs(np.linalg.det(A)) - v2) < 1e-12 * v2, "V by determinant and by formula disagree"

        hkl, glen, F = reflections(table, cell, site_list)
        aF = np.abs(F)
        listed = aF > LISTED
        rows = np.column_stack([hkl[listed], glen[listed], 1.0 / glen[listed], F.real[listed], F.imag[listed],
                                aF[listed], aF[listed] ** 2])
        rows = rows[np.lexsort((rows[:, 2], rows[:, 1], rows[:, 0], rows[:, 3]))]
        rows.astype("<f8").tofile(os.path.join(out, f"{name}.ref.f64"))
        kept = (aF > CUT) & (glen <= KMAX)

        # extinction rules, in numpy, over every (hkl) in range (the rule decides, the numbers must agree)
        if rule:
            h, k, l = (hkl[:, i].astype(int) for i in range(3))
            parity = (h % 2) + (k % 2) + (l % 2)
            mixed = (parity != 0) & (parity != 3)
            absent = mixed.copy()
            if rule == "diamond":
                absent |= (parity == 0) & (((h + k + l) % 4) == 2)
            assert (aF[absent] < 1e-9).all(), f"{name}: a rule-absent reflection has |F| = {aF[absent].max()}"
            assert (aF[~absent] > 1e-3).all(), f"{name}: a rule-allowed reflection is weak: {aF[~absent].min()}"
            print(f"  {name}: extinction rule '{rule}' holds in numpy: {int(absent.sum())} absent (max |F| "
                  f"{aF[absent].max():.2e}), {int((~absent).sum())} allowed (min |F| {aF[~absent].min():.3e})")

        # mutation-moves: each variant must change its target quantity (relative to the baseline, on common hkl)
        def moved(**kw):
            h2, g2_, F2 = reflections(table, cell, site_list, **kw)
            return h2, g2_, F2

        def rel(F2, mask=None):
            m = (aF > CUT) if mask is None else mask      # only reflections the harness compares (|F| > cut)
            return float(np.max(np.abs(np.abs(F2[m]) - aF[m]) / aF[m]))

        mm = {}
        if name == "Au":
            _, _, F2 = moved(z_shift=-1)
            mm["table-row"] = rel(F2)
        if name == "Al":
            _, _, F2 = moved(power=1)
            mm["fe-of-g"] = rel(F2)
        if name == "Mg":
            _, _, F2 = moved(inv_v=False)
            mm["no-inverse-volume"] = rel(F2)
        if name == "Si":
            _, _, F2 = moved(sites_override=sites(14, FCC))
            allowed = aF > 1e-3
            mm["no-diamond-basis"] = rel(F2, allowed)
            # and the 4n+2 reflections the diamond rule forbids appear without the basis
            h, k, l = (hkl[:, i].astype(int) for i in range(3))
            fourn2 = ((h % 2 + k % 2 + l % 2) == 0) & (((h + k + l) % 4) == 2)
            mm["no-diamond-basis-4n+2-leak"] = float(np.abs(F2[fourn2]).max())
        if name == "Cu3Au-occ":
            _, _, F2 = moved(occ_on=False)
            mm["occupancy-ignored"] = rel(F2)

        if name == "Weak-cut":
            weak = aF[(glen <= KMAX)]
            near_hi = int(((weak > CUT * 1.01) & (weak < 1e-3)).sum())
            near_lo = int(((weak < CUT / 1.01) & (weak > CUT / 10)).sum())
            assert near_hi >= 3 and near_lo >= 3, f"Weak-cut does not straddle the cut: {near_hi} kept in (1e-4, 1e-3), {near_lo} dropped in (1e-5, 1e-4)"
            mm["tolerance-1e-3"] = float(near_hi)
            print(f"  Weak-cut: occupancy {q:.9f}; {near_hi} reflections kept in (1e-4, 1e-3), {near_lo} dropped in (1e-5, 1e-4); "
                  f"closest to the cut: {np.min(np.abs(weak - CUT)):.3e} from it")

        if name == "Mg":
            # hcp setting pinned independently of the sites above: 000l with l odd, and h-k = 3n with l odd, are absent
            h, k, l = (hkl[:, i].astype(int) for i in range(3))
            hcp_abs = (l % 2 == 1) & (((h - k) % 3) == 0)
            allowed = (l % 2 == 0) | (((h - k) % 3) != 0)
            assert hcp_abs.sum() > 10 and (aF[hcp_abs] < 1e-9).all(), f"Mg: hcp absences violated, max |F| {aF[hcp_abs].max()}"
            assert (aF[allowed & (glen <= KMAX)] > 1e-3).all(), "Mg: an hcp-allowed reflection is weak"
            print(f"  Mg: hcp absences (000l l odd; h-k = 3n, l odd) hold in numpy: {int(hcp_abs.sum())} absent, max |F| {aF[hcp_abs].max():.2e}")
            # phase-conjugate: |F| is identical, only Im(F) changes sign -- the complex check is what sees it
            Fc = np.conj(F)
            assert np.allclose(np.abs(Fc), aF) and np.abs(F.imag[aF > CUT]).max() > 1e-3, "Mg: F is real, phase-conjugate invisible"
            mm["phase-conjugate (Im F)"] = float(np.abs(F.imag[aF > CUT]).max())

        for key, val in mm.items():
            assert val > 1e-6, f"{name}: mutation '{key}' moves its target by only {val:.2e} -- it proves nothing"
            print(f"  {name}: mutation '{key}' moves its target by {val:.3e} (relative / absolute for the leak)")

        manifest["cases"].append({
            "name": name, "file": f"{name}.ref.f64", "rows": int(rows.shape[0]), "kept": int(kept.sum()),
            "cell": list(cell), "volume": vol, "extinction": rule,
            "mutation_moves": mm,
            "sites": [[z, *pos, occ] for (z, pos, occ) in site_list],
        })
        print(f"  {name}: V = {vol:.6f} A^3, {int(kept.sum())} reflections above the cut within kMax {KMAX}, "
              f"{rows.shape[0]} listed (|F| > {LISTED:g})")
    table.astype("<f8").tofile(os.path.join(out, "table.f64"))      # all 103 rows, for the whole-table comparison
    with open(os.path.join(out, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=1)
    print(f"reference.py: numpy {np.__version__}, table sha256 {TABLE_SHA256[:12]}..., {len(CASES)} cases")


if __name__ == "__main__":
    main()
