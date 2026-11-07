"""tools/parity/sem/texture_cases.py — the texture cases of emit.py (milestone 5, figure F13).

Pole figures and inverse pole figure densities are orix 0.15.0's `orix.measure.pole_density_function` (Rohrer et al.
2004): the vectors' azimuth and polar angles binned on the equal-area grid of `_sample_S2_equal_area_coordinates`
(numpy.histogram2d), smoothed with scipy.ndimage.gaussian_filter (sigma / resolution bins, truncate 4, `wrap` in
azimuth and `reflect` in polar), folded into a point group's fundamental sector when a symmetry is given, in multiples
of random distribution (the mean bin is 1). The pole figure's vectors are orix's: the {hkil} or {hkl} family
`Miller.symmetrise(unique=True)` under the phase's Laue group, turned into the sample frame by the inverse orientation
(`(~O).outer(m)`, orix's pole figure convention).

The ODF is the kernel density estimate on SO(3) of Hielscher and Schaeben (2008, J. Appl. Cryst. 41, 1024) with MTEX's
de la Vallee Poussin kernel (Schaeben 1997), as MTEX's `calcDensity` evaluates it: f(g) = 1 / (N |G|) sum_i sum_s
C(kappa) |<g_i g^-1, s>|^(2 kappa) over the N orientations and the |G| proper symmetry elements, kappa = ln(1/2) /
(2 ln cos(h / 2)) for the half-width h, C(kappa) = B(3/2, 1/2) / B(3/2, kappa + 1/2), so the uniform ODF is 1 mrd. orix
0.15.0 has no ODF, so this closed form is written here on orix's rotations and symmetry elements (`Orientation`,
`Symmetry.proper_subgroup`, `Rotation.from_euler` for the Bunge section grid). Two checks independent of the formula
are in the bundle: the mean of the ODF over orix's uniform cubochoric sample of SO(3) (1 within the sample's
resolution) and the ODF of the identity alone at the identity (C(kappa) |G|-fold symmetric, exact).

Tolerances: histogram counts exact (each bundle states how far the closest angle lies from a bin edge); densities atol
1e-7 (catalogue section 5, pole figures); ODF values rtol 1e-4 (brief P5-02, catalogue section 5); grid coordinates
atol 1e-10. emit.py imports every `case_` function here.
"""

from __future__ import annotations

import json
from math import ceil, lgamma, exp, log, cos, radians
from pathlib import Path

import numpy as np

from refbundle import Bundle

HERE = Path(__file__).resolve().parent
ORIENTATION_INPUTS = HERE / "fixtures" / "orientation_inputs.json"
ORIENTATION_INPUTS_LABEL = "fixtures/orientation_inputs.json"

EXACT = {"rtol": 0.0, "atol": 0.0}
GRID = {"rtol": 0.0, "atol": 1e-10}
DENSITY = {"rtol": 0.0, "atol": 1e-7}
ODF = {"rtol": 1e-4, "atol": 0.0}

TI_LATTICE = (2.951, 2.951, 4.684, 90.0, 90.0, 120.0)  # grain_cases.py's Ti phase, orix-data's Ti_orientations.ctf
TI_FAMILIES = {"0001": [0, 0, 0, 1], "10-10": [1, 0, -1, 0], "11-20": [1, 1, -2, 0]}
CUBIC_FAMILIES = {"100": [1, 0, 0], "110": [1, 1, 0], "111": [1, 1, 1]}
HALF_WIDTH_DEGREES = 10.0  # MTEX calcDensity's default half-width
SECTION_STEP_DEGREES = 5.0


def _inputs() -> dict:
    return json.loads(ORIENTATION_INPUTS.read_text())


def _phase(point_group: str, lattice=(1.0, 1.0, 1.0, 90.0, 90.0, 90.0)):
    from diffpy.structure import Lattice, Structure
    from orix.crystal_map import Phase

    return Phase(point_group=point_group, structure=Structure(lattice=Lattice(*lattice)))


def _poles(phase, family: list[int]):
    from orix.vector import Miller

    m = Miller(hkil=family, phase=phase) if len(family) == 4 else Miller(hkl=family, phase=phase)
    return m.symmetrise(unique=True).unit


