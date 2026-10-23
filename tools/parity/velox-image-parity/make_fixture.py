#!/usr/bin/env python3
"""Planted Velox-shaped EMD files, with their truth, for tools/parity/velox-image-parity (archive: roadmap-registrations-2026-10-15.md V1-3a).

    make_fixture.py <out-dir>               the gate's planted files (each <= 1 MiB) and planted.json
    make_fixture.py --unit <dir>            the unit tests' files macTEMTests/Fixtures/velox-*.emd (each <= 64 KiB)
                                            and velox.truth.json; writes twice and refuses a file that is not byte-for-byte
                                            reproducible (commit the files and the truth; review the diff)
    make_fixture.py --stack <file.emd>      the memory plant: 1024 x 1024 x 64 uint16, one frame per chunk (134 MB)

A Velox EMD is HDF5: a root `Version` JSON {"version", "format": "Velox"}, `Data/Image/<id>/Data` shaped (y, x, frame) and
`Data/Image/<id>/Metadata`, a (rows, columns) uint8 dataset whose column 0 is the entry's metadata as NUL-padded JSON. The
Detectors table, BinaryResult {Detector, DetectorIndex, PixelSize, PixelUnitX/Y, Offset} and Optics are what the reader
and RosettaSciIO use; numbers are written as decimal strings, as Velox does. A stack's other metadata columns carry a
pixel width of 1.0e-9 (no case's first column does), so a reader of any column but the first cannot pass.

The truth is by construction. Each case below names, by hand, the entry the object rule must open, the pixels of every
frame, each axis's scale (the decimal string as a float64), unit string and origin (-Offset/PixelSize, in exact
rational arithmetic), the voltage, the notes, and for a refusal its name. Nothing is derived from a reader.

  haadf-last       [SuperXG1 map, SuperXG2 map (float32, no DetectorIndex), DF4, HAADF]: the HAADF opens, last in key order
  no-haadf         [an EDX map WITH DetectorIndex (AnalyticalDetector), DF2, BF]: DF2 opens, the first candidate
  maps-only        [a map without DetectorIndex, a map whose index is AnalyticalDetector]: refused, noImage
  compound-only    a compound FFT image: refused, noImage
  aniso-m          5 x 3, pixel 2.5e-10 x 4e-10 m, Offset (-1.5e-9, 2e-9): origin (6, -5), 300 kV
  aniso-1perm      3 x 4, pixel 3.5e5 x 5e5 1/m, Offset (-8.75e5, 1.5e6): origin (2.5, -3)
  aniso-mixed      5 x 3, PixelUnitX "m", PixelUnitY "1/m": each axis keeps its own unit (the DEVIATION from RosettaSciIO)
  frames           3 frames, every pixel different in each frame, one frame per chunk
  int16-negative   2 frames of int16 holding -32768, -1, 32767: a read as unsigned changes them; a camera (ImagingDetector)
                   image, so its Scan.DwellTime is not an acquisition's dwell (the .emd metadata reads none)
  int32-rounded    int32 beyond 2^24: rounded to Float32 and the note says so
  berkeley         a Berkeley (NCEM) EMD: refused, notVelox
  not-hdf5         text in a file named .emd: refused, notVelox
  uncalibrated     no PixelSize, no Offset, no unit, no voltage: both axes and the voltage nil
  bad-size         PixelSize width 0: x uncalibrated, y calibrated
  too-large        17000 x 17000 uint8 (no chunk written): refused, unreadable, never allocated
  bad-metadata     a Metadata column that is not JSON: refused, unreadable (never a raw JSON error)
  type-<t>         one stored type each (uint8, int8, uint32, int64, uint64, float64) at the ends of its range: Float32 as
                   h5py reads it, and the rounding note for the types Float32 cannot hold
"""
import hashlib
import json
import os
import sys
from fractions import Fraction

import h5py
import numpy as np

