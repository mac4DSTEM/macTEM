"""tools/parity/sem/simulation_cases.py — the Kikuchi simulation cases of emit.py (milestone 6, figure F14).

kikuchipy 0.13.1's `KikuchiPatternSimulator` on diffsims 0.7.0's `ReciprocalLatticeVector`: the lattice (diffpy's
`Lattice.base`, `recbase`, `rnorm`), the reflectors (`symmetrise`, `from_min_dspacing`, `allowed`, `dspacing`), the
kinematical structure factors (`calculate_structure_factor`, International Tables X-ray parameters) and Bragg angles
(`calculate_theta`, the refraction-corrected wavelength with Doyle-Turner's mean inner potential), the geometrical
simulation on a detector (`on_detector`, `lines_coordinates`, `zone_axes_coordinates`: figure F14 on pattern (0, 0) of
nickel_ebsd_large and three more points, and a titanium detector at every angle), and the kinematical master pattern
(`calculate_master_pattern`). Every input is in fixtures/simulation_cases.json; F14 also reads the nickel_ebsd_large
file (its crystal map and projection centres). emit.py imports every `case_` function here.

Tolerances: numpy's float64 default (rtol 1e-7) for what kikuchipy and diffsims compute in float64; atol 1e-6 px on the
detector coordinates (the brief's bound; numba's fastmath kernels round differently in the last bits); exact for indices
and masks. The master pattern at rtol 1e-5 (the brief's bound), emitted with numba on one thread: kikuchipy's
`get_pattern` adds every reflector into the same pixel from a `prange`, which can lose an addition when several threads
hit one pixel (one thread is the algorithm as written, and every value is a sum of the reflectors' intensities).
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from refbundle import Bundle

F64 = {"rtol": 1e-7, "atol": 0.0}
F64Z = {"rtol": 1e-7, "atol": 1e-12}
PX = {"rtol": 1e-7, "atol": 1e-6}
MP = {"rtol": 1e-5, "atol": 1e-8}
EXACT = {"rtol": 0.0, "atol": 0.0}

CASES_FILE = Path(__file__).resolve().parent / "fixtures" / "simulation_cases.json"
CASES_LABEL = "fixtures/simulation_cases.json"
_C = json.loads(CASES_FILE.read_text())


def _phase(name: str, symbols: bool = True):
    """The phase as kikuchipy's tutorial builds it: an orix `Phase` with a diffpy `Structure` of the asymmetric atoms,
    elements by symbol (diffsims looks the X-ray parameters up by symbol)."""
    from diffpy.structure import Atom, Lattice, Structure
    from orix.crystal_map import Phase

    p = _C["phases"][name]
    atoms = [Atom(sym if symbols else z, xyz, occupancy=occ) for sym, z, xyz, occ in p["atoms"]]
    return Phase(name=name, space_group=p["space_group"], structure=Structure(lattice=Lattice(*p["lattice"]), atoms=atoms))


def _hkl_int(a) -> np.ndarray:
    return np.round(np.asarray(a, dtype=np.float64)).astype(np.int32)


def case_m6_kikuchi_lattice(ctx):
    """diffpy's lattice as the simulation uses it: `base` (rows a, b, c in Cartesian, c along z, b in the yz plane; and as orix's `Phase` re-aligns it, x along a and
    z along c*, the frame every simulation here works in),
    `recbase` (its inverse, columns a*, b*, c*), `volume` and `rnorm` (|g| in 1/length) of a few hkl, for cubic,
    hexagonal, triclinic, monoclinic and rhombohedral cells (the exact cosines of 60, 90 and 120 degrees included)."""
    from diffpy.structure import Lattice

    b = Bundle("m6/kikuchi-lattice", 6, "diffpy.structure", "diffpy.structure.Lattice base / recbase / volume / rnorm", ctx.out)
    b.input(CASES_FILE, CASES_LABEL)
    lattices = _C["lattices"]
    hkl = np.asarray(_C["lattice_hkl"], dtype=np.float64)
    b.value("lattices", lattices)
    b.value("hkl", _C["lattice_hkl"])
    from diffpy.structure import Structure
    from orix.crystal_map import Phase

    bases, recs, vols, norms, obases, orecs = [], [], [], [], [], []
    for lat in lattices:
        L = Lattice(*lat)
        bases.append(L.base)
        recs.append(L.recbase)
        vols.append(L.volume)
        norms.append(L.rnorm(hkl))
        O = Phase(space_group=1, structure=Structure(lattice=Lattice(*lat))).structure.lattice
        obases.append(O.base)
        orecs.append(O.recbase)
    b.array("base", np.asarray(bases), **F64Z, note="lattice, row (a, b, c), Cartesian (x, y, z)")
    b.array("recbase", np.asarray(recs), **F64Z, note="lattice, Cartesian row, column (a*, b*, c*); the inverse of base")
    b.array("orix_base", np.asarray(obases), **F64Z,
            note="the same lattice as an orix Phase holds it: rows a, b, c with x along a and z along c* (rounded to 12 decimals)")
    b.array("orix_recbase", np.asarray(orecs), **F64Z)
    b.array("volume", np.asarray(vols), **F64)
    b.array("rnorm", np.asarray(norms), **F64, note="lattice, hkl (values['hkl'])")
    b.write()
    ctx.done("m6/kikuchi-lattice")


def _reflectors_bundle(ctx, name: str) -> None:
    import diffsims
    from diffsims.crystallography import ReciprocalLatticeVector
    from diffsims.structure_factor.structure_factor import get_refraction_corrected_wavelength

    case = f"m6/kikuchi-reflectors-{name.replace('al2cu', 'al2cu')}"
    b = Bundle(case, 6, "diffsims", "diffsims.crystallography.ReciprocalLatticeVector symmetrise / from_min_dspacing / "
               "allowed / dspacing / calculate_structure_factor / calculate_theta", ctx.out)
    b.input(CASES_FILE, CASES_LABEL)
    phase = _phase(name)
    families = _C["families"][name]
    min_d = _C["min_dspacing"][name]
    b.value("phase", name)
    b.value("space_group", phase.space_group.number)
    b.value("centering", phase.space_group.short_name[0])
    b.value("point_group", phase.point_group.name)
    b.value("lattice", _C["phases"][name]["lattice"])
    b.value("families", families)
    b.value("min_dspacing", min_d)
    b.value("diffsims", diffsims.__version__)

    # symmetrise: the families' symmetrically equivalent, unique vectors, in diffsims' order, with the family each came from
    ref, mult = ReciprocalLatticeVector(phase=phase, hkl=families).symmetrise(return_multiplicity=True)
    b.array("symmetrised_hkl", _hkl_int(ref.hkl), **EXACT, note="diffsims' order: family by family, orix's operation order")
    b.array("multiplicity", np.asarray(mult, dtype=np.int32), **EXACT)
    b.array("symmetrised_hkl_float", np.asarray(ref.hkl, dtype=np.float64), **F64Z)
    b.array("dspacing", np.asarray(ref.dspacing, dtype=np.float64), **F64)

    # from_min_dspacing and the centering rule
    full = ReciprocalLatticeVector.from_min_dspacing(phase, min_dspacing=min_d)
    b.array("min_dspacing_hkl", _hkl_int(full.hkl), **EXACT, note="diffsims' order (the index product reversed, (000) removed, d >= min)")
    if phase.space_group.short_name[0] == "P" and full.has_hexagonal_lattice:
        b.value("allowed", "diffsims raises NotImplementedError for a primitive hexagonal lattice")
    else:
        b.array("min_dspacing_allowed", np.asarray(full.allowed, dtype=np.uint8), **EXACT)

    # structure factors (X-ray International Tables parameters) on the sanitised (expanded) cell, and the Bragg angles
    from diffpy.structure.symmetryutilities import expandPosition

    first = phase.structure[0]
    b.value("first_orbit_size", len(expandPosition(phase.space_group, first.xyz)[0]))
    b.value("first_orbit_element", str(first.element))
    ref.sanitise_phase()
    cell = ref.phase.structure
    b.value("cell_atoms", [[str(a.element), [float(x) for x in a.xyz], float(a.occupancy), float(a.Bisoequiv)] for a in cell])
    ref.calculate_structure_factor()
    # |F| only: diffsims computes F for one member of each family and copies it to the others, so the phase of a member's
    # F is its representative's; the simulator uses |F| (or |F|^2) alone.
    b.array("structure_factor_abs", np.abs(np.asarray(ref.structure_factor)).astype(np.float64), **F64)
    thetas, waves = [], []
    for kv in _C["voltages"]:
        ref.calculate_theta(kv)
        thetas.append(np.asarray(ref.theta, dtype=np.float64))
        waves.append(float(get_refraction_corrected_wavelength(ref.phase, kv)))
    b.value("voltages", _C["voltages"])
    b.array("wavelength_nm", np.asarray(waves), **F64, note="refraction-corrected, per voltage")
    b.array("theta", np.asarray(thetas), **F64, note="voltage, reflector (symmetrised_hkl), radians")
    b.write()
    ctx.done(case)


def case_m6_kikuchi_reflectors_ni(ctx):
    _reflectors_bundle(ctx, "ni")


def case_m6_kikuchi_reflectors_ti(ctx):
    _reflectors_bundle(ctx, "ti")


def case_m6_kikuchi_reflectors_al2cu(ctx):
    _reflectors_bundle(ctx, "al2cu")


def case_m6_kikuchi_scattering_tables(ctx):
    """The two parameter tables the port carries: diffsims' X-ray (International Tables 4.3.2.3, a1..a5, b1..b5 per
    element by symbol) and Doyle-Turner (De Graef & McHenry 2007, Table 12.1: a1..a4, b1..b4 for Z = 1..98), and the
    CODATA constants scipy hands diffsims. Exact: a transcription."""
    from diffsims.structure_factor.atomic_scattering_parameters import ATOMIC_SCATTERING_PARAMETERS_DOYLETURNER, ELEMENTS
    from diffsims.utils.atomic_scattering_params import ATOMIC_SCATTERING_PARAMS
    from scipy.constants import c, e, h, physical_constants

    b = Bundle("m6/kikuchi-scattering-tables", 6, "diffsims", "diffsims.utils.atomic_scattering_params / "
               "diffsims.structure_factor.atomic_scattering_parameters", ctx.out)
    b.input(CASES_FILE, CASES_LABEL)
    symbols = list(ATOMIC_SCATTERING_PARAMS.keys())
    b.value("xray_symbols", symbols)
    b.array("xray", np.asarray([np.asarray(ATOMIC_SCATTERING_PARAMS[s], dtype=np.float64) for s in symbols]), **EXACT,
            note="symbol (values['xray_symbols']), term, (a, b)")
    b.value("doyle_turner_elements", list(ELEMENTS[:98]))
    b.array("doyle_turner", np.asarray(ATOMIC_SCATTERING_PARAMETERS_DOYLETURNER, dtype=np.float64), **EXACT,
            note="Z - 1, (a1..a4, b1..b4) in 1/Å^2")
    b.value("constants", {"c": c, "e": e, "h": h, "m_e": physical_constants["atomic unit of mass"][0]})
    b.write()
    ctx.done("m6/kikuchi-scattering-tables")


def _sim_arrays(b: Bundle, prefix: str, g, index=None) -> None:
    """One pattern's lines (reflector order) and zone axes (sorted by uvw) in pixel and gnomonic coordinates."""
    index = (0,) if index is None else index
    lines_px = g.lines_coordinates(index, coordinates="pixel")
    lines_gn = g.lines_coordinates(index, coordinates="gnomonic")
    keep = ~np.isnan(g.lines_coordinates(index, coordinates="pixel", exclude_nan=False)).any(axis=-1).ravel()
    hkl = _hkl_int(g._lines.vector.hkl.reshape(-1, 3))[keep]
    b.array(f"{prefix}lines_hkl", hkl, **EXACT, note="the visible reflectors whose line meets the r_max circle, in reflector order")
    b.array(f"{prefix}lines_px", np.asarray(lines_px, dtype=np.float64), **PX, note="x1, y1, x2, y2 in detector pixels")
    b.array(f"{prefix}lines_gnomonic", np.asarray(lines_gn, dtype=np.float64), **F64Z, note="x1, y1, x2, y2 on the r_max circle")
    labels = g._zone_axes_labels_as_array()
    za_px_all = g.zone_axes_coordinates(index, coordinates="pixel", exclude_nan=False).reshape(-1, 2)
    za_gn_all = g._zone_axes._xy_within_r_gnomonic[index].reshape(-1, 2)
    uvw_all = _hkl_int(g._zone_axes.vector.coordinates.reshape(-1, 3))
    keep = ~np.isnan(za_px_all).any(axis=-1)
    uvw, px, gn = uvw_all[keep], za_px_all[keep], za_gn_all[keep]
    order = np.lexsort((uvw[:, 2], uvw[:, 1], uvw[:, 0]))
    b.array(f"{prefix}zone_axes_uvw", uvw[order].astype(np.int32), **EXACT, note="sorted by u, then v, then w")
    b.array(f"{prefix}zone_axes_px", np.asarray(px[order], dtype=np.float64), **PX, note="x, y in detector pixels")
    b.array(f"{prefix}zone_axes_gnomonic", np.asarray(gn[order], dtype=np.float64), **F64Z)
    b.value(f"{prefix}zone_axes_labels", [str(s) for s in np.asarray(labels)[keep][order]])


