#!/usr/bin/env python
"""tools/parity/sem/make_fixtures.py — write the planted fixtures that no public file covers.

    make_fixtures.py [--data References/sem-data]

Planted, deterministic, small, committed under fixtures/ with the hand-written truth beside them:

* `planted_oxford.ctf`: an Oxford Channel 5 text file with 4 x 5 points of two phases (fcc and bcc iron, the duplex
  steel of the public .ang map), hand-written values in the table below, one not-indexed point (phase 0, error 3)
  and the MAD, BC and BS columns.
  orix has no .ctf writer (0.15.0 saves .ang and .h5 only) and no public .ctf of a known licence was found on the
  day, so the planted file is the ctf reader's fixture; its truth is `planted_oxford.truth.json`.
* `oxford_h5oina_patterns.h5oina` and `bruker_h5ebsd_patterns.h5`: kikuchipy's own dummy writers
  (`kikuchipy.data._dummy_files`), which build a 3 x 3 file around the Ni small dataset. Regenerated here so a
  kikuchipy change in the writers is a visible diff, never a silent one.
* `rsciio/edax/*_crop8.spd`, `rsciio/edax/line_scan_crop.lsd` and their `.spc`/`.ipr`/`.csv` companions: 8 x 8 pixel
  windows of RosettaSciIO's EDAX test maps (`edax_files.zip`, 200-256 MB each, too large to commit; the window keeps
  every byte of the pixels it holds and rewrites only nPoints/nLines/nSpectra of the 1068-byte header) and its line
  scan with nPoints cut to its three spectra (rsciio reads nPoints x nLines spectra and keeps the first nSpectra, so
  the result is the same three spectra). Needs `--data` (fetch-data.sh); skipped with a line without it.
* `rsciio/jeol/View000_0000006_4frames.pts` and `View000_0000006_2.5frames.pts`: RosettaSciIO's JEOL map cut after
  its fourth frame (sweep) and in the middle of its third, header untouched (it still says 14 sweeps): the first
  reads four complete frames, the second two and drops the incomplete third, as `_readcube` does.
* `planted_emsoft_tkd_master_pattern.h5` and `planted_emsoft_ecp_master_pattern.h5`: EMsoft TKD and ECP master pattern
  files as kikuchipy's own test fixtures build them (`kikuchipy/conftest.py`, `emsoft_tkd_master_pattern_file` and
  `emsoft_ecp_master_pattern_file`: 13 x 13 Lambert and stereographic patterns at 11 energies, 10 to 20 kV, of the
  Al2Cu test phase). kikuchipy ships no TKD or ECP master pattern file, so these are the readers' fixtures for those two.
* `orientation_inputs.json`: the inputs of the orientation-maths bundles (m3): seeded unit quaternions with seven
  special rotations, Bunge angles, cubochoric points, vectors, seeded m-3m orientations, the point-group names orix
  defines, and the Bunge angles of the first 2000 rows of orix-data's `Ti_orientations.ctf` (CC BY 4.0, the head
  committed as macTEMTests/Fixtures/sem/oxford/ti_orientations_head.ctf). `--orientation-only` writes just this file.

* `grain_inputs.json`: the input of the grain bundle `m5/grains-ti`: a 90 x 120 corner of orix-data's
  `Ti_orientations.ctf` (hcp titanium, CC BY 4.0), the file's own Bunge angles in degrees, read from the fetched dataset
  (fetch-data.sh first). `--grain-only` writes just this file.

Run with `python -I -B`.
"""

from __future__ import annotations

import argparse
import json
import shutil
import struct
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"

