"""tools/parity/sem/similarity_cases.py — the orientation similarity map and the merge of dictionary maps (milestone 4).

kikuchipy 0.13.1's `orientation_similarity_map` (Marquardt et al. 2017, Microsc. Microanal. 23, 1144) and
`merge_crystal_maps`, the two tools that work on the ranked simulation indices and scores that dictionary indexing
leaves in a crystal map (`m4/dictionary-indexing-*`). Both are bookkeeping on integers and float32 scores, so everything is
held exact (the brief asks for the OSM to match exactly).

`m4/orientation-similarity-map`: a 7 x 9 synthetic map with keep_n 6 drawn from a pool of 16 indices (so neighbours share
some), run with the defaults, with n_best 5 down to from_n_best 2 normalised, with a full 3 x 3 footprint, with an even
2 x 2 footprint (scipy's origin) and with a footprint whose centre index is not the middle; and the default OSM of figure
F9's whole 55 x 75 scan from the committed `m4/dictionary-indexing-nickel-ebsd-large` indices.

`m4/merge-crystal-maps`: three synthetic 6 x 7 maps with keep_n 5 (float32 scores on a coarse grid of 40 levels, so scores
tie across maps and the stable merge sort and nanargmax's first maximum are exercised): two phases by mean of the best 1,
three maps of which the third repeats the first phase (equal: one phase; different lattice: renamed with the map's
index), the mean of the best 3, the lowest 2 (a negative mean_n_best), and navigation masks (merged indices as floats
with NaN, kikuchipy's increment with nanmax and nanmin).
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from refbundle import Bundle

HERE = Path(__file__).resolve().parent
F9 = HERE / "references" / "m4" / "dictionary-indexing-nickel-ebsd-large"
EXACT = {"rtol": 0.0, "atol": 0.0}


def _osm_run(b: Bundle, name: str, xmap, **kw) -> None:
    from kikuchipy.indexing import orientation_similarity_map

    osm = np.asarray(orientation_similarity_map(xmap, **kw), dtype=np.float32)
    b.value(f"{name}_options", {k: (v.astype(int).tolist() if isinstance(v, np.ndarray) else v) for k, v in kw.items()})
    b.array(f"{name}_osm", osm, **EXACT, note="float32 as kikuchipy returns it; NaN where a point has no neighbour")


def _index_map(indices: np.ndarray, shape: tuple[int, int]):
    from orix.crystal_map import CrystalMap, create_coordinate_arrays
    from orix.quaternion import Rotation

    m, n = indices.shape
    coords, _ = create_coordinate_arrays(shape, step_sizes=(1.0, 1.0))
    return CrystalMap(rotations=Rotation(np.tile([1.0, 0, 0, 0], (m, n, 1))), prop={"simulation_indices": indices}, **coords)


def case_m4_orientation_similarity_map(ctx):
    b = Bundle("m4/orientation-similarity-map", 4, "kikuchipy",
               "kikuchipy.indexing.orientation_similarity_map", ctx.out)
    rng = np.random.default_rng(213)
    shape, keep_n = (7, 9), 6
    idx = np.stack([rng.choice(16, size=keep_n, replace=False) for _ in range(shape[0] * shape[1])]).astype(np.int32)
    b.value("shape", list(shape))
    b.array("simulation_indices", idx, **EXACT, note="synthetic: keep_n 6 distinct of 0..15 per point, row-major")
    xmap = _index_map(idx, shape)
    _osm_run(b, "default", xmap)
    _osm_run(b, "range", xmap, n_best=5, from_n_best=2, normalize=True)
    _osm_run(b, "square", xmap, footprint=np.ones((3, 3), dtype=int), center_index=4)
    _osm_run(b, "even", xmap, n_best=3, footprint=np.ones((2, 2), dtype=int), center_index=3)
    _osm_run(b, "corner", xmap, footprint=np.array([[1, 1, 0], [0, 1, 0], [0, 0, 1]]), center_index=0)

    f9 = F9 / "ncc_simulation_indices.bin"
    b.input(f9, "references/m4/dictionary-indexing-nickel-ebsd-large/ncc_simulation_indices.bin")
    real = np.fromfile(f9, dtype="<i4").reshape(-1, 5)
    _osm_run(b, "f9", _index_map(real, (55, 75)))
    b.write()
    ctx.done("m4/orientation-similarity-map")


PHASES = {
    "ni": dict(space_group=225, lattice=(3.52, 3.52, 3.52, 90, 90, 90)),
    "al": dict(space_group=225, lattice=(4.05, 4.05, 4.05, 90, 90, 90)),
    "ni_other": dict(space_group=225, lattice=(3.60, 3.60, 3.60, 90, 90, 90)),
}


def _phase(key: str):
    from diffpy.structure import Lattice, Structure
    from orix.crystal_map import Phase

    p = PHASES[key]
    return Phase(name=key.split("_")[0], space_group=p["space_group"], structure=Structure(lattice=Lattice(*p["lattice"])))


def _merge_inputs(rng, shape, keep_n, count):
    m = shape[0] * shape[1]
    out = []
    for _ in range(count):
        scores = -np.sort(-rng.integers(0, 40, size=(m, keep_n)), axis=1).astype(np.float32) / np.float32(40)
        indices = np.stack([rng.choice(300, size=keep_n, replace=False) for _ in range(m)]).astype(np.int32)
        q = rng.normal(size=(m, keep_n, 4))
        q /= np.linalg.norm(q, axis=-1, keepdims=True)
        out.append((scores, indices, q))
    return out


def _merge_run(b: Bundle, name: str, inputs, keys, shape, masks=None, **kw) -> None:
    from kikuchipy.indexing import merge_crystal_maps
    from orix.crystal_map import CrystalMap, PhaseList, create_coordinate_arrays
    from orix.quaternion import Rotation

    xmaps = []
    for i, (key, (scores, indices, q)) in enumerate(zip(keys, inputs)):
        keep = np.ones(scores.shape[0], dtype=bool) if masks is None or masks[i] is None else ~masks[i].ravel()
        coords, _ = create_coordinate_arrays(shape, step_sizes=(1.0, 1.0))
        coords = {k: v[keep] for k, v in coords.items()}
        xmaps.append(CrystalMap(rotations=Rotation(q[keep]), phase_list=PhaseList(_phase(key)),
                                prop={"scores": scores[keep], "simulation_indices": indices[keep]}, **coords))
    merged = merge_crystal_maps(xmaps, simulation_indices_prop="simulation_indices", navigation_masks=masks, **kw)
    b.value(f"{name}_maps", list(keys))
    b.value(f"{name}_options", kw)
    b.value(f"{name}_phases", {str(i): {"name": p.name, "color": p.color} for i, p in merged.phases})
    b.array(f"{name}_phase_id", np.asarray(merged.phase_id, dtype=np.int32), **EXACT)
    b.array(f"{name}_rotations", np.asarray(merged.rotations.data, dtype=np.float64).reshape(-1, inputs[0][0].shape[1], 4), **EXACT)
    b.array(f"{name}_scores", np.asarray(merged.prop["scores"], dtype=np.float32), **EXACT)
    b.array(f"{name}_merged_scores", np.asarray(merged.prop["merged_scores"], dtype=np.float32), **EXACT,
            note="every map's scores per point, merge-sorted best first (stable over n-major, map-minor order)")
    b.array(f"{name}_simulation_indices", np.asarray(merged.prop["simulation_indices"], dtype=np.int32), **EXACT)
    b.array(f"{name}_merged_simulation_indices",
            np.asarray(merged.prop["merged_simulation_indices"], dtype=np.float64), **EXACT,
            note="each map's indices shifted past the previous map's (kikuchipy's increment), sorted as the scores; NaN out of data")


def case_m4_merge_crystal_maps(ctx):
    b = Bundle("m4/merge-crystal-maps", 4, "kikuchipy", "kikuchipy.indexing.merge_crystal_maps", ctx.out)
    rng = np.random.default_rng(2131)
    shape, keep_n = (6, 7), 5
    inputs = _merge_inputs(rng, shape, keep_n, 3)
    b.value("shape", list(shape))
    b.value("keep_n", keep_n)
    b.value("phases", {k: {"name": k.split("_")[0], **{kk: list(vv) if isinstance(vv, tuple) else vv for kk, vv in v.items()}}
                       for k, v in PHASES.items()})
    for i, (scores, indices, q) in enumerate(inputs):
        b.array(f"map{i}_scores", scores, **EXACT, note="synthetic float32 scores, 40 levels, best first")
        b.array(f"map{i}_simulation_indices", indices, **EXACT)
        b.array(f"map{i}_rotations", q, **EXACT)
    _merge_run(b, "two", inputs[:2], ["ni", "al"], shape)
    _merge_run(b, "equal", inputs, ["ni", "al", "ni"], shape, mean_n_best=3)
    _merge_run(b, "renamed", inputs, ["ni", "al", "ni_other"], shape)
    _merge_run(b, "lowest", inputs[:2], ["ni", "al"], shape, mean_n_best=-2)
    masks = [np.zeros(shape, dtype=bool), None, np.zeros(shape, dtype=bool)]
    masks[0][0, :4] = True
    masks[0][3, 2] = True
    masks[2][5, :] = True
    masks[2][0, 1] = True
    b.array("masked_mask0", masks[0].astype(np.uint8), **EXACT, note="1 = point not in map 0")
    b.array("masked_mask2", masks[2].astype(np.uint8), **EXACT, note="1 = point not in map 2")
    _merge_run(b, "masked", inputs, ["ni", "al", "ni_other"], shape, masks=masks, greater_is_better=True)
    b.write()
    ctx.done("m4/merge-crystal-maps")
