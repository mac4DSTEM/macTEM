# tools/parity/sem-readers/make_edax_fixtures.py — writes the EDAX binary (.up1/.up2) and .ang fixtures of macTEMTests and the
# truth they are read against (kikuchipy 0.13.1 `edax_binary.file_reader`, orix 0.15.0 `ang.file_reader`).
#
#   python -I -B make_edax_fixtures.py <out dir> [sdss_ferrite_austenite.ang]
#
# Fixtures (copied flat into the test bundle, so the names are unique):
#   ebsd-edax-binary.up1          kikuchipy's in-package edax_binary/edax_binary.up1 (version 1, 9 patterns of 60 x 60 uint8, CC BY 4.0)
#   ebsd-edax-binary-hex.up2      kikuchipy's in-package edax_binary/edax_binary.up2 (version 3, hexagonal grid flag set, 10 patterns uint16)
#   ebsd-edax-binary.up2          written here: version 3, square grid, 3 x 4 patterns of 6 x 8 uint16, step 0.25 x 0.5 µm
#   ebsd-edax-binary-v2.up2       written here: version 2, which kikuchipy refuses
#   ebsd-sdss-ferrite-austenite.ang  orix-data's sdss_ferrite_austenite.ang (EMsoft EMdpmerge, 8 columns, 117 x 100, CC BY 4.0)
#   ebsd-tsl.ang                  written here: an EDAX TSL OIM header with 10 columns, 4 x 3 points, one not indexed (CI -1)
#   ebsd-tsl-hex.ang              the same header on a hexagonal grid: refused by the app (decision D-SEM-9)
# Truth: ebsd-edax.truth.json, what the references return for each file. Floats are repr() (round-trip exact); a column of the
# .ang is the sha256 of its float64 bytes (np.loadtxt parses correctly rounded, so a Swift Double parse is bit-equal).
import hashlib, json, shutil, sys, warnings
from pathlib import Path
import numpy as np
import kikuchipy as kp
import orix
from orix.io import load as orix_load
from orix.io.plugins.ang import _get_header, _get_vendor_columns

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
pkg = Path(kp.__file__).parent / "data" / "edax_binary"
shutil.copy(pkg / "edax_binary.up1", out / "ebsd-edax-binary.up1")
shutil.copy(pkg / "edax_binary.up2", out / "ebsd-edax-binary-hex.up2")
# orix-data's file: given as the second argument, else fetched from GitHub (orix's own data registry URL) into the out dir.
if len(sys.argv) > 2:
    shutil.copy(sys.argv[2], out / "ebsd-sdss-ferrite-austenite.ang")
else:
    import urllib.request
    urllib.request.urlretrieve("https://raw.githubusercontent.com/pyxem/orix-data/main/sdss_ferrite_austenite/sdss_ferrite_austenite.ang",
                               out / "ebsd-sdss-ferrite-austenite.ang")


def write_up(path, version, patterns, nx=None, ny=None, is_hex=False, dx=1.0, dy=1.0):
    """EDAX UP layout as kikuchipy reads it: uint32 version, sx, sy, pattern offset; version >= 3 adds one unused byte, uint32 nx, ny,
    uint8 hex flag, float64 dx, dy; then the patterns."""
    n, sy, sx = patterns.shape
    with open(path, "wb") as f:
        head = np.array([version, sx, sy, 0], dtype="<u4")
        if version >= 3:
            offset = 16 + 1 + 8 + 1 + 16
        else:
            offset = 16
        head[3] = offset
        f.write(head.tobytes())
        if version >= 3:
            f.write(b"\x00")
            f.write(np.array([nx, ny], dtype="<u4").tobytes())
            f.write(np.array([1 if is_hex else 0], dtype="u1").tobytes())
            f.write(np.array([dx, dy], dtype="<f8").tobytes())
        f.write(np.ascontiguousarray(patterns).tobytes())


rng = np.random.default_rng(7)
square = rng.integers(0, 65535, size=(12, 6, 8), dtype=np.uint16)
write_up(out / "ebsd-edax-binary.up2", 3, square, nx=4, ny=3, dx=0.25, dy=0.5)
write_up(out / "ebsd-edax-binary-v2.up2", 2, square[:2])

tsl_header = """# TEM_PIXperUM          1.000000
# x-star                 0.512345
# y-star                 0.678901
# z-star                 0.654321
# WorkingDistance        15.000000
#
# Phase 1
# MaterialName  	Nickel
# Formula     	Ni
# Info 		
# Symmetry              43
# LatticeConstants      3.524 3.524 3.524  90.000  90.000  90.000
# NumberFamilies        4
# hklFamilies   	 1  1  1 1 0.000000 1
# hklFamilies   	 2  0  0 1 0.000000 1
# hklFamilies   	 2  2  0 1 0.000000 1
# hklFamilies   	 3  1  1 1 0.000000 1
# Categories 0 0 0 0 0
#
# GRID: {grid}
# XSTEP: 2.000000
# YSTEP: 2.000000
# NCOLS_ODD: 4
# NCOLS_EVEN: 4
# NROWS: 3
#
# OPERATOR: 	tester
#
# SAMPLEID: 	
#
# SCANID: 	
#
"""
tsl_rows = []
for r in range(3):
    for c in range(4):
        i = r * 4 + c
        ci = -1.0 if i == 5 else 0.1 + 0.07 * i
        tsl_rows.append(f"  {0.1 * i:.5f}  {0.2 + 0.05 * i:.5f}  {6.0 - 0.3 * i:.5f}  {2.0 * c:.5f}  {2.0 * r:.5f}  {100.0 + i:.1f}  {ci:.3f}  1  {1000 + i}  {0.5 + 0.01 * i:.3f}")
