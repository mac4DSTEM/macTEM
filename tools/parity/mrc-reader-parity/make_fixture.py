#!/usr/bin/env python3
"""Planted MRC files and their truth for tools/parity/mrc-reader-parity.

    make_fixture.py <out-dir>

The files are written by this script's own MRC2014 writer (struct.pack of the 1024-byte header), NOT by mrcfile, so
the layout the reference reads was not produced by the reference. Each case plants ONE thing (a mode, a byte order, an
extended header, an anisotropic cell, a defect); planted.json holds the truth reference.py must reproduce before any
reading counts: pixels (sha256 of the little-endian float32 bytes, row 0 = the file's first row), width, height, the
x / y axes ({"scale": float(float32(cella)/float32(m)), "origin": 0.0, "units": "Å"} or null), the notes, the
refusal's name (error).

MRC2014 header words used (little-endian unless the machine stamp says big): 0 nx ny nz, 12 mode, 28 mx my mz,
40 cella (3 float32), 64 mapc mapr maps, 88 ispg, 92 nsymbt (extended header bytes), 208 "MAP ", 212 machine stamp.
Mode data: 0 int8, 1 int16, 2 float32, 6 uint16, 12 float16 (3 complex int16, 4 complex64, 101 packed 4-bit: refused).
"""
import hashlib
import json
import os
import struct
import sys

import numpy as np

UNCAL = "uncalibrated: the cell length is not positive"
FEI = "uncalibrated: an FEI extended header holds the pixel size, not read"
LE = b"\x44\x44\x00\x00"
LE_ALT = b"\x44\x41\x00\x00"
BE = b"\x11\x11\x00\x00"


def header(nx, ny, nz, mode, *, mx=None, my=None, mz=1, cella=None, ispg=0, nsymbt=0, stamp=LE, mapid=b"MAP ",
           axes=(1, 2, 3), end="<"):
    mx = nx if mx is None else mx
    my = ny if my is None else my
    cella = (float(mx), float(my), float(mz)) if cella is None else cella
    h = bytearray(1024)
    struct.pack_into(end + "4i", h, 0, nx, ny, nz, mode)
    struct.pack_into(end + "3i", h, 28, mx, my, mz)
    struct.pack_into(end + "3f", h, 40, *cella)
    struct.pack_into(end + "3f", h, 52, 90.0, 90.0, 90.0)
    struct.pack_into(end + "3i", h, 64, *axes)
    struct.pack_into(end + "2i", h, 88, ispg, nsymbt)
    h[208:212] = mapid
    h[212:216] = stamp
    return bytes(h)


def f32_axis(cell, m):
    """The registered scale: Double(Float(cell) / Float(m)) -- the float32 quotient converted to Double."""
    with np.errstate(all="ignore"):
        return float(np.float32(cell) / np.float32(m))


def axis(cell, m):
    s = f32_axis(cell, m)
    return {"scale": s, "origin": 0.0, "units": "Å"} if np.isfinite(s) and s > 0 else None


def sha_f32(a):
    return hashlib.sha256(np.ascontiguousarray(a.astype("<f4")).tobytes()).hexdigest()


def ramp(h, w, dtype, lo, hi):
    """h x w values spanning [lo, hi], every one distinct from its neighbours, row-major."""
    v = np.linspace(lo, hi, h * w)
    return np.round(v).astype(dtype).reshape(h, w) if np.dtype(dtype).kind in "iu" else v.astype(dtype).reshape(h, w)