def _sample_vectors(O, poles):
    from orix.quaternion import Rotation
    from orix.vector import Vector3d

    return Rotation(O.data).inv().outer(Vector3d(poles.data)).flatten()


def _raw_counts(v, resolution=1.0, hemisphere="upper"):
    """The histogram pole_density_function smooths (numpy.histogram2d of azimuth and polar on the equal-area edges), and
    how many vectors lie within 1e-12 rad of an edge: those go to either neighbouring bin depending on the last bit of
    atan2 and arccos (glibc against Apple's libm), so the port's counts may move each of them one bin (D-SEM decision in
    docs/decisions.md). A vector orix's to_polar puts on the x-z or y-z plane (x or y within numpy's isclose of 0) has an
    azimuth of exactly 0, pi/2, pi or 3 pi/2 in both and is not counted."""
    from orix.sampling.S2_sampling import _sample_S2_equal_area_coordinates

    az, po, _ = v.to_polar()
    az, po = np.ravel(az), np.ravel(po)
    ae, pe = _sample_S2_equal_area_coordinates(resolution, hemisphere=hemisphere, azimuth_endpoint=True)
    counts, *_ = np.histogram2d(az, po, bins=(ae, pe))
    inside = po <= pe[-1] + 1e-12
    xy = v.data.reshape(-1, 3)[:, :2]
    off_axis = np.all(np.abs(xy) > 1e-8, axis=1)
    near_a = off_axis & (np.min(np.abs(az[:, None] - ae[None, :]), axis=1) < 1e-12)
    near_p = np.min(np.abs(po[:, None] - pe[None, 1:]), axis=1) < 1e-12  # the first polar edge is the pole itself
    ambiguous = int(np.count_nonzero(inside & (near_a | near_p)) + np.count_nonzero(np.abs(po - pe[-1]) < 1e-12))
    return counts.astype(np.int32), ambiguous


def kappa_for(half_width_degrees: float) -> float:
    return 0.5 * log(0.5) / log(cos(radians(half_width_degrees) / 2))


def kernel_constant(kappa: float) -> float:
    beta = lambda a, b: exp(lgamma(a) + lgamma(b) - lgamma(a + b))  # noqa: E731
    return beta(1.5, 0.5) / beta(1.5, kappa + 0.5)


def odf_values(O, grid_quaternions: np.ndarray, half_width_degrees: float = HALF_WIDTH_DEGREES) -> np.ndarray:
    """f(g) at each grid quaternion, in mrd (see the module docstring)."""
    sym = O.symmetry.proper_subgroup.data  # (|G|, 4)
    q = O.data / np.linalg.norm(O.data, axis=1, keepdims=True)
    kappa = kappa_for(half_width_degrees)
    c = kernel_constant(kappa)
    out = np.empty(len(grid_quaternions))
    for k, g in enumerate(grid_quaternions):
        # m = q_i * conj(g), the same product as orix's _ori_angle_with_outer_sym (other_j * self_i^-1)
        a1, b1, c1, d1 = g
        a2, b2, c2, d2 = q[:, 0], q[:, 1], q[:, 2], q[:, 3]
        mw = a2 * a1 + b2 * b1 + c2 * c1 + d2 * d1
        mx = b2 * a1 - a2 * b1 + d2 * c1 - c2 * d1
        my = c2 * a1 - d2 * b1 - a2 * c1 + b2 * d1
        mz = d2 * a1 + c2 * b1 - b2 * c1 - a2 * d1
        m = np.stack([mw, mx, my, mz], axis=1)
        d = np.abs(m @ sym.T)
        out[k] = c * np.sum(np.minimum(d, 1.0) ** (2 * kappa)) / (len(q) * len(sym))
    return out


def section_grid(phi2_degrees: float, phi1_max: float, Phi_max: float, step: float = SECTION_STEP_DEGREES):
    """Bunge (phi1, Phi) nodes of one phi2 section: phi1 = 0, step, ... below phi1_max, Phi = 0, step, ..., Phi_max;
    row-major (phi1 outer, Phi inner); the quaternions orix's Rotation.from_euler gives them."""
    from orix.quaternion import Rotation

    phi1 = np.arange(0.0, phi1_max - 1e-9, step)
    Phi = np.arange(0.0, Phi_max + 1e-9, step)
    P1, P = np.meshgrid(phi1, Phi, indexing="ij")
    eu = np.stack([P1.ravel(), P.ravel(), np.full(P1.size, phi2_degrees)], axis=1)
    return phi1, Phi, Rotation.from_euler(np.deg2rad(eu)).data


