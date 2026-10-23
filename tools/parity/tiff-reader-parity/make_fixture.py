#!/usr/bin/env python3
"""Planted TIFFs for tools/parity/tiff-reader-parity, written with tifffile (pinned: tools/lib/references-lock.txt).

    make_fixture.py <out-dir>

Writes one .tif per case plus <out-dir>/planted.json: the truth that was PLANTED (not what any reader says), one entry
per case:  name, file, kind ("image" | "refusal"), width, height, dtype, x / y (scale, origin, units or null),
notes, error, and for an image the pixel values' file-free description (reference.py re-reads the pixels from the
.tif and compares them with `pixels_sha256`, the sha256 of the planted array in row-major little-endian bytes, taking
channel 0 of an R=G=B RGB).

Conventions planted (what each reader convention reads — see README.md):
  ImageJ   ImageDescription "ImageJ=…\\nunit=micron", X/YResolution (RATIONAL, pixels per unit; scale = den/num).
  DM       tags 65003/65004 units (latin-1), 65006/65007 offset (in axis units), 65009/65010 scale; x = width.
  Velox    tag 34683 XML (BinaryResult/PixelSize/X,Y with a unit attribute) + 65450/65451 (RATIONAL pixels per cm,
           integer) + 65452 = 3, on an 8-bit RGB render.
Also planted (V1-3b Gate B): ImageJ single-IFD stacks (images/slices/frames/channels > 1, next-IFD offset 0), anisotropic
FEI SEM INI text (tag 34682; truth = the registration's convention PixelWidth -> x, which RosettaSciIO swaps), the Velox
agreement band (float32 half-ulp, see README.md), key/value trimming, fabricated-calibration traps, a corrupt header.
A case may carry "reference" ("rsciio" | "registration"; default by name) and "rsciio" = the axes RosettaSciIO is
EXPECTED to read when they differ from the truth (the FEI swap; DM scale 0), which reference.py asserts.
Every array holds values that only the right sign and width decode to (a value above the signed maximum in each
unsigned type, a negative in each signed type, a non-integer in float32), and is NON-SQUARE (40 x 24) with x != y.
"""
import hashlib
import json
import os
import struct
import sys
from fractions import Fraction

import numpy as np
import tifffile

W, H = 40, 24


def grid(dtype, w=W, h=H):
    """Unique-ish, asymmetric values (the transpose and a swapped byte order both change them)."""
    i = np.arange(h * w, dtype=np.int64).reshape(h, w)
    dt = np.dtype(dtype)
    if dt == np.uint8:
        return ((i * 7 + 130) % 256).astype(np.uint8)                    # > 127
    if dt == np.uint16:
        return ((i * 69 + 33000) % 65536).astype(np.uint16)              # > 32767, > 255
    if dt == np.int16:
        return ((i * 69) % 65536 - 32768).astype(np.int16)               # negatives, beyond int8
    if dt == np.int32:
        return (i * 100003 - 50_000_000).astype(np.int32)                # negatives, beyond int16
    if dt == np.float32:
        return ((i - 400) * 0.37 + 1e-3 * (i % 7)).astype(np.float32)    # negative non-integers
    raise ValueError(dtype)


def sha(a):
    return hashlib.sha256(np.ascontiguousarray(a.astype(a.dtype.newbyteorder("<"))).tobytes()).hexdigest()


def velox_xml(px, py, unit="m"):
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<Metadata xmlns:nil="http://schemas.fei.com/Metadata/v1/2013/07" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n'
        "    <BinaryResult>\n"
        "        <Detector>BM-Ceta</Detector>\n"
        "        <ImageSize>\n            <X>4096</X>\n            <Y>4096</Y>\n        </ImageSize>\n"
        "        <PixelSize>\n"
        f'            <X unit="{unit}">{px!r}</X>\n            <Y unit="{unit}">{py!r}</Y>\n'
        "        </PixelSize>\n"
        "        <Offset>\n            <X>-4.56</X>\n            <Y>0</Y>\n        </Offset>\n"
        "    </BinaryResult>\n</Metadata>\n"
    )


def f32_half_ulp(v):
    """Half the float32 spacing at v: Velox stores the per-cm count after a float32 rounding (as a RATIONAL n/1)."""
    return float(np.spacing(np.float32(v))) / 2


