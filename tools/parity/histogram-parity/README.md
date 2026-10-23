# histogram-parity

macTEM's `IntensityHistogram` (ImagoKit's `compute(_:bins:range:)` at 96 bins, with the app's `Sources/TEMCore/Compute/IntensityHistogram.swift` extension; compiled from
`tools/lib/sources.manifest` groups `histogram` and `dm`) against numpy 2.5.4 (pinned in
`tools/lib/references-lock.txt`). A `scientific` gate (`tools/run-tests.sh scientific`); the pre-registration is archive: roadmap-registrations-2026-10-15.md
V1-4, "Completed at pickup (2026-10-13)". Run `tools/parity/histogram-parity/run.sh`, redirect it to a log, and read the exit code
on its own line.

The quantity is `a` float32, `f = a[np.isfinite(a)]`, `np.histogram(f, bins=96, range=(f.min(), f.max()))`, plus the finite
count, `f.min()`, `f.max()` and `f.astype(np.float64).mean()`. The histogram is of the RAW pixels, never of the display
canvas.

## Pass band (P1)

- counts equal bin for bin, and numpy's 97 `bin_edges` equal bit for bit;
- min and max equal bit for bit (numpy orders -0.0 below +0.0; so does the port), the finite count equal;
- the mean within 1e-9 of the larger of |mean| and the mean of |pixel| (numpy sums pairwise, macTEM blockwise in Double;
  the scale keeps a mean near zero from large values of both signs from needing an impossible relative bar). The
  measured difference over every case in the 2026-10-13 run: bit-identical but for one case at 7.5e-16.
- where numpy refuses the range (`ValueError: Too many bins for data range`) macTEM's histogram has no counts and no
  edges, its statistics still equal numpy's; where no pixel is finite there is no histogram (`nil`).

## What numpy does (read in `numpy/lib/_histograms_impl.py` and `numpy/_core/function_base.py`, 2.5.4)

`range=(f.min(), f.max())` passes numpy float32 SCALARS, so the whole uniform-bins path stays in float32 (NEP 50: a
Python `0.5` or `96` does not promote):

1. a range with `first == last` becomes `(first - 0.5, last + 0.5)`, in float32;
2. the edges are `np.linspace(first, last, 97, dtype=float32)`: `step = (last - first)/96` in float32, edge i =
   `float32(i)*step + first` (two roundings, no fused multiply-add), the last edge assigned `last`; when `step == 0`
   (denormal range) it is `float32(i)/96*(last - first) + first`;
3. edges that are not strictly increasing are refused: a range of fewer than 96 ulps, a denormal range numpy's linspace
   cannot space, a constant whose +-0.5 is lost to rounding (3e7, 1e8), a `last - first` that overflows (+-3.4e38);
4. a pixel's bin is `int(((p - first)/(last - first))*96)` in float32, a value on the last edge moved down one, then
   corrected against the edges by ONE decrement (`p < edges[i]`) and then ONE increment (`p >= edges[i+1]` and `i` is not
   the last bin). The uncorrected index is wrong within an ulp of an edge: on the planted edge arrays it is one too low for
   843 pixels and one too high for 718 (2026-10-13 run), so the corrections are exercised in both directions
   (`reference.py` asserts this before it counts as a comparator). One correction each way is not always enough in a
   denormal range of some hundreds of units, where numpy's counts disagree with its own edges (Gate B 2026-10-13: 6 of
   201 pixels over 0…200 units); the port reproduces numpy there, which is what P1 asks.

## Datasets

1. **Planted float32 arrays** (`reference.py`), seeded, written to the scratch directory at every run, each checked against
   what was planted before numpy's answer counts:
   - values on every bin edge numpy computes for 36 ranges, and one ulp either side (the values within the range): unit,
     a 16-bit camera range, DM's int16 range, a 1e6 offset, 1e30, 1000 ulps wide, 24 random ones; numpy's counts must
     equal the definition (the last edge <= value, the last bin closed) by `searchsorted`;
   - constants (7.25, 0, -3.5, widened to +-0.5 with every pixel in bin 48; 3e7 and 1e8, refused);
   - one finite value among NaN and +-inf; 5000 normal values among 100 NaN and 80 infinities; no finite value; empty;
   - two values (600 / 400 in the first and last bins); two values one ulp apart (refused);
   - spans of 1, 2, 50, 95 (refused: 97 distinct float32 edges do not fit) to 100, 200, 1000 ulps, at 1, 1e-3, 1e6, -1
     and 0 (denormals); denormal ranges; +-3.4e38 (overflow, refused) and 0 to 3.4e38;
   - signed zeros in every order (numpy's min is -0.0 and its max +0.0 whenever both are present);
   - three 2048 x 2048 images (normal noise with hot and dead pixels, every integer, Poisson counts with a saturated pixel)
     and a million lognormal values.
2. **Real images**: the harness opens each through `ImageOpening.openNow` and writes the pixels it got; numpy histograms
   the same float32 values (the readers' own correctness is `tools/parity/dm4-reader-parity`, `tiff-reader-parity` and
   `mrc-reader-parity`). The committed `macTEMTests/Fixtures/planted-2d.dm4` (40 x 24, row*1000 + col - 12000, asserted),
   RosettaSciIO's GMS DigitalMicrograph files, ImageJ and DM-saved TIFFs and single-image MRCs at its pinned commit (sha256
   against its registry), and the owner's six Ceta TIFFs from `References/example_files/` where present (gitignored,
   machine-local: the summary line says how many were gated).

## Negative controls

Seven, each caught only when the mutant exits 1 and the check it targets is among its failures (`run.sh`). Six edit a COPY
of `IntensityHistogram.swift` (one exact edit each, which must apply once; the file in `Sources/` is never touched) and
rebuild; the seventh feeds the harness's normalised pixels to the unedited histogram.

| Mutation | Its check |
|---|---|
| edge corrections dropped | `edges-tenth counts` |
| last bin half-open | `two-valued counts` |
| non-finite counted | `mixed-nonfinite finite count` |
| 95 bins | `bin count` |
| constant image not widened | `constant-7.25 refusal` |
| histogram of the display canvas (`MACTEM_PARITY_MUTATE=display-canvas`) | `real-planted-2d.dm4 minimum` |
| mean accumulated in Float32 | `noisy-2048 mean` |
