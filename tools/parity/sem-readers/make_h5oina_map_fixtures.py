# tools/parity/sem-readers/make_h5oina_map_fixtures.py — writes the map-only H5OINA fixtures of macTEMTests (#513).
#
#   python -I -B make_h5oina_map_fixtures.py <out dir>        (h5py 3.16.0, NumPy 2.5.4, as pinned in tools/parity/sem)
#
# AZtec exports an EBSD map as an H5OINA file without patterns: /1/EBSD/Data holds Euler, Phase, X, Y and the indexing columns,
# /1/EBSD/Header the cells, steps and phases, and the header names the acquired pattern size ("Acquired Pattern Height") but no
# "Pattern Height". The layout is the H5OINA specification's (github.com/oinanoanalysis/h5oina, H5OINAFile.md, format 7.0). Neither
# kikuchipy nor orix reads such a map, so these files are planted: every value is exact in float32 (dyadic fractions), and the test
# states the map it must read in the test itself (EBSDH5OxfordMapTests). Fixtures (each a few KiB, copied flat into the test bundle):
#   ebsd-oxford-map.h5oina           a 4 x 3 map, two phases (Al m-3m, Mg 6/mmm), one point not indexed; X and Y row by row
#   ebsd-oxford-map-shuffled.h5oina  the same points stored in another order, each with its X and Y (DREAM3D's EbsdLib places them)
#   ebsd-oxford-map-grid.h5oina      the same map without X and Y (the header's cells and steps place the points, as MTEX does)
#   ebsd-oxford-map-no-euler.h5oina  the header and phases but no Euler angles and no patterns: nothing to show, refused in words
import sys
from pathlib import Path
import h5py
import numpy as np

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)

NX, NY, DX, DY = 4, 3, 0.5, 0.25
N = NX * NY
PHASE = np.array([1, 1, 2, 2,
                  1, 0, 2, 2,
                  1, 1, 1, 2], dtype=np.uint8)
I = np.arange(N, dtype=np.float32)
EULER = np.column_stack([0.5 + 0.125 * I, 0.25 + 0.0625 * I, 1.0 + 0.03125 * I]).astype(np.float32)
EULER[PHASE == 0] = 0
MAD = (0.0078125 * (I + 1)).astype(np.float32)          # radians, as the specification states
BC = (100 + np.arange(N)).astype(np.uint8)
BS = (50 + np.arange(N)).astype(np.uint8)
BANDS = (8 + np.arange(N) % 4).astype(np.uint8)
ERROR = np.where(PHASE == 0, 2, 1).astype(np.uint8)    # NoSolution where not indexed, Success elsewhere
COLUMN = np.tile(np.arange(NX), NY)
ROW = np.repeat(np.arange(NY), NX)
X = (COLUMN * DX).astype(np.float32)
Y = (ROW * DY).astype(np.float32)


def scalar(group, name, value, dtype, unit=None):
    group.create_dataset(name, data=np.array([value], dtype=dtype))
    if unit:
        group[name].attrs["Unit"] = unit


def text(group, name, value):
    group.create_dataset(name, data=np.array([value.encode()], dtype=h5py.string_dtype("ascii", len(value))))


def phase(group, name, dims, angles_deg, laue, laue_symbol, space, space_symbol):
    g = group.create_group(name)
    text(g, "Phase Name", {"1": "Aluminium", "2": "Magnesium"}[name])
    g.create_dataset("Lattice Dimensions", data=np.array([dims], dtype=np.float32))
    g.create_dataset("Lattice Angles", data=np.deg2rad(np.array([angles_deg], dtype=np.float64)).astype(np.float32))
    scalar(g, "Laue Group", laue, np.int32)
    g["Laue Group"].attrs["Symbol"] = laue_symbol
    scalar(g, "Space Group", space, np.int32)
    g["Space Group"].attrs["Symbol"] = space_symbol
    scalar(g, "Database Id", 0, np.int32)
    scalar(g, "Phase Id", int(name), np.int32)


def write(name, order=None, xy=True, euler=True):
    o = np.arange(N) if order is None else np.asarray(order)
    with h5py.File(out / name, "w") as f:
        text(f, "Format Version", "7.0")
        text(f, "Manufacturer", "Oxford Instruments")
        text(f, "Software Version", "6.1.8691.1")
        text(f, "Index", "1")
        ebsd = f.create_group("1").create_group("EBSD")
        data = ebsd.create_group("Data")
        data.create_dataset("Phase", data=PHASE[o])
        if euler:
            data.create_dataset("Euler", data=EULER[o])
            data["Euler"].attrs["Unit"] = "rad"
        data.create_dataset("Mean Angular Deviation", data=MAD[o])
        data["Mean Angular Deviation"].attrs["Unit"] = "rad"
        data.create_dataset("Band Contrast", data=BC[o])
        data.create_dataset("Band Slope", data=BS[o])
        data.create_dataset("Bands", data=BANDS[o])
        data.create_dataset("Error", data=ERROR[o])
        if xy:
            data.create_dataset("X", data=X[o]); data["X"].attrs["Unit"] = "um"
            data.create_dataset("Y", data=Y[o]); data["Y"].attrs["Unit"] = "um"
        header = ebsd.create_group("Header")
        scalar(header, "X Cells", NX, np.int32, "px")
        scalar(header, "Y Cells", NY, np.int32, "px")
        scalar(header, "X Step", DX, np.float32, "um")
        scalar(header, "Y Step", DY, np.float32, "um")
        scalar(header, "Acquired Pattern Width", 156, np.int32, "px")
        scalar(header, "Acquired Pattern Height", 128, np.int32, "px")
        scalar(header, "Beam Voltage", 20, np.float32, "kV")
        scalar(header, "Magnification", 1000, np.float32)
        scalar(header, "Working Distance", 15, np.float32, "mm")
        scalar(header, "Tilt Angle", np.deg2rad(70), np.float32, "rad")
        scalar(header, "Scanning Rotation Angle", np.pi, np.float32, "rad")
        header.create_dataset("Specimen Orientation Euler", data=np.zeros((1, 3), dtype=np.float32))
        text(header, "Camera Mode", "Speed 2 (156x128 px)")
        phases = header.create_group("Phases")
        phase(phases, "1", [4.05, 4.05, 4.05], [90, 90, 90], 11, "m-3m", 225, "F m -3 m")
        phase(phases, "2", [3.21, 3.21, 5.21], [90, 90, 120], 9, "6/mmm", 194, "P 63/m m c")


write("ebsd-oxford-map.h5oina")
# Another storage order (the rows bottom to top, each right to left, then every other point swapped): X and Y place each point.
shuffled = np.arange(N)[::-1].copy()
shuffled[0::2], shuffled[1::2] = shuffled[1::2].copy(), shuffled[0::2].copy()
write("ebsd-oxford-map-shuffled.h5oina", order=shuffled)
write("ebsd-oxford-map-grid.h5oina", xy=False)
write("ebsd-oxford-map-no-euler.h5oina", euler=False)