ROWS = 4096
STR = h5py.string_dtype()
FFT = np.dtype([("realFloatHalfEven", "<f4"), ("imagFloatHalfEven", "<f4")])
DETECTORS = [(0, "HAADF", "ScanningDetector"), (1, "DF2", "ScanningDetector"), (2, "DF4", "ScanningDetector"),
             (3, "BF", "ScanningDetector"), (4, "SuperXG1", "AnalyticalDetector"), (5, "SuperXG2", "AnalyticalDetector"),
             (6, "BM-Ceta", "ImagingDetector")]
NUMPY = {"uint8": np.uint8, "int8": np.int8, "uint16": np.uint16, "int16": np.int16, "uint32": np.uint32, "int32": np.int32,
         "uint64": np.uint64, "int64": np.int64, "float32": np.float32, "float64": np.float64}
MIB = 1 << 20


def gid(prefix):
    return (prefix + "0123456789abcdef0123456789abcdef")[:32]


def column(m):
    b = json.dumps(m).encode()
    assert len(b) < ROWS, len(b)
    return np.frombuffer(b.ljust(ROWS, b"\0"), dtype=np.uint8)


def column_bytes(b):
    assert len(b) < ROWS
    return np.frombuffer(b.ljust(ROWS, b"\0"), dtype=np.uint8)


def metadata(e, width=None):
    """One column of an entry's Metadata (`width` overrides the pixel width: the trap columns)."""
    dets = {f"Detector-{i}": {"DetectorName": n, "DetectorType": t, "Enabled": "true"} for i, n, t in e.get("table", DETECTORS)}
    br = {"Detector": e["detector"]}
    if e.get("index") is not None:
        br["DetectorIndex"] = str(e["index"])
    if e.get("pixel") is not None:
        br["PixelSize"] = {"width": width or e["pixel"][0], "height": e["pixel"][1]}
    ux, uy = e.get("units", (None, None))
    if ux is not None:
        br["PixelUnitX"] = ux
    if uy is not None:
        br["PixelUnitY"] = uy
    if e.get("offset") is not None:
        br["Offset"] = {"x": e["offset"][0], "y": e["offset"][1]}
    optics = {} if e.get("voltage") is None else {"AccelerationVoltage": e["voltage"]}
    return {"Detectors": dets, "BinaryResult": br,
            "Scan": {"ScanSize": {"width": "4096", "height": "4096"}, "DwellTime": "1e-6", "FrameTime": "0.5"},
            "Optics": optics, "Instrument": {"InstrumentModel": "Talos F200X"},
            "Acquisition": {"AcquisitionStartDatetime": {"DateTime": e.get("start", "1776689766")}}}


def write_velox(path, entries):
    with h5py.File(path, "w") as f:
        f.create_dataset("Version", data=[json.dumps({"version": "11", "format": "Velox"})], dtype=STR, track_times=False)
        for e in entries:
            g = f.create_group(f"Data/Image/{e['gid']}")
            frames = e["frames"]
            if e.get("raw_metadata"):   # a Metadata column that is not the JSON it must be
                g.create_dataset("Data", data=np.zeros((2, 3, 1), dtype=np.uint16), chunks=(2, 3, 1), track_times=False)
                g.create_dataset("Metadata", data=np.stack([column_bytes(e["raw_metadata"])], axis=1), track_times=False)
                continue
            if e.get("shape"):          # only a shape: no chunk is written, so the file stays small
                g.create_dataset("Data", shape=e["shape"], dtype=NUMPY[e["dtype"]], chunks=(1000, 1000, 1), track_times=False)
                g.create_dataset("Metadata", data=np.stack([column(metadata(e))], axis=1), track_times=False)
                continue
            h, w = np.array(frames[0]).shape
            if e["dtype"] == "fft":
                data = np.zeros((h, w, 1), dtype=FFT)
            else:
                data = np.stack([np.array(fr, dtype=NUMPY[e["dtype"]]) for fr in frames], axis=2)
            g.create_dataset("Data", data=data, chunks=(h, w, 1), track_times=False)
            cols = [column(metadata(e))] + [column(metadata(e, width="1.0e-9")) for _ in frames[1:]]
            g.create_dataset("Metadata", data=np.stack(cols, axis=1), track_times=False)


