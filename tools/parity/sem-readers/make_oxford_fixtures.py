# SPDX-License-Identifier: GPL-3.0-only
"""Reference fixtures for the Oxford Instruments readers (SEM program, brief P1-03).

Writes, under macTEMTests/Fixtures/sem/oxford/, the files the unit tests read bit-exact (.ebsp) and at 1e-12 (.ctf)
against what kikuchipy 0.13.1 and orix 0.15.0 read from the same bytes:

  patterns.ebsp              kikuchipy's own test file (kikuchipy/data/oxford_binary, CC BY 4.0: nickel_ebsd_small
                             written as a version-2 .ebsp with the patterns rolled one step in the file)
  dummy-v<n>[-...].ebsp      the dummy files kikuchipy's conftest.py writes for its reader tests, one per layout
                             (version 0, 1, 2, 4, 5, 6; uint16; a file with one pattern missing; a compressed file)
  <name>.ebsp.json           what kikuchipy.load gives for that file: version, shapes, dtype, step, beam and map
                             positions, the file order
  <name>.ebsp.u8 / .u16      the patterns in map order, flattened, little-endian, as kikuchipy returns them
  oxford.ctf, bruker.ctf, astar.ctf, emsoft.ctf, mtex.ctf
                             the Channel Text Files orix's conftest.py writes for its reader tests (seeded here)
  <name>.ctf.json            orix.io.load's crystal map: phases, coordinates, phase ids, Euler angles (degrees),
                             properties with the vendor's column names
  ti_orientations_head.ctf   the first 2000 rows of orix-data's Ti_orientations.ctf (Krakow et al. 2017, CC BY 4.0),
                             an MTEX export without the Channel Text File header; orix.data.ti_orientations reads its
                             three Euler columns and attaches the 622 point group by hand
  ti_orientations.json       orix's reading of the head file, and of the whole file (every 997th row) for the opt-in
                             real-data test on the Mac ($MACEM_DATA/sem/Ti_orientations.ctf)

Run from the SEM parity environment (tools/parity/sem, CPython 3.13: kikuchipy 0.13.1, orix 0.15.0, numpy 2.x):

    python tools/parity/sem-readers/make_oxford_fixtures.py [--ti path/to/Ti_orientations.ctf]
"""

import argparse
import hashlib
import json
import os
import shutil
import sys

import numpy as np

import kikuchipy as kp
from kikuchipy.io.plugins.oxford_binary._api import OxfordBinaryFileReader
from orix import io

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
OUT = os.path.join(ROOT, "macTEMTests", "Fixtures", "sem", "oxford")


# ------------------------------------------------------------------ .ebsp


def write_dummy_ebsp(path, nav_shape, sig_shape, dtype, version, compressed, all_present):
    """kikuchipy/conftest.py::oxford_binary_file, verbatim in behaviour (kikuchipy 0.13.1)."""
    (nr, nc), (sr, sc) = nav_shape, sig_shape
    f = open(path, mode="w")
    if version > 0:
        np.array(-version, dtype=np.int64).tofile(f)
    pattern_header_size = 16
    if version == 0:
        pattern_footer_size = 0
    elif version == 1:
        pattern_footer_size = 16
    else:
        pattern_footer_size = 18
    n_patterns = nr * nc
    n_pixels = sr * sc
    n_bytes = n_pixels if np.issubdtype(dtype, np.uint8) else 2 * n_pixels
    pattern_starts = np.arange(n_patterns, dtype=np.int64)
    pattern_starts *= pattern_header_size + n_bytes + pattern_footer_size
    pattern_starts += n_patterns * 8
    if version in [1, 2, 3]:
        pattern_starts += 8
    elif version > 3:
        np.array(0, dtype=np.uint8).tofile(f)
        pattern_starts += 9
    pattern_starts = np.roll(pattern_starts, shift=1)
    if not all_present:
        pattern_starts[0] = 0
    pattern_starts.tofile(f)
    new_order = np.roll(np.arange(n_patterns), shift=-1)
    pattern_header = np.array([compressed, sr, sc, n_bytes], dtype=np.int32)
    data = np.arange(n_patterns * n_pixels, dtype=dtype).reshape((nr, nc, sr, sc))
    if not all_present:
        new_order = new_order[1:]
    for i in new_order:
        r, c = np.unravel_index(i, (nr, nc))
        if version > 4:
            np.array([c, r], dtype=np.int32).tofile(f)
        pattern_header.tofile(f)
        data[r, c].tofile(f)
        if version > 1:
            np.array(1, dtype=bool).tofile(f)
        if version > 0:
            np.array(c, dtype=np.float64).tofile(f)
        if version > 1:
            np.array(1, dtype=bool).tofile(f)
        if version > 0:
            np.array(r, dtype=np.float64).tofile(f)
    f.close()