def velox_agree(per_cm, scale):
    """One axis of the Velox cross-check: the tag agrees with 0.01/scale within 0.5 + float32_half_ulp(tag)."""
    return abs(per_cm - 0.01 / scale) <= 0.5 + f32_half_ulp(per_cm)


def patch_first_ifd(path, fn):
    """Rewrite entries of the first IFD of a little-endian classic TIFF: fn(tag, typ, count, value4) -> (tag, typ,
    count, value4) | None (None leaves the entry alone)."""
    b = bytearray(open(path, "rb").read())
    assert bytes(b[:4]) == b"II*\0", "patch_first_ifd needs a little-endian classic TIFF"
    off = struct.unpack("<I", b[4:8])[0]
    n = struct.unpack("<H", b[off:off + 2])[0]
    for i in range(n):
        e = off + 2 + 12 * i
        tag, typ, cnt = struct.unpack("<HHI", b[e:e + 8])
        new = fn(tag, typ, cnt, bytes(b[e + 8:e + 12]))
        if new is not None:
            b[e:e + 12] = struct.pack("<HHI", *new[:3]) + new[3]
    open(path, "wb").write(bytes(b))
    return off + 2 + 12 * n          # where the next-IFD offset sits


def zero_next_ifd(path):
    """Make a multi-IFD file single-IFD by zeroing the first IFD's next-IFD offset (the data stays in the file)."""
    at = patch_first_ifd(path, lambda *a: None)
    b = bytearray(open(path, "rb").read())
    b[at:at + 4] = b"\0\0\0\0"
    open(path, "wb").write(bytes(b))


def ax(scale, origin, units):
    return {"scale": scale, "origin": origin, "units": units}


