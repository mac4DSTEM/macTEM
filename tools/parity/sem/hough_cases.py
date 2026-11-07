"""tools/parity/sem/hough_cases.py — the Hough-indexing cases of emit.py (milestone 4, figure F8).

pyEBSDindex 0.3.10.1 (US Naval Research Laboratory, public domain in the US) as kikuchipy 0.13.1 drives it: the reflector
(triplet) library of a phase (`tripletvote.addphase` / `BandIndexer.build_trip_lib`), the Radon transform and band
detection (`radon_fast.Radon`, `band_detect.BandDetect` on the CPU: pyopencl is not in the lock), the band normals in the
detector frame (`Radon.radon2pole`), the triplet vote and the band assignment (`BandIndexer.bandindex`: `_tripvote_numba`,
`_assign_bands_nb2`, the QUEST fit, `_calc_cm`) and `EBSDIndexer.index_pats` with the vendor "KIKUCHIPY" frame. The
patterns are kikuchipy's docs chain (static then dynamic background, uint8) of nickel_ebsd_large, the PC the file's mean
(Bruker convention, as `EBSDDetector.get_indexer` passes it), the indexer kikuchipy's tutorial's (nBands 10, tSigma 2,
rSigma 2, everything else EBSDIndexer's defaults). Inputs: fixtures/hough_inputs.json and the fetched scan.

Tolerances. The library is integer and float64 maths on integer poles: indices exact, angles rtol 1e-7 with atol 1e-5
degrees (arccos near 0 is ill-conditioned) and the triplet table rounded to 0.01 degrees as pyEBSDindex rounds it. The
band detection runs in float32 under numba fastmath (Radon sums, an FFT convolution): rtol 1e-5 with an atol of about
1e-6 of the array's range for the Radon arrays (1e-4 and 2e-3 on ranges of 150 and 1000); peak cells exact; sub-pixel peak positions, theta and rho within 1e-3 pixel and
1e-4 rad (the brief's bound is 1 px / 1 degree). Votes are float32 sums: rtol 1e-5. Orientations: the brief's bound, under
1 degree (symmetry-reduced) of pyEBSDindex for 99 % of points (docs/sem/north-star.md, figure 4), fraction indexed equal;
the arrays are stored float64 with a loose element tolerance the Swift test does not use for the claim.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from refbundle import Bundle

EXACT = {"rtol": 0.0, "atol": 0.0}
F64 = {"rtol": 1e-7, "atol": 0.0}
ANG = {"rtol": 1e-7, "atol": 1e-5}
F32 = {"rtol": 1e-5, "atol": 1e-6}
SUBPX = {"rtol": 0.0, "atol": 1e-3}
RAD = {"rtol": 0.0, "atol": 1e-4}
LOOSE = {"rtol": 0.0, "atol": 2e-2}
RADON = {"rtol": 1e-5, "atol": 1e-4}
CONV = {"rtol": 1e-5, "atol": 2e-3}
VOTE = {"rtol": 1e-5, "atol": 1e-3}
WIDTH = {"rtol": 0.0, "atol": 1e-3}
NORM = {"rtol": 1e-4, "atol": 1e-6}
# arccos of a float32 mean dot product near 1: one float32 ulp there is about 6e-4 degrees of fit.
FIT = {"rtol": 0.0, "atol": 2e-3}

INPUTS_FILE = Path(__file__).resolve().parent / "fixtures" / "hough_inputs.json"
INPUTS_LABEL = "fixtures/hough_inputs.json"
_H = json.loads(INPUTS_FILE.read_text())
SCAN_LABEL = "sem-data/nickel_ebsd_large/patterns_v2.h5"


def _phase(p):
    from pyebsdindex.tripletvote import addphase

    fam = None if p["polefamilies"] is None else np.asarray(p["polefamilies"])
    return addphase(phasename=p["name"], spacegroup=p["spacegroup"], latticeparameter=np.asarray(p["lattice"], dtype=float),
                    polefamilies=fam, nband_earlyexit=p["nband_earlyexit"])


def _canonical_triplets(angles: np.ndarray, ids: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """pyEBSDindex orders the triplet table by `np.argsort` (quicksort, not stable) of the family-id key; ties keep an
    arbitrary order. The bundle stores the table sorted by (family key, angles) so the order is defined; the port sorts
    the same way (the vote sums over the whole table, so the order moves only float32 rounding)."""
    basis = ids.max() + 1
    key = ids @ np.array([1, basis, basis ** 2])
    order = np.lexsort((angles[:, 2], angles[:, 1], angles[:, 0], key))
    return angles[order], ids[order]


def case_m4_hough_library(ctx):
    """The reflector library of each phase in the fixture: the pole families (after de-duplication), every symmetry
    variant (`completelib`: hkl, unit Cartesian normals, family id, the variant-to-variant angle table, the family sizes and
    offsets), the unique family-pair angles and the triplet table."""
    b = Bundle("m4/hough-library", 4, "pyebsdindex", "pyebsdindex.tripletvote.addphase / BandIndexer.build_trip_lib", ctx.out)
    b.input(INPUTS_FILE, INPUTS_LABEL)
    for p in _H["phases"]:
        lib = _phase(p)
        n = p["name"]
        b.value(f"{n}_laue", {"lauecode": int(lib.lauecode), "nsymops": int(lib.qsymops.shape[0]),
                              "npolefamilies": int(lib.npolefamilies), "angTol": float(lib.angTol),
                              "nband_earlyexit": int(lib.nband_earlyexit)})
        b.array(f"{n}_polefamilies", np.asarray(lib.polefamilies, dtype=np.float64).reshape(lib.npolefamilies, -1), **EXACT)
        c = lib.completelib
        b.array(f"{n}_poles", np.asarray(c["poles"], dtype=np.float64), **F64, note="every variant, hkl (3-index)")
        b.array(f"{n}_poles_cart", np.asarray(c["polesCart"], dtype=np.float64), **F64)
        b.array(f"{n}_family_id", np.asarray(c["familyid"], dtype=np.int32), **EXACT)
        b.array(f"{n}_ang_table", np.asarray(c["angTable"], dtype=np.float64), **ANG, note="degrees")
        b.array(f"{n}_n_family", np.asarray(c["nFamily"], dtype=np.int32), **EXACT)
        b.array(f"{n}_fam_index", np.asarray(c["famIndex"], dtype=np.int64), **EXACT)
        b.array(f"{n}_pair_angles", np.asarray(lib.angpairs["angles"], dtype=np.float64), **F64, note="degrees, 0.01 steps")
        b.array(f"{n}_pair_family_id", np.asarray(lib.angpairs["familyid"], dtype=np.int64), **EXACT)
        ta, ti = _canonical_triplets(np.asarray(lib.angtriplets["angles"], dtype=np.float64),
                                     np.asarray(lib.angtriplets["familyid"], dtype=np.int64))
        b.array(f"{n}_triplet_angles", ta, **F64, note="degrees, rows sorted ascending, table sorted by (family key, angles)")
        b.array(f"{n}_triplet_family_id", ti, **EXACT)
    b.write()
    ctx.done("m4/hough-library")


def _corrected(path: Path):
    import kikuchipy as kp

    s = kp.load(str(path))
    c = s.deepcopy()
    c.remove_static_background(operation="subtract")
    c.remove_dynamic_background(operation="subtract", filter_domain="frequency", truncate=4.0)
    return s, c


def _indexer(det, shape):
    from orix.crystal_map import Phase, PhaseList
    from diffpy.structure import Lattice, Structure

    ni = _H["phases"][0]
    a, bb, cc, al, be, ga = ni["lattice"]
    pl = PhaseList(Phase(name=ni["name"], space_group=ni["spacegroup"],
                         structure=Structure(lattice=Lattice(a, bb, cc, al, be, ga))))
    ix = _H["indexer"]
    indexer = det.get_indexer(pl, nBands=ix["nBands"], tSigma=ix["tSigma"], rSigma=ix["rSigma"])
    return pl, indexer


def _detector(s):
    det = s.detector.deepcopy()
    det.pc = s.detector.pc_average
    return det


def case_m4_hough_nickel_block(ctx):
    """Every stage on a 6 x 6 block of the corrected nickel scan (kikuchipy's uint8 patterns stored, so the port is fed
    exactly pyEBSDindex's input): the Radon plan's per-cell pixel counts, the Radon mask, the Laplacian-of-Gaussian
    kernel, the Radon transform and its convolution of the block's first pattern, the band table of every pattern, the
    band normals, the vote (weighted and plain accumulators, family and rank per band) and the indexing result."""
    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if not ctx.have(p, "m4/hough-nickel-block"):
        return
    s, c = _corrected(p)
    det = _detector(s)
    pl, indexer = _indexer(det, s.axes_manager.signal_shape[::-1])
    r0, r1 = _H["block"]["rows"]
    k0, k1 = _H["block"]["cols"]
    blk = np.asarray(c.data)[r0:r1, k0:k1]
    pats = blk.reshape(-1, *blk.shape[-2:])
    b = Bundle("m4/hough-nickel-block", 4, "pyebsdindex", "pyebsdindex.ebsd_index.EBSDIndexer.index_pats (CPU)", ctx.out)
    b.input(INPUTS_FILE, INPUTS_LABEL)
    b.input(p, SCAN_LABEL)
    b.array("block_corrected_patterns", blk, **EXACT, note=f"scan rows {r0}..{r1 - 1}, cols {k0}..{k1 - 1}, kikuchipy's uint8")
    bd = indexer.bandDetectPlan
    rp = bd.radonPlan
    b.value("pc_bruker", [float(x) for x in np.asarray(indexer.PC)])
    b.value("geometry", {"sample_tilt": float(indexer.sampleTilt), "camera_elevation": float(indexer.camElev),
                         "vendor": indexer.vendor})
    b.value("plan", {"nRho": int(bd.nRho), "nTheta": int(bd.nTheta), "rhoMax": float(bd.rhoMax), "dRho": float(bd.dRho),
                     "tSigma": float(bd.tSigma), "rSigma": float(bd.rSigma), "rhoMaskFrac": float(bd.rhoMaskFrac),
                     "peakPad": [int(x) for x in bd.peakPad], "padding": [int(x) for x in bd.padding],
                     "nBands": int(bd.nBands)})
    npx = int(rp.imDim[0] * rp.imDim[1])
    b.array("radon_counts", np.sum(rp.indexPlan < npx, axis=2).astype(np.int32), **EXACT, note="pixels on each (rho, theta) line")
    b.array("radon_theta", np.asarray(rp.theta, dtype=np.float32), **EXACT, note="degrees, float32")
    b.array("radon_rho", np.asarray(rp.rho, dtype=np.float32), **EXACT, note="pixels, float32")
    b.array("radon_mask", bd.rdnmask.astype(np.uint8), **EXACT)
    b.array("kernel", bd.kernel[0].astype(np.float32), **F32)
    first = pats[:1]
    rdn = rp.radon_faster(first, bd.padding, fixArtifacts=False, background=bd.backgroundsub)
    pr, pt = bd.padding
    b.array("radon_first", np.ascontiguousarray(rdn[pr:-pr, pt:-pt, 0]), **RADON, note="unpadded (nRho, nTheta)")
    conv, mam = bd.rdn_conv(rdn.copy())
    b.array("radon_conv_first", np.ascontiguousarray(conv[:, :, 0]), **CONV,
            note="padded (nRho + 2 pad, nTheta + 2 pad) after the edge fill and the convolution")
    b.array("radon_conv_stats_first", np.asarray([mam[0][0], mam[1][0], mam[2][0]], dtype=np.float32), **CONV,
            note="min, mean, max over pyEBSDindex's window")
    data, bands, _, _ = indexer.index_pats(patsin=pats, verbose=0, chunksize=528)
    b.array("band_max", np.asarray(bands["max"], dtype=np.float32), **F32, note="convolved Radon peak value")
    b.array("band_avemax", np.asarray(bands["avemax"], dtype=np.float32), **F32)
    b.array("band_normmax", np.asarray(bands["normmax"], dtype=np.float32), **NORM, note="(max - min) / (mean - min) of the convolved Radon")
    b.array("band_width", np.asarray(bands["width"], dtype=np.float32), **WIDTH)
    b.array("band_maxloc", np.asarray(bands["maxloc"], dtype=np.float32), **EXACT, note="(rho, theta) Radon cell, unpadded")
    b.array("band_aveloc", np.asarray(bands["aveloc"], dtype=np.float32), **SUBPX)
    b.array("band_theta", np.asarray(bands["theta"], dtype=np.float32), **RAD, note="radians")
    b.array("band_rho", np.asarray(bands["rho"], dtype=np.float32), **SUBPX, note="pixels")
    b.array("band_valid", np.asarray(bands["valid"], dtype=np.uint8), **EXACT)
    norms = rp.radon2pole(bands, PC=indexer.PC, vendor=indexer.vendor)
    b.array("band_normals", np.asarray(norms, dtype=np.float32), **RAD, note="unit normals in the detector frame")
    lib = indexer.phaseLib[0]
    rhomax = bd.rhoMax
    adj = (-1 * np.abs(bands["rho"]) * 0.5 / rhomax + 1) * bands["max"]
    adj *= ((bands["theta"] > (2 * np.pi / 180)).astype(np.float32) + 0.5) / 2
    adj *= ((bands["theta"] < (178.0 * np.pi / 180)).astype(np.float32) + 0.5) / 2
    adj *= bands["valid"]
    b.array("band_intensity", np.asarray(adj, dtype=np.float32), **F32, note="the vote's band weights")
    accW, fam, rank, bcm, acc = lib._tripvote_numba(norms, adj, lib.lut, lib.angTol, lib.angtriplets["angles"],
                                                    lib.angtriplets["familyid"], lib.polefamilies.shape[0])
    b.array("vote_accumulator_weighted", np.asarray(accW, dtype=np.float32), **VOTE)
    b.array("vote_accumulator", np.asarray(acc, dtype=np.float32), **EXACT)
    b.array("vote_band_family", np.asarray(fam, dtype=np.int32), **EXACT)
    b.array("vote_band_rank", np.asarray(rank, dtype=np.float32), **VOTE)
    d = data[-1]
    b.array("quaternion", np.asarray(d["quat"], dtype=np.float64), **LOOSE, note="KIKUCHIPY frame, a >= 0; the test holds misorientation")
    b.array("fit", np.asarray(d["fit"], dtype=np.float32), **FIT, note="degrees")
    b.array("cm", np.asarray(d["cm"], dtype=np.float32), **F32)
    b.array("pq", np.asarray(d["pq"], dtype=np.float32), **F32)
    b.array("iq", np.asarray(d["iq"], dtype=np.float32), **NORM)
    b.array("nmatch", np.asarray(d["nmatch"], dtype=np.int32), **EXACT)
    b.array("phase", np.asarray(d["phase"], dtype=np.int32), **EXACT)
    b.array("matchattempts", np.asarray(d["matchattempts"], dtype=np.int32), **EXACT)
    b.array("totvotes", np.asarray(d["totvotes"], dtype=np.int32), **EXACT)
    b.array("band_match_index", np.asarray(bands["band_match_index"][:, :, 0], dtype=np.int64), **EXACT,
            note="library variant per band; symmetry-equivalent solutions pick other variants, the test holds the family")
    b.array("band_fit", np.asarray(bands["bandfit"][:, :, 0], dtype=np.float64), **{"rtol": 1e-4, "atol": 1e-3})
    b.write()
    ctx.done("m4/hough-nickel-block")


def case_m4_hough_indexing_nickel_large(ctx):
    """North-star figure F8: the Hough-indexed map of the whole corrected scan, Ni only, through kikuchipy's
    `EBSD.hough_indexing` (the crystal map's quaternions, Euler angles and properties)."""
    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    if not ctx.have(p, "m4/hough-indexing-nickel-large"):
        return
    s, c = _corrected(p)
    det = _detector(s)
    pl, indexer = _indexer(det, s.axes_manager.signal_shape[::-1])
    xmap, data, bands = c.hough_indexing(pl, indexer, verbose=0, return_index_data=True, return_band_data=True)
    b = Bundle("m4/hough-indexing-nickel-large", 4, "kikuchipy", "kikuchipy.signals.EBSD.hough_indexing (pyEBSDindex CPU)", ctx.out)
    b.input(INPUTS_FILE, INPUTS_LABEL)
    b.input(p, SCAN_LABEL)
    nav = list(c.axes_manager.navigation_shape[::-1])
    b.value("navigation_shape_rc", nav)
    b.value("pc_bruker", [float(x) for x in np.asarray(indexer.PC)])
    pid = np.asarray(xmap.phase_id, dtype=np.int32)
    b.value("indexed", int((pid >= 0).sum()))
    b.value("points", int(pid.size))
    b.array("phase", pid.reshape(nav), **EXACT)
    b.array("quaternion", np.asarray(xmap.rotations.data, dtype=np.float64).reshape(*nav, 4), **LOOSE,
            note="orix Rotation data (KIKUCHIPY frame); the test holds the symmetry-reduced misorientation < 1 degree")
    b.array("euler", np.asarray(xmap.rotations.to_euler(), dtype=np.float64).reshape(*nav, 3), **LOOSE, note="Bunge, radians")
    b.array("nmatch", np.asarray(xmap.prop["nmatch"], dtype=np.int32).reshape(nav), **EXACT)
    for f in ["fit", "cm", "pq"]:
        b.array(f, np.asarray(xmap.prop[f], dtype=np.float32).reshape(nav), **F32)
    b.write()
    ctx.done("m4/hough-indexing-nickel-large")
