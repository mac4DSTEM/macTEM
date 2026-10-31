#!/usr/bin/env python3
"""Planted truth for tools/parity/metadata-parity: files and maps whose acquisition metadata is KNOWN, written first.

    make_fixture.py <out-dir>

Writes <out-dir>/planted.json and the planted files beside it:
  * FEI2 / FEI1 MRC files, by this script's own struct.pack writer (NOT mrcfile): the extended-header offsets and the
    bitmask bit positions below are typed here from the Thermo/FEI layout, and reference.py requires mrcfile's dtype to
    reproduce every one of them (`layout` in planted.json) before it reads anything;
  * Velox TIFFs (tag 34683 XML) and FEI SEM TIFFs (tag 34682 / 34680 INI text), written with tifffile;
  * DM image-object tag maps ({numbers, strings}, keys relative to "ImageList.N.ImageTags.") as JSON;
  * (slice S-b, the DM wiring and tag 65027) DM4 files by dm4_writer.py beside this script (the verbatim copy,
    imported, not copied again) and TIFFs holding a DM4 tag stream in tag 65027, listed under `reads` in planted.json: the
    inputs of AcquisitionMetadata.read(path:) end to end, each with the hand-written truth of what it must show.

Each case carries its TRUTH: for each of the nine fields, null ("not recorded") or {"value", "note", "otherCopy"}. The
truth is written by hand from the registered rules (archive: roadmap-registrations-2026-10-15.md V1-4a; AcquisitionMetadata.swift rules a-g), never by
running any reader. reference.py then has to reproduce it from the pinned references; a reference that disagrees with
the plant exits 1, loudly.

Notes (exact texts): "local time, zone not stored" (a Velox, DM or FEI SEM date), "clock of the writer, zone not stored"
(an MRC date), "mm (assumed)" (a DM camera length), "month-first order assumed" (a DM date whose first two fields are
both <= 12), "unvalidated: the mode is not checked" (an MRC camera length), "unvalidated: no published reader reads it"
(a value whose path no pinned reference reads); several on one value joined with "; " in the order the harness lists
them.

Mutant inputs. A case that a negative control targets also carries `mutants`: the input the real code would need to
see for the BROKEN reader's output to appear (README.md says which mutation does what). A mutant is written here, from
the plant, not by reference.py.
"""
import json
import os
import shutil
import struct
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime

import numpy as np
import tifffile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)                                             # `python -I` drops the script's directory
import dm4_writer                                                    # noqa: E402  (the verbatim copy of mac4DSTEM's)
from dm4_writer import Group, image_object, write_dm4                # noqa: E402

LOCAL = "local time, zone not stored"
WRITER = "clock of the writer, zone not stored"
MM = "mm (assumed)"
MONTH_FIRST = "month-first order assumed"
NOMODE = "unvalidated: the mode is not checked"
UNVAL = "unvalidated: no published reader reads it"
FIELDS = ["highTensionKV", "magnification", "cameraLengthMM", "detector", "dwellUS", "exposureS", "acquired",
          "instrument", "mode"]


def R(value, *notes, other=None):
    """One recorded value: the truth the harness expects (notes joined with '; ', in the registered order)."""
    return {"value": value, "note": "; ".join(notes) if notes else None, "otherCopy": other}


def truth(**given):
    """The nine fields: those not given are 'not recorded' (null)."""
    bad = set(given) - set(FIELDS)
    assert not bad, bad
    return {f: given.get(f) for f in FIELDS}


# ------------------------------------------------------------------------------------------------ MRC / FEI -------
# One packed FEI2 record (888 bytes; FEI1 is its first 768). Offsets typed from the Thermo layout as mrcfile 1.5.4
# dtypes.py lays it out; reference.py re-derives every one from mrcfile and requires equality.
REC = {"FEI2": 888, "FEI1": 768}
OFF = {"Metadata size": 0, "Metadata version": 4, "Bitmask 1": 8, "Timestamp": 12, "Microscope type": 20, "HT": 84,
       "Instrument mode": 244, "Magnification": 289, "Bitmask 2": 297, "Camera length": 301, "Integration time": 419,
       "Camera name": 435, "Bitmask 3": 490, "STEM Detector name": 519, "Dwell time": 571, "Bitmask 4": 748,
       "Detector commercial name": 804}
# Which bit of which bitmask says a field was written: bit i of Bitmask k is the i-th field after that bitmask, the
# 48-byte "Unused range" counting 6 bits (so each of bitmasks 1-3 covers exactly 32).
BITS = {"Timestamp": (1, 0), "Microscope type": (1, 1), "HT": (1, 5), "Instrument mode": (1, 25),
        "Magnification": (1, 31), "Camera length": (2, 0), "Integration time": (2, 16), "Camera name": (2, 19),
        "STEM Detector name": (3, 7), "Dwell time": (3, 15), "Detector commercial name": (4, 7)}
STRINGS = {"Microscope type", "Camera name", "STEM Detector name", "Detector commercial name"}
INT32 = {"Instrument mode"}
LE_STAMP = b"\x44\x44\x00\x00"
BE_STAMP = b"\x11\x11\x00\x00"


def ole_days(dt):
    """The OLE automation date of a naive datetime: days since 1899-12-30 (the inverse of what reference.py computes)."""
    return (dt - datetime(1899, 12, 30)).total_seconds() / 86400.0


def mrc_header(nx, ny, mode, *, exttyp, nsymbt, end="<", stamp=LE_STAMP):
    h = bytearray(1024)
    struct.pack_into(end + "4i", h, 0, nx, ny, 1, mode)
    struct.pack_into(end + "3i", h, 28, nx, ny, 1)
    struct.pack_into(end + "3f", h, 40, float(nx), float(ny), 1.0)
    struct.pack_into(end + "3f", h, 52, 90.0, 90.0, 90.0)
    struct.pack_into(end + "3i", h, 64, 1, 2, 3)
    struct.pack_into(end + "2i", h, 88, 0, nsymbt)
    h[104:108] = exttyp
    struct.pack_into(end + "i", h, 108, 20141)
    h[208:212] = b"MAP "
    h[212:216] = stamp
    return bytes(h)


def fei_record(kind, values, written, *, end="<", masks=None):
    """The packed record. `values`: field -> value for every field to store (written or not); `written`: the fields
    whose bitmask bit is set. Bitmasks are little-endian whatever `end` is (mrcfile's mixed-endian layout). `masks`
    overrides the four bitmask words (the mutant that ignores them sets every bit)."""
    rec = bytearray(REC[kind])
    struct.pack_into(end + "i", rec, 0, REC[kind])
    struct.pack_into(end + "i", rec, 4, 2 if kind == "FEI2" else 0)
    for field, v in values.items():
        off = OFF[field]
        if field in STRINGS:
            rec[off:off + 16] = v.encode("ascii")[:16].ljust(16, b"\0")
        elif field in INT32:
            struct.pack_into(end + "i", rec, off, v)
        else:
            struct.pack_into(end + "d", rec, off, v)
    words = [0, 0, 0, 0]
    for field in written:
        k, b = BITS[field]
        words[k - 1] |= 1 << b
    if masks is not None:
        words = list(masks)
    for k, name in enumerate(("Bitmask 1", "Bitmask 2", "Bitmask 3", "Bitmask 4")):
        if OFF[name] + 4 <= len(rec):
            struct.pack_into("<I", rec, OFF[name], words[k])
    return bytes(rec)


def mrc_bytes(rec, *, kind="FEI2", end="<", stamp=LE_STAMP, exttyp=None, nsymbt=None):
    """A 8 x 8 float32 image behind one extended-header record."""
    nx = ny = 8
    pixels = np.arange(nx * ny, dtype=np.dtype("float32").newbyteorder(end)).tobytes()
    ext = rec if rec is not None else b""
    head = mrc_header(nx, ny, 2, exttyp=(exttyp if exttyp is not None else kind.encode()),
                      nsymbt=(len(ext) if nsymbt is None else nsymbt), end=end, stamp=stamp)
    return head + ext + pixels


# ------------------------------------------------------------------------------------------------ Velox XML ------
def velox_xml(tree):
    """A Velox-schema document from nested dicts (leaf values are written as given, str())."""
    root = ET.Element("Metadata")

    def add(parent, d):
        for k, v in d.items():
            e = ET.SubElement(parent, k)
            if isinstance(v, dict):
                add(e, v)
            else:
                e.text = str(v)
    add(root, tree)
    ET.indent(root, space="    ")
    return '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(root, encoding="unicode") + "\n"


def with_extra(xml, chunk):
    """The document with `chunk` (raw XML) as a last child of <Metadata>."""
    assert xml.count("</Metadata>") == 1
    return xml.replace("</Metadata>", chunk + "</Metadata>")


def with_doctype(xml, declarations):
    """The document with a DOCTYPE (internal subset `declarations`) between its XML declaration and its root."""
    head, body = xml.split("\n", 1)
    return head + "\n<!DOCTYPE Metadata [" + declarations + "]>\n" + body


def velox_tree(*, ht="200000", mode="TEM", projector="Imaging", mag=None, cl=None, detector="BM-Ceta", exposure=None,
               frame_time=None, start="2025-03-04T09:08:07.000", acq=None, model="Themis Z", detectors=None):
    """The sections a reader looks at; a None leaves the element out ('not recorded'). `detectors`, when given, is the
    whole Detectors section ({element name: {DetectorName, ExposureTime?}}, in document order) instead of the one
    ImagingDetector that `exposure` writes."""
    optics = {"AccelerationVoltage": ht, "OperatingMode": mode, "ProjectorMode": projector}
    if mag is not None:
        optics["NominalMagnification"] = mag
    if cl is not None:
        optics["CameraLength"] = cl
    tree = {"Core": {"ApplicationSoftware": "Velox"}, "Instrument": {"InstrumentModel": model},
            "Acquisition": {"AcquisitionStartDatetime": start,
                            "AcquisitionDatetime": start if acq is None else acq},
            "Optics": optics}
    if frame_time is not None:
        tree["ScanSettings"] = {"FrameTime": frame_time}
    if detectors is not None:
        tree["Detectors"] = detectors
    elif exposure is not None:
        tree["Detectors"] = {"ImagingDetector": {"DetectorName": detector, "ExposureTime": exposure}}
    tree["BinaryResult"] = {"Detector": detector, "PixelSize": {"X": "1e-09", "Y": "1e-09"}}
    return tree