def write_berkeley(path):
    """A Berkeley EMD 0.2 file: root version attributes, /data/<group> with emd_group_type 1, data and dims."""
    with h5py.File(path, "w") as f:
        f.attrs["version_major"] = 0
        f.attrs["version_minor"] = 2
        g = f.create_group("data/image")
        g.attrs["emd_group_type"] = 1
        g.create_dataset("data", data=np.arange(12, dtype=np.uint16).reshape(3, 4), track_times=False)
        for i, n in enumerate(("dim1", "dim2")):
            d = g.create_dataset(n, data=np.arange(3 if i == 0 else 4, dtype=np.float64), track_times=False)
            d.attrs["name"] = "y" if i == 0 else "x"
            d.attrs["units"] = "nm"


def write_text(path):
    with open(path, "wb") as fh:
        fh.write(b"this is not an HDF5 file, whatever its extension says\n")


def origin(offset, size):
    """-Offset / PixelSize in exact rational arithmetic, as a float64: the registered conversion."""
    return float(-Fraction(offset) / Fraction(size))


def axis(size, unit, offset):
    if size is None or not float(size) > 0 or float(size) == float("inf"):
        return None
    return {"scale": float(size), "units": unit or "", "origin": 0.0 if offset is None else origin(offset, size)}


def f32(x):
    return float(np.float32(x))


# ---------------------------------------------------------------------------------------------------- the cases
def case_haadf_last():
    pix = ("1e-9", "1e-9")
    h, w = 4, 6
    haadf = [[100 * r + c for c in range(w)] for r in range(h)]
    df4 = [[7000 + 10 * r + c for c in range(w)] for r in range(h)]
    maps = [[[0.5 * (r * w + c) - 3.25 for c in range(w)] for r in range(h)],
            [[1000.5 - 0.25 * (r * w + c) for c in range(w)] for r in range(h)]]
    entries = [
        dict(gid=gid("00a1"), detector="SuperXG1", index=None, dtype="float32", frames=[maps[0]], pixel=pix, units=("m", "m"), voltage="200000"),
        dict(gid=gid("11b2"), detector="SuperXG2", index=None, dtype="float32", frames=[maps[1]], pixel=pix, units=("m", "m"), voltage="200000"),
        dict(gid=gid("22c3"), detector="DF4", index=2, dtype="uint16", frames=[df4], pixel=pix, units=("m", "m"), voltage="200000"),
        dict(gid=gid("33d4"), detector="HAADF", index=0, dtype="uint16", frames=[haadf], pixel=pix, units=("m", "m"), voltage="200000"),
    ]
    flags = [False, False, True, True]
    return dict(entries=entries, candidates=flags, opens=3, rsciio=True)


def case_no_haadf():
    pix = ("1e-9", "1e-9")
    h, w = 3, 5
    entries = [
        dict(gid=gid("00a1"), detector="SuperXG1", index=4, dtype="float32", frames=[[[2.5 * (r * w + c) + 0.125 for c in range(w)] for r in range(h)]], pixel=pix, units=("m", "m"), voltage="200000"),
        dict(gid=gid("11b2"), detector="DF2", index=1, dtype="uint16", frames=[[[3000 + 10 * r + c for c in range(w)] for r in range(h)]], pixel=pix, units=("m", "m"), voltage="200000"),
        dict(gid=gid("22c3"), detector="BF", index=3, dtype="uint16", frames=[[[5000 + 10 * r + c for c in range(w)] for r in range(h)]], pixel=pix, units=("m", "m"), voltage="200000"),
    ]
    return dict(entries=entries, candidates=[False, True, True], opens=1, rsciio=True)


def case_maps_only():
    pix = ("1e-9", "1e-9")
    h, w = 3, 5
    entries = [
        dict(gid=gid("00a1"), detector="SuperXG1", index=None, dtype="float32", frames=[[[1.5 * (r * w + c) for c in range(w)] for r in range(h)]], pixel=pix, units=("m", "m"), voltage="200000"),
        dict(gid=gid("11b2"), detector="SuperXG2", index=5, dtype="float32", frames=[[[0.75 * (r * w + c) + 9 for c in range(w)] for r in range(h)]], pixel=pix, units=("m", "m"), voltage="200000"),
    ]
    return dict(entries=entries, candidates=[False, False], opens=None, error="noImage", rsciio=True)