def case_m6_geometrical_simulation_nickel(ctx):
    """Figure F14: kikuchipy's geometrical simulation of the {111}, {200}, {220} and {311} bands and their zone axes on
    nickel_ebsd_large, the file's crystal map (Ni, 0.35236 nm) and per-pattern projection centres, at pattern (0, 0) and
    three more points, as kikuchipy's tutorial runs it: `on_detector` on the whole scan, so every line ends on the circle of
    the scan's largest r_max (`max_r_gnomonic`, a scalar here), which the port takes as an argument."""
    import kikuchipy as kp
    from diffsims.crystallography import ReciprocalLatticeVector

    p = ctx.data / "nickel_ebsd_large" / "patterns_v2.h5"
    case = "m6/geometrical-simulation-nickel"
    if not ctx.have(p, case):
        return
    s = kp.load(str(p), lazy=True)
    xmap, det = s.xmap, s.detector
    phase = xmap.phases[0]
    families = _C["families"]["ni"]
    ref = ReciprocalLatticeVector(phase=phase, hkl=families).symmetrise()
    sim = kp.simulations.KikuchiPatternSimulator(ref)

    b = Bundle(case, 6, "kikuchipy", "kikuchipy.simulations.KikuchiPatternSimulator.on_detector / "
               "GeometricalKikuchiPatternSimulation.lines_coordinates / zone_axes_coordinates", ctx.out)
    b.input(p, "sem-data/nickel_ebsd_large/patterns_v2.h5")
    b.input(CASES_FILE, CASES_LABEL)
    b.value("figure", "F14")
    b.value("families", families)
    b.value("lattice", [phase.structure.lattice.a, phase.structure.lattice.b, phase.structure.lattice.c,
                        phase.structure.lattice.alpha, phase.structure.lattice.beta, phase.structure.lattice.gamma])
    b.value("point_group", phase.point_group.name)
    b.value("scan_shape", list(xmap.shape))
    b.value("detector", {"shape": list(det.shape), "sample_tilt": float(det.sample_tilt), "tilt": float(det.tilt),
                         "azimuthal": float(det.azimuthal), "twist": float(det.twist), "binning": int(det.binning),
                         "px_size": float(det.px_size)})
    b.array("reflectors_hkl", _hkl_int(ref.hkl), **EXACT, note="the symmetrised families in diffsims' order (the simulator's input)")
    points = _C["nickel_points"]
    b.value("points", points)
    full = sim.on_detector(det, xmap.rotations.reshape(*xmap.shape))
    b.scalar("max_r_gnomonic", float(np.max(det.r_max)), **F64)
    rotations, pcs = [], []
    for r, c in points:
        rotations.append(xmap.rotations[r * xmap.shape[1] + c].data[0])
        pcs.append(det.pc[r, c])
        _sim_arrays(b, f"p{r}_{c}_", full, (r, c))
    b.array("rotations", np.asarray(rotations, dtype=np.float64), **EXACT, note="point, (a, b, c, d) of the crystal map")
    b.array("pcs", np.asarray(pcs, dtype=np.float64), **EXACT, note="point, (PCx, PCy, PCz) Bruker")
    b.write()
    ctx.done(case)