def ebsp_reference(path):
    """What kikuchipy reads from an .ebsp file, as JSON plus the patterns in map order as raw little-endian bytes."""
    name = os.path.basename(path)
    with open(path, mode="rb") as f:
        reader = OxfordBinaryFileReader(f)
        version = reader.version
        n_patterns = reader.n_patterns
    s = kp.load(path)
    om = s.original_metadata.as_dictionary()
    ref = {
        "version": int(version),
        "nPatternsInHeader": int(n_patterns),
        "navigationShape": [int(v) for v in s._navigation_shape_rc],
        "signalShape": [int(v) for v in s.axes_manager.signal_shape[::-1]],
        "dtype": str(s.data.dtype),
        "stepSizes": [float(a.scale) for a in s.axes_manager.navigation_axes][::-1],
        "scanUnit": s.axes_manager.navigation_axes[0].units,
        "map1dID": [int(v) for v in om["map1d_id"]],
        "fileOrder": [int(v) for v in om["file_order"]],
    }
    for key in ("beam_x", "beam_y", "map_x", "map_y"):
        if key in om:
            ref[key] = [float(v) for v in np.asarray(om[key]).ravel()]
    data = np.ascontiguousarray(s.data)
    suffix = "u8" if data.dtype == np.uint8 else "u16"
    data.astype("<" + data.dtype.str[1:]).tofile(os.path.join(OUT, name + "." + suffix))
    ref["patterns"] = name + "." + suffix
    with open(os.path.join(OUT, name + ".json"), "w") as f:
        json.dump(ref, f, indent=1)
    return ref


def make_ebsp():
    src = os.path.join(os.path.dirname(kp.__file__), "data", "oxford_binary", "patterns.ebsp")
    shutil.copyfile(src, os.path.join(OUT, "patterns.ebsp"))
    ebsp_reference(os.path.join(OUT, "patterns.ebsp"))
    # kikuchipy's reader-test layouts (tests/test_io/test_oxford_binary.py).
    layouts = {
        "dummy-v0.ebsp": ((2, 3), (60, 60), np.uint8, 0, False, True),
        "dummy-v1-uint16.ebsp": ((2, 3), (60, 60), np.uint16, 1, False, True),
        "dummy-v2.ebsp": ((2, 3), (60, 60), np.uint8, 2, False, True),
        "dummy-v2-uint16.ebsp": ((2, 3), (60, 60), np.uint16, 2, False, True),
        "dummy-v2-missing.ebsp": ((2, 3), (60, 60), np.uint8, 2, False, False),
        "dummy-v2-compressed.ebsp": ((2, 3), (60, 60), np.uint8, 2, True, True),
        "dummy-v2-3x4-62x73.ebsp": ((3, 4), (62, 73), np.uint8, 2, False, True),
        "dummy-v4.ebsp": ((2, 3), (60, 60), np.uint8, 4, False, True),
        "dummy-v5.ebsp": ((2, 3), (50, 50), np.uint8, 5, False, True),
        "dummy-v6.ebsp": ((2, 3), (50, 50), np.uint8, 6, False, True),
    }
    for name, layout in layouts.items():
        path = os.path.join(OUT, name)
        write_dummy_ebsp(path, *layout)
        if layout[4]:
            try:
                kp.load(path)
            except NotImplementedError as e:
                with open(path + ".json", "w") as f:
                    json.dump({"refused": str(e).split(" from ")[0]}, f, indent=1)
            continue
        if layout[3] > 4:
            # kikuchipy's conftest writes the 24-byte version-5 pattern header but spaces the pattern starts by the 16-byte
            # one, so its own test (`test_version_5`) checks only the number of patterns guessed from the header; loading
            # fails in kikuchipy too. The reference is that count and the refusal.
            with open(path, mode="rb") as f:
                reader = OxfordBinaryFileReader(f)
                ref = {"version": int(reader.version), "nPatternsInHeader": int(reader.n_patterns), "loadFails": True}
            try:
                kp.load(path)
                ref["loadFails"] = False
            except ValueError:
                pass
            with open(path + ".json", "w") as f:
                json.dump(ref, f, indent=1)
            continue
        ebsp_reference(path)