def case_compound_only():
    entries = [dict(gid=gid("00a1"), detector="HAADF", index=0, dtype="fft", frames=[[[0.0] * 4] * 3],
                    pixel=("5e5", "5e5"), units=("1/m", "1/m"), offset=("-2.5e5", "-1.5e5"), voltage="200000")]
    return dict(entries=entries, candidates=[False], opens=None, error="noImage", rsciio=False)


def aniso(units, pixel, offset, name_hint):
    h, w = (3, 5) if units[0] == "m" else (4, 3)
    pixels = [[10 * r + c + 1 for c in range(w)] for r in range(h)]
    e = dict(gid=gid("00a1"), detector="HAADF", index=0, dtype="uint16", frames=[pixels], pixel=pixel, units=units,
             offset=offset, voltage="300000")
    return dict(entries=[e], candidates=[True], opens=0, rsciio=True)


def case_aniso_m():
    return aniso(("m", "m"), ("2.5e-10", "4e-10"), ("-1.5e-9", "2e-9"), "m")


def case_aniso_1perm():
    return aniso(("1/m", "1/m"), ("3.5e5", "5e5"), ("-8.75e5", "1.5e6"), "1/m")


def case_aniso_mixed():
    return aniso(("m", "1/m"), ("2e-10", "8e-10"), ("-1e-9", "1.6e-9"), "mixed")


def case_frames():
    h, w, n = 3, 4, 3
    frames = [[[1000 * f + 10 * r + c + 1 for c in range(w)] for r in range(h)] for f in range(n)]
    for a in range(n):
        for b in range(a + 1, n):
            assert all(frames[a][r][c] != frames[b][r][c] for r in range(h) for c in range(w))
    e = dict(gid=gid("00a1"), detector="HAADF", index=0, dtype="uint16", frames=frames, pixel=("1.25e-9", "1.25e-9"),
             units=("m", "m"), voltage="200000")
    return dict(entries=[e], candidates=[True], opens=0, rsciio=True)


def case_int16_negative():
    f0 = [[-1, -32768, 32767, 300, 0], [17, -300, 42, -7, 1000], [-12345, 256, -256, 5, -99]]
    f1 = [[2, 32767, -32768, -300, 123], [-18, 301, -43, 8, -1000], [12346, -257, 257, -6, 100]]
    assert all(a != b for r0, r1 in zip(f0, f1) for a, b in zip(r0, r1))
    e = dict(gid=gid("00a1"), detector="BM-Ceta", index=6, dtype="int16", frames=[f0, f1], pixel=("2.5e-9", "4e-9"),
             units=("m", "m"), offset=("7e-9", "-3e-9"), voltage="200000")
    return dict(entries=[e], candidates=[True], opens=0, rsciio=True)


def case_int32_rounded():
    px = [[16777217, -16777217, 2147483647], [-2147483648, 123456789, 7]]
    e = dict(gid=gid("00a1"), detector="DF2", index=1, dtype="int32", frames=[px], pixel=("1e-9", "1e-9"),
             units=("m", "m"), voltage="200000")
    return dict(entries=[e], candidates=[True], opens=0, rsciio=True)


def case_uncalibrated():
    e = dict(gid=gid("00a1"), detector="HAADF", index=0, dtype="uint16", frames=[[[1, 2], [3, 4], [5, 6]]], voltage=None)
    return dict(entries=[e], candidates=[True], opens=0, rsciio=False)


def case_bad_size():
    e = dict(gid=gid("00a1"), detector="HAADF", index=0, dtype="uint16", frames=[[[1, 2, 3], [4, 5, 6]]],
             pixel=("0", "4e-10"), units=("m", "m"), offset=("-2e-9", "-2e-9"), voltage="200000")
    return dict(entries=[e], candidates=[True], opens=0, rsciio=False)


def case_too_large():
    """17000 x 17000 uint8 = 289 M pixels, over the 2^28 the reader accepts: a candidate by the object rule, refused when read."""
    e = dict(gid=gid("00a1"), detector="HAADF", index=0, dtype="uint8", frames=[[[0]]], shape=(17000, 17000, 1),
             pixel=("1e-9", "1e-9"), units=("m", "m"), voltage="200000")
    return dict(entries=[e], candidates=[True], opens=None, error="unreadable", rsciio=False)