# phase, x, y, bands, error, euler1, euler2, euler3, MAD, BC, BS. Point (row 1, col 2) is not indexed (phase 0).
CTF_ROWS = [
    (1, 0.0, 0.0, 9, 0, 97.5831, 44.5012, 210.5470, 0.3271, 150, 180),
    (1, 0.5, 0.0, 9, 0, 97.6060, 44.5600, 210.6700, 0.3122, 152, 181),
    (2, 1.0, 0.0, 10, 0, 203.2510, 35.1250, 77.0780, 0.4410, 131, 160),
    (2, 1.5, 0.0, 10, 0, 203.2700, 35.1500, 77.0100, 0.4512, 128, 158),
    (2, 2.0, 0.0, 10, 0, 203.3100, 35.2000, 76.9900, 0.4388, 130, 161),
    (1, 0.0, 0.5, 9, 0, 97.5900, 44.5100, 210.5300, 0.3300, 149, 179),
    (1, 0.5, 0.5, 8, 0, 97.6100, 44.5500, 210.6000, 0.3190, 151, 182),
    (0, 1.0, 0.5, 0, 3, 0.0000, 0.0000, 0.0000, 0.0000, 60, 20),
    (2, 1.5, 0.5, 10, 0, 203.2600, 35.1400, 77.0300, 0.4499, 127, 157),
    (2, 2.0, 0.5, 10, 0, 203.3000, 35.1900, 77.0000, 0.4400, 129, 160),
    (1, 0.0, 1.0, 9, 0, 97.5700, 44.4900, 210.5600, 0.3250, 150, 180),
    (1, 0.5, 1.0, 9, 0, 97.6000, 44.5400, 210.6500, 0.3100, 153, 183),
    (1, 1.0, 1.0, 9, 0, 97.6200, 44.5700, 210.6900, 0.3150, 152, 182),
    (2, 1.5, 1.0, 10, 0, 203.2800, 35.1600, 77.0200, 0.4520, 126, 156),
    (2, 2.0, 1.0, 10, 0, 203.2900, 35.1800, 77.0100, 0.4450, 128, 159),
    (1, 0.0, 1.5, 9, 0, 97.5800, 44.5000, 210.5500, 0.3280, 151, 181),
    (1, 0.5, 1.5, 9, 0, 97.6050, 44.5450, 210.6600, 0.3110, 152, 182),
    (1, 1.0, 1.5, 9, 0, 97.6150, 44.5650, 210.6800, 0.3160, 151, 181),
    (2, 1.5, 1.5, 10, 0, 203.2750, 35.1550, 77.0250, 0.4515, 127, 157),
    (2, 2.0, 1.5, 10, 0, 203.2950, 35.1850, 77.0050, 0.4440, 129, 160),
]

CTF_HEADER = """Channel Text File
Prj	planted_oxford
Author	[Unknown]
JobMode	Grid
XCells	5
YCells	4
XStep	0.5000
YStep	0.5000
AcqE1	0.0000
AcqE2	0.0000
AcqE3	0.0000
Euler angles refer to Sample Coordinate system (CS0)!	Mag	2000	Coverage	100	Device	0	KV	20	TiltAngle	70	TiltAxis	0
Phases	2
3.5900;3.5900;3.5900	90.000;90.000;90.000	Iron fcc	11	225			Generic superlattice
2.8660;2.8660;2.8660	90.000;90.000;90.000	Iron bcc (old)	11	229
Phase	X	Y	Bands	Error	Euler1	Euler2	Euler3	MAD	BC	BS
"""


def write_ctf() -> None:
    lines = [CTF_HEADER]
    for r in CTF_ROWS:
        lines.append("\t".join(["%d" % r[0], "%.4f" % r[1], "%.4f" % r[2], "%d" % r[3], "%d" % r[4],
                                "%.4f" % r[5], "%.4f" % r[6], "%.4f" % r[7], "%.4f" % r[8], "%d" % r[9], "%d" % r[10]]) + "\n")
    (FIXTURES / "planted_oxford.ctf").write_text("".join(lines), encoding="utf-8")
    truth = {
        "shape_rc": [4, 5], "x_step": 0.5, "y_step": 0.5,
        "phases": {"1": {"name": "Iron fcc", "space_group": 225, "a": 3.59}, "2": {"name": "Iron bcc (old)", "space_group": 229, "a": 2.866}},
        "not_indexed_points": [[1, 2]],
        "rows": [list(r) for r in CTF_ROWS],
        "columns": ["phase", "x", "y", "bands", "error", "euler1_deg", "euler2_deg", "euler3_deg", "MAD", "BC", "BS"],
    }
    (FIXTURES / "planted_oxford.truth.json").write_text(json.dumps(truth, indent=2) + "\n", encoding="utf-8")


def write_kikuchipy_dummies() -> None:
    import kikuchipy.data._dummy_files.bruker_h5ebsd as bruker
    import kikuchipy.data._dummy_files.oxford_h5ebsd as oxford

    oxford.create_dummy_oxford_h5ebsd_file(FIXTURES / "oxford_h5oina_patterns.h5oina")
    bruker.create_dummy_bruker_h5ebsd_file(FIXTURES / "bruker_h5ebsd_patterns.h5")