# ------------------------------------------------------------------- .ctf

CTF_HEADERS = {
    "oxford": """Channel Text File
Prj\tstandard steel sample
Author
JobMode\tGrid
XCells\t%i
YCells\t%i
XStep\t%.4f
YStep\t%.4f
AcqE1\t0.0000
AcqE2\t0.0000
AcqE3\t0.0000
Euler angles refer to Sample Coordinate system (CS0)!\tMag\t180.0000\tCoverage\t97\tDevice\t0\tKV\t20.0000\tTiltAngle\t70.0010\tTiltAxis\t0\tDetectorOrientationE1\t0.9743\tDetectorOrientationE2\t89.4698\tDetectorOrientationE3\t2.7906\tWorkingDistance\t14.9080\tInsertionDistance\t185.0
Phases\t2
3.660;3.660;3.660\t90.000;90.000;90.000\tIron fcc\t11\t225\t\t\tSome reference
2.867;2.867;2.867\t90.000;90.000;90.000\tIron bcc\t11\t229\t\t\tSome other reference
Phase\tX\tY\tBands\tError\tEuler1\tEuler2\tEuler3\tMAD\tBC\tBS""",
    "bruker": """Channel Text File
Prj unnamed
Author\t[Unknown]
JobMode\tGrid
XCells\t%i
YCells\t%i
XStep\t0,001998
YStep\t0,001998
AcqE1\t0
AcqE2\t0
AcqE3\t0
Euler angles refer to Sample Coordinate system (CS0)!\tMag\t150000,000000\tCoverage\t100\tDevice\t0\tKV\t30,000000\tTiltAngle\t0\tTiltAxis\t0
Phases\t1
4,079000;4,079000;4,079000\t90,000000;90,000000;90,000000\tGold\t11\t225
Phase\tX\tY\tBands\tError\tEuler1\tEuler2\tEuler3\tMAD\tBC\tBS""",
    "astar": """Channel Text File
Prj\tC:\\some\\where\\scan.res
Author\tFile created from ACOM RES results
JobMode\tGrid
XCells\t%i
YCells\t%i
XStep\t0.00191999995708466
YStep\t0.00191999995708466
AcqE1\t0
AcqE2\t0
AcqE3\t0
Euler angles refer to Sample Coordinate system (CS0)!\tMag\t200\tCoverage\t100\tDevice\t0\tKV\t20\tTiltAngle\t70\tTiltAxis\t0
Phases\t1
4.0780;4.0780;4.0780\t90;90;90\t_mineral 'Gold'  'Gold'\t11\t225
Phase\tX\tY\tBands\tError\tEuler1\tEuler2\tEuler3\tMAD\tBC\tBS""",
    "emsoft": """Channel Text File
EMsoft v. 4_1_1_9d5269a; BANDS=pattern index, MAD=CI, BC=OSM, BS=IQ
Author\tMe
JobMode\tGrid
XCells\t  %i
YCells\t  %i
XStep\t  %.2f
YStep\t  %.2f
AcqE1\t0
AcqE2\t0
AcqE3\t0
Euler angles refer to Sample Coordinate system (CS0)!\tMag\t30\tCoverage\t100\tDevice\t0\tKV\t 0.0\tTiltAngle\t0.00\tTiltAxis\t0
Phases\t1
3.524;3.524;3.524\t90.000;90.000;90.000\tNi\t11\t225
Phase\tX\tY\tBands\tError\tEuler1\tEuler2\tEuler3\tMAD\tBC\tBS""",
    "mtex": """Channel Text File
Prj /some/where/mtex.ctf
Author\tMe Again
JobMode\tGrid
XCells\t%i
YCells\t%i
XStep\t%.4f
YStep\t%.4f
AcqE1\t0.0000
AcqE2\t0.0000
AcqE3\t0.0000
Euler angles refer to Sample Coordinate system (CS0)!\tMag\t0.0000\tCoverage\t0\tDevice\t0\tKV\t0.0000\tTiltAngle\t0.0000\tTiltAxis\t0\tDetectorOrientationE1\t0.0000\tDetectorOrientationE2\t0.0000\tDetectorOrientationE3\t0.0000\tWorkingDistance\t0.0000\tInsertionDistance\t0.0000
Phases\t1
4.079;4.079;4.079\t90.000;90.000;90.000\tGold\t11\t0\t\t\tCreated from mtex
Phase\tX\tY\tBands\tError\tEuler1\tEuler2\tEuler3\tMAD\tBC\tBS""",
}

