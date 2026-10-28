# indexing-parity

archive: roadmap-registrations-2026-10-15.md V1-8 S2 (indexing a measured |q| against the kinematic list, ADR 022): `DSpacingIndexing.families(of:kMax:)` and
`DSpacingIndexing.index(q:sigma:in:coverage:)` against a numpy script written from the registration's definition (not from the
Swift). `./run.sh` is the gate; classified `scientific` in `tools/run-tests.sh` once it is green.

- **Reference** (`reference.py`, numpy 2.5.4, CPython 3.14 from the lock): S1's list rebuilt as `tools/parity/crystal-parity/reference.py`
  does (py4DSTEM `f050d207` `scattering_factors.txt`, sha256-pinned); families grouped by exact rational invariants and
  asserted equal to the 1e-9 float grouping; orbits as the closure of the point-group generators on integer (h, k, l),
  asserted constant on an orbit and distinct between orbits; the decision implemented twice (vectorised and scalar) and
  asserted equal. It writes `manifest.json` and `plants.f64` (rows of 37 float64; the column order is in its docstring).
- **Crystals**: Au, Al, Si, Mg, Mg-ideal (c = a sqrt(8/3)), S1's Weak-cut, and the T4 cells (tetragonal, orthorhombic,
  b = a(1 + 1e-6), b = a(1 + 1e-11), gamma = 120 deg + 1e-10 deg, an Au cell with one Z = 104 site, k_max from 0 to 1e19).
- **Plants** (k_max 1.2 Å⁻¹, k = 3): T1 deterministic (747 per u, five u); T2 untruncated calibration error and noise, 300
  patterns per cell; **T3 common-mode understatement, 50 patterns per cell** (an addition to the registration, which gave
  no count; printed, and P2 still compares every verdict); T4 refusal plants (41); T5 foreign rings (2000 per crystal and u).
  Seeds: T2 2026101402, T3 2026101403, T5 2026101405.
- **Checks**: P1 closed forms (z = |s|/(1 + su), delta = -su/(1 + su), z = |g eps + n|/sigma) and no own-family-within-k plant
  mis-assigned; P2 verdict, family, payload set (order where z differ by more than 1e-6), lists (members, orbits,
  multiplicities), delta within 1e-14, z within 1e-10 max(1, z), margin within 1e-9 max(1, margin); P3 each T4 plant by its own
  name (k_max 5, 1e6, 1e19 each in a child process with a 20 s limit; a trap or timeout fails that plant's check). One FAIL line
  per check name, with the first plants.
- **Negative controls**: the 20 registered source mutants of `DSpacingIndexing.swift`, **and a 21st, `lattice-exact`** (an
  addition to the registration: it only tightens the gate): the lattice recognised at exact equality refuses the near-cubic
  and near-hexagonal cells, caught by `near-cubic list` and `near-hexagonal list`. `reference.py` confirms each moves a plant,
  a family or a crystal. Each mutant edits a copy; the gate needs "21 of 21 caught".
- **Annotation corrections** (ADR 022 addendum): the registration's "Au 8 -> 19" for absences kept is the advisor's |F| > 0
  figure; at the registered cut of -1 it is 20. The closest z to k over every family of every T1 plant is 4.9e-4 (the
  registration said 3.7e-3, probably the own family only). "Every accepted T1 plant is its own family" does not hold at
  u = 3e-2, s = -2.9 (19 accepted as another family, own z > k), as the registered prediction itself says.
- **Held only by the unit tests** (`macTEMTests/DSpacingIndexingTests.swift`): the boundary cases the 1e-6 redraw removes from the
  plants by design, so no plant sits on them: z = k exactly (accepted, not `z < k`), a margin of exactly ln 19 (accepted, not
  `<=`), q + R = k_max exactly (accepted, not `>=`), ties in (z, g) ordered by g ascending, the k_max cap of 4, the lattice
  tolerance of 1e-9 (1e-8 refused), and the family tolerance against a pair 1e-5 apart (Gate B, gbC1). The numeric reach of a
  `beyondKMax` verdict is compared here (`T<n> reach`, the margin's band 1e-9 max(1, reach)).
- **Known limit**: `validation: "none"`: chance acceptance and the real sigma are unmeasured until a pattern of known phase is indexed.

**Memory cap** (suite rule, 2026-10-15): run under a 24 GB memory cap, one at a time, nothing else heavy running. Measured peak 17.5 GB resident over 2 processes (the Swift harness and the numpy reference over 2,950,840 plants; 2026-10-15, killed at 16 GB).

## S2c: CIF import and monoclinic cells (archive: roadmap-registrations-2026-10-15.md V1-8 "S2c", ADR 024)

- **Added to the reference**: the monoclinic (unique axis b, 2/m) lattice, orbits (closure of (h,k,l) -> (-h,k,-l) and (h,-k,l)),
  canonical forms and family names ("{2 0 -1}", "{2 0 0} + {2 0 -1}"), four crystals at k_max 1.2 (M-P, M-C, M-sq, beta'') and eleven
  T4 cells. beta'' is read by **gemmi 0.7.5** (the lock) from the CIF `tools/parity/crystal-structures/make_beta_double_prime.py` writes
  into `References/crystal-structures/` (Andersen et al. 1998, Table 3 set 3); the Swift reads the same file through `CIFImport`.
  Families by exact invariants ((h2, k2, l2, hl) for a generic cell, exact `Fraction`s for M-sq) asserted equal to the 1e-9 float
  grouping. Every family also carries its `name`, compared as a string.
- **Seeds** (fixed in the build commit): T2 2026101601 (M-C and beta''), T3 2026101602 and T5 2026101603 (beta'' and M-sq); the
  base tiers' seeds and plants are unchanged. `payload.i32` (beside `plants.f64`) holds the ambiguous families of a verdict, with an
  offset per row: the beta'' list gives up to 158 per verdict, which as padded columns would be 4 GB.
- **Checks added**: `<crystal> names`; `cif model`, `cif sites` (beta'' through `CIFImport`: `.monoclinic` since the 7d6fdbd1 re-sync (`.identity` before), usable, space group 12, the
  cell exactly gemmi's, 22 sites each equal to one of gemmi's); `gemmi |g|`, `gemmi allowed` (gemmi finds 1448 space-group-allowed
  reflections at k_max 1.2, S1's list has 1442; the difference is exactly the six of {3 3 3} and {14 0 1}, under S1's 1e-4 cut),
  `gemmi orbits`; `monoclinic anchors` (d(h00) = a sin(beta)/h, d(0k0) = b/k, d(00l) = c sin(beta)/l and the closed form for (hkl), on
  M-P and beta''). T1 over the four monoclinic crystals (9810 plants per u) is compared with the registered counts.
- **Controls**: 21 (S2) + m1-m15 of `DSpacingIndexing.swift` + c1-c5 of `CIFImport.swift` + x1 of `Crystal.swift` (the oblique metric's
  cos(beta) flipped, the first test of it in macTEM) = 42; m15 (grouping at 30 %) and x1 are additions to the registration (they only
  tighten the gate). Each edits a copy.
- **Recorded, not gated**: archive: tools/parity/indexing-parity/external-pymatgen.py (pymatgen 2026.9.24 in `References/python-venv-pymatgen`, its own lock): 410 peaks,
  409 equal a family in d and multiplicity, the remaining one is {14 0 1} (S1's cut); 8 families are X-ray-extinct for it.