# ------------------------------------------------------------------------------------------------ DM4 files ------
def tag_tree(numbers, strings, *, label="ImageTags", nul=()):
    """The group of an image object's tags from the two maps (keys are dotted paths; a key's last part is the tag, the
    rest its groups, created on first use and kept in order). Numbers are written as float64, strings as GMS writes
    them (a uint16 array); a key in `nul` gets a trailing NUL unit, as a fixed-width GMS string field does."""
    root, made = Group(label), {}

    def parent(parts):
        g, path = root, ()
        for part in parts:
            path += (part,)
            if path not in made:
                made[path] = g.group(part)
            g = made[path]
        return g
    for key, v in numbers.items():
        parts = key.split(".")
        parent(parts[:-1]).value(parts[-1], "f64", v)
    for key, text in strings.items():
        parts = key.split(".")
        parent(parts[:-1]).string(parts[-1], text + ("\0" if key in nul else ""))
    return root


def dm_image(name, tags, *, dims=(6, 4), units=("nm", "nm"), uid=(5, 6, 7, 8)):
    """One ImageList entry: a small int16 picture (two axes in `units`, `dims` fastest first) with `tags` as its ImageTags."""
    n = int(np.prod(dims))
    return image_object(name=name, dtype="i16", dims=list(dims), data=(np.arange(n, dtype="<i2") * 3 - 7).astype("<i2"),
                        calibrations=[(0.0, 0.1, u) for u in units], unique_id=list(uid), image_tags=tags)


def dm_thumbnail():
    """The RGBA preview GMS writes first (listed under Thumbnails, with no ImageTags)."""
    return image_object(name="thumbnail", dtype="rgba", dims=[8, 6], data=np.zeros(8 * 6 * 4, np.uint8),
                        calibrations=[(0.0, 1.0, ""), (0.0, 1.0, "")], unique_id=[1, 2, 3, 4],
                        image_tags=Group("ImageTags"))


def write_gms(path, objects, *, thumbnails=True):
    """A DM4 file whose ImageList holds `objects` in order; with `thumbnails` the first is listed as the thumbnail."""
    root = Group()
    if thumbnails:
        root.group("Thumbnails").group("").value("ImageIndex", "u32", 0)
    image_list = root.group("ImageList")
    for o in objects:
        image_list.add(o)
    write_dm4(path, root)


def tag_stream(numbers, strings):
    """A complete DM4 byte stream whose root group is the tags themselves (no ImageList): what a DM-saved TIFF holds in tag 65027."""
    root = Group()
    for child in tag_tree(numbers, strings).children:
        root.add(child)
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "stream.dm4")
        write_dm4(path, root)
        with open(path, "rb") as fh:
            return fh.read()