R_EXAMPLE = np.array([[4.48549, 0.95242, 0.79150], [1.34390, 0.27611, 0.82589]])


def write_dummy_ctf(path, vendor, map_shape, step_sizes, seed):
    """orix/tests/conftest.py::ctf_<vendor>, with a seeded generator so the file is reproducible."""
    from orix.crystal_map.crystal_map import create_coordinate_arrays

    (ny, nx), (dy, dx) = map_shape, step_sizes
    rng = np.random.default_rng(seed)
    d, map_size = create_coordinate_arrays((ny, nx), (dy, dx))
    x, y = d["x"], d["y"]
    err = np.zeros(map_size, dtype=np.uint8)
    mad = rng.random(map_size)
    R = R_EXAMPLE[rng.choice(np.arange(len(R_EXAMPLE)), map_size)]
    R = np.rad2deg(R)
    if vendor == "oxford":
        phase_id = rng.choice([1, 2], map_size)
        bands = rng.integers(8, size=map_size, dtype=np.uint8)
        bc = rng.integers(150, 200, map_size)
        bs = rng.integers(190, 255, map_size)
        fmt = "%-4i%-8.4f%-8.4f%-4i%-4i%-11.4f%-11.4f%-11.4f%-8.4f%-4i%-i"
        header = CTF_HEADERS[vendor] % (nx, ny, dx, dy)
    elif vendor == "bruker":
        phase_id = np.ones(map_size, dtype=np.uint8)
        bands = rng.integers(8, size=map_size, dtype=np.uint8)
        bc = rng.integers(50, 105, map_size)
        bs = np.full(map_size, 255, dtype=np.uint8)
        fmt = "%-4i%-8.4f%-8.4f%-4i%-4i%-11.4f%-11.4f%-11.4f%-8.4f%-4i%-i"
        header = CTF_HEADERS[vendor] % (nx, ny)
    elif vendor == "astar":
        phase_id = np.ones(map_size, dtype=np.uint8)
        bands = np.full(map_size, 6, dtype=np.uint8)
        bc = rng.integers(0, 60, map_size)
        bs = rng.integers(35, 42, map_size)
        fmt = "%-4i%-8.4f%-8.4f%-4i%-4i%-9.2f%-9.2f%-9.2f%-8.4f%-4i%-i"
        header = CTF_HEADERS[vendor] % (nx, ny)
    elif vendor == "emsoft":
        phase_id = np.ones(map_size, dtype=np.uint8)
        bands = rng.integers(0, 333_000, map_size)
        bc = rng.integers(60, 140, map_size)
        bs = rng.integers(60, 120, map_size)
        fmt = "%-4i%-8.4f%-8.4f%-7i%-4i%-10.3f%-10.3f%-10.3f%-8.4f%-4i%-i"
        header = CTF_HEADERS[vendor] % (nx, ny, dx, dy)
    else:  # mtex
        phase_id = np.ones(map_size, dtype=np.uint8)
        bands = np.zeros(map_size)
        mad = np.zeros(map_size)
        bc = np.zeros(map_size)
        bs = np.zeros(map_size)
        fmt = "%-4i%-8.4f%-8.4f%-4i%-4i%-11.4f%-11.4f%-11.4f%-8.4f%-4i%-i"
        header = CTF_HEADERS[vendor] % (nx, ny, dx, dy)
    non_indexed = rng.choice(np.arange(map_size), replace=False, size=int(map_size * 0.1))
    phase_id[non_indexed] = 0
    R[non_indexed] = 0.0
    if vendor != "mtex":
        bands[non_indexed] = 0
        mad[non_indexed] = 0.0
        bc[non_indexed] = 0
        bs[non_indexed] = 0
        if vendor != "emsoft":
            err[non_indexed] = 3
    np.savetxt(
        fname=path,
        X=np.column_stack((phase_id, x, y, bands, err, R[:, 0], R[:, 1], R[:, 2], mad, bc, bs)),
        fmt=fmt,
        header=header,
        comments="",
    )