def _pole_figure_arrays(b, O, phase, families: dict, grids: bool = False) -> None:
    """Per family: the symmetrised poles, the raw counts and how many vectors sit on an edge, the density; the bin-edge grid
    in the stereographic plane (the same for every case, so stored once) when `grids`."""
    from orix.measure import pole_density_function

    for tag, family in families.items():
        poles = _poles(phase, family)
        b.value(f"family_{tag}", family)
        b.array(f"poles_{tag}", poles.data, **GRID)
        v = _sample_vectors(O, poles)
        counts, ambiguous = _raw_counts(v)
        hist, (x, y) = pole_density_function(v)
        b.array(f"counts_{tag}", counts, **EXACT)
        b.value(f"ambiguous_{tag}", ambiguous)
        b.array(f"pdf_{tag}", np.asarray(hist.data, dtype=np.float64), **DENSITY)
        if grids and tag == next(iter(families)):
            b.array("grid_x", np.asarray(x, dtype=np.float64), **GRID)
            b.array("grid_y", np.asarray(y, dtype=np.float64), **GRID)


def _ipf_density_arrays(b, O, laue, grids: bool = False) -> None:
    from orix.measure import pole_density_function
    from orix.vector import Vector3d

    v = O * Vector3d.zvector()
    hist, (x, y) = pole_density_function(v, symmetry=laue)
    counts, ambiguous = _raw_counts(v.in_fundamental_sector(laue), resolution=0.5)
    b.value("ipf_symmetry", laue.name)
    b.array("ipf_z_counts", counts, **EXACT)
    b.value("ipf_z_ambiguous", ambiguous)
    b.array("ipf_z_mask", np.asarray(np.ma.getmaskarray(hist), dtype=np.uint8), **EXACT)
    b.array("ipf_z_density", np.asarray(hist.filled(-1.0), dtype=np.float64), **DENSITY)
    if grids:
        b.array("ipf_grid_x", np.asarray(x, dtype=np.float64), **GRID)
        b.array("ipf_grid_y", np.asarray(y, dtype=np.float64), **GRID)


def _odf_arrays(b, O, sections: list[float], phi1_max: float, Phi_max: float) -> None:
    kappa = kappa_for(HALF_WIDTH_DEGREES)
    b.value(f"odf_half_width_degrees", HALF_WIDTH_DEGREES)
    b.value(f"odf_step_degrees", SECTION_STEP_DEGREES)
    b.value(f"odf_sections_phi2_degrees", sections)
    b.scalar(f"odf_kappa", kappa, rtol=1e-12)
    b.scalar(f"odf_kernel_constant", kernel_constant(kappa), rtol=1e-12)
    for phi2 in sections:
        phi1, Phi, grid = section_grid(phi2, phi1_max, Phi_max)
        if phi2 == sections[0]:
            b.value(f"odf_section_shape", [len(phi1), len(Phi)])
        b.array(f"odf_phi2_{int(phi2)}", odf_values(O, grid).reshape(len(phi1), len(Phi)), **ODF)


def case_m5_texture_ti(ctx):
    """Figure F13 on the committed Ti orientations (orix-data Ti_orientations.ctf, first 2000 rows, point group 622):
    pole figures {0001}, {10-10}, {11-20} (upper hemisphere, 1 degree equal-area grid, sigma 5 degrees, mrd), the
    IPF-Z density in 6/mmm's sector, and the ODF sections phi2 = 0, 30 and 45 degrees (half-width 10 degrees, 5 degree
    nodes over phi1 0..355, Phi 0..90)."""
    from orix.quaternion import Orientation
    from orix.quaternion.symmetry import D6, D6h

    inp = _inputs()
    assert inp["ti_point_group"] == D6.name
    eu = np.asarray(inp["ti_euler_degrees"], dtype=np.float64)
    O = Orientation.from_euler(eu, symmetry=D6, degrees=True)
    b = Bundle("m5/texture-ti", 5, "orix",
               "orix.measure.pole_density_function of (~O).outer(Miller.symmetrise); ODF kernel density (de la Vallee Poussin)", ctx.out)
    b.input(ORIENTATION_INPUTS, ORIENTATION_INPUTS_LABEL)
    b.value("point_group", D6.name)
    b.value("lattice", list(TI_LATTICE))
    b.array("euler_degrees", eu, **EXACT)
    _pole_figure_arrays(b, O, _phase("6/mmm", TI_LATTICE), TI_FAMILIES)
    _ipf_density_arrays(b, O, D6h)
    _odf_arrays(b, O, [0.0, 30.0, 45.0], 360.0, 90.0)
    b.write()
    ctx.done("m5/texture-ti")