SPD_HEADER = 1068
SPD_WINDOW = {"spd_map": (96, 120), "spc0_61-ipr333_xrf": (96, 120)}  # (first row, first column) of the 8 x 8 window
SPD_IPR = {"spd_map": "Live Map 2_Img.ipr", "spc0_61-ipr333_xrf": "Garnet1_Img.ipr"}


def _crop_spd(raw: bytes, row0: int, col0: int, size: int = 8) -> bytes:
    """An 8 x 8 window of an SPD map: the header with nSpectra, nPoints, nLines rewritten, then the window's spectra."""
    n_spectra, n_points, n_lines, n_channels, count_bytes, data_offset = struct.unpack_from("<iiIIII", raw, 20)
    assert raw[:15] == b"MAPSPECTRA_DATA" and data_offset == SPD_HEADER, "not an SPD map of the known layout"
    head = bytearray(raw[:data_offset])
    struct.pack_into("<iiI", head, 20, size * size, size, size)
    per_pixel = n_channels * count_bytes
    body = bytearray()
    for r in range(row0, row0 + size):
        start = data_offset + (r * n_points + col0) * per_pixel
        body += raw[start:start + size * per_pixel]
    return bytes(head) + bytes(body)


def write_rsciio_derived(data: Path) -> list[str]:
    """The windows of RosettaSciIO's EDAX and JEOL test files that are too large to commit (see the module text)."""
    written = []
    zip_path = data / "rsciio" / "edax" / "edax_files.zip"
    if zip_path.exists():
        out = FIXTURES / "rsciio" / "edax"
        out.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zip_path) as z:
            for stem, (r0, c0) in SPD_WINDOW.items():
                (out / f"{stem}_crop8.spd").write_bytes(_crop_spd(z.read(f"{stem}.spd"), r0, c0))
                (out / f"{stem}_crop8.spc").write_bytes(z.read(f"{stem}.spc"))
                (out / SPD_IPR[stem]).write_bytes(z.read(SPD_IPR[stem]))
                written.append(f"rsciio/edax/{stem}_crop8.spd")
            lsd = bytearray(z.read("line_scan.lsd"))
            n_spectra, n_points, n_lines, n_channels, count_bytes, data_offset = struct.unpack_from("<iiIIII", lsd, 20)
            struct.pack_into("<i", lsd, 24, n_spectra)
            (out / "line_scan_crop.lsd").write_bytes(bytes(lsd[:data_offset + n_spectra * n_lines * n_channels * count_bytes]))
            (out / "line_scan_crop.spc").write_bytes(z.read("line_scan.spc"))
            (out / "line_scan_crop.csv").write_bytes(z.read("line_scan.csv"))
            (out / "single_spect.spc").write_bytes(z.read("single_spect.spc"))
            written += ["rsciio/edax/line_scan_crop.lsd", "rsciio/edax/single_spect.spc"]
    else:
        print(f"make_fixtures.py: skip the EDAX windows, {zip_path} not fetched (fetch-data.sh)")
    pts = data / "rsciio" / "jeol" / "Sample" / "00_View000" / "View000_0000006.pts"
    if pts.exists():
        import numpy as np
        from rsciio.jeol._api import _skip_frame

        raw = pts.read_bytes()
        data_pos = struct.unpack_from("<I", raw, 4 + 8 + 16)[0]
        stream = np.frombuffer(raw[data_pos:], dtype="<u2")
        starts = [0]
        while len(starts) < 5:
            starts.append(starts[-1] + int(_skip_frame(stream[starts[-1]:])))
        out = FIXTURES / "rsciio" / "jeol"
        out.mkdir(parents=True, exist_ok=True)
        (out / "View000_0000006_4frames.pts").write_bytes(raw[:data_pos + 2 * starts[4]])
        half = starts[2] + (starts[3] - starts[2]) // 2
        (out / "View000_0000006_2.5frames.pts").write_bytes(raw[:data_pos + 2 * half])
        written += ["rsciio/jeol/View000_0000006_4frames.pts", "rsciio/jeol/View000_0000006_2.5frames.pts"]
    else:
        print(f"make_fixtures.py: skip the JEOL frame cuts, {pts} not fetched (fetch-data.sh)")
    return written