(out / "ebsd-tsl.ang").write_text(tsl_header.format(grid="SqrGrid") + "\n".join(tsl_rows) + "\n")
(out / "ebsd-tsl-hex.ang").write_text(tsl_header.format(grid="HexGrid") + "\n".join(tsl_rows) + "\n")


def sha(b): return hashlib.sha256(b).hexdigest()
def flt(a): return [repr(float(v)) for v in np.asarray(a, dtype=np.float64).ravel()]


truth = {"kikuchipy": kp.__version__, "orix": orix.__version__, "up": {}, "ang": {}}

for name in ["ebsd-edax-binary.up1", "ebsd-edax-binary-hex.up2", "ebsd-edax-binary.up2"]:
    path = out / name
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        s = kp.load(path)
    with open(path, "rb") as f:
        header = kp.io.plugins.edax_binary._api.EDAXBinaryFileReader(f).read_header()
    data = np.ascontiguousarray(s.data)
    nav = list(s._navigation_shape_rc); sig = list(s._signal_shape_rc)
    truth["up"][name] = {
        "file_sha256": sha(path.read_bytes()),
        "version": int(np.fromfile(path, "<u4", 1)[0]),
        "header": {k: (bool(v) if k == "is_hex" else (repr(float(v)) if k in ("dx", "dy") else int(v))) for k, v in header.items()},
        "nav_shape": nav, "sig_shape": sig, "dtype": str(data.dtype),
        "warnings": [str(w.message) for w in caught],
        "patterns_sha256": sha(data.tobytes()),
        "first_pattern": [int(v) for v in data.reshape(-1, sig[0], sig[1])[0].ravel()],
        "last_pattern": [int(v) for v in data.reshape(-1, sig[0], sig[1])[-1].ravel()],
    }
v2 = out / "ebsd-edax-binary-v2.up2"
try:
    kp.load(v2); refused = None
except ValueError as e:
    refused = str(e)
truth["up"]["ebsd-edax-binary-v2.up2"] = {"file_sha256": sha(v2.read_bytes()), "version": 2, "refused": refused}

for name in ["ebsd-sdss-ferrite-austenite.ang", "ebsd-tsl.ang", "ebsd-tsl-hex.ang"]:
    path = out / name
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        xmap = orix_load(path)
    with open(path) as f:
        header = _get_header(f)
    file_data = np.loadtxt(path)
    vendor, columns = _get_vendor_columns(header, file_data.shape[1])
    n = file_data.shape[0]
    sample = sorted(set(range(0, n, 97)) | {0, n - 1})
    header_fields = {}
    for line in header:
        for key in ["TEM_PIXperUM", "x-star", "y-star", "z-star", "WorkingDistance", "XSTEP:", "YSTEP:", "NCOLS_ODD:", "NCOLS_EVEN:", "NROWS:", "GRID:"]:
            if line.startswith("# " + key):
                header_fields[key.rstrip(":")] = line[2 + len(key):].strip()
    truth["ang"][name] = {
        "file_sha256": sha(path.read_bytes()),
        "vendor": vendor, "columns": columns, "n_rows": n, "n_columns": int(file_data.shape[1]),
        "header_fields": header_fields,
        "shape": list(xmap.shape), "dx": repr(float(xmap.dx)), "dy": repr(float(xmap.dy)), "scan_unit": xmap.scan_unit,
        "phase_ids": [int(i) for i in xmap.phases.ids],
        "phase_names": [str(p.name) for _, p in xmap.phases],
        "point_groups": [None if p.point_group is None else p.point_group.name for _, p in xmap.phases],
        "lattices": [flt(p.structure.lattice.abcABG()) for _, p in xmap.phases],
        "indexed_phase_ids": [int(i) for i in xmap.phases_in_data.ids if i != -1],
        # phase_id is the map's (not indexed -> -1), every other column the file's.
        "column_sha256": {c: sha(np.ascontiguousarray(xmap.phase_id if c == "phase_id" else file_data[:, i], dtype="<f8").tobytes())
                          for i, c in enumerate(columns)},
        "first_row": flt(file_data[0]), "last_row": flt(file_data[-1]),
        "phase_id_counts": {str(int(k)): int(v) for k, v in zip(*np.unique(xmap.phase_id, return_counts=True))},
        "not_indexed": int(np.sum(~xmap.is_indexed)),
        "rotation_sample_rows": sample,
        "rotation_sample": flt(xmap.rotations.data[sample]),
        "prop_names": sorted(xmap.prop.keys()),
    }

(out / "ebsd-edax.truth.json").write_text(json.dumps(truth, indent=1) + "\n")
print("wrote", len(truth["up"]) + len(truth["ang"]), "fixtures to", out)