def case_m5_texture_cubic(ctx):
    """The seeded m-3m orientations of orientation_inputs.json (the Ni symmetry): pole figures {100}, {110}, {111},
    the IPF-Z density in m-3m's sector, the ODF section phi2 = 45 degrees over phi1, Phi 0..90; plus the two checks
    independent of the formula (module docstring)."""
    from orix.quaternion import Orientation
    from orix.quaternion.symmetry import Oh
    from orix.sampling import get_sample_fundamental

    inp = _inputs()
    assert inp["cubic_point_group"] == Oh.name
    q = np.asarray(inp["cubic_quaternions"], dtype=np.float64)
    O = Orientation(q, symmetry=Oh)
    b = Bundle("m5/texture-cubic", 5, "orix",
               "orix.measure.pole_density_function of (~O).outer(Miller.symmetrise); ODF kernel density (de la Vallee Poussin)", ctx.out)
    b.input(ORIENTATION_INPUTS, ORIENTATION_INPUTS_LABEL)
    b.value("point_group", Oh.name)
    b.array("quaternions", q, **EXACT)
    _pole_figure_arrays(b, O, _phase("m-3m"), CUBIC_FAMILIES, grids=True)
    _ipf_density_arrays(b, O, Oh, grids=True)
    _odf_arrays(b, O, [45.0], 90.0 + SECTION_STEP_DEGREES, 90.0)

    identity = Orientation(np.array([[1.0, 0, 0, 0]]), symmetry=Oh)
    at_identity = odf_values(identity, np.array([[1.0, 0, 0, 0]]))[0]
    kappa = kappa_for(HALF_WIDTH_DEGREES)
    assert abs(at_identity - kernel_constant(kappa) / 24) < 1e-9 * at_identity
    b.scalar("odf_identity_at_identity", at_identity, rtol=1e-12)
    uniform = get_sample_fundamental(resolution=3.0, point_group=Oh)
    mean = float(np.mean(odf_values(O, uniform.data)))
    b.scalar("odf_mean_over_uniform_sample", mean, rtol=1e-4)
    assert abs(mean - 1.0) < 0.05, f"the ODF's mean over SO(3) is {mean}, not 1 mrd"
    b.write()
    ctx.done("m5/texture-cubic")


def case_m5_texture_ti_full(ctx):
    """Figure F13: orix-data's whole Ti map (381 x 507, point group 622, read as orix.data.ti_orientations reads it):
    the three pole figures and the IPF-Z density of every point; the ODF phi2 = 30 degree section of every tenth point
    (the 19 305 orientations of rows 0, 10, 20, ... of the flat map), half-width 10 degrees."""
    from orix.quaternion import Orientation
    from orix.quaternion.symmetry import D6, D6h

    p = ctx.data / "orix" / "Ti_orientations.ctf"
    if not ctx.have(p, "m5/texture-ti-full"):
        return
    table = np.loadtxt(p, skiprows=1)
    O = Orientation.from_euler(np.deg2rad(table[:, :3]), D6)
    b = Bundle("m5/texture-ti-full", 5, "orix",
               "orix.data.ti_orientations; pole_density_function; ODF kernel density (de la Vallee Poussin)", ctx.out)
    b.input(p, "sem-data/orix/Ti_orientations.ctf")
    b.value("point_group", D6.name)
    b.value("points", int(O.size))
    _pole_figure_arrays(b, O, _phase("6/mmm", TI_LATTICE), TI_FAMILIES)
    _ipf_density_arrays(b, O, D6h)
    b.value("odf_stride", 10)
    _odf_arrays(b, O[::10], [30.0], 360.0, 90.0)
    b.write()
    ctx.done("m5/texture-ti-full")