def main(out):
    os.makedirs(out, exist_ok=True)
    cases = []

    def add(name, kind, data, x=None, y=None, notes=(), error=None, w=W, h=H, planted=None):
        a = data if planted is None else planted
        cases.append({"name": name, "file": name + ".tif", "kind": kind, "width": w, "height": h,
                      "dtype": str(a.dtype), "x": x, "y": y, "notes": list(notes), "error": error,
                      "pixels_sha256": sha(a) if kind == "image" else None})

    def path(name):
        return os.path.join(out, name + ".tif")

    # --- ImageJ: anisotropic µm (scale = den/num, exactly representable inputs), three pixel types ---------------
    xres, yres = (1000000, 12345), (1000000, 20617)                       # scale 0.012345 / 0.020617 µm
    for dt in ("uint8", "uint16", "float32"):
        a = grid(dt)
        n = f"imagej-{dt}-aniso-um"
        tifffile.imwrite(path(n), a, imagej=True, resolution=(xres, yres), metadata={"unit": "micron"})
        add(n, "image", a, ax(xres[1] / xres[0], 0.0, "µm"), ax(yres[1] / yres[0], 0.0, "µm"))
    a = grid("uint16")
    tifffile.imwrite(path("imagej-uint16-nocal"), a, imagej=True)
    add("imagej-uint16-nocal", "image", a)

    # --- plain TIFF (no calibration convention): the signed types and a big-endian file -----------------------
    for dt in ("int16", "int32"):
        a = grid(dt)
        tifffile.imwrite(path(f"plain-{dt}"), a)
        add(f"plain-{dt}", "image", a)
    a = grid("uint16")
    tifffile.imwrite(path("plain-uint16-bigendian"), a, byteorder=">")
    add("plain-uint16-bigendian", "image", a)

    # --- Digital Micrograph tags (the layout RosettaSciIO's writer and DM's files use) ---------------------------
    for dt, unit, label in (("int32", "nm", "nm"), ("float32", "µm", "um")):
        a = grid(dt)
        sx, sy, ox, oy = 0.0123456789, 0.0234567891, 2.5, -1.25          # offsets in axis units
        tags = [(65003, "s", 0, unit.encode("latin-1") + b"\0", True), (65004, "s", 0, unit.encode("latin-1") + b"\0", True),
                (65006, "d", 1, ox, True), (65007, "d", 1, oy, True),
                (65009, "d", 1, sx, True), (65010, "d", 1, sy, True)]
        n = f"dm-{dt}-aniso-{label}"
        tifffile.imwrite(path(n), a, extratags=tags)
        add(n, "image", a, ax(sx, -ox / sx, unit), ax(sy, -oy / sy, unit))

    # --- Velox / Ceta (tag 34683): RGB render R=G=B ------------------------------------------------------------
    # The plant computes the expected outcome from its own implementation of the rule (velox_agree), then `expect`
    # pins the INTENT of the case, so a case that does not exercise what its name says fails here.
    RN = "8-bit render, not counts"
    UV = "scale unvalidated (one acquisition)"
    DIS = "uncalibrated: the Velox XML and the resolution tags disagree"

    def velox(name, px, py, per_cm_x, per_cm_y, rgb_equal=True, unit="m", grey=None, expect=None, tag_units=None):
        if grey is not None:
            data = grey
            photometric = "minisblack"
        else:
            g = grid("uint8")
            data = np.stack([g, g, g], axis=-1)
            if not rgb_equal:
                data = data.copy()
                data[5, 7, 1] = (int(data[5, 7, 1]) + 1) % 256            # one unequal pixel
            photometric = "rgb"
        tags = [(34683, "s", 0, velox_xml(px, py, unit) + "\0", True)]
        if per_cm_x is not None:
            tags.append((65450, 5, 1, (per_cm_x, 1), True))
        if per_cm_y is not None:
            tags.append((65451, 5, 1, (per_cm_y, 1), True))
        if per_cm_x is not None or per_cm_y is not None:
            tags.append((65452, "H", 1, 3, True))
        tifffile.imwrite(path(name), data, photometric=photometric, extratags=tags)
        if not rgb_equal:
            add(name, "refusal", data, error="unequalChannels")
            return
        checked = unit == "m" and (per_cm_x is not None or per_cm_y is not None)
        agree = True
        if checked:
            for per, s_ in ((per_cm_x, px), (per_cm_y, py)):
                if per is not None:
                    agree = agree and velox_agree(per, s_)
        if expect is not None:
            assert agree == (expect == "agree"), f"{name}: the plant computes {agree}, the case means {expect}"
        lead = [RN] if grey is None else []
        planted = data[..., 0] if grey is None else data
        if agree:
            add(name, "image", data, ax(px, 0.0, unit), ax(py, 0.0, unit), lead + [UV], planted=planted)
        else:
            add(name, "image", data, None, None, lead + [DIS], planted=planted)

    px, py = 1.6448334831730098e-09, 2.7e-09
    per = lambda s: round(0.01 / s)
    velox("velox-rgb-agree", px, py, per(px), per(py), expect="agree")
    # the count is non-integer; the tag is its rounding (error <= 0.5 pixel count), inside the agreement band
    pr = 2.1016264901077918e-09
    assert abs(0.01 / pr - round(0.01 / pr)) > 0.05
    velox("velox-rgb-agree-rounding", pr, pr, per(pr), per(pr), expect="agree")
    # 65450 off by 10 %: both axes null, the disagreement named (the cross-check is per axis, either one fails both)
    velox("velox-rgb-disagree", px, py, round(per(px) * 1.1), per(py), expect="disagree")
    # ... and only 65451 off (65450 right): the y check alone must fail both axes
    velox("velox-rgb-disagree-y-only", px, py, per(px), round(per(py) * 1.1), expect="disagree")
    # the band's edge, per axis: a tag P agrees iff |P - 0.01/scale| <= 0.5 + float32_half_ulp(P). The scale is
    # set from the target count 0.01/scale = P + d, so |P - 0.01/scale| = |d| exactly (to ~1e-9 counts).
    Px, Py = per(px), per(py)
    bx, by = 0.5 + f32_half_ulp(Px), 0.5 + f32_half_ulp(Py)
    assert 0.5 < bx < 1 and 0.5 < by < 1
    hair = 1e-3
    # at the bound (a hair inside): x on the high side, y on the low side; calibrated
    velox("velox-rgb-at-bound", 0.01 / (Px + bx - hair), 0.01 / (Py - (by - hair)), Px, Py, expect="agree")
    # one whole count past the bound (x): disagrees
    velox("velox-rgb-past-bound-plus-one", 0.01 / (Px + bx + 1), py, Px, Py, expect="disagree")
    # a hair past the bound (y, low side): disagrees
    velox("velox-rgb-past-bound-hair", px, 0.01 / (Py - (by + hair)), Px, Py, expect="disagree")
    # the owner's 630 kx file: tag 224125360 against 0.01/scale = 224125354.07 (float32 step 16 there) -> agrees
    s630 = 0.01 / 224125354.07
    P630 = int(np.float32(224125354.07))
    assert P630 == 224125360 and abs(P630 - 0.01 / s630) > 0.5
    velox("velox-rgb-float32-rounded", s630, s630, P630, P630, expect="agree")
    # one tag only: 65450 alone (agreeing) -> calibrated; 65451 alone (off) -> uncalibrated; neither -> no check
    velox("velox-rgb-only-x-tag", px, py, Px, None, expect="agree")
    velox("velox-rgb-only-y-tag-disagree", px, py, None, round(Py * 1.1), expect="disagree")
    velox("velox-rgb-no-tags", px, py, None, None, expect="agree")
    velox("velox-grey-uint16", 3.1e-10, 3.1e-10, None, None, grey=grid("uint16"), expect="agree")
    velox("velox-rgb-unequal", px, py, per(px), per(py), rgb_equal=False)

    # Velox XML without PixelSize, but ImageJ calibration in the same file: the ImageJ reading stands, no Velox notes
    a = grid("uint16")
    tifffile.imwrite(path("imagej-velox-nopixelsize"), a, description="ImageJ=1.11a\nunit=micron\n", metadata=None,
                     resolution=(xres, yres),
                     extratags=[(34683, "s", 0, '<?xml version="1.0"?><Metadata><BinaryResult><Detector>BM-Ceta</Detector>'
                                                '</BinaryResult></Metadata>\0', True)])
    add("imagej-velox-nopixelsize", "image", a, ax(xres[1] / xres[0], 0.0, "µm"), ax(yres[1] / yres[0], 0.0, "µm"))

    # --- ImageJ: trimming ("unit = micron" with spaces) and the fabricated-calibration trap ------------------------
    a = grid("uint16")
    tifffile.imwrite(path("imagej-unit-spaces"), a, description="ImageJ=1.11a\nunit = micron\n", metadata=None,
                     resolution=(xres, yres))
    add("imagej-unit-spaces", "image", a, ax(xres[1] / xres[0], 0.0, "µm"), ax(yres[1] / yres[0], 0.0, "µm"))
    # unit=micron but no XResolution/YResolution: the scale is not in the file; RosettaSciIO opens it uncalibrated
    tifffile.imwrite(path("imagej-unit-no-resolution"), a, imagej=True, metadata={"unit": "micron"})
    patch_first_ifd(path("imagej-unit-no-resolution"),
                    lambda tag, typ, cnt, v: (tag + 50000, typ, cnt, v) if tag in (282, 283) else None)
    add("imagej-unit-no-resolution", "image", a)

    # --- ImageJ stacks in ONE IFD (next-IFD offset 0): images/slices/frames/channels > 1 -> refused -------------
    st = (np.arange(3 * 8 * 10) % 200).astype(np.uint8).reshape(3, 8, 10)
    for n, arr, axes in (("ijstack-1ifd-images3", st, "ZYX"), ("ijstack-1ifd-slices2", st[:2], "ZYX"),
                         ("ijstack-1ifd-frames2", st[:2], "TYX"),
                         ("ijstack-1ifd-frames2-channels2", np.stack([st[:2], st[:2]], 1), "TCYX")):
        tifffile.imwrite(path(n), arr, imagej=True, metadata={"axes": axes})
        zero_next_ifd(path(n))
        add(n, "refusal", st, error="multiPage", w=10, h=8)
    tifffile.imwrite(path("ijstack-1ifd-images3-channels"), st, imagej=True)       # tifffile's default axis: channels=3
    zero_next_ifd(path("ijstack-1ifd-images3-channels"))
    add("ijstack-1ifd-images3-channels", "refusal", st, error="multiPage", w=10, h=8)

    # --- Digital Micrograph scale 0: the file's own scale is unusable -> that axis uncalibrated -------------------
    a = grid("float32")
    tags = [(65003, "s", 0, b"nm\0", True), (65004, "s", 0, b"nm\0", True), (65009, "d", 1, 0.0, True),
            (65010, "d", 1, 0.5, True)]
    tifffile.imwrite(path("dm-scale-zero-x"), a, extratags=tags)
    add("dm-scale-zero-x", "image", a, None, ax(0.5, 0.0, "nm"))
    cases[-1]["reference"] = "registration"
    cases[-1]["rsciio"] = {"x": ax(0.0, 0.0, "nm"), "y": ax(0.5, 0.0, "nm")}   # RosettaSciIO keeps a scale of 0

    # --- FEI SEM, anisotropic (tag 34682 INI text). RosettaSciIO 049e7d70 puts PixelWidth (and HFW/ResolutionX) on
    # the HEIGHT axis; macTEM's documented DEVIATION puts them on x (width). Truth = the registration; "rsciio" =
    # the expected (swapped) RosettaSciIO reading, asserted by reference.py.
    def fei(name, ini, sx, sy):
        a = grid("uint16")
        tifffile.imwrite(path(name), a, extratags=[(34682, "s", 0, ini + "\0", True)])
        add(name, "image", a, ax(sx, 0.0, "m"), ax(sy, 0.0, "m"))
        cases[-1]["reference"] = "registration"
        cases[-1]["rsciio"] = {"x": ax(sy, 0.0, "m"), "y": ax(sx, 0.0, "m")}
        assert sx != sy
    fei("fei-scan-aniso", "[Scan]\nPixelWidth=2.5e-09\nPixelHeight=4e-09\n", 2.5e-09, 4e-09)
    fei("fei-irbeam-aniso", "[IRBeam]\nHFW=0.0001\nVFW=7.2e-05\n[Image]\nResolutionX=40\nResolutionY=24\n",
        0.0001 / 40, 7.2e-05 / 24)
    fei("fei-scan-spaces-aniso", "[Scan]\nPixelWidth = 1e-9\nPixelHeight = 3e-9\n", 1e-9, 3e-9)

    # --- a corrupt header: ImageWidth = ImageLength = 0xFFFFFFFF on a 16-bit grey file ---------------------------
    a = grid("uint16")
    tifffile.imwrite(path("refuse-huge-dimensions"), a)
    patch_first_ifd(path("refuse-huge-dimensions"),
                    lambda tag, typ, cnt, v: (tag, 4, 1, b"\xff\xff\xff\xff") if tag in (256, 257) else None)
    add("refuse-huge-dimensions", "refusal", a, error="truncated")

    # --- plain RGB: equal channels open as one grey channel, labelled; one unequal pixel refuses ------------------
    g = grid("uint8")
    rgb = np.stack([g, g, g], axis=-1)
    tifffile.imwrite(path("rgb-equal-plain"), rgb, photometric="rgb")
    add("rgb-equal-plain", "image", rgb, notes=[RN], planted=g)
    rgb2 = rgb.copy()
    rgb2[0, 0, 2] = (int(rgb2[0, 0, 2]) + 1) % 256
    tifffile.imwrite(path("rgb-unequal-plain"), rgb2, photometric="rgb")
    add("rgb-unequal-plain", "refusal", rgb2, error="unequalChannels")

    # --- refusals -----------------------------------------------------------------------------------------------
    a = grid("uint16")
    with tifffile.TiffWriter(path("refuse-two-pages")) as tw:
        tw.write(a)
        tw.write(a[::-1].copy())
    add("refuse-two-pages", "refusal", a, error="multiPage")
    tifffile.imwrite(path("refuse-lzw"), a, compression="lzw")
    add("refuse-lzw", "refusal", a, error="compressed")
    t = grid("uint16", 48, 32)
    tifffile.imwrite(path("refuse-tiled"), t, tile=(16, 16))
    add("refuse-tiled", "refusal", t, error="tiled", w=48, h=32)
    g8 = grid("uint8")
    tifffile.imwrite(path("refuse-whiteiszero"), g8, photometric="miniswhite")
    add("refuse-whiteiszero", "refusal", g8, error="sampleFormat")
    # uint32 reads: values past 2**24 round to float32 the same way on both sides (numpy's cast, Swift's Float(_:))
    u32 = a.astype(np.uint32) * 70000 + 16_777_217
    tifffile.imwrite(path("plain-uint32-large"), u32)
    add("plain-uint32-large", "image", u32, planted=u32)
    c64 = (a.astype(np.float32) + 1j).astype(np.complex64)
    tifffile.imwrite(path("refuse-complex64-sampleformat"), c64)
    add("refuse-complex64-sampleformat", "refusal", a, error="sampleFormat")

    with open(os.path.join(out, "planted.json"), "w") as fh:
        json.dump({"tifffile": tifffile.__version__, "cases": cases}, fh, indent=1, ensure_ascii=False)
    print(f"make_fixture: {len(cases)} planted TIFFs in {out}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