def case_bad_metadata():
    """A Metadata column that is not JSON: the file is damaged, refused as unreadable (a raw JSON error is not a refusal)."""
    e = dict(gid=gid("00a1"), detector="HAADF", index=0, dtype="uint16", frames=[[[0]]], raw_metadata=b"this is not JSON {")
    return dict(entries=[e], candidates=[False], opens=None, error="unreadable", rsciio=False)


# Each stored type the reader takes beyond uint16, int16 and float32, with values at the ends of its range and, in the wide
# ones, beyond what Float32 keeps (16777217 = 2^24 + 1, 2^64 - 1, 0.1): rounded to the nearest Float32, and the note says so.
TYPES = {
    "uint8": [[0, 255, 128], [1, 127, 254]],
    "int8": [[-128, 127, -1], [0, 1, -127]],
    "uint32": [[0, 4294967295, 2147483648], [16777216, 16777217, 4278190080]],
    "int64": [[-2 ** 63, 2 ** 63 - 1, -1], [2 ** 32, -16777217, 2 ** 53 + 1]],
    "uint64": [[0, 2 ** 64 - 1, 2 ** 63], [2 ** 32, 16777217, 2 ** 53 + 1]],
    "float64": [[0.5, -2.25, 1e10], [0.1, 3.4e38, 123456789.123]],
}


def case_type(dtype):
    def make():
        e = dict(gid=gid("00a1"), detector="DF2", index=1, dtype=dtype, frames=[TYPES[dtype]], pixel=("1e-9", "1e-9"),
                 units=("m", "m"), voltage="200000")
        return dict(entries=[e], candidates=[True], opens=0, rsciio=True)
    return make



def case_two_haadf():
    """Two exact HAADF entries: the first in key order opens. And name variants that are not exactly HAADF."""
    pix = ("1e-9", "1e-9")
    h, w = 3, 4
    mk = lambda base: [[base + 10 * r + c for c in range(w)] for r in range(h)]
    entries = [
        dict(gid=gid("00a1"), detector="BF", index=3, dtype="uint16", frames=[mk(100)], pixel=pix, units=("m", "m"), voltage="200000"),
        dict(gid=gid("11b2"), detector="haadf", index=0, dtype="uint16", frames=[mk(200)], pixel=pix, units=("m", "m"), voltage="200000"),
        dict(gid=gid("22c3"), detector="HAADF-2", index=0, dtype="uint16", frames=[mk(300)], pixel=pix, units=("m", "m"), voltage="200000"),
        dict(gid=gid("33d4"), detector="HAADF", index=0, dtype="uint16", frames=[mk(400)], pixel=pix, units=("m", "m"), voltage="200000"),
        dict(gid=gid("44e5"), detector="HAADF", index=0, dtype="uint16", frames=[mk(500)], pixel=pix, units=("m", "m"), voltage="200000"),
    ]
    return dict(entries=entries, candidates=[True] * 5, opens=3, rsciio=False)


GAP = [(1, "SuperXG1", "AnalyticalDetector"), (2, "HAADF", "ScanningDetector"), (5, "BM-Ceta", "ImagingDetector")]


def case_detector_gap():
    """A Detectors table without Detector-0 (indices 1, 2, 5): an index is a key, not a position in the table."""
    pix = ("1e-9", "1e-9")
    h, w = 3, 4
    mk = lambda base: [[base + 10 * r + c for c in range(w)] for r in range(h)]
    entries = [
        dict(gid=gid("00a1"), detector="SuperXG1", index=1, dtype="float32", frames=[[[0.5 * (r * w + c) for c in range(w)] for r in range(h)]], pixel=pix, units=("m", "m"), voltage="200000", table=GAP),
        dict(gid=gid("11b2"), detector="HAADF", index=2, dtype="uint16", frames=[mk(100)], pixel=pix, units=("m", "m"), voltage="200000", table=GAP),
        dict(gid=gid("22c3"), detector="BM-Ceta", index=5, dtype="int16", frames=[mk(900)], pixel=pix, units=("m", "m"), voltage="200000", table=GAP),
    ]
    return dict(entries=entries, candidates=[False, True, True], opens=1, rsciio=True)


