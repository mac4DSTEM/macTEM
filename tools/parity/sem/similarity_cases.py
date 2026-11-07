"""tools/parity/sem/similarity_cases.py — the orientation similarity map and the merge of dictionary maps (milestone 4).

kikuchipy 0.13.1's `orientation_similarity_map` (Marquardt et al. 2017, Microsc. Microanal. 23, 1144) and
`merge_crystal_maps`, the two tools that work on the ranked simulation indices and scores that dictionary indexing
leaves in a crystal map (`m4/dictionary-indexing-*`). Both are bookkeeping on integers and float32 scores, so they are
held exact (the brief asks for the OSM to match exactly); only the merged rotations are held to 1e-15, as orix
normalises quaternions again when it builds the merged map.

The settings are `fixtures/similarity_inputs.json`. `m4/orientation-similarity-map`: a 7 x 9 synthetic map with keep_n 6
drawn from a pool of 16 indices (so neighbours share some) in five settings (defaults; n_best 5 down to 2 normalised; a
full 3 x 3 footprint; an even 2 x 2 footprint, scipy's origin; a footprint whose centre index is a corner), and the default
OSM of figure F9's whole 55 x 75 scan from the committed `m4/dictionary-indexing-nickel-ebsd-large` indices.

`m4/merge-crystal-maps`: three synthetic 6 x 7 maps with keep_n 5 (float32 scores on 40 levels, so scores tie across maps
and the stable merge sort and nanargmax's first maximum are exercised): two phases by the best score, three maps whose
third repeats the first phase (equal: one phase; different lattice: renamed with the map's index), the mean of the best 3,
the lowest 2 (a negative mean_n_best), navigation masks, and the three maps' best match alone (keep_n 1: one score and index
per point, the 1-D properties kikuchipy's merge takes). Each merge without navigation masks also holds kikuchipy's
orientation similarity map on its merged simulation indices (`orientation_similarity_map(merged,
simulation_indices_prop="merged_simulation_indices")` with its defaults: every merged match, not normalised, the four nearest
neighbours), the Indexing room's OSM of a run against several phases (D-SEM-98).

A reference holds no NaN (SEMParityHarnessTests): kikuchipy's NaN (an OSM point without neighbours, a merged score or
index out of a map's data) is stored as -1, which no OSM value, score or index takes.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from refbundle import Bundle

HERE = Path(__file__).resolve().parent
INPUTS = HERE / "fixtures" / "similarity_inputs.json"
EXACT = {"rtol": 0.0, "atol": 0.0}
ROTATIONS = {"rtol": 0.0, "atol": 1e-15}
NAN = -1


def _no_nan(a: np.ndarray) -> np.ndarray:
    a = np.array(a, copy=True)
    a[np.isnan(a)] = NAN
    return a


def _index_map(indices: np.ndarray, shape):
    from orix.crystal_map import CrystalMap, create_coordinate_arrays
    from orix.quaternion import Rotation

    m, n = indices.shape
    coords, _ = create_coordinate_arrays(tuple(shape), step_sizes=(1.0, 1.0))
    return CrystalMap(rotations=Rotation(np.tile([1.0, 0, 0, 0], (m, n, 1))), prop={"simulation_indices": indices}, **coords)


def _osm_run(b: Bundle, name: str, xmap, kw: dict) -> None:
    from kikuchipy.indexing import orientation_similarity_map

    kw = {k: (np.array(v) if k == "footprint" else v) for k, v in kw.items()}
    osm = np.asarray(orientation_similarity_map(xmap, **kw), dtype=np.float32)
    b.array(f"{name}_osm", _no_nan(osm), **EXACT, note="float32 as kikuchipy returns it, n_best..from_n_best on the last axis; -1 for NaN")


def case_m4_orientation_similarity_map(ctx):
    cfg = json.loads(INPUTS.read_text())["orientation_similarity_map"]
    b = Bundle("m4/orientation-similarity-map", 4, "kikuchipy", "kikuchipy.indexing.orientation_similarity_map", ctx.out)
    b.input(INPUTS, "fixtures/similarity_inputs.json")
    rng = np.random.default_rng(cfg["seed"])
    shape, keep_n = cfg["shape"], cfg["keep_n"]
    idx = np.stack([rng.choice(cfg["pool"], size=keep_n, replace=False) for _ in range(shape[0] * shape[1])]).astype(np.int32)
    b.array("simulation_indices", idx, **EXACT, note="synthetic: keep_n distinct of the pool per point, row-major")
    xmap = _index_map(idx, shape)
    for name, kw in cfg["runs"].items():
        _osm_run(b, name, xmap, kw)
    real = np.fromfile(HERE / cfg["f9"], dtype="<i4").reshape(-1, 5)
    _osm_run(b, "f9", _index_map(real, (55, 75)), {})
    b.write()
    ctx.done("m4/orientation-similarity-map")


def _phase(p: dict):
    from diffpy.structure import Lattice, Structure
    from orix.crystal_map import Phase

    return Phase(name=p["name"], space_group=p["space_group"], structure=Structure(lattice=Lattice(*p["lattice"])))


def _merge_run(b: Bundle, name: str, inputs, cfg: dict, run: dict) -> None:
    from kikuchipy.indexing import merge_crystal_maps
    from orix.crystal_map import CrystalMap, PhaseList, create_coordinate_arrays
    from orix.quaternion import Rotation

    shape = tuple(cfg["shape"])
    keys = run["maps"]
    keep_n = run.get("keep_n", cfg["keep_n"])
    masks = None
    if "masked_points" in run:
        masks = []
        for points in run["masked_points"]:
            if points is None:
                masks.append(None)
                continue
            m = np.zeros(shape, dtype=bool)
            for r, c in points:
                m[r, c] = True
            masks.append(m)
    xmaps = []
    for i, key in enumerate(keys):
        scores, indices, q = inputs[i]
        if keep_n == 1:
            # The best match alone, as 1-D properties (kikuchipy's merge takes one score per point only so).
            scores, indices, q = scores[:, 0], indices[:, 0], q[:, 0]
        keep = np.ones(scores.shape[0], dtype=bool) if masks is None or masks[i] is None else ~masks[i].ravel()
        coords, _ = create_coordinate_arrays(shape, step_sizes=(1.0, 1.0))
        coords = {k: v[keep] for k, v in coords.items()}
        xmaps.append(CrystalMap(rotations=Rotation(q[keep]), phase_list=PhaseList(_phase(cfg["phases"][key])),
                                prop={"scores": scores[keep], "simulation_indices": indices[keep]}, **coords))
    merged = merge_crystal_maps(xmaps, simulation_indices_prop="simulation_indices", navigation_masks=masks, **run["options"])
    b.value(f"{name}_phases", {str(i): {"name": p.name, "color": p.color} for i, p in merged.phases})
    b.array(f"{name}_phase_id", np.asarray(merged.phase_id, dtype=np.int32), **EXACT)
    b.array(f"{name}_rotations", np.asarray(merged.rotations.data, dtype=np.float64).reshape(-1, keep_n, 4), **ROTATIONS,
            note="orix normalises the chosen map's quaternions again in the merged map")
    b.array(f"{name}_scores", np.asarray(merged.prop["scores"], dtype=np.float32), **EXACT)
    b.array(f"{name}_merged_scores", _no_nan(np.asarray(merged.prop["merged_scores"], dtype=np.float32)), **EXACT,
            note="every map's scores per point, merge-sorted best first (stable over n-major, map-minor order); -1 for NaN")
    b.array(f"{name}_simulation_indices", np.asarray(merged.prop["simulation_indices"], dtype=np.int32), **EXACT)
    b.array(f"{name}_merged_simulation_indices",
            _no_nan(np.asarray(merged.prop["merged_simulation_indices"], dtype=np.float64)), **EXACT,
            note="each map's indices shifted past the previous map's (kikuchipy's increment), sorted as the scores; -1 for NaN")
    if masks is None:
        from kikuchipy.indexing import orientation_similarity_map

        osm = np.asarray(orientation_similarity_map(merged, simulation_indices_prop="merged_simulation_indices"), dtype=np.float32)
        b.array(f"{name}_osm", _no_nan(osm), **EXACT,
                note="orientation_similarity_map(merged, simulation_indices_prop='merged_simulation_indices') with its defaults "
                     "(n_best = keep_n x maps, not normalised, the four nearest neighbours): the Indexing room's OSM of several "
                     "phases")


def case_m4_merge_crystal_maps(ctx):
    cfg = json.loads(INPUTS.read_text())["merge_crystal_maps"]
    b = Bundle("m4/merge-crystal-maps", 4, "kikuchipy", "kikuchipy.indexing.merge_crystal_maps", ctx.out)
    b.input(INPUTS, "fixtures/similarity_inputs.json")
    rng = np.random.default_rng(cfg["seed"])
    m, keep_n, levels = cfg["shape"][0] * cfg["shape"][1], cfg["keep_n"], cfg["score_levels"]
    inputs = []
    for i in range(cfg["maps"]):
        scores = -np.sort(-rng.integers(0, levels, size=(m, keep_n)), axis=1).astype(np.float32) / np.float32(levels)
        indices = np.stack([rng.choice(cfg["index_pool"], size=keep_n, replace=False) for _ in range(m)]).astype(np.int32)
        q = rng.normal(size=(m, keep_n, 4))
        q /= np.linalg.norm(q, axis=-1, keepdims=True)
        b.array(f"map{i}_scores", scores, **EXACT, note="synthetic float32 scores on score_levels levels, best first")
        b.array(f"map{i}_simulation_indices", indices, **EXACT)
        b.array(f"map{i}_rotations", q, **EXACT)
        inputs.append((scores, indices, q))
    for name, run in cfg["runs"].items():
        _merge_run(b, name, inputs, cfg, run)
    b.write()
    ctx.done("m4/merge-crystal-maps")