def ctf_reference(path):
    """What orix.io.load gives for a Channel Text File."""
    xmap = io.load(path)
    # The Euler angles as orix's reader parses them from the file (np.loadtxt below the header), not the rotation round
    # trip: the reader's parity is the columns.
    with open(path) as f:
        data_starting_row = 0
        for line in f:
            data_starting_row += 1
            if line.startswith("Phase\tX\tY"):
                break
    euler = np.loadtxt(path, skiprows=data_starting_row)[:, 5:8]
    ref = {
        "shape": [int(v) for v in xmap.shape],
        "size": int(xmap.size),
        "scanUnit": xmap.scan_unit,
        "stepSizes": [float(xmap.dy), float(xmap.dx)],
        "x": xmap.x.tolist(),
        "y": xmap.y.tolist(),
        "phaseID": [int(v) for v in xmap.phase_id],
        "eulerDegrees": euler.tolist(),
        "props": {k: np.asarray(v).tolist() for k, v in xmap.prop.items()},
        "propNames": list(xmap.prop.keys()),
        "phases": [],
    }
    for pid, phase in xmap.phases:
        ref["phases"].append({
            "id": int(pid),
            "name": phase.name,
            "pointGroup": phase.point_group.name if phase.point_group is not None else None,
            "spaceGroup": int(phase.space_group.number) if phase.space_group is not None else None,
            "lattice": [float(v) for v in phase.structure.lattice.abcABG()] if phase.structure is not None else None,
        })
    with open(path + ".json", "w") as f:
        json.dump(ref, f, indent=1)


def make_ctf():
    layouts = {
        "oxford.ctf": ("oxford", (5, 3), (0.1, 0.1), 1),
        "bruker.ctf": ("bruker", (7, 13), (0.001998, 0.001998), 2),
        "astar.ctf": ("astar", (7, 13), (0.00191999995708466, 0.00191999995708466), 3),
        "emsoft.ctf": ("emsoft", (7, 13), (1.0, 2.0), 4),
        "mtex.ctf": ("mtex", (7, 13), (1.0, 2.0), 5),
    }
    for name, (vendor, shape, steps, seed) in layouts.items():
        path = os.path.join(OUT, name)
        write_dummy_ctf(path, vendor, shape, steps, seed)
        ctf_reference(path)


def make_ti(ti_path, head_rows=2000):
    """orix.data.ti_orientations: np.loadtxt(skiprows=1, usecols=(0, 1, 2)) in degrees, point group D6 (622)."""
    from orix.quaternion import Orientation
    from orix.quaternion.symmetry import D6

    with open(ti_path, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    with open(ti_path) as src, open(os.path.join(OUT, "ti_orientations_head.ctf"), "w") as dst:
        for i, line in enumerate(src):
            if i > head_rows:
                break
            dst.write(line)
    full = np.loadtxt(ti_path, skiprows=1)
    euler = full[:, :3]
    ori = Orientation.from_euler(np.deg2rad(euler), D6)
    sample = np.arange(0, len(full), 997)
    head = np.loadtxt(os.path.join(OUT, "ti_orientations_head.ctf"), skiprows=1)
    with open(ti_path) as f:
        columns = f.readline().split()
    ref = {
        "source": "https://github.com/pyxem/orix-data/raw/main/ti_orientations/Ti_orientations.ctf",
        "sha256": digest,
        "pointGroup": ori.symmetry.name,
        "columns": columns,
        "head": {"rows": int(len(head)), "eulerDegrees": head[:, :3].tolist(), "all": head.tolist()},
        "full": {
            "rows": int(len(full)),
            "sampleRows": sample.tolist(),
            "sampleEulerDegrees": euler[sample].tolist(),
            "sampleQuaternions": ori.data[sample].tolist(),
        },
    }
    with open(os.path.join(OUT, "ti_orientations.json"), "w") as f:
        json.dump(ref, f, indent=1)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--ti", help="path to orix-data's Ti_orientations.ctf (downloaded separately; 29 MB)")
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    make_ebsp()
    make_ctf()
    if args.ti:
        make_ti(args.ti)
    print("kikuchipy", kp.__version__, "orix", __import__("orix").__version__, "numpy", np.__version__, "->", OUT)