def case_sizes_not_positive():
    """x: a negative width, y: an infinite height: both axes uncalibrated, whatever else the file says."""
    e = dict(gid=gid("00a1"), detector="HAADF", index=0, dtype="uint16", frames=[[[1, 2, 3], [4, 5, 6]]],
             pixel=("-2.5e-10", "inf"), units=("m", "m"), offset=("-2e-9", "-2e-9"), voltage="200000")
    return dict(entries=[e], candidates=[True], opens=0, rsciio=False)


def case_x_unit_only():
    """PixelUnitX only: the y axis has a size but no unit of its own (uncalibrated, never X's unit by default)."""
    e = dict(gid=gid("00a1"), detector="HAADF", index=0, dtype="uint16", frames=[[[1, 2, 3], [4, 5, 6]]],
             pixel=("2.5e-10", "4e-10"), units=("m", None), offset=("-1.5e-9", "2e-9"), voltage="200000")
    return dict(entries=[e], candidates=[True], opens=0, rsciio=False)


def case_unit_nm():
    """Sizes and offsets in nm: the origin is -Offset / PixelSize in the file's own unit, with no conversion."""
    h, w = 3, 5
    e = dict(gid=gid("00a1"), detector="HAADF", index=0, dtype="uint16", frames=[[[10 * r + c + 1 for c in range(w)] for r in range(h)]],
             pixel=("0.25", "0.4"), units=("nm", "nm"), offset=("-1.5", "2"), voltage="300000")
    return dict(entries=[e], candidates=[True], opens=0, rsciio=True)


def case_entries_differ():
    """An EDX-grid map and a DF4 image beside the HAADF, each with its own pixel size, unit, offset and voltage: the opened
    entry's calibration, never another's."""
    h, w = 3, 4
    mk = lambda base: [[base + 10 * r + c for c in range(w)] for r in range(h)]
    entries = [
        dict(gid=gid("00a1"), detector="DF4", index=2, dtype="uint16", frames=[mk(700)], pixel=("3e-9", "5e-9"), units=("m", "m"), offset=("-1e-8", "-2e-8"), voltage="200000"),
        dict(gid=gid("11b2"), detector="HAADF", index=0, dtype="uint16", frames=[mk(100)], pixel=("1.5e-10", "2e-10"), units=("m", "m"), offset=("-3e-10", "5e-10"), voltage="300000"),
    ]
    return dict(entries=entries, candidates=[True, True], opens=1, rsciio=True)


def case_index_absent():
    """The HAADF's DetectorIndex (99) is not in the Detectors table: it is not a candidate (the DF2 behind it opens)."""
    pix = ("1e-9", "1e-9")
    h, w = 3, 4
    mk = lambda base: [[base + 10 * r + c for c in range(w)] for r in range(h)]
    entries = [
        dict(gid=gid("00a1"), detector="HAADF", index=99, dtype="uint16", frames=[mk(100)], pixel=pix, units=("m", "m"), voltage="200000"),
        dict(gid=gid("11b2"), detector="DF2", index=1, dtype="uint16", frames=[mk(300)], pixel=pix, units=("m", "m"), voltage="200000"),
    ]
    return dict(entries=entries, candidates=[False, True], opens=1, rsciio=False)


def case_frac_date():
    """AcquisitionStartDatetime 1776689766.75: shown as the whole second 12:56:06 UTC (truncated, not rounded to :07)."""
    h, w = 3, 5
    e = dict(gid=gid("00a1"), detector="HAADF", index=0, dtype="uint16", frames=[[[10 * r + c + 1 for c in range(w)] for r in range(h)]],
             pixel=("2.5e-10", "4e-10"), units=("m", "m"), offset=("-1.5e-9", "2e-9"), voltage="300000", start="1776689766.75")
    return dict(entries=[e], candidates=[True], opens=0, rsciio=True)