# ------------------------------------------------------------------------------------------------ main -----------
def main(out):
    os.makedirs(out, exist_ok=True)
    cases = []
    image = (np.arange(24 * 40, dtype=np.uint16) * 7).reshape(24, 40)

    def add(name, fmt, tr, *, file=None, numbers=None, strings=None, outcome="values", mutants=None, extra=None,
            comment=""):
        cases.append({"name": name, "format": fmt, "file": file, "numbers": numbers, "strings": strings,
                      "truth": tr, "outcome": outcome, "mutants": mutants or {}, "extra": extra or {},
                      "comment": comment})

    def tiff_path(name):
        return os.path.join(out, name + ".tif")

    def write_tiff(name, tags, data=image):
        tifffile.imwrite(tiff_path(name), data, extratags=tags)
        return name + ".tif"

    def write_velox(name, tree):
        return write_tiff(name, [(34683, "s", 0, velox_xml(tree) + "\0", True)])

    def write_fei(name, ini, tag=34682):
        return write_tiff(name, [(tag, "s", 0, ini + "\0", True)])

    def write_blob(name, blob):
        with open(os.path.join(out, name), "wb") as fh:
            fh.write(blob)
        return name

    # ---------------------------------------------------------------- Velox TIFF (tag 34683) ---------------------
    # HT and camera length carry no 'unvalidated' note (RosettaSciIO emd/_emd_velox.py:938-945 converts them); the
    # other fields' XML paths are read by no pinned reference.
    base = dict(ht="300000", mode="TEM", projector="Diffraction", cl="0.5", exposure="0.25", frame_time="7.5",
                start="2025-03-04T09:08:07.000", model="Themis Z")
    f = write_velox("planted-velox-diffraction", velox_tree(**base))
    kv = write_velox("planted-velox-diffraction.kv-unscaled", velox_tree(**{**base, "ht": "300000000"}))
    mm = write_velox("planted-velox-diffraction.mm-unscaled", velox_tree(**{**base, "cl": "0.0005"}))
    add("planted-velox-diffraction", "tiff", truth(
        highTensionKV=R(300.0), cameraLengthMM=R(500.0), detector=R("BM-Ceta", UNVAL), exposureS=R(0.25, UNVAL),
        acquired=R("2025-03-04 09:08:07", LOCAL, UNVAL), instrument=R("Themis Z", UNVAL), mode=R("TEM", UNVAL)),
        file=f, mutants={"kv-unscaled": {"file": kv}, "mm-unscaled": {"file": mm}},
        comment="diffraction mode: the camera length is real (500 mm); FrameTime 7.5 s present, the dwell is not "
                "recorded; no NominalMagnification")

    f = write_velox("planted-velox-imaging", velox_tree(ht="200000", mode="TEM", projector="Imaging", mag="17749.325",
                                                        cl="0.844", exposure="1"))
    add("planted-velox-imaging", "tiff", truth(
        highTensionKV=R(200.0), magnification=R(17749.325, UNVAL), detector=R("BM-Ceta", UNVAL),
        exposureS=R(1.0, UNVAL), acquired=R("2025-03-04 09:08:07", LOCAL, UNVAL), instrument=R("Themis Z", UNVAL),
        mode=R("TEM", UNVAL)), file=f,
        comment="imaging mode with a CameraLength of 0.844 m stored: not in effect, so not recorded (rule c)")

    f = write_velox("planted-velox-stem", velox_tree(ht="200000", mode="STEM", projector="Imaging", mag="225000",
                                                     cl="0.145", detector="HAADF", frame_time="3.2"))
    add("planted-velox-stem", "tiff", truth(
        highTensionKV=R(200.0), magnification=R(225000.0, UNVAL), cameraLengthMM=R(145.0),
        detector=R("HAADF", UNVAL), acquired=R("2025-03-04 09:08:07", LOCAL, UNVAL), instrument=R("Themis Z", UNVAL),
        mode=R("STEM", UNVAL)), file=f, extra={"frameTimeS": 3.2},
        comment="STEM: the camera length is real (145 mm); FrameTime 3.2 s is a scan setting, not a dwell (the dwell "
                "path of a Velox STEM TIFF is unobserved: not recorded)")

    f = write_velox("planted-velox-two-datetimes", velox_tree(start="2025-03-04T09:08:07.000",
                                                              acq="2025-03-04T09:08:21.500"))
    add("planted-velox-two-datetimes", "tiff", truth(
        highTensionKV=R(200.0), detector=R("BM-Ceta", UNVAL),
        acquired=R("2025-03-04 09:08:07", LOCAL, UNVAL, other="2025-03-04 09:08:21"),
        instrument=R("Themis Z", UNVAL), mode=R("TEM", UNVAL)), file=f,
        comment="AcquisitionStartDatetime and AcquisitionDatetime differ by 14 s: the start first, the other kept "
                "(rule f)")

    f = write_velox("planted-velox-absent", {"Core": {"ApplicationSoftware": "Velox"}})
    add("planted-velox-absent", "tiff", truth(), file=f, comment="a Velox document with none of the sections")

    f = write_velox("planted-velox-garbage", velox_tree(ht="0", mode="", projector="Diffraction", mag="notafloat",
                                                        cl="", detector="", exposure="-1", start="not a date",
                                                        model="   "))
    add("planted-velox-garbage", "tiff", truth(), file=f,
        comment="zero HT, unparseable magnification, empty camera length in diffraction, empty detector, negative "
                "exposure, unparseable date, blank model, empty mode: every field not recorded, none 0")

    # Rule (b) applies to the number as shown, after the unit conversion (the MRC case planted-fei2-converted-to-zero
    # does the same): 5e-324 V is 0.0 kV and 1e306 m is inf mm, though each stored number is positive and finite; the
    # twin keeps values that stay finite and positive after the conversion (1e300 V is 1e297 kV; 5e-324 m is 4.94e-321 mm).
    f = write_velox("planted-velox-converted-to-zero", velox_tree(ht="5e-324", mode="STEM", projector="Imaging",
                                                                  cl="1e306", detector="HAADF"))
    add("planted-velox-converted-to-zero", "tiff", truth(
        detector=R("HAADF", UNVAL), acquired=R("2025-03-04 09:08:07", LOCAL, UNVAL), instrument=R("Themis Z", UNVAL),
        mode=R("STEM", UNVAL)), file=f,
        comment="a stored AccelerationVoltage of 5e-324 V is 0.0 kV and a CameraLength of 1e306 m (STEM: real) is inf "
                "mm after the conversion: both not recorded (rule b after the unit conversion)")
    f = write_velox("planted-velox-converted-finite", velox_tree(ht="1e300", mode="STEM", projector="Imaging",
                                                                 cl="5e-324", detector="HAADF"))
    add("planted-velox-converted-finite", "tiff", truth(
        highTensionKV=R(1e300 / 1e3), cameraLengthMM=R(5e-324 * 1e3), detector=R("HAADF", UNVAL),
        acquired=R("2025-03-04 09:08:07", LOCAL, UNVAL), instrument=R("Themis Z", UNVAL), mode=R("STEM", UNVAL)),
        file=f, comment="1e300 V is 1e297 kV and a CameraLength of 5e-324 m is 4.94e-321 mm: still positive and "
                        "finite after the conversion, so recorded")

    f = write_velox("planted-velox-padded", velox_tree(ht="\n   200000  \n", detector="  BM-Ceta  ", exposure=" 2 ",
                                                       model=" Themis Z "))
    add("planted-velox-padded", "tiff", truth(
        highTensionKV=R(200.0), detector=R("BM-Ceta", UNVAL), exposureS=R(2.0, UNVAL),
        acquired=R("2025-03-04 09:08:07", LOCAL, UNVAL), instrument=R("Themis Z", UNVAL), mode=R("TEM", UNVAL)),
        file=f, comment="surrounding whitespace is not part of a value (rule a)")

    # The exposure is the one of the Detectors/* element whose DetectorName is BinaryResult/Detector (macTEM policy (i)
    # in reference.py: no pinned reader reads the TIFF path); the truth below is written from that sentence.
    f = write_velox("planted-velox-exposure-decoy", velox_tree(
        ht="200000", mode="STEM", projector="Imaging", cl="0.145", detector="HAADF", detectors={
            "ScanningDetector": {"DetectorName": "HAADF"},
            "ImagingDetector": {"DetectorName": "BM-Ceta", "ExposureTime": "1"}}))
    add("planted-velox-exposure-decoy", "tiff", truth(
        highTensionKV=R(200.0), cameraLengthMM=R(145.0), detector=R("HAADF", UNVAL),
        acquired=R("2025-03-04 09:08:07", LOCAL, UNVAL), instrument=R("Themis Z", UNVAL), mode=R("STEM", UNVAL)),
        file=f, comment="STEM image from the HAADF detector, which stores no exposure; a decoy ImagingDetector "
                        "(BM-Ceta, 1 s) is another detector's: exposure not recorded")
    f = write_velox("planted-velox-exposure-named", velox_tree(
        ht="200000", detector="BM-Ceta", detectors={
            "ImagingDetector": {"DetectorName": "Falcon", "ExposureTime": "9"},
            "AnalyticalDetector": {"DetectorName": "BM-Ceta", "ExposureTime": "3"}}))
    add("planted-velox-exposure-named", "tiff", truth(
        highTensionKV=R(200.0), detector=R("BM-Ceta", UNVAL), exposureS=R(3.0, UNVAL),
        acquired=R("2025-03-04 09:08:07", LOCAL, UNVAL), instrument=R("Themis Z", UNVAL), mode=R("TEM", UNVAL)),
        file=f, comment="the image's detector (BM-Ceta) is the second listed and not an ImagingDetector element; "
                        "the ImagingDetector (Falcon, 9 s) is another detector's: 3 s")

    # The mode that opens the camera-length gate is matched without regard to case (policy (j): the registration states
    # no case, no pinned reader reads ProjectorMode); the mode shown is the stored text.
    f = write_velox("planted-velox-mode-case-projector", velox_tree(mode="tem", projector="dIFFRACTION", cl="0.5"))
    add("planted-velox-mode-case-projector", "tiff", truth(
        highTensionKV=R(200.0), cameraLengthMM=R(500.0), detector=R("BM-Ceta", UNVAL),
        acquired=R("2025-03-04 09:08:07", LOCAL, UNVAL), instrument=R("Themis Z", UNVAL), mode=R("tem", UNVAL)),
        file=f, comment="ProjectorMode 'dIFFRACTION': a diffraction mode, the camera length is real (500 mm)")
    f = write_velox("planted-velox-mode-case-operating", velox_tree(mode="Stem", projector="imaging", cl="0.145"))
    add("planted-velox-mode-case-operating", "tiff", truth(
        highTensionKV=R(200.0), cameraLengthMM=R(145.0), detector=R("BM-Ceta", UNVAL),
        acquired=R("2025-03-04 09:08:07", LOCAL, UNVAL), instrument=R("Themis Z", UNVAL), mode=R("Stem", UNVAL)),
        file=f, comment="OperatingMode 'Stem': the STEM mode, the camera length is real (145 mm)")

    # The second start stamp: a year before 1990 is an unset field, not a copy (policy (k): the Velox schema postdates
    # 1990; the sentinel form is inferred from same-schema EMD files). A stamp from 1990 on is kept.
    for suffix, second, other, note in (
            ("epoch-local", "1970-01-01T01:00:00", None, "the unix epoch on a UTC+1 clock"),
            ("year-1", "0001-01-01T00:00:00.000", None, "year 1"),
            ("1989", "1989-12-31T23:59:59", None, "the last second before 1990"),
            ("1990-kept", "1990-01-01T00:00:00", "1990-01-01 00:00:00", "the first second of 1990: kept")):
        f = write_velox("planted-velox-second-stamp-" + suffix,
                        velox_tree(start="2026-06-05T13:05:31.000", acq=second))
        add("planted-velox-second-stamp-" + suffix, "tiff", truth(
            highTensionKV=R(200.0), detector=R("BM-Ceta", UNVAL),
            acquired=R("2026-06-05 13:05:31", LOCAL, UNVAL, other=other), instrument=R("Themis Z", UNVAL),
            mode=R("TEM", UNVAL)), file=f,
            comment=f"AcquisitionDatetime {second} ({note}) beside a start stamp of 2026-06-05 13:05:31")

    # A string value over 256 characters is not recorded; 200 characters are (policy (m)).
    for n, kept in ((300, False), (200, True)):
        name_ = "M" * n
        f = write_velox(f"planted-velox-value-{n}", velox_tree(
            detector=name_, model=name_, detectors={"ImagingDetector": {"DetectorName": name_, "ExposureTime": "2"}}))
        add(f"planted-velox-value-{n}", "tiff", truth(
            highTensionKV=R(200.0), detector=R(name_, UNVAL) if kept else None,
            exposureS=R(2.0, UNVAL) if kept else None, acquired=R("2025-03-04 09:08:07", LOCAL, UNVAL),
            instrument=R(name_, UNVAL) if kept else None, mode=R("TEM", UNVAL)), file=f,
            comment=f"detector and instrument names of {n} characters: " +
                    ("read" if kept else "not recorded (so no exposure is looked up either)"))

    # Hostile documents (policy (m), the guarded XML loader): each carries real fields, so a reader that parsed it would
    # show them; the truth is that none is shown. Sizes are the ones the guard names: depth 64, 1 MiB of text, 4 MiB
    # of tag, any entity declaration. The unguarded cost of the laughs document is 10 MB, not the gigabytes of a
    # ten-level one.
    good = velox_xml(velox_tree(ht="200000", detector="HAADF", model="Themis Z"))
    hostile = {
        "deep": (with_extra(good, "<Deep>" + "<a>" * 2000 + "</a>" * 2000 + "</Deep>"), "2000 nested elements"),
        "laughs": (with_doctype(good, '<!ENTITY a0 "xxxxxxxxxx">' + "".join(
            f'<!ENTITY a{i} "' + f"&a{i - 1};" * 10 + '">' for i in range(1, 7))).replace(
                "<InstrumentModel>Themis Z</InstrumentModel>", "<InstrumentModel>&a6;</InstrumentModel>"),
                   "seven nested entity declarations that expand to 10 MB"),
        # any entity declaration refuses the document, whatever it expands to (the laughs document is also over the
        # text bound once expanded; these three are not): an internal one used once, an external one, an unparsed one
        "entity-internal": (with_doctype(good, '<!ENTITY x "Themis Z">').replace(
            "<InstrumentModel>Themis Z</InstrumentModel>", "<InstrumentModel>&x;</InstrumentModel>"),
                            "one small internal entity declaration, used once"),
        "entity-external": (with_doctype(good, '<!ENTITY y SYSTEM "file:///nonexistent-entity-target">'),
                            "one external entity declaration, unused"),
        "entity-unparsed": (with_doctype(good, '<!NOTATION n SYSTEM "n"><!ENTITY u SYSTEM "u" NDATA n>'),
                            "one unparsed entity declaration, unused"),
        "text": (with_extra(good, "<Padding>" + "x" * (2 * 1024 * 1024) + "</Padding>"), "2 MiB of character data"),
        # a comment is no character data, so only the size bound refuses this one
        "huge": (with_extra(good, "<!--" + "x" * (5 * 1024 * 1024) + "-->"), "a 5 MiB tag (a comment: no text)"),
    }
    assert "&a6;" in hostile["laughs"][0] and "&x;" in hostile["entity-internal"][0]
    for key, (xml, what) in hostile.items():
        f = write_tiff("planted-velox-hostile-" + key, [(34683, "s", 0, xml + "\0", True)])
        add("planted-velox-hostile-" + key, "tiff", truth(), file=f,
            comment=f"a Velox document with its real fields and {what}: refused, so every field not recorded")

    # ---------------------------------------------------------------- TIFFs with no acquisition tags -----------
    tifffile.imwrite(tiff_path("planted-tiff-plain"), image)
    add("planted-tiff-plain", "tiff", truth(), file="planted-tiff-plain.tif", comment="a plain TIFF")
    tifffile.imwrite(tiff_path("planted-tiff-imagej"), image, imagej=True, resolution=(1000000, 12345),
                     metadata={"unit": "micron"})
    add("planted-tiff-imagej", "tiff", truth(), file="planted-tiff-imagej.tif", comment="an ImageJ TIFF")
    f = write_tiff("planted-tiff-dm", [(65003, "s", 0, b"nm\0", True), (65004, "s", 0, b"nm\0", True),
                                       (65009, "d", 1, 0.0123456789, True), (65010, "d", 1, 0.0234567891, True)])
    add("planted-tiff-dm", "tiff", truth(), file=f, comment="a Digital Micrograph TIFF with only its calibration tags "
        "(65003-65025), which hold no acquisition value (a DM-saved TIFF may also carry its whole ImageTags tree in tag "
        "65027: the S-b plants and the real files are the `reads` cases rsciio-dm-tiff-65027 and planted-tiff-65027-*)")
    f = write_tiff("planted-tiff-bad-velox-xml", [(34683, "s", 0, "this is not xml <<<\0", True)])
    add("planted-tiff-bad-velox-xml", "tiff", truth(), file=f, outcome="nilOrThrows",
        comment="tag 34683 holds text that is not XML: refused or not recorded, never a value")

    # ---------------------------------------------------------------- FEI SEM INI (tags 34682 / 34680) ----------
    def ini(beam_hv, *, dwell="1e-05", date="05/17/2022", time="09:07:08 AM", system="Quanta 250 FEG", det="ETD",
            extra=""):
        return (f"[System]\nSystemType={system}\n[Beam]\nHV={beam_hv}\n[Scan]\nDwelltime={dwell}\n"
                f"PixelWidth=1e-08\nPixelHeight=1e-08\n[User]\nDate={date}\nTime={time}\n[Detectors]\nName={det}\n"
                + extra)

    f = write_fei("planted-fei-sem-full", ini("30000", dwell="2.5e-05", date="11/27/2019", time="01:02:03 PM",
                                              extra="[EBeam]\nHV=12345\n"))
    add("planted-fei-sem-full", "tiff", truth(
        highTensionKV=R(30.0), dwellUS=R(25.0), acquired=R("2019-11-27 13:02:03", LOCAL),
        instrument=R("Quanta 250 FEG"), detector=R("ETD", UNVAL)), file=f,
        comment="[Beam] HV 30000 V (an [EBeam] HV of 12345 beside it is not read); dwell 2.5e-5 s = 25 us; US date "
                "and 12-hour clock")
    f = write_fei("planted-fei-sem-hv-empty", ini(""), tag=34680)
    add("planted-fei-sem-hv-empty", "tiff", truth(
        dwellUS=R(10.0), acquired=R("2022-05-17 09:07:08", LOCAL), instrument=R("Quanta 250 FEG"),
        detector=R("ETD", UNVAL)), file=f,
        comment="[Beam] HV empty (as the Helios navcam files; tag 34680): high tension not recorded, never 0")
    f = write_fei("planted-fei-sem-hv-notafloat", ini("notafloat"))
    add("planted-fei-sem-hv-notafloat", "tiff", truth(
        dwellUS=R(10.0), acquired=R("2022-05-17 09:07:08", LOCAL), instrument=R("Quanta 250 FEG"),
        detector=R("ETD", UNVAL)), file=f, comment="[Beam] HV = notafloat: not recorded")
    f = write_fei("planted-fei-sem-hv-zero", ini("0", dwell="0"))
    add("planted-fei-sem-hv-zero", "tiff", truth(
        acquired=R("2022-05-17 09:07:08", LOCAL), instrument=R("Quanta 250 FEG"), detector=R("ETD", UNVAL)),
        file=f, comment="HV 0 and Dwelltime 0 stored: strictly positive quantities, so not recorded (rule b)")
    f = write_fei("planted-fei-sem-12am", ini("5000", date="12/31/2020", time="12:05:09 AM"))
    add("planted-fei-sem-12am", "tiff", truth(
        highTensionKV=R(5.0), dwellUS=R(10.0), acquired=R("2020-12-31 00:05:09", LOCAL),
        instrument=R("Quanta 250 FEG"), detector=R("ETD", UNVAL)), file=f, comment="12:05:09 AM is 00:05:09")
    f = write_fei("planted-fei-sem-12pm", ini("5000", date="01/15/2021", time="12:30:00 PM"))
    add("planted-fei-sem-12pm", "tiff", truth(
        highTensionKV=R(5.0), dwellUS=R(10.0), acquired=R("2021-01-15 12:30:00", LOCAL),
        instrument=R("Quanta 250 FEG"), detector=R("ETD", UNVAL)), file=f, comment="12:30:00 PM is 12:30:00")
    f = write_fei("planted-fei-sem-garbage", ini("-30000", dwell="notafloat", date="notadate", time="nonsense",
                                                 system="   ", det=""))
    add("planted-fei-sem-garbage", "tiff", truth(), file=f,
        comment="negative HV, unparseable dwell, unparseable date, blank system type, empty detector: all not "
                "recorded")

    # Rule (b) after the unit conversion (see planted-velox-converted-to-zero): 5e-324 V is 0.0 kV and 1e306 s is inf us.
    f = write_fei("planted-fei-sem-converted-to-zero", ini("5e-324", dwell="1e306"))
    add("planted-fei-sem-converted-to-zero", "tiff", truth(
        acquired=R("2022-05-17 09:07:08", LOCAL), instrument=R("Quanta 250 FEG"), detector=R("ETD", UNVAL)), file=f,
        comment="[Beam] HV 5e-324 V is 0.0 kV and [Scan] Dwelltime 1e306 s is inf us after the conversion: both not "
                "recorded (rule b after the unit conversion)")
    f = write_fei("planted-fei-sem-converted-finite", ini("1e300", dwell="5e-324"))
    add("planted-fei-sem-converted-finite", "tiff", truth(
        highTensionKV=R(1e300 / 1e3), dwellUS=R(5e-324 * 1e6), acquired=R("2022-05-17 09:07:08", LOCAL),
        instrument=R("Quanta 250 FEG"), detector=R("ETD", UNVAL)), file=f,
        comment="HV 1e300 V is 1e297 kV and Dwelltime 5e-324 s is 4.94e-318 us: still positive and finite after the "
                "conversion, so recorded")

    # tifffile's read_fei_metadata: a repeated key takes its LAST line, an empty one included (`HV=` stores ''), and a
    # repeated section replaces the earlier one whole. The truth is what tifffile does, written down first.
    f = write_fei("planted-fei-sem-repeated-key-empty", ini("5000\nHV="))
    add("planted-fei-sem-repeated-key-empty", "tiff", truth(
        dwellUS=R(10.0), acquired=R("2022-05-17 09:07:08", LOCAL), instrument=R("Quanta 250 FEG"),
        detector=R("ETD", UNVAL)), file=f,
        comment="[Beam] HV=5000 and then HV= : the later, empty copy is the value (as tifffile): high tension not "
                "recorded, not 5 kV")
    f = write_fei("planted-fei-sem-repeated-key-later", ini("5000\nHV=6000"))
    add("planted-fei-sem-repeated-key-later", "tiff", truth(
        highTensionKV=R(6.0), dwellUS=R(10.0), acquired=R("2022-05-17 09:07:08", LOCAL),
        instrument=R("Quanta 250 FEG"), detector=R("ETD", UNVAL)), file=f,
        comment="[Beam] HV=5000 and then HV=6000: the later copy wins")
    f = write_fei("planted-fei-sem-repeated-section", ini("5000", extra="[Beam]\nPixelWidth=1e-08\n"))
    add("planted-fei-sem-repeated-section", "tiff", truth(
        dwellUS=R(10.0), acquired=R("2022-05-17 09:07:08", LOCAL), instrument=R("Quanta 250 FEG"),
        detector=R("ETD", UNVAL)), file=f,
        comment="a second [Beam] section without HV replaces the first (as tifffile): high tension not recorded")

    # The FEI [User] Date is month-first by format (as mapping_fei parses it): no order note, whatever the fields.
    f = write_fei("planted-fei-sem-ambiguous-date", ini("5000", date="05/06/2022"))
    add("planted-fei-sem-ambiguous-date", "tiff", truth(
        highTensionKV=R(5.0), dwellUS=R(10.0), acquired=R("2022-05-06 09:07:08", LOCAL),
        instrument=R("Quanta 250 FEG"), detector=R("ETD", UNVAL)), file=f,
        comment="05/06/2022 is May 6 (month first by format) and says no more than 'local time'")
    f = write_fei("planted-fei-sem-day-first", ini("5000", date="13/06/2022"))
    add("planted-fei-sem-day-first", "tiff", truth(
        highTensionKV=R(5.0), dwellUS=R(10.0), acquired=R("2022-06-13 09:07:08", LOCAL),
        instrument=R("Quanta 250 FEG"), detector=R("ETD", UNVAL)), file=f,
        comment="13/06/2022: a first field above 12 can only be a day (as dateutil reads it)")
    # A date needs its time (rule e): either one alone is not recorded (RosettaSciIO would map the date alone).
    f = write_fei("planted-fei-sem-date-no-time", ini("5000", time=""))
    add("planted-fei-sem-date-no-time", "tiff", truth(
        highTensionKV=R(5.0), dwellUS=R(10.0), instrument=R("Quanta 250 FEG"), detector=R("ETD", UNVAL)), file=f,
        comment="[User] Date without a Time: the acquisition date is not recorded")
    f = write_fei("planted-fei-sem-time-no-date", ini("5000", date=""))
    add("planted-fei-sem-time-no-date", "tiff", truth(
        highTensionKV=R(5.0), dwellUS=R(10.0), instrument=R("Quanta 250 FEG"), detector=R("ETD", UNVAL)), file=f,
        comment="[User] Time without a Date: the acquisition date is not recorded")

    # ---------------------------------------------------------------- MRC, FEI extended header ------------------
    # The rules as amended after Gate B: the date carries WRITER (of the two pinned files one is on local time, the
    # other on UTC); the camera length is shown as stored and says the mode is not checked (NOMODE); the mode is the
    # stored int32 as text (UNVAL, no published reader reads it); the exposure is the camera's Integration time (UNVAL).
    t_img = datetime(2023, 3, 4, 9, 8, 7, 350000)
    t_stm = datetime(2022, 12, 5, 12, 13, 7, 350000)
    f_img_vals = {"Timestamp": ole_days(t_img), "Microscope type": "Titan Themis", "HT": 200000.0,
                  "Instrument mode": 1, "Magnification": 52000.5, "Camera length": 0.2, "Integration time": 0.5,
                  "Camera name": "BM-Ceta"}
    img_written = list(f_img_vals)
    img_truth = truth(highTensionKV=R(200.0), magnification=R(52000.5), cameraLengthMM=R(200.0, NOMODE),
                      detector=R("BM-Ceta"), exposureS=R(0.5, UNVAL), acquired=R("2023-03-04 09:08:07", WRITER),
                      instrument=R("Titan Themis"), mode=R("1", UNVAL))
    f = write_blob("planted-fei2-imaging.mrc", mrc_bytes(fei_record("FEI2", f_img_vals, img_written)))
    add("planted-fei2-imaging", "mrc", img_truth, file=f,
        comment="little-endian FEI2: every field's bit set; 200 kV, 52000.5 x, camera length 0.2 m shown as stored "
                "(imaging, no mode check), Integration time 0.5 s, Instrument mode 1")

    stem_vals = {"Timestamp": ole_days(t_stm), "Microscope type": "", "HT": 300000.0, "Instrument mode": 2,
                 "Magnification": 0.0, "Camera length": 0.0911, "Integration time": 0.0, "Camera name": "BM-Ceta",
                 "STEM Detector name": "HAADF", "Dwell time": 1e-05}
    stem = mrc_bytes(fei_record("FEI2", stem_vals, list(stem_vals)))
    # the broken reader reads the record big-endian: the 8 bytes of HT reversed (HT is an 8-byte double at 1024 + 84)
    flipped = bytearray(stem)
    flipped[1024 + 84:1024 + 92] = bytes(reversed(flipped[1024 + 84:1024 + 92]))
    f = write_blob("planted-fei2-stem.mrc", stem)
    fb = write_blob("planted-fei2-stem.mrc-big-endian.mrc", bytes(flipped))
    add("planted-fei2-stem", "mrc", truth(
        highTensionKV=R(300.0), cameraLengthMM=R(91.1, NOMODE), detector=R("HAADF"), dwellUS=R(10.0),
        acquired=R("2022-12-05 12:13:07", WRITER), mode=R("2", UNVAL)), file=f,
        mutants={"mrc-big-endian": {"file": fb}},
        comment="STEM: Magnification 0.0 and Integration time 0.0 with their bits SET are not recorded (rule b); an "
                "empty Microscope type; the STEM detector name wins over the camera name; dwell 1e-5 s = 10 us; OLE "
                "date of 2022-12-05 12:13:07.35")

    ghost_vals = {"Timestamp": ole_days(datetime(2020, 1, 2, 3, 4, 5, 350000)), "Microscope type": "Realscope",
                  "HT": 123456.0, "Instrument mode": 2, "Magnification": 40000.0, "Camera length": 0.5,
                  "Integration time": 0.9, "Camera name": "GhostCam", "STEM Detector name": "GhostSTEM",
                  "Dwell time": 3e-06, "Detector commercial name": "GhostCommercial"}
    ghost = mrc_bytes(fei_record("FEI2", ghost_vals, ["Microscope type"]))
    ghost_all = mrc_bytes(fei_record("FEI2", ghost_vals, ["Microscope type"],
                                     masks=(0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF)))
    f = write_blob("planted-fei2-unset-bits.mrc", ghost)
    fa = write_blob("planted-fei2-unset-bits.mrc-bitmask-ignored.mrc", ghost_all)
    add("planted-fei2-unset-bits", "mrc", truth(instrument=R("Realscope")), file=f,
        mutants={"mrc-bitmask-ignored": {"file": fa}},
        comment="ten non-zero fields whose bitmask bit is UNSET (a field the file did not write is not recorded, "
                "whatever its bytes hold); only the Microscope type bit is set")

    zero_vals = {"Microscope type": "Spectra   ", "HT": 0.0, "Instrument mode": 0, "Magnification": -5.0,
                 "Camera length": 0.0, "Integration time": 0.0, "Camera name": "", "STEM Detector name": "",
                 "Dwell time": 0.0, "Detector commercial name": "Ceta-S speed"}
    f = write_blob("planted-fei2-zero-set.mrc", mrc_bytes(fei_record("FEI2", zero_vals, list(zero_vals))))
    add("planted-fei2-zero-set", "mrc", truth(detector=R("Ceta-S speed"), instrument=R("Spectra"),
                                              mode=R("0", UNVAL)), file=f,
        comment="bits set on a zero HT, camera length, Integration time and dwell and a negative magnification: not "
                "recorded (rule b); a recorded Instrument mode of 0 is a value, not 'not recorded'; empty "
                "STEM-detector and camera names fall through to the commercial name; 'Spectra   ' is trimmed")

    # Rule (b) applies to the converted number: the smallest double / 1e3 is 0.0 kV, and 1.7e308 m x 1e3 and 1.7e308 s
    # x 1e6 are inf. Each stored number is positive and finite; none may be shown.
    tiny_vals = {"Microscope type": "Realscope", "HT": 5e-324, "Camera length": 1.7e308, "Dwell time": 1.7e308}
    f = write_blob("planted-fei2-converted-to-zero.mrc", mrc_bytes(fei_record("FEI2", tiny_vals, list(tiny_vals))))
    add("planted-fei2-converted-to-zero", "mrc", truth(instrument=R("Realscope")), file=f,
        comment="a stored HT of 5e-324 V is 0.0 kV and a camera length / dwell of 1.7e308 is inf mm / us after the "
                "conversion: not recorded (rule b after the unit conversion)")

    f = write_blob("planted-fei2-bigendian.mrc", mrc_bytes(
        fei_record("FEI2", f_img_vals, img_written, end=">"), end=">", stamp=BE_STAMP))
    add("planted-fei2-bigendian", "mrc", img_truth, file=f,
        comment="machine stamp 11 11: mrcfile lays the record out big-endian with LITTLE-endian bitmasks "
                "(dtypes.py, 'mixed-endian'); the same content as planted-fei2-imaging")

    fei1_vals = {"Timestamp": ole_days(datetime(2021, 11, 12, 13, 14, 15, 350000)), "Microscope type": "Tecnai",
                 "HT": 120000.0, "Instrument mode": 3, "Magnification": 8000.0, "Camera length": 0.15,
                 "Integration time": 0.125, "Camera name": "BM-Ceta", "Dwell time": 2e-06}
    f = write_blob("planted-fei1.mrc", mrc_bytes(fei_record("FEI1", fei1_vals, list(fei1_vals)), kind="FEI1"))
    add("planted-fei1", "mrc", truth(
        highTensionKV=R(120.0), magnification=R(8000.0), cameraLengthMM=R(150.0, NOMODE), detector=R("BM-Ceta"),
        dwellUS=R(2.0), exposureS=R(0.125, UNVAL), acquired=R("2021-11-12 13:14:15", WRITER),
        instrument=R("Tecnai"), mode=R("3", UNVAL)), file=f,
        comment="exttyp FEI1: the 768-byte record (the FEI2 fields up to Alpha tilt max)")

    # The seconds are TRUNCATED: a clock shows 12:00:07 until 12:00:08, and 23:59:59.99 does not roll the day over.
    trunc_vals = {"Timestamp": ole_days(datetime(2022, 12, 5, 12, 0, 7, 750000)), "HT": 200000.0,
                  "Instrument mode": 4, "Integration time": 0.25}
    f = write_blob("planted-fei2-seconds-truncated.mrc", mrc_bytes(fei_record("FEI2", trunc_vals, list(trunc_vals))))
    add("planted-fei2-seconds-truncated", "mrc", truth(
        highTensionKV=R(200.0), exposureS=R(0.25, UNVAL), acquired=R("2022-12-05 12:00:07", WRITER),
        mode=R("4", UNVAL)), file=f,
        comment="OLE date of 12:00:07.75 shows :07 (truncated, not rounded to :08); Integration time 0.25 s; mode 4")
    midnight_vals = {"Timestamp": ole_days(datetime(2022, 12, 31, 23, 59, 59, 990000)), "HT": 200000.0}
    f = write_blob("planted-fei2-midnight.mrc", mrc_bytes(fei_record("FEI2", midnight_vals, list(midnight_vals))))
    add("planted-fei2-midnight", "mrc", truth(
        highTensionKV=R(200.0), acquired=R("2022-12-31 23:59:59", WRITER)), file=f,
        comment="OLE date of 23:59:59.99 shows 23:59:59 on the same day")

    f = write_blob("planted-mrc-no-extended-header.mrc", mrc_bytes(None, exttyp=b"\0\0\0\0", nsymbt=0))
    add("planted-mrc-no-extended-header", "mrc", truth(), file=f, comment="a plain MRC: nothing recorded")
    f = write_blob("planted-mrc-other-exttyp.mrc", mrc_bytes(bytes((7 * i + 3) % 251 + 1 for i in range(1024)),
                                                             exttyp=b"CCP4"))
    add("planted-mrc-other-exttyp", "mrc", truth(), file=f,
        comment="exttyp CCP4 with 1024 non-zero bytes: not an FEI header, nothing recorded")
    full = mrc_bytes(fei_record("FEI2", f_img_vals, img_written))
    f = write_blob("planted-fei2-truncated-record.mrc", full[:1024 + 100])
    add("planted-fei2-truncated-record", "mrc", truth(), file=f, outcome="nilOrThrows",
        comment="exttyp FEI2, NSYMBT 888, the file ends 100 bytes into the record: refused or not recorded")
    f = write_blob("planted-mrc-not-mrc.mrc", bytes((13 * i + 5) % 256 for i in range(700)))
    add("planted-mrc-not-mrc", "mrc", truth(), file=f, outcome="nilOrThrows",
        comment="700 bytes that are not an MRC header: refused or not recorded")

    # The record must be the type it says: its own first int32 equals the layout's size (mrcfile's test), and the
    # extended header must hold a whole record. Each file carries a record with values and set bits, so a reader
    # without the check shows them.
    wrong = bytearray(fei_record("FEI2", f_img_vals, img_written))
    struct.pack_into("<i", wrong, 0, REC["FEI1"])
    f = write_blob("planted-fei2-wrong-record-size.mrc", mrc_bytes(bytes(wrong)))
    add("planted-fei2-wrong-record-size", "mrc", truth(), file=f, outcome="nilOrThrows",
        comment="exttyp FEI2 and 888 bytes, but the record's own size says 768 (a FEI1): not the type it claims, "
                "refused or not recorded")
    f = write_blob("planted-fei2-nsymbt-short.mrc",
                   mrc_bytes(fei_record("FEI2", f_img_vals, img_written), nsymbt=500))
    add("planted-fei2-nsymbt-short", "mrc", truth(), file=f, outcome="nilOrThrows",
        comment="NSYMBT 500 with a whole 888-byte record after the header: the extended header is shorter than a "
                "record, refused or not recorded")
    # FEI1 has no Detector commercial name (it starts at 804, past its 768 bytes), but its Bitmask 4 can say bit 7.
    # No camera or STEM detector name is written, so the name search reaches the commercial one.
    f = write_blob("planted-fei1-commercial-bit.mrc", mrc_bytes(
        fei_record("FEI1", {"HT": 120000.0}, ["HT", "Detector commercial name"]), kind="FEI1"))
    add("planted-fei1-commercial-bit", "mrc", truth(highTensionKV=R(120.0)), file=f,
        comment="FEI1 record whose Bitmask 4 bit 7 says a field that lies past the record: not read, no trap")

    # ---------------------------------------------------------------- DM tag maps (keys relative) --------------
    def dm(name, numbers, strings, tr, *, mutants=None, comment=""):
        add(name, "dm", tr, numbers=numbers, strings=strings, mutants=mutants, comment=comment)

    MI = "Microscope Info."
    DATE, TIME = "DataBar.Acquisition Date", "DataBar.Acquisition Time"
    EXP, EXP2 = "Acquisition.Parameters.Detector.exposure (s)", "DataBar.Exposure Time (s)"

    n1 = {MI + "Voltage": 200000.0, MI + "Indicated Magnification": 51.0, MI + "Actual Magnification": 83.0,
          MI + "STEM Camera Length": 255.0, EXP: 0.5, EXP2: 0.5}
    s1 = {MI + "Illumination Mode": "TEM", MI + "Imaging Mode": "IMAGING", MI + "Name": "FEI Tecnai",
          "Acquisition.Device.Name": "BM-UltraScan", DATE: "7/20/2015", TIME: "6:48:25 PM"}
    dm("planted-dm-tem-imaging-stem255", n1, s1, truth(
        highTensionKV=R(200.0), magnification=R(51.0), detector=R("BM-UltraScan", UNVAL), exposureS=R(0.5),
        acquired=R("2015-07-20 18:48:25", LOCAL), instrument=R("FEI Tecnai"), mode=R("TEM · IMAGING")),
        comment="TEM imaging with a stale STEM Camera Length of 255 (as test_dm_image_um_unit): not recorded")

    dm("planted-dm-sem-stemcl1",
       {MI + "Voltage": 3000.0, MI + "Indicated Magnification": 2500.0, MI + "STEM Camera Length": 1.0,
        "DigiScan.Sample Time": 10.0},
       {MI + "Illumination Mode": "SEM", MI + "Imaging Mode": "IMAGING", MI + "Name": "Zeiss SEM COM",
        DATE: "5/14/2021", TIME: "11:41:07 AM"},
       truth(highTensionKV=R(3.0), magnification=R(2500.0), dwellUS=R(10.0),
             acquired=R("2021-05-14 11:41:07", LOCAL), instrument=R("Zeiss SEM COM"), mode=R("SEM · IMAGING")),
       comment="SEM with a junk STEM Camera Length of 1.0 (as test-MonarcCL_mono-image): not recorded")

    d3 = {MI + "Voltage": 200000.0, MI + "Indicated Magnification": 320.0, MI + "Actual Magnification": 32.0,
          MI + "STEM Camera Length": 0.0, EXP: 0.2, EXP2: 0.2}
    s3 = {MI + "Illumination Mode": "TEM", MI + "Imaging Mode": "DIFFRACTION", MI + "Name": "FEI Tecnai",
          "Acquisition.Device.Name": "BM-UltraScan", DATE: "7/9/2014", TIME: "6:56:37 PM"}
    dm("planted-dm-tem-diffraction", d3, s3, truth(
        highTensionKV=R(200.0), cameraLengthMM=R(320.0, MM), detector=R("BM-UltraScan", UNVAL),
        exposureS=R(0.2), acquired=R("2014-07-09 18:56:37", LOCAL, MONTH_FIRST), instrument=R("FEI Tecnai"),
        mode=R("TEM · DIFFRACTION")),
        mutants={"dm-date-swapped": {"numbers": d3, "strings": {**s3, DATE: "9/7/2014"}}},
        comment="TEM diffraction: Indicated Magnification holds the camera length (320 mm assumed), magnification "
                "not recorded; 7/9/2014 is July 9 (month first assumed, both fields <= 12)")

    d4 = {MI + "Voltage": 200000.0, MI + "Indicated Magnification": 225000.0, MI + "Actual Magnification": 231000.5,
          MI + "STEM Camera Length": 135.0, "DigiScan.Sample Time": 3.5}
    s4 = {MI + "Illumination Mode": "STEM NANOPROBE", MI + "Imaging Mode": "DIFFRACTION",
          MI + "Name": "FEI Tecnai Remote", DATE: "8/8/2016", TIME: "4:26:37 PM"}
    dm("planted-dm-actual-ne-indicated", d4, s4, truth(
        highTensionKV=R(200.0), magnification=R(225000.0), cameraLengthMM=R(135.0, MM), dwellUS=R(3.5),
        acquired=R("2016-08-08 16:26:37", LOCAL, MONTH_FIRST), instrument=R("FEI Tecnai Remote"),
        mode=R("STEM NANOPROBE · DIFFRACTION")),
        mutants={"actual-for-indicated": {"numbers": {**d4, MI + "Indicated Magnification": 231000.5},
                                          "strings": s4}},
        comment="Actual Magnification 231000.5 differs from Indicated 225000: Indicated is shown (rule g); STEM: "
                "camera length 135 mm assumed")

    dm("planted-dm-exposure-copies-differ",
       {MI + "Voltage": 200000.0, EXP: 0.5, EXP2: 0.75},
       {MI + "Illumination Mode": "TEM", MI + "Imaging Mode": "IMAGING"},
       truth(highTensionKV=R(200.0), exposureS=R(0.5, other=0.75), mode=R("TEM · IMAGING")),
       comment="the two stored exposures differ: the detector's first, the DataBar's kept beside it (rule f)")
    dm("planted-dm-exposure-copies-agree",
       {MI + "Voltage": 200000.0, EXP: 0.5, EXP2: 0.5000001},
       {MI + "Illumination Mode": "TEM", MI + "Imaging Mode": "IMAGING"},
       truth(highTensionKV=R(200.0), exposureS=R(0.5), mode=R("TEM · IMAGING")),
       comment="the copies differ by 2e-7 relative, inside 1e-6: one value, no other copy")

    dm("planted-dm-zero-and-empty",
       {MI + "Voltage": 0.0, MI + "Indicated Magnification": 0.0, MI + "STEM Camera Length": 0.0,
        "DigiScan.Sample Time": 0.0, EXP: 0.0},
       {MI + "Illumination Mode": "STEM", MI + "Imaging Mode": "", MI + "Name": "", "Acquisition.Device.Name": "",
        DATE: "", TIME: ""},
       truth(mode=R("STEM")),
       comment="zero quantities and empty strings: not recorded; the mode is the Illumination Mode alone")
    # Rule (b) after the unit conversion: the Voltage is stored in V and shown in kV, so 5e-324 V is 0.0 kV (a huge
    # voltage stays finite after /1e3). The other DM quantities are shown in the unit they are stored in.
    dm("planted-dm-converted-to-zero",
       {MI + "Voltage": 5e-324},
       {MI + "Illumination Mode": "TEM", MI + "Imaging Mode": "IMAGING"},
       truth(mode=R("TEM · IMAGING")),
       comment="a stored Voltage of 5e-324 V is 0.0 kV after the /1e3: not recorded (rule b after the unit conversion)")
    dm("planted-dm-converted-finite",
       {MI + "Voltage": 1e306},
       {MI + "Illumination Mode": "TEM", MI + "Imaging Mode": "IMAGING"},
       truth(highTensionKV=R(1e306 / 1e3), mode=R("TEM · IMAGING")),
       comment="a stored Voltage of 1e306 V is 1e303 kV: still finite and positive after the /1e3, so recorded")
    dm("planted-dm-garbage-date",
       {MI + "Voltage": 200000.0},
       {MI + "Name": "  Padded Scope  ", DATE: "not a date", TIME: "x"},
       truth(highTensionKV=R(200.0), instrument=R("Padded Scope")),
       comment="an unparseable date is not recorded; a name is trimmed")
    dm("planted-dm-date-no-time",
       {MI + "Voltage": 120000.0},
       {DATE: "7/20/2015", TIME: ""},
       truth(highTensionKV=R(120.0)),
       comment="a date without a time: the acquisition date is not recorded (rule e; RosettaSciIO would map the date "
               "alone)")
    dm("planted-dm-day-first",
       {MI + "Voltage": 120000.0},
       {DATE: "25/12/2019", TIME: "9:05:00 AM"},
       truth(highTensionKV=R(120.0), acquired=R("2019-12-25 09:05:00", LOCAL)),
       comment="a first field above 12 is a day: no day/month note")
    dm("planted-dm-stackbuilder-source-only",
       {"source.Tags at creation." + MI + "Voltage": 200000.0,
        "source.Tags at creation." + MI + "Indicated Magnification": 200000.0,
        "source.Tags at creation." + MI + "STEM Camera Length": 15.0,
        "source.Tags at creation.DigiScan.Sample Time": 30000.05078125},
       {"source.Tags at creation." + MI + "Illumination Mode": "STEM",
        "source.Tags at creation." + MI + "Imaging Mode": "MAG",
        "source.Tags at creation." + MI + "Name": "JEOL COM",
        "source.Tags at creation." + DATE: "5/17/2015", "source.Tags at creation." + TIME: "5:00:16 PM"},
       truth(highTensionKV=R(200.0), magnification=R(200000.0), cameraLengthMM=R(15.0, MM),
             dwellUS=R(30000.05078125), acquired=R("2015-05-17 17:00:16", LOCAL), instrument=R("JEOL COM"),
             mode=R("STEM · MAG")),
       comment="a stack-builder object keeps the acquisition tags under source.Tags at creation. (as "
               "test_stackbuilder_imagestack.dm3): read there when the top level has none")
    # The instrument, RosettaSciIO's order (_api.py:820-837 behind the :963 gate): Session Info.Microscope, then
    # Microscope Info.Name, then Microscope Info.Microscope; an empty value and the text "[]" are passed over. The
    # truth below is written from that rule, one object per step of the chain.
    SESSION = "Session Info.Microscope"
    dm("planted-dm-instrument-session-first", {MI + "Voltage": 200000.0},
       {SESSION: "FEI Titan", MI + "Name": "FEI Tecnai Remote", MI + "Microscope": "Third Scope"},
       truth(highTensionKV=R(200.0), instrument=R("FEI Titan")),
       comment="all three locations written: the name typed into GMS wins over the COM interface name")
    dm("planted-dm-instrument-session-empty", {MI + "Voltage": 200000.0},
       {SESSION: "", MI + "Name": "Zeiss SEM COM", MI + "Microscope": "Third Scope"},
       truth(highTensionKV=R(200.0), instrument=R("Zeiss SEM COM")),
       comment="Session Info.Microscope written but empty (as test-MonarcCL_mono-image): Microscope Info.Name is read")
    dm("planted-dm-instrument-session-brackets", {MI + "Voltage": 200000.0},
       {SESSION: "[]", MI + "Name": "Zeiss SEM COM"},
       truth(highTensionKV=R(200.0), instrument=R("Zeiss SEM COM")),
       comment="the text [] is passed over like an empty one")
    dm("planted-dm-instrument-session-blank", {MI + "Voltage": 200000.0},
       {SESSION: " \t ", MI + "Name": "  Padded Scope\n"},
       truth(highTensionKV=R(200.0), instrument=R("Padded Scope")),
       comment="a whitespace-only Session Info.Microscope is empty (rule a), the next name is read and trimmed; "
               "RosettaSciIO returns the blank text as written (the one override)")
    dm("planted-dm-instrument-third-location", {MI + "Voltage": 200000.0},
       {SESSION: "", MI + "Name": "[]", MI + "Microscope": "Third Scope"},
       truth(highTensionKV=R(200.0), instrument=R("Third Scope")),
       comment="Session and Name unusable: Microscope Info.Microscope is read")
    dm("planted-dm-instrument-all-empty", {MI + "Voltage": 200000.0},
       {SESSION: "[]", MI + "Name": "", MI + "Microscope": "  "},
       truth(highTensionKV=R(200.0)),
       comment="no usable location: not recorded, never an empty text or []")
    dm("planted-dm-instrument-session-without-group", {"DigiScan.Sample Time": 10.0},
       {SESSION: "FEI Titan", "Session Info.Operator": "someone"},
       truth(dwellUS=R(10.0)),
       comment="RosettaSciIO maps the microscope only inside an existing Microscope Info group (:963): "
               "a Session Info.Microscope alone is not recorded")
    dm("planted-dm-stackbuilder-session",
       {"source.Tags at creation." + MI + "Voltage": 200000.0},
       {"source.Tags at creation." + MI + "Name": "JEOL COM", "source.Tags at creation." + SESSION: "JEM-ARM200F"},
       truth(highTensionKV=R(200.0), instrument=R("JEM-ARM200F")),
       comment="a stack-builder object (as test_stackbuilder_imagestack.dm3): both names under source.Tags at "
               "creation., the session name wins")
    dm("planted-dm-no-tags", {}, {}, truth(), comment="an object with no ImageTags: nothing recorded")

    # ---------------------------------------------------------------- slice S-b: read(path:) end to end ----------
    # What AcquisitionMetadata.read(path:) shows for a FILE: a DM4 whose object the open would show (the same maps and
    # truth as the S-a plants above, written into a file), and a TIFF holding a DM tag stream in tag 65027. `numbers` /
    # `strings` are the maps of the SHOWN object as the writer was told them (the tag walker has to return exactly
    # these: keys relative to ImageList.N.ImageTags.); `nul` lists strings written with a trailing NUL unit, which the
    # walker drops and the declared maps do not carry. Truth is hand-written, as above.
    reads = []

    def read_plant(name, fmt, tr, *, file, via=None, object=None, openable=None, numbers=None, strings=None, nul=(),
                   block=None, entry=None, isolate=False, mutants=None, comment=""):
        # `entry`: the geometry of a tag-65027 entry written by hand (type, count, offset, file size), which reference.py
        # reads back from the bytes and requires to be as declared. `isolate`: the harness runs the case in a child process,
        # so a reader that TRAPS on it is a failed check of the harness, not a lost run.
        reads.append({"name": name, "format": fmt, "file": file, "via": via, "object": object, "openable": openable,
                      "numbers": numbers, "strings": strings, "nul": sorted(nul), "block": block, "entry": entry,
                      "isolate": isolate, "truth": tr, "mutants": mutants or {}, "comment": comment})

    def dm4_path(name):
        return os.path.join(out, name + ".dm4")

    SBC = "source.Tags at creation."
    # The truth of the maps n1/s1 and d4/s4 above (the S-a plants planted-dm-tem-imaging-stem255 and
    # planted-dm-actual-ne-indicated): the same hand arithmetic, restated for the file cases.
    truth_n1 = truth(highTensionKV=R(200.0), magnification=R(51.0), detector=R("BM-UltraScan", UNVAL),
                     exposureS=R(0.5), acquired=R("2015-07-20 18:48:25", LOCAL), instrument=R("FEI Tecnai"),
                     mode=R("TEM · IMAGING"))
    truth_d4 = truth(highTensionKV=R(200.0), magnification=R(225000.0), cameraLengthMM=R(135.0, MM), dwellUS=R(3.5),
                     acquired=R("2016-08-08 16:26:37", LOCAL, MONTH_FIRST), instrument=R("FEI Tecnai Remote"),
                     mode=R("STEM NANOPROBE · DIFFRACTION"))

    # C4. A thumbnail, a spectrum-image decoy ahead of the shown image (another voltage, the STEM mode: a reader that
    # takes the first object that is not the thumbnail shows 300 kV and a camera length), then the image the open shows.
    decoy_n = {MI + "Voltage": 300000.0, MI + "Indicated Magnification": 225000.0, MI + "STEM Camera Length": 135.0,
               "DigiScan.Sample Time": 7.0}
    decoy_s = {MI + "Illumination Mode": "STEM", MI + "Imaging Mode": "MAG", MI + "Name": "Decoy Scope",
               "Meta Data.Format": "Spectrum image"}
    write_gms(dm4_path("planted-dm4-two-objects"), [
        dm_thumbnail(), dm_image("SI decoy", tag_tree(decoy_n, decoy_s)), dm_image("shown", tag_tree(n1, s1))])
    read_plant("planted-dm4-two-objects", "dm4", truth_n1, file="planted-dm4-two-objects.dm4", object=3, openable=True,
               numbers=n1, strings=s1,
               comment="ImageList.1 the thumbnail, .2 a spectrum-image decoy (300 kV, STEM, tagged Spectrum image), .3 "
                       "the image the open shows (200 kV, TEM imaging): the maps and the reading are the shown "
                       "object's")

    # A ushort date with and without its trailing NUL unit (GMS writes fixed-width string fields): the walker drops
    # every zero unit, so both read the same date. 7/9/2014 is July 9: both fields <= 12, so the order note too.
    dn = {MI + "Voltage": 200000.0}
    ds = {MI + "Illumination Mode": "TEM", MI + "Imaging Mode": "IMAGING", DATE: "7/9/2014", TIME: "6:56:37 PM"}
    truth_date = truth(highTensionKV=R(200.0), acquired=R("2014-07-09 18:56:37", LOCAL, MONTH_FIRST),
                       mode=R("TEM · IMAGING"))
    for stem, nul in (("planted-dm4-date-nul", (DATE, TIME)), ("planted-dm4-date-no-nul", ())):
        write_gms(dm4_path(stem), [dm_thumbnail(), dm_image("shown", tag_tree(dn, ds, nul=nul))])
        read_plant(stem, "dm4", truth_date, file=stem + ".dm4", object=2, openable=True, numbers=dn, strings=ds, nul=nul,
                   comment="the date and the time as a uint16 array " + ("with" if nul else "without") +
                           " a trailing NUL unit: 2014-07-09 18:56:37 either way")

    # The stack builder keeps the acquisition tags only under source.Tags at creation.: read there when the top level
    # has none (the same maps as the S-a plant planted-dm-stackbuilder-source-only, in a file the open shows).
    sb_n = {SBC + MI + "Voltage": 200000.0, SBC + MI + "Indicated Magnification": 200000.0,
            SBC + MI + "STEM Camera Length": 15.0, SBC + "DigiScan.Sample Time": 30000.05078125}
    sb_s = {SBC + MI + "Illumination Mode": "STEM", SBC + MI + "Imaging Mode": "MAG", SBC + MI + "Name": "JEOL COM",
            SBC + DATE: "5/17/2015", SBC + TIME: "5:00:16 PM"}
    write_gms(dm4_path("planted-dm4-creation-only"), [dm_thumbnail(), dm_image("shown", tag_tree(sb_n, sb_s))])
    read_plant("planted-dm4-creation-only", "dm4", truth(
        highTensionKV=R(200.0), magnification=R(200000.0), cameraLengthMM=R(15.0, MM), dwellUS=R(30000.05078125),
        acquired=R("2015-05-17 17:00:16", LOCAL), instrument=R("JEOL COM"), mode=R("STEM · MAG")),
        file="planted-dm4-creation-only.dm4", object=2, openable=True, numbers=sb_n, strings=sb_s,
        comment="the acquisition tags only under source.Tags at creation.: the walker keeps those keys relative "
                "(source.Tags at creation.Microscope Info.Voltage), the rules fall back to them")

    # A label that is valid UTF-8 and not ASCII ("Field of View (µm)", the µ written as the two bytes C2 B5): ncempy reads
    # it as the Latin-1 text "Âµ" and the walker as "µ" (C2 step (i)). The real files' labels are the other case, a lone
    # 0xB5 byte, which the dm4 writer cannot write.
    un = {MI + "Voltage": 200000.0, MI + "Field of View (\u00b5m)": 0.5}
    us = {MI + "Illumination Mode": "TEM", MI + "Imaging Mode": "IMAGING"}
    write_gms(dm4_path("planted-dm4-utf8-label"), [dm_thumbnail(), dm_image("shown", tag_tree(un, us))])
    read_plant("planted-dm4-utf8-label", "dm4", truth(highTensionKV=R(200.0), mode=R("TEM \u00b7 IMAGING")),
               file="planted-dm4-utf8-label.dm4", object=2, openable=True, numbers=un, strings=us,
               comment="a tag label with a UTF-8 micro sign (C2 B5): the walker's key is the text it spells")

    write_gms(dm4_path("planted-dm4-no-tags"), [dm_thumbnail(), dm_image("shown", tag_tree({}, {}))])
    read_plant("planted-dm4-no-tags", "dm4", truth(), file="planted-dm4-no-tags.dm4", object=2, openable=True,
               numbers={}, strings={}, comment="the shown image has an empty ImageTags: nothing recorded, never 0")

    # A file with no object the open shows: a thumbnail and a [170, 1] line scan that states 200 kV. The open refuses
    # it, so nothing is described: a reader that took the line scan would show 200 kV.
    ls_n = {MI + "Voltage": 200000.0, MI + "Indicated Magnification": 50000.0}
    ls_s = {MI + "Illumination Mode": "TEM", MI + "Imaging Mode": "IMAGING"}
    write_gms(dm4_path("planted-dm4-no-primary-object"), [
        dm_thumbnail(), dm_image("line scan", tag_tree(ls_n, ls_s), dims=(170, 1))])
    read_plant("planted-dm4-no-primary-object", "dm4", truth(), file="planted-dm4-no-primary-object.dm4",
               object=None, openable=False,
               comment="a thumbnail and a [170, 1] line scan that states 200 kV: the open shows no image, so the file "
                       "describes none (nothing recorded)")

    # ImageList.1 shown (no thumbnail list) and ImageList.2 .. .11 other objects: with two-digit indices, a walker whose
    # object prefix is "ImageList.1" (no trailing dot) also collects the tags of .10 and .11, which carry keys of their own.
    ten = [dm_image("shown", tag_tree(n1, s1), uid=(1, 1, 1, 1))]
    for k in range(2, 12):
        extra_n = {MI + "Voltage": 300000.0 + 1000.0 * k, f"Decoy.Marker {k}": float(k)}
        ten.append(dm_image(f"other {k}", tag_tree(extra_n, {"Meta Data.Format": "Spectrum image"}),
                            dims=(3, 2), uid=(k, 2, 3, 4)))
    write_gms(dm4_path("planted-dm4-eleven-objects"), ten, thumbnails=False)
    read_plant("planted-dm4-eleven-objects", "dm4", truth_n1, file="planted-dm4-eleven-objects.dm4", object=1,
               openable=True, numbers=n1, strings=s1,
               comment="eleven objects, the shown one first; ImageList.10 and .11 carry a voltage and marker keys of "
                       "their own that ImageList.1 must not collect (the prefix ends with a dot)")

    # C5 / M6. A DM-saved TIFF holds the ImageTags as a DM4 stream in private tag 65027 (type 1, BYTE).
    stream_d4 = tag_stream(d4, s4)
    f = write_tiff("planted-tiff-65027-dm", [(65027, "B", len(stream_d4), stream_d4, True)])
    read_plant("planted-tiff-65027-dm", "tiff", truth_d4, file=f, via="dm-block", block={"numbers": d4, "strings": s4},
               comment="tag 65027 (type 1) holds a DM4 stream of the maps d4/s4 and none of 34680, 34682, 34683 exists: "
                       "read with the DM rules (STEM, camera length 135 mm assumed, month-first order assumed)")
    # Precedence FEI SEM, Velox, DM: a file with a Velox or an FEI tag is read as that, whatever else it carries.
    hv_n = {MI + "Voltage": 120000.0}
    hv_s = {MI + "Illumination Mode": "TEM", MI + "Imaging Mode": "IMAGING"}
    stream_120 = tag_stream(hv_n, hv_s)
    velox_xml_text = velox_xml(velox_tree(ht="200000")) + "\0"
    f = write_tiff("planted-tiff-velox-and-dm", [(34683, "s", 0, velox_xml_text, True),
                                                  (65027, "B", len(stream_120), stream_120, True)])
    f_dm_only = write_tiff("planted-tiff-velox-and-dm.tiff-dm-before-velox",
                           [(65027, "B", len(stream_120), stream_120, True)])
    read_plant("planted-tiff-velox-and-dm", "tiff", truth(
        highTensionKV=R(200.0), detector=R("BM-Ceta", UNVAL), acquired=R("2025-03-04 09:08:07", LOCAL, UNVAL),
        instrument=R("Themis Z", UNVAL), mode=R("TEM", UNVAL)), file=f, via="velox",
        block={"numbers": hv_n, "strings": hv_s}, mutants={"tiff-dm-before-velox": {"file": f_dm_only}},
        comment="tag 34683 (200 kV, Velox) and tag 65027 (120 kV, DM): Velox is read, the DM tree is not; the "
                "mutant's twin has the DM tag only")
    f = write_tiff("planted-tiff-fei-and-dm", [(34682, "s", 0, ini("30000") + "\0", True),
                                                (65027, "B", len(stream_120), stream_120, True)])
    read_plant("planted-tiff-fei-and-dm", "tiff", truth(
        highTensionKV=R(30.0), dwellUS=R(10.0), acquired=R("2022-05-17 09:07:08", LOCAL),
        instrument=R("Quanta 250 FEG"), detector=R("ETD", UNVAL)), file=f, via="fei",
        block={"numbers": hv_n, "strings": hv_s},
        comment="tag 34682 (30 kV, FEI SEM) and tag 65027 (120 kV, DM): the FEI SEM INI is read, the DM tree is not")
    # The Velox convention is the EXISTENCE of tag 34683: one that is not text (a SHORT here) still closes the DM tree off.
    f = write_tiff("planted-tiff-velox-tag-not-text-and-dm", [(34683, "H", 1, 7, True),
                                                               (65027, "B", len(stream_120), stream_120, True)])
    read_plant("planted-tiff-velox-tag-not-text-and-dm", "tiff", truth(), file=f, via="dm-block",
               block={"numbers": hv_n, "strings": hv_s},
               comment="tag 34683 exists but is a SHORT, not text, beside a 120 kV DM block: the DM tree is read only when "
                       "none of 34680, 34682, 34683 EXISTS, so nothing is recorded")
    # Only a BYTE (type 1) block that the tag walker accepts is read; anything else reads empty, never throws.
    f = write_tiff("planted-tiff-65027-type-undefined", [(65027, 7, len(stream_d4), stream_d4, True)])
    read_plant("planted-tiff-65027-type-undefined", "tiff", truth(), file=f, via="dm-block",
               block={"numbers": d4, "strings": s4},
               comment="the same DM4 stream in tag 65027 as type 7 (UNDEFINED), not type 1: not read, nothing recorded")
    garbage = bytes((13 * i + 5) % 256 for i in range(600))
    f = write_tiff("planted-tiff-65027-garbage", [(65027, "B", len(garbage), garbage, True)])
    read_plant("planted-tiff-65027-garbage", "tiff", truth(), file=f, via="dm-block",
               comment="600 bytes that are no DM stream in tag 65027 (type 1): the walker refuses, nothing recorded")
    cut = stream_d4[:300]
    f = write_tiff("planted-tiff-65027-truncated", [(65027, "B", len(cut), cut, True)])
    read_plant("planted-tiff-65027-truncated", "tiff", truth(), file=f, via="dm-block",
               comment="the first 300 bytes of a DM4 stream in tag 65027 (type 1): cut mid-tree, the walker refuses, "
                       "nothing recorded")

    # A block that must lie wholly inside the file: an entry whose COUNT runs past the last byte is refused (FormatoTIFF's
    # TIFFFile throws truncated; read(path:) shows it as empty), never clamped to the bytes that are there and never trapped on
    # (a slice of the file out of range traps). tifffile writes
    # only consistent files, so these two are written byte by byte: little-endian, the header, a directory of ONE entry
    # (tag 65027, type 1) at offset 8, the value at offset 26 (just after the directory), and nothing after the payload.
    def write_overrunning(name, payload, count):
        blob = (b"II" + struct.pack("<HI", 42, 8) + struct.pack("<H", 1) + struct.pack("<HHII", 65027, 1, count, 26)
                + struct.pack("<I", 0) + payload)
        assert len(blob) == 26 + len(payload)
        return write_blob(name + ".tif", blob), {"type": 1, "count": count, "offset": 26, "size": len(blob)}
    f, geometry = write_overrunning("planted-tiff-65027-overruns-by-one", stream_120, len(stream_120) + 1)
    read_plant("planted-tiff-65027-overruns-by-one", "tiff", truth(), file=f, via="dm-block", entry=geometry, isolate=True,
               comment=f"a COMPLETE 120 kV DM stream of {len(stream_120)} bytes at the end of the file, and tag 65027 "
                       "(type 1) says it has one byte more: the block does not lie inside the file, so nothing is "
                       "recorded (a reader that clamped the count to the file would show 120 kV; one that sliced the "
                       "file out of range would trap)")
    f, geometry = write_overrunning("planted-tiff-65027-overruns-far", stream_120[:74], 5000)
    assert geometry["size"] == 100, "the far plant is a 100-byte file"
    read_plant("planted-tiff-65027-overruns-far", "tiff", truth(), file=f, via="dm-block", entry=geometry, isolate=True,
               comment="a 100-byte file whose tag 65027 (type 1) says 5000 bytes at offset 26 and 74 follow, the first 74 "
                       "bytes of the 120 kV stream: cut mid-tree and far past the end, nothing recorded (the geometry "
                       "on which the Gate B review made the unguarded reader trap)")

    # C6. The extension picks the reader (as ImageOpening.openNow does, case-insensitively): a Velox TIFF named .tiff and
    # .TIF, an MRC named .MRC and the two-object DM4 named .DM4 read as their .tif / .mrc / .dm4 originals do.
    def renamed(src_name, new_name, ext, *, fmt, via=None):
        src = next(c for c in (cases if fmt != "dm4" else reads) if c["name"] == src_name)
        shutil.copyfile(os.path.join(out, src["file"]), os.path.join(out, new_name + ext))
        entry = {k: v for k, v in src.items() if k != "mutants"}
        entry.update({"name": new_name, "file": new_name + ext, "format": fmt, "via": via, "mutants": {},
                      "comment": f"{src_name} under the extension {ext}: the extension picks the reader, "
                                 f"whatever its case"})
        if fmt == "dm4":
            reads.append({**entry, "nul": list(src["nul"]), "block": None})
        else:
            reads.append({"name": new_name, "format": fmt, "file": new_name + ext, "via": via, "object": None,
                          "openable": None, "numbers": None, "strings": None, "nul": [], "block": None,
                          "truth": src["truth"], "mutants": {}, "comment": entry["comment"]})
    renamed("planted-velox-diffraction", "planted-ext-tiff", ".tiff", fmt="tiff", via="velox")
    renamed("planted-velox-diffraction", "planted-ext-upper-TIF", ".TIF", fmt="tiff", via="velox")
    renamed("planted-fei2-stem", "planted-ext-upper-MRC", ".MRC", fmt="mrc", via="mrc")
    renamed("planted-dm4-two-objects", "planted-ext-upper-DM4", ".DM4", fmt="dm4")

    with open(os.path.join(out, "planted.json"), "w") as fh:
        json.dump({"layout": {"offsets": OFF, "bits": {k: list(v) for k, v in BITS.items()}, "records": REC},
                   "cases": cases, "reads": reads}, fh, indent=1, ensure_ascii=False)
    print(f"make_fixture.py: {len(cases)} planted cases and {len(reads)} read(path:) plants in {out}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