def write_emsoft_master_pattern(path: Path, diffraction_type: str) -> None:
    """kikuchipy's conftest fixture of the same name, for "TKD" or "ECP" (the two differ in the energy dataset's name,
    the Monte Carlo name list's and the names in it, and ECP has no BetheParameters)."""
    import h5py
    import numpy as np

    import kikuchipy as kp
    from kikuchipy.io.plugins._h5ebsd import _dict2hdf5group

    npx = 6
    signal_shape = (npx * 2 + 1,) * 2
    energies = np.linspace(10, 20, 11, dtype=np.float32)
    data_shape = (len(energies),) + signal_shape
    mp_lam_upper = np.ones((1,) + data_shape, dtype=np.float32) * energies.reshape((1, 11, 1, 1))
    mp_lam_lower = mp_lam_upper
    circle = kp.filters.Window(shape=signal_shape).astype(np.float32)
    mp_sph_upper = mp_lam_upper.squeeze() * circle
    mp_sph_lower = mp_sph_upper
    crystal = {
        "AtomData": np.array([[0.1587, 0], [0.6587, 0], [0, 0.25], [1, 1], [0.005, 0.005]], dtype=np.float32),
        "Atomtypes": np.array([13, 29], dtype=np.int32),
        "CrystalSystem": 2,
        "LatticeParameters": np.array([0.5949, 0.5949, 0.5821, 90, 90, 90]),
        "Natomtypes": 2,
        "Source": "Su Y.C., Yan J., Lu P.T., Su J.T.: Thermodynamic...",
        "SpaceGroupNumber": 140,
        "SpaceGroupSetting": 1,
    }
    mc = {"Ebinsize": energies[1] - energies[0], "Ehistmin": np.min(energies), "EkeV": np.max(energies), "MCmode": "CSDA",
          "dataname": "crystal_data/al2cu/al2cu_mc_mp_20kv.h5", "depthmax": 100.0, "depthstep": 1.0, "numsx": npx,
          "totnum_el": 2000000000}
    if diffraction_type == "ECP":
        master = {"EkeV": np.linspace(10, 20, 11, dtype=np.float32), "mLPNH": mp_lam_upper, "masterSPNH": mp_sph_upper,
                  "masterSPSH": mp_sph_lower, "numset": 1}
        mc.update({"mode": "bse1", "sigend": 10.0, "sigstart": 0.0, "sigstep": 2.0})
        mc_name = "MCCLNameList"
    else:
        master = {"BetheParameters": np.array([4, 8, 50, 1], dtype=np.float32),
                  "EkeVs": np.linspace(10, 20, 11, dtype=np.float32), "mLPNH": mp_lam_upper, "masterSPNH": mp_sph_upper,
                  "masterSPSH": mp_sph_lower, "numEbins": len(energies), "numset": 1}
        mc.update({"sig": -20.0})
        mc_name = "MCCLfoilNameList"
    program = f"EM{diffraction_type}master.f90".encode()
    data = {
        "CrystalData": crystal,
        "EMData": {f"{diffraction_type}master": master},
        "NMLparameters": {f"{diffraction_type}MasterNameList": {"dmin": 0.05, "npx": npx}, mc_name: mc,
                          "BetheList": {"c1": 4.0, "c2": 8.0, "c3": 50.0, "sgdbdiff": 1.0}},
        "EMheader": {f"{diffraction_type}master": {"ProgramName": np.array([program], dtype=f"S{len(program)}")}},
    }
    with h5py.File(path, mode="w") as f:
        _dict2hdf5group(dictionary=data, group=f["/"])
        f[f"EMData/{diffraction_type}master"].create_dataset("mLPSH", data=mp_lam_lower, chunks=True)
        f["CrystalData"].create_dataset("CreationTime", data=b"12:30:13.559 PM\xf0\x14\x1e\xc8\xbcU")


