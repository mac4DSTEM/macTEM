#!/usr/bin/env python3
# macTEM's own since 2026-10-15: copied from mac4DSTEM 7d6fdbd1 (tools/crystal-structures/), which no longer has it.
"""Write a CIF for the beta'' (Mg5Si6) precipitate phase in Al-Mg-Si alloys.

SOURCE, and it is the canonical one:

    S. J. Andersen, H. W. Zandbergen, J. Jansen, C. Traeholt, U. Tundal, O. Reiso,
    "The crystal structure of the beta'' phase in Al-Mg-Si alloys",
    Acta Materialia 46(9), 3283-3298 (1998). doi:10.1016/S1359-6454(97)00493-X

    Cell from the abstract; atomic coordinates from Table 3, SET 3 -- the C2/m
    refinement, R = 3.16% over 377 reflections from seven diffraction data sets.
    Sets 1 and 2 in that table are the exit-wave extraction and the Cm
    refinement and are NOT used here.

WHY THIS RATHER THAN A DATABASE ENTRY. Materials Project mp-31404 is the same
phase and is CC BY 4.0, but it is DFT-relaxed: MP's own documentation notes
relaxed volumes run a few percent high, which is roughly 1% on d-spacings --
a systematic error that matters when the whole point is matching diffraction
geometry. Andersen et al. is experimental. The Crystallography Open Database
has no Mg5Si6 entry (checked 2026-09-11).

ON REDISTRIBUTION. Lattice parameters and atomic coordinates are measurements
of a crystal -- facts, not authorship -- which is the basis on which COD, ICSD
and Materials Project all republish structures from the literature with
citation. This script therefore carries the values and writes the CIF into
References/, which is gitignored: the repository documents the provenance and
does not redistribute a file.

VERIFICATION BUILT IN. Expanding the six sites under C2/m must give exactly
Mg10Si12 = 2 x Mg5Si6 = 22 atoms, which is the cell content the paper states.
A misread coordinate or the wrong axis setting breaks that, so it is asserted
rather than assumed.
"""
import os, sys

# Abstract: C-centred monoclinic, C2/m.
A, B, C, BETA = 15.16, 4.05, 6.74, 105.3          # Angstrom, degrees
# Table 3, set 3 (C2/m). Every site lies on y = 0.
SITES = [("Mg1", "Mg", 0.0,    0.0, 0.0,   0.5),
         ("Mg2", "Mg", 0.3459, 0.0, 0.089, 1.0),
         ("Mg3", "Mg", 0.430,  0.0, 0.652, 0.8),
         ("Si1", "Si", 0.0565, 0.0, 0.649, 1.1),
         ("Si2", "Si", 0.1885, 0.0, 0.224, 0.5),
         ("Si3", "Si", 0.2171, 0.0, 0.617, 2.5)]
# C2/m (No. 12), unique axis b: four general operations, plus C-centring.
OPS = ["x,y,z", "-x,y,-z", "-x,-y,-z", "x,-y,z",
       "1/2+x,1/2+y,z", "1/2-x,1/2+y,-z", "1/2-x,1/2-y,-z", "1/2+x,1/2-y,z"]

def multiplicity(x, y, z):
    seen = set()
    for sx, sy, sz in [(1, 1, 1), (-1, 1, -1), (-1, -1, -1), (1, -1, 1)]:
        for dx, dy in [(0.0, 0.0), (0.5, 0.5)]:
            seen.add((round((sx * x + dx) % 1, 4),
                      round((sy * y + dy) % 1, 4),
                      round((sz * z) % 1, 4)))
    return len(seen)

def main(out_path):
    counts = {"Mg": 0, "Si": 0}
    for _, el, x, y, z, _ in SITES:
        counts[el] += multiplicity(x, y, z)
    assert counts == {"Mg": 10, "Si": 12}, (
        f"expanded to {counts}, not Mg10Si12 -- a coordinate or the axis "
        f"setting is wrong; the paper states two units of Mg5Si6 per cell")

    lines = [
        "data_beta_double_prime_Mg5Si6",
        "_chemical_name_mineral            'beta-double-prime'",
        "_chemical_formula_sum             'Mg10 Si12'",
        "_chemical_formula_structural      'Mg5 Si6'",
        "_publ_author_name                 'Andersen, S. J.'",
        "_journal_name_full                'Acta Materialia'",
        "_journal_volume                   46",
        "_journal_year                     1998",
        "_journal_page_first               3283",
        f"_cell_length_a                    {A}",
        f"_cell_length_b                    {B}",
        f"_cell_length_c                    {C}",
        "_cell_angle_alpha                 90.0",
        f"_cell_angle_beta                  {BETA}",
        "_cell_angle_gamma                 90.0",
        "_symmetry_space_group_name_H-M    'C 2/m'",
        "_symmetry_Int_Tables_number       12",
        "loop_",
        "_symmetry_equiv_pos_as_xyz",
    ] + [f"  '{o}'" for o in OPS] + [
        "loop_",
        "_atom_site_label",
        "_atom_site_type_symbol",
        "_atom_site_fract_x",
        "_atom_site_fract_y",
        "_atom_site_fract_z",
        "_atom_site_occupancy",
        "_atom_site_B_iso_or_equiv",
    ] + [f"  {lab:5s} {el:3s} {x:8.4f} {y:8.4f} {z:8.4f}  1.0  {b:.1f}"
         for lab, el, x, y, z, b in SITES]

    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {out_path}")
    print(f"  C2/m, a={A} b={B} c={C} A, beta={BETA} deg")
    print(f"  {len(SITES)} sites expand to Mg{counts['Mg']}Si{counts['Si']} "
          f"= 2 x Mg5Si6 = {sum(counts.values())} atoms -- matches the paper")

if __name__ == "__main__":
    default = os.path.join(os.path.dirname(__file__), "..", "..", "..",
                           "References", "crystal-structures", "beta_double_prime_Mg5Si6.cif")
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(default)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    main(out)