def case_camera_index_mismatch():
    """Velox v4 `1854 Camera Ceta.emd` in miniature: BinaryResult.Detector names the Ceta camera (an ImagingDetector,
    Detector-6 here) but DetectorIndex 0 names the HAADF's table entry. The detector is the one the Detector name says: a
    camera image, whose Scan.DwellTime is not a dwell."""
    h, w = 3, 4
    e = dict(gid=gid("00a1"), detector="BM-Ceta", index=0, kind="ImagingDetector", dtype="int16",
             frames=[[[10 * r + c - 5 for c in range(w)] for r in range(h)]], pixel=("2e-9", "2e-9"), units=("m", "m"),
             voltage="200000")
    return dict(entries=[e], candidates=[True], opens=0, rsciio=False)

CASES = {
    "haadf-last": case_haadf_last, "no-haadf": case_no_haadf, "maps-only": case_maps_only,
    "compound-only": case_compound_only, "aniso-m": case_aniso_m, "aniso-1perm": case_aniso_1perm,
    "aniso-mixed": case_aniso_mixed, "frames": case_frames, "int16-negative": case_int16_negative,
    "int32-rounded": case_int32_rounded, "uncalibrated": case_uncalibrated, "bad-size": case_bad_size,
    "too-large": case_too_large, "two-haadf": case_two_haadf, "detector-gap": case_detector_gap,
    "sizes-not-positive": case_sizes_not_positive, "x-unit-only": case_x_unit_only, "unit-nm": case_unit_nm,
    "entries-differ": case_entries_differ,
    "index-absent": case_index_absent, "camera-index-mismatch": case_camera_index_mismatch, "frac-date": case_frac_date, "bad-metadata": case_bad_metadata, **{f"type-{t}": case_type(t) for t in TYPES},
}
UNIT = {"velox-haadf-last": "haadf-last", "velox-maps-only": "maps-only", "velox-aniso": "aniso-mixed",
        "velox-frames": "frames", "velox-int16-negative": "int16-negative", "velox-bad-metadata": "bad-metadata"}


def truth_of(name, file, spec):
    """The planted truth of one case, written by hand above (see the module docstring)."""
    ents = spec["entries"]
    t = {"name": name, "file": file,
         "entries": [{"id": e["gid"], "detector": e["detector"], "candidate": c, "dtype": e["dtype"],
                      "shape": e["shape"] if e.get("shape") else [len(e["frames"][0]), len(e["frames"][0][0]), len(e["frames"])]}
                     for e, c in zip(ents, spec["candidates"])],
         "rsciio": spec["rsciio"]}
    if spec.get("error"):
        t.update(kind="refusal", error=spec["error"])
        return t
    e = ents[spec["opens"]]
    n = len(e["frames"])
    px = e.get("pixel")
    ux, uy = e.get("units", (None, None))
    off = e.get("offset")
    notes = lambda k: ([f"frame {k + 1} of {n}"] if n > 1 else []) + (
        [f"stored as {e['dtype']}, rounded to Float32"] if e["dtype"] in ("int32", "uint32", "int64", "uint64", "float64") else [])
    frames = [[[f32(v) for v in row] for row in fr] for fr in e["frames"]]
    kind = e.get("kind") or dict((i, t_) for i, _, t_ in e.get("table", DETECTORS)).get(e.get("index"))
    t.update(kind="image", opens=e["gid"], source=f"Data/Image/{e['gid']} · {e['detector']}",
             metadata={"highTensionKV": None if e.get("voltage") is None else float(e["voltage"]) / 1e3,
                       "detector": e["detector"], "instrument": "Talos F200X",
                       "dwellUS": 1.0 if kind == "ScanningDetector" else None,    # Scan.DwellTime 1e-6 s, a scan's alone
                       "acquiredUTC": "2026-04-20 12:56:06"},                      # Unix 1776689766, by hand
             width=len(frames[0][0]), height=len(frames[0]), frames=frames,
             notes=[notes(k) for k in range(n)],
             x=axis(px and px[0], ux, off and off[0]), y=axis(px and px[1], uy, off and off[1]),
             voltage=None if e.get("voltage") is None else float(e["voltage"]))
    return t