def write_orientation_inputs() -> None:
    import numpy as np
    from orix.quaternion import Rotation, symmetry

    rng = np.random.default_rng(20261106)
    axes = [(0, 0, 1), (0, 0, 1), (1, 0, 0), (1, 1, 1), (0, 1, 0), (1, 1, 0)]
    angles = [0.0, np.pi / 2, np.pi, 2 * np.pi / 3, 1e-5, np.pi]
    special = np.concatenate([Rotation.from_axes_angles(a, w).data for a, w in zip(axes, angles)]
                             + [[[-np.sqrt(0.5), 0, 0, np.sqrt(0.5)]]])
    q = rng.normal(size=(57, 4))
    q /= np.linalg.norm(q, axis=1, keepdims=True)
    eu = np.column_stack([rng.uniform(0, 2 * np.pi, 64), rng.uniform(0, np.pi, 64), rng.uniform(0, 2 * np.pi, 64)])
    half = np.pi ** (2 / 3) / 2
    cu = np.concatenate([[[0, 0, 0], [0, 0, 0.5], [0, 0, -0.5], [0.5, 0, 0], [-0.5, 0, 0], [0, 0.5, 0], [0, -0.5, 0]],
                         rng.uniform(-half, half, size=(57, 3)) * 0.999])
    v = rng.normal(size=(64, 3))
    c = np.random.default_rng(3).normal(size=(100, 4))
    c /= np.linalg.norm(c, axis=1, keepdims=True)
    ti = HERE.parent.parent.parent / "macTEMTests" / "Fixtures" / "sem" / "oxford" / "ti_orientations_head.ctf"
    ti_eu = np.loadtxt(ti, skiprows=1, usecols=(0, 1, 2))
    groups = list(symmetry._groups) + [symmetry.C2, symmetry.Cs, symmetry.D3]
    out = {
        "note": "Inputs of tools/parity/sem bundles m3/*: seeded (numpy default_rng 20261106 and 3) except ti_euler_degrees, "
                "the first 2000 rows of orix-data Ti_orientations.ctf (CC BY 4.0).",
        "quaternions": np.concatenate([special, q]).tolist(),
        "special_rows": ["identity", "90 deg about z", "180 deg about x", "120 deg about [111]", "1e-5 rad about y",
                         "180 deg about [110]", "270 deg about z written with a < 0"],
        "euler_radians": eu.tolist(),
        "cubochoric": cu.tolist(),
        "vectors": v.tolist(),
        "improper_every": 3,
        "point_groups": [g.name for g in groups],
        "ti_point_group": "622",
        "ti_euler_degrees": ti_eu.tolist(),
        "cubic_point_group": "m-3m",
        "cubic_quaternions": c.tolist(),
    }
    (FIXTURES / "orientation_inputs.json").write_text(json.dumps(out) + "\n", encoding="utf-8")


# The grain input (m5): rows 0-89, columns 0-119 of orix-data's Ti_orientations.ctf, so the Swift test of the grain
# port runs without the 29 MB download (the whole map is figure F11's bundle, which skips without it).
GRAIN_TI_CROP = (0, 0, 90, 120)  # row, column, height, width of the 381 x 507 map


def write_grain_inputs() -> None:
    import numpy as np

    path = HERE.parent.parent.parent / "References" / "sem-data" / "orix" / "Ti_orientations.ctf"
    ti = np.loadtxt(path, skiprows=1)
    assert ti.shape == (381 * 507, 13), ti.shape
    r0, c0, h, w = GRAIN_TI_CROP
    eu = ti[:, :3].reshape(381, 507, 3)[r0:r0 + h, c0:c0 + w].reshape(-1, 3)
    out = {
        "note": "Input of tools/parity/sem bundle m5/grains-ti: rows 0-89, columns 0-119 of orix-data Ti_orientations.ctf "
                "(CC BY 4.0), Bunge angles in degrees as written, rows first.",
        "ti": {"shape": [h, w], "crop_row_column": [r0, c0], "step_um": 0.25, "euler_degrees": eu.tolist()},
    }
    (FIXTURES / "grain_inputs.json").write_text(json.dumps(out) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data", type=Path, default=HERE.parent.parent.parent / "References" / "sem-data")
    ap.add_argument("--orientation-only", action="store_true", help="write orientation_inputs.json only")
    ap.add_argument("--grain-only", action="store_true", help="write grain_inputs.json only (needs fetch-data.sh)")
    args = ap.parse_args()
    if args.grain_only:
        FIXTURES.mkdir(exist_ok=True)
        write_grain_inputs()
        print("make_fixtures.py: grain_inputs.json written")
        return 0
    FIXTURES.mkdir(exist_ok=True)
    write_orientation_inputs()
    if args.orientation_only:
        print("make_fixtures.py: orientation_inputs.json written")
        return 0
    write_ctf()
    write_kikuchipy_dummies()
    write_emsoft_master_pattern(FIXTURES / "planted_emsoft_tkd_master_pattern.h5", "TKD")
    write_emsoft_master_pattern(FIXTURES / "planted_emsoft_ecp_master_pattern.h5", "ECP")
    derived = write_rsciio_derived(args.data.resolve())
    print("make_fixtures.py: planted_oxford.ctf, oxford_h5oina_patterns.h5oina, bruker_h5ebsd_patterns.h5, "
          "planted_emsoft_tkd_master_pattern.h5, planted_emsoft_ecp_master_pattern.h5, orientation_inputs.json"
          + "".join(", " + d for d in derived) + " written")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