def main(out):
    os.makedirs(out, exist_ok=True)
    cases = []

    def write(name, blob):
        with open(os.path.join(out, name + ".mrc"), "wb") as fh:
            fh.write(blob)
        return name + ".mrc"

    def image(name, arr, mode, *, end="<", stamp=LE, ext=0, ispg=0, cella=None, mx=None, my=None, note=None):
        """arr is the (ny, nx) array in its mode's dtype; the file stores it in `end` byte order."""
        ny, nx = arr.shape
        dt = arr.dtype.newbyteorder(end)
        blob = header(nx, ny, 1, mode, mx=mx, my=my, cella=cella, ispg=ispg, nsymbt=ext, stamp=stamp, end=end)
        blob += bytes((7 * i + 3) % 251 + 1 for i in range(ext)) + arr.astype(dt).tobytes()
        mxv, myv = (nx if mx is None else mx), (ny if my is None else my)
        cx, cy = (float(mxv), float(myv)) if cella is None else (cella[0], cella[1])
        x, y = axis(cx, mxv), axis(cy, myv)
        notes = [UNCAL] if (x is None or y is None) else []
        if ext == 128 * 1024:
            notes = [FEI]
        if notes:
            x = y = None
        cases.append({"name": name, "file": write(name, blob), "kind": "image", "mode": mode, "width": nx,
                      "height": ny, "pixels_sha256": sha_f32(arr), "x": x, "y": y, "notes": notes,
                      "ispg": ispg, "ext": ext, "comment": note or ""})

    def refusal(name, blob, error, note=""):
        cases.append({"name": name, "file": write(name, blob), "kind": "refusal", "error": error, "comment": note})

    # ---- modes, each with values that only the right dtype and byte order decode to ----
    image("mode0-int8", np.arange(256, dtype=np.uint8).view(np.int8).reshape(16, 16), 0,
          note="all 256 int8 values, -128..127 (RosettaSciIO would read them as uint8)")
    i16 = ramp(8, 12, np.int16, -32768, 32767)
    image("mode1-int16", i16, 1, note="negatives down to -32768")
    f32 = (np.arange(60, dtype=np.float32).reshape(6, 10) - 29.5) * np.float32(0.173)
    f32[0, 0], f32[0, 1], f32[0, 2] = np.float32(-3.4e38), np.float32(1.17549435e-38), np.float32(3.4e38)
    image("mode2-float32", f32, 2, note="negatives, fractions, float32 extremes")
    u16 = ramp(8, 12, np.uint16, 0, 65535)
    image("mode6-uint16", u16, 6, note="values above 32767")
    f16 = (np.arange(60, dtype=np.float32).reshape(6, 10) - 29.5) * np.float32(0.37)
    f16 = f16.astype(np.float16)
    f16[0, 0], f16[0, 1], f16[0, 2], f16[0, 3] = np.float16(65504), np.float16(-65504), np.float16(6.1e-5), np.float16(6e-8)
    image("mode12-float16", f16, 12, note="float16 extremes: +-65504, smallest normal, a subnormal")
    image("mode1-bigendian", i16, 1, end=">", stamp=BE, note="big-endian header and data, stamp 11 11")
    image("mode2-stamp4441", f32, 2, stamp=LE_ALT, note="machine stamp 44 41 (little-endian)")
    image("mode1-ext1024", i16, 1, ext=1024, note="1024 non-zero extended-header bytes before the data")
    image("fei-ext-131072", i16, 1, ext=128 * 1024, cella=(16 * 1.5, 16 * 1.5, 1.0),
          note="an FEI-sized extended header (128 × 1024 bytes): uncalibrated, its pixel size is not read")
    image("mode6-ispg1", u16, 6, ispg=1,
          note="nz=1 with ispg 1 (a volume of one section): mrcfile shapes it (1, ny, nx)")

    # ---- calibration ----
    aniso = (np.arange(24 * 40, dtype=np.float32).reshape(24, 40) * np.float32(0.25)) - 100
    image("aniso-40x24", aniso, 2, cella=(40 * 1.37, 24 * 2.11, 1.0),
          note="40 x 24, cella.x/mx 1.37 != cella.y/my 2.11 (float32 rounding of the quotient)")
    image("aniso-mx-ne-nx", aniso[:12, :20].copy(), 2, mx=5, my=3, cella=(10.0, 9.0, 1.0),
          note="mx 5 and my 3 are not nx and ny: the scale divides by mx / my, not by the pixel count")
    image("cella-negative", aniso[:6, :8].copy(), 2, cella=(-80.0, -40.0, 0.0),
          note="negative cella (as the DE files): both axes null, one note")
    image("cella-negative-y", aniso[:6, :8].copy(), 2, cella=(8.0, -6.0, 1.0),
          note="only y negative: both axes null")
    image("cella-zero", aniso[:6, :8].copy(), 2, cella=(0.0, 6.0, 1.0), note="cella.x = 0: scale 0 is not positive")
    image("cella-nan", aniso[:6, :8].copy(), 2, cella=(float("nan"), 6.0, 1.0), note="cella.x = NaN: not finite")
    image("mx-zero", aniso[:6, :8].copy(), 2, mx=0, cella=(8.0, 6.0, 1.0),
          note="mx = 0: cella.x/mx = inf, not finite")

    # ---- refusals: exactly one defect each ----
    px = np.arange(48, dtype="<f4")
    d = px.tobytes()
    refusal("stack-nz3", header(4, 4, 3, 2) + d, "stack", "nz = 3, ispg 0")
    refusal("nz-zero", header(4, 4, 0, 2) + d[:64], "notMRC", "nz = 0")
    refusal("nz-negative", header(4, 4, -1, 2) + d[:64], "notMRC", "nz = -1")
    refusal("mode3-and-stack", header(4, 4, 3, 3) + bytes(192), "mode", "mode 3 AND nz = 3: the mode is named first")
    refusal("stack-nz3-volume", header(4, 4, 3, 2, mz=3, ispg=1) + d, "stack", "nz = 3, ispg 1 (a volume)")
    refusal("mode3-complex-int16", header(4, 4, 1, 3) + bytes(64), "mode", "mode 3; mrcfile does not recognise it")
    refusal("mode4-complex64", header(4, 4, 1, 4) + bytes(128), "mode", "mode 4; mrcfile reads complex64")
    refusal("mode101-packed4", header(4, 4, 1, 101) + bytes(8), "mode", "mode 101 (packed 4-bit)")
    refusal("mode5-unknown", header(4, 4, 1, 5) + bytes(16), "mode", "an unassigned mode")
    refusal("stamp-0000", header(4, 4, 1, 2, stamp=b"\0\0\0\0") + d[:64], "byteOrder", "machine stamp 00 00 00 00")
    refusal("no-map-id", header(4, 4, 1, 2, mapid=b"XXXX") + d[:64], "notMRC", 'no "MAP " id')
    refusal("short-file", header(4, 4, 1, 2)[:700], "notMRC", "700 bytes, less than the 1024-byte header")
    refusal("nx-zero", header(0, 4, 1, 2), "notMRC", "nx = 0")
    refusal("ny-negative", header(4, -4, 1, 2) + d[:64], "notMRC", "ny = -4")
    refusal("axes-213", header(4, 4, 1, 2, axes=(2, 1, 3)) + d[:64], "axisOrder", "mapc/mapr/maps = 2 1 3")
    refusal("axes-132", header(4, 4, 1, 2, axes=(1, 3, 2)) + d[:64], "axisOrder", "mapc/mapr/maps = 1 3 2")
    refusal("axes-000", header(4, 4, 1, 2, axes=(0, 0, 0)) + d[:64], "axisOrder", "mapc/mapr/maps = 0 0 0")
    refusal("truncated-data", header(4, 4, 1, 2) + d[:40], "truncated", "40 of 64 data bytes")
    refusal("nsymbt-past-eof", header(4, 4, 1, 2, nsymbt=4096) + d[:64], "truncated", "NSYMBT 4096, 64 bytes follow")
    refusal("nsymbt-negative", header(4, 4, 1, 2, nsymbt=-1024) + d[:64], "truncated", "NSYMBT = -1024")

    with open(os.path.join(out, "planted.json"), "w") as fh:
        json.dump({"cases": cases}, fh, indent=1, ensure_ascii=False)
    print(f"make_fixture.py: {len(cases)} planted cases in {out}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
