# tools/parity/sem-readers/make_orix_map_fixtures.py — writes the orix HDF5 map fixtures of macTEMTests and what orix reads from them (#514).
#
#   python -I -B make_orix_map_fixtures.py <out dir>        (orix 0.15.0, h5py 3.16.0, NumPy 2.5.4, as pinned in tools/parity/sem)
#
# orix saves a crystal map in its own HDF5 layout (`orix.io.save`, io/plugins/orix_hdf5.py): /manufacturer "orix", /version and
# /crystal_map/{data,header} (`crystalmap2dict`). kikuchipy's dictionary indexing saves its maps so, with the best n matches of each point
# (`rotations_per_point` n; orix shows the first). Every fixture is written by orix itself (a few KiB each, copied flat into the test bundle):
#   ebsd-orix-map.h5        a 4 x 3 map in µm, two phases (Al m-3m, Mg 6/mmm), one point not indexed, a property `iq`
#   ebsd-orix-map-best2.h5  the same points with two rotations and two scores each
#   ebsd-orix-map-crop.h5   the 4 x 3 map's last two columns: the points outside stay in the file, masked by `is_in_data`
# Truth: ebsd-orix-map.truth.json, what `orix.io.load` returns for each file, the points in data in order: phase ids, x, y, the Euler
# angles the file stores for each (the first rotation where there are more), the properties (their first column), the phases and the
# scan unit. Floats are repr() (round-trip exact).
import json, sys
from pathlib import Path
import numpy as np
from orix import __version__ as orix_version
from orix.crystal_map import CrystalMap, Phase, PhaseList
from orix.io import load, save
from orix.quaternion import Rotation
from diffpy.structure import Lattice, Structure

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)

NX, NY, DX, DY = 4, 3, 0.5, 0.25
N = NX * NY
PHASE = np.array([1, 1, 2, 2,
                  1, -1, 2, 2,
                  1, 1, 1, 2])
I = np.arange(N, dtype=np.float64)
EULER = np.column_stack([0.5 + 0.125 * I, 0.25 + 0.0625 * I, 1.0 + 0.03125 * I])
Y, X = np.divmod(np.arange(N), NX)
X = X * DX; Y = Y * DY
PHASES = PhaseList(
    names=["Al", "Mg"], space_groups=[225, 194],
    structures=[Structure(lattice=Lattice(4.05, 4.05, 4.05, 90, 90, 90)), Structure(lattice=Lattice(3.21, 3.21, 5.21, 90, 90, 120))],
    ids=[1, 2])


def crystal_map(rotations, prop):
    return CrystalMap(rotations=rotations, phase_id=PHASE, x=X, y=Y, phase_list=PHASES.deepcopy(), prop=prop, scan_unit="um")


one = crystal_map(Rotation.from_euler(EULER), {"iq": 0.5 + I / 16})
save(out / "ebsd-orix-map.h5", one)
second = EULER[::-1] + 0.0078125
two = crystal_map(Rotation.from_euler(np.stack([EULER, second], axis=1)),
                  {"scores": np.column_stack([0.75 - I / 64, 0.5 - I / 64]), "simulation_indices": np.column_stack([I, I + 100])})
save(out / "ebsd-orix-map-best2.h5", two)
save(out / "ebsd-orix-map-crop.h5", one[:, 2:])

flt = lambda a: [repr(float(v)) for v in np.asarray(a, dtype=np.float64).ravel()]
truth = {"orix": orix_version, "files": {}}
for name in ["ebsd-orix-map.h5", "ebsd-orix-map-best2.h5", "ebsd-orix-map-crop.h5"]:
    xmap = load(out / name)
    import h5py
    with h5py.File(out / name, "r") as f:
        data = f["crystal_map/data"]
        inside = np.asarray(data["is_in_data"][()], dtype=bool)
        euler = np.column_stack([np.asarray(data[k][()]).reshape(len(inside), -1)[:, 0] for k in ["phi1", "Phi", "phi2"]])[inside]
    assert xmap.size == int(inside.sum())
    # xmap.prop[k] masks by is_in_data; dict items() would give every stored point.
    props = {k: flt(np.asarray(xmap.prop[k]).reshape(xmap.size, -1)[:, 0]) for k in xmap.prop.keys()}
    truth["files"][name] = {
        "size": int(xmap.size), "pointCount": int(len(inside)), "shape": list(xmap.shape), "rotationsPerPoint": int(xmap.rotations_per_point),
        "phaseIDs": [int(v) for v in xmap.phase_id], "x": flt(xmap.x), "y": flt(xmap.y), "euler": flt(euler),
        "properties": props, "scanUnit": xmap.scan_unit, "dx": repr(float(xmap.dx)), "dy": repr(float(xmap.dy)),
        "phases": [{"id": int(i), "name": p.name, "spaceGroup": None if p.space_group is None else int(p.space_group.number),
                    "pointGroup": None if p.point_group is None else p.point_group.name, "color": p.color,
                    "lattice": flt(p.structure.lattice.cell_parms())} for i, p in xmap.phases],
    }
(out / "ebsd-orix-map.truth.json").write_text(json.dumps(truth, indent=1, sort_keys=True) + "\n")