def write_case(path, spec):
    write_velox(path, spec["entries"])


def sha256(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def write_stack(path):
    """1024 x 1024 x 64 uint16, one frame per chunk, HAADF: pixel(f, r, c) = (7919 f + 31 r + 17 c) mod 65536."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    h = w = 1024
    n = 64
    ent = dict(gid=gid("00a1"), detector="HAADF", index=0, dtype="uint16", pixel=("1e-9", "1e-9"), units=("m", "m"),
               voltage="200000", frames=[[[0]]] * n)
    with h5py.File(path, "w") as f:
        f.create_dataset("Version", data=[json.dumps({"version": "11", "format": "Velox"})], dtype=STR, track_times=False)
        g = f.create_group(f"Data/Image/{ent['gid']}")
        d = g.create_dataset("Data", shape=(h, w, n), dtype=np.uint16, chunks=(h, w, 1), track_times=False)
        r = np.arange(h, dtype=np.uint32)[:, None]
        c = np.arange(w, dtype=np.uint32)[None, :]
        for k in range(n):
            d[:, :, k] = ((7919 * k + 31 * r + 17 * c) & 0xFFFF).astype(np.uint16)
        g.create_dataset("Metadata", data=np.stack([column(metadata(ent))] + [column(metadata(ent, width="1.0e-9"))] * (n - 1), axis=1),
                         track_times=False)


def main(argv):
    if len(argv) == 3 and argv[1] == "--stack":
        write_stack(argv[2])
        print(f"make_fixture: wrote {argv[2]} ({os.path.getsize(argv[2])} bytes)")
        return
    unit = len(argv) == 3 and argv[1] == "--unit"
    if not (unit or len(argv) == 2):
        sys.exit(__doc__)
    out = argv[2] if unit else argv[1]
    os.makedirs(out, exist_ok=True)
    cases = []
    if unit:
        for name, key in UNIT.items():
            spec = CASES[key]()
            path = os.path.join(out, name + ".emd")
            write_case(path, spec)
            again = path + ".again"
            write_case(again, spec)
            same = sha256(path) == sha256(again)
            os.remove(again)
            if not same:
                sys.exit(f"{name}: two writes differ byte for byte; the fixture is not reproducible")
            cases.append(truth_of(name, name + ".emd", spec))
        berkeley = os.path.join(out, "velox-berkeley.emd")
        write_berkeley(berkeley)
        cases.append({"name": "velox-berkeley", "file": "velox-berkeley.emd", "kind": "refusal", "error": "notVelox",
                      "entries": [], "rsciio": False})
        limit, truth = 64 * 1024, "velox.truth.json"
    else:
        for key, make in CASES.items():
            spec = make()
            name = "planted-" + key
            write_case(os.path.join(out, name + ".emd"), spec)
            cases.append(truth_of(name, name + ".emd", spec))
        write_berkeley(os.path.join(out, "planted-berkeley.emd"))
        cases.append({"name": "planted-berkeley", "file": "planted-berkeley.emd", "kind": "refusal", "error": "notVelox",
                      "entries": [], "rsciio": False})
        write_text(os.path.join(out, "planted-not-hdf5.emd"))
        cases.append({"name": "planted-not-hdf5", "file": "planted-not-hdf5.emd", "kind": "refusal", "error": "notVelox",
                      "entries": [], "rsciio": False})
        limit, truth = MIB, "planted.json"
    for c in cases:
        p = os.path.join(out, c["file"])
        size = os.path.getsize(p)
        if size > limit:
            sys.exit(f"{c['file']} is {size} bytes, over the {limit} limit")
        c["sha256"] = sha256(p)
        c["bytes"] = size
    with open(os.path.join(out, truth), "w") as fh:   # one case per line: a reviewable diff
        fh.write('{"h5py": %s, "cases": [\n' % json.dumps(h5py.__version__))
        fh.write(",\n".join(json.dumps(c) for c in cases))
        fh.write("\n]}\n")
    print(f"make_fixture: wrote {len(cases)} files and {truth} into {out} (largest {max(c['bytes'] for c in cases)} bytes)")


if __name__ == "__main__":
    main(sys.argv)