def case_m6_geometrical_simulation_tilted(ctx):
    """The same on a 48 x 64 detector at every angle (sample tilt 68, tilt 10, azimuthal 2.5, twist 1.2 deg), titanium
    (hexagonal, 6/mmm), one PC per orientation: the non-square aspect, the hexagonal lattice and the angles at once."""
    import kikuchipy as kp
    from diffsims.crystallography import ReciprocalLatticeVector
    from orix.quaternion import Rotation

    case = "m6/geometrical-simulation-tilted"
    b = Bundle(case, 6, "kikuchipy", "kikuchipy.simulations.KikuchiPatternSimulator.on_detector", ctx.out)
    b.input(CASES_FILE, CASES_LABEL)
    t = _C["tilted_detector"]
    phase = _phase("ti")
    families = _C["families"]["ti"]
    ref = ReciprocalLatticeVector(phase=phase, hkl=families).symmetrise()
    sim = kp.simulations.KikuchiPatternSimulator(ref)
    b.array("reflectors_hkl", _hkl_int(ref.hkl), **EXACT)
    b.array("reflectors_hkl_float", np.asarray(ref.hkl, dtype=np.float64), **F64Z)
    eulers = np.asarray(_C["tilted_euler_deg"], dtype=np.float64)
    b.value("euler_deg", _C["tilted_euler_deg"])
    quats = []
    for i, (eu, pc) in enumerate(zip(eulers, t["pc"])):
        det = kp.detectors.EBSDDetector(shape=tuple(t["shape"]), px_size=t["px_size"], binning=t["binning"], pc=pc,
                                        sample_tilt=t["sample_tilt"], tilt=t["tilt"], azimuthal=t["azimuthal"],
                                        twist=t["twist"])
        rot = Rotation.from_euler(np.deg2rad(eu))
        quats.append(rot.data[0])
        _sim_arrays(b, f"o{i}_", sim.on_detector(det, rot))
    b.array("rotations", np.asarray(quats, dtype=np.float64), **F64Z)
    b.write()
    ctx.done(case)


