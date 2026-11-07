"""tools/parity/sem/ctf_writer.py — the reference Oxford Channel Text File (.ctf) writer for macTEM's `CTFWriter`.

orix 0.15.0 reads .ctf (`orix.io.plugins.ctf.file_reader`) but writes none (`writes = False`), and neither kikuchipy nor
rosettasciio writes one. This writer is the layout macTEM writes, stated once in Python on orix's own `CrystalMap` API
so that `emit.py` can hand it to orix's reader and assert the round trip (figure F18): the header AZtec writes (project,
grid, steps, the CS0 line, one line per phase with lattice, name, Laue group id and space group), then one tab-separated
row per point of the data extent: phase (0 = not indexed, else 1..n in the phase list's order), X, Y, Bands, Error,
Euler1-3 in degrees, MAD, BC, BS.

Choices (macTEM docs/decisions.md, the P8-01 entry), each as orix's .ang writer makes the same one where it has one:
- Coordinates start at 0 on the data extent with the map's steps (`create_coordinate_arrays`), as the .ang writer does;
  a 1D map is one row.
- Points that are not indexed, or not in data, are phase 0 with Euler angles 0 (AZtec writes 0); their Bands, Error, MAD,
  BC and BS are the map's values where it has the property (AZtec keeps BC and BS of unindexed points), else 0, with
  Error 3 ("no solution") when the map has no error column.
- Properties are found by name, case and underscores ignored: bands; error; mad / meanangulardeviation;
  bc / bandcontrast; bs / bandslope. Integer columns are rounded half to even (numpy's rint).
- Euler angles are the rotations' Bunge angles (`to_euler`) times 180/pi, printed with four decimals as AZtec prints
  them; steps and coordinates with four, lattice lengths four and angles three decimals.
- Phase lines: `a;b;c<TAB>alpha;beta;gamma<TAB>name<TAB>Laue id<TAB>space group` (0 when none); the Laue id is orix's
  reader table inverted (1 = -1 ... 11 = m-3m); a phase without a point group is Laue group -1; a missing lattice is
  1, 1, 1, 90, 90, 90 (orix's default); an empty name is "phase<i>"; tabs in a name become spaces.

GPL-3.0-or-later, as orix whose API it uses.
"""

from __future__ import annotations

import numpy as np

LAUE_IDS = {"-1": 1, "2/m": 2, "mmm": 3, "4/m": 4, "4/mmm": 5, "-3": 6, "-3m": 7, "6/m": 8, "6/mmm": 9, "m-3": 10, "m-3m": 11}

PROPERTY_NAMES = {
    "bands": ["bands"],
    "error": ["error"],
    "mad": ["mad", "meanangulardeviation"],
    "bc": ["bc", "bandcontrast"],
    "bs": ["bs", "bandslope"],
}


def _shape_steps(xmap):
    dy, dx = xmap.dy, xmap.dx
    if xmap.ndim == 1:
        return 1, xmap.shape[0], 1, dx
    nrows, ncols = xmap.shape
    return nrows, ncols, dy, dx


def _property(xmap, key: str, size: int):
    lowered = {k.lower().replace("_", ""): k for k in reversed(list(xmap.prop.keys()))}
    for candidate in PROPERTY_NAMES[key]:
        if candidate in lowered:
            values = xmap.get_map_data(lowered[candidate], fill_value=0)
            return np.asarray(values, dtype=np.float64).reshape(size)
    return None


def ctf_text(xmap, project: str = "macTEM", author: str = "macTEM") -> str:
    from orix.crystal_map import create_coordinate_arrays

    nrows, ncols, dy, dx = _shape_steps(xmap)
    size = nrows * ncols
    pl = xmap.phases.deepcopy()
    if -1 in pl.ids:
        del pl[-1]

    lines = [
        "Channel Text File",
        f"Prj\t{project}",
        f"Author\t{author}",
        "JobMode\tGrid",
        f"XCells\t{ncols}",
        f"YCells\t{nrows}",
        f"XStep\t{float(dx):.4f}",
        f"YStep\t{float(dy):.4f}",
        "AcqE1\t0.0000",
        "AcqE2\t0.0000",
        "AcqE3\t0.0000",
        "Euler angles refer to Sample Coordinate system (CS0)!\tMag\t0\tCoverage\t100\tDevice\t0\tKV\t0\tTiltAngle\t0\tTiltAxis\t0",
        f"Phases\t{pl.size}",
    ]
    for i, (_, phase) in enumerate(pl):
        a, b, c, alpha, beta, gamma = (float(v) for v in phase.structure.lattice.abcABG())
        name = phase.name.replace("\t", " ") or f"phase{i + 1}"
        laue = LAUE_IDS[phase.point_group.laue.name] if phase.point_group is not None else 1
        sg = phase.space_group.number if phase.space_group is not None else 0
        lines.append(f"{a:.4f};{b:.4f};{c:.4f}\t{alpha:.3f};{beta:.3f};{gamma:.3f}\t{name}\t{laue}\t{sg}")
    lines.append("Phase\tX\tY\tBands\tError\tEuler1\tEuler2\tEuler3\tMAD\tBC\tBS")

    euler = xmap.get_map_data("rotations", fill_value=0).reshape(size, 3) * (180.0 / np.pi)
    indexed = xmap.get_map_data(xmap.is_indexed, fill_value=False).reshape(size).astype(bool)
    original = xmap.get_map_data("phase_id").reshape(size)
    phase = np.zeros(size, dtype=np.int64)
    for i, (phase_id, _) in enumerate(pl):
        phase[original == phase_id] = i + 1
    phase[~indexed] = 0
    euler[~indexed] = 0.0

    d, _ = create_coordinate_arrays((nrows, ncols), (dy, dx))
    x = np.asarray(d["x"], dtype=np.float64)
    y = np.asarray(d["y"], dtype=np.float64)

    def column(key, default):
        values = _property(xmap, key, size)
        return values if values is not None else np.full(size, default, dtype=np.float64)

    bands = np.rint(column("bands", 0.0)).astype(np.int64)
    error_values = _property(xmap, "error", size)
    if error_values is None:
        error = np.where(indexed, 0, 3).astype(np.int64)
    else:
        error = np.rint(error_values).astype(np.int64)
    mad = column("mad", 0.0)
    bc = np.rint(column("bc", 0.0)).astype(np.int64)
    bs = np.rint(column("bs", 0.0)).astype(np.int64)

    for k in range(size):
        e1, e2, e3 = euler[k]
        lines.append(f"{phase[k]}\t{x[k]:.4f}\t{y[k]:.4f}\t{bands[k]}\t{error[k]}\t{e1:.4f}\t{e2:.4f}\t{e3:.4f}"
                     f"\t{mad[k]:.4f}\t{bc[k]}\t{bs[k]}")
    return "\n".join(lines) + "\n"


def write_ctf(path, xmap, **kw) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(ctf_text(xmap, **kw))
