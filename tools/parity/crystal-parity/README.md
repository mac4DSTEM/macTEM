# crystal-parity

archive: roadmap-registrations-2026-10-15.md V1-8 S1 (the kinematic d list): `Crystal.<preset>.reflections(kMax:)` against a numpy script written from the
definitions. `./run.sh` is the gate; classify it `scientific` in `tools/run-tests.sh`.

- **Reference** (`reference.py`): reciprocal lattice `inv(A).T` from a, b, c, α, β, γ; atom sites from the structure
  definitions (fcc, diamond = fcc + (¼,¼,¼), hcp); f_e from the Lobato–Van Dyck sum with the table of py4DSTEM
  `f050d207` `scattering_factors.txt`, fetched by `tools/lib/fetch-py4dstem-scattering.sh` and held to sha256
  `be845d1d…` (not from `ScatteringFactors.swift`); F = (1/V) Σ f_e occ e^{2πi(hx+ky+lz)}, |F| > 1e-4, d = 1/|g|.
- **Cases** at kMax = 1.2 Å⁻¹: Au, Al, Si, Mg (the Swift presets' constants) and a disordered Cu3Au-like cell for occupancy.
- **Checks**: P1 d within 1e-12; P2 |F|, complex F and intensity within 1e-9 on the same (h, k, l) set (reflections whose
  reference |F| is within ×10 of the cut, or |g| within 1e-9 of kMax, are excluded and listed); P3 fcc mixed parity and
  diamond mixed parity / 4n+2 absent.
- **Negative controls** (`MACTEM_PARITY_MUTATE`): table-row, fe-of-g, no-inverse-volume, no-diamond-basis,
  occupancy-ignored, d-offset, drop-reflection. `reference.py` also confirms in numpy that each moves its target.
- **Added after the Gate B review**: Weak-cut (occupancy solved from the table; 38 reflections kept in 1e-4...1e-3, 24 dropped in
  1e-5...1e-4) exercises the cut, edge band = relative 1e-6 of the cut; `table` compares all 103 Swift rows with py4DSTEM's to
  1e-12 (and f_e at four g^2); `hcp-absences` pins Mg's setting; controls tolerance-1e-3, table-perturb, phase-conjugate
  (|F| is unchanged by conjugation, only the complex check on non-centrosymmetric Mg sees it), sort-order (11 in all).
- **Known limit**: real ring intensities are not compared (no Debye-Waller, no absorption).