def case_m6_kinematic_master_pattern_ni(ctx):
    """The kinematical master pattern of kikuchipy's tutorial nickel (the {111}, {200}, {220} and {311} bands, structure
    factors and Bragg angles at 20 kV) in the stereographic projection, both hemispheres, with each band intensity scaling
    kikuchipy offers (|F|, |F|^2, none)."""
    import kikuchipy as kp
    import numba
    from diffsims.crystallography import ReciprocalLatticeVector

    case = "m6/kinematic-master-pattern-ni"
    b = Bundle(case, 6, "kikuchipy", "kikuchipy.simulations.KikuchiPatternSimulator.calculate_master_pattern", ctx.out)
    b.input(CASES_FILE, CASES_LABEL)
    m = _C["master_pattern"]
    phase = _phase("ni")
    ref = ReciprocalLatticeVector(phase=phase, hkl=_C["families"]["ni"]).symmetrise()
    ref.sanitise_phase()
    ref.calculate_structure_factor()
    ref.calculate_theta(m["voltage"])
    sim = kp.simulations.KikuchiPatternSimulator(ref)
    b.value("half_size", m["half_size"])
    b.value("voltage", m["voltage"])
    b.value("scalings", m["scalings"])
    b.array("reflectors_hkl", _hkl_int(ref.hkl), **EXACT)
    b.array("theta", np.asarray(ref.theta, dtype=np.float64), **F64)
    b.array("structure_factor_abs", np.abs(np.asarray(ref.structure_factor)).astype(np.float64), **F64)
    threads = numba.get_num_threads()
    numba.set_num_threads(1)
    try:
        for scaling in m["scalings"]:
            mp = sim.calculate_master_pattern(half_size=m["half_size"], hemisphere="both", scaling=scaling)
            b.array(f"master_pattern_{scaling or 'none'}", np.asarray(mp.data, dtype=np.float64), **MP,
                    note="hemisphere (upper, lower), row, column; stereographic, x and y from -1 to 1")
    finally:
        numba.set_num_threads(threads)
    b.write()
    ctx.done(case)
