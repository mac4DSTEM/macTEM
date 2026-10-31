#!/usr/bin/env python3
"""Truth for tools/parity/metadata-parity: the pinned references' reading of every case, as the registered expectations.

    reference.py <planted-dir> <rsciio-root> <owner-dir-or-"-"> <out-dir>

The Metadata panel's compute core. The Swift code under test is
AcquisitionMetadata.tiff(data:), .mrc(data:), .dm(numbers:strings:); this script never re-implements it. It builds, per
case, the nine fields' expected readings from the PINNED REFERENCES, then states each place where the registered rules
deliberately differ as a named, commented OVERRIDE step. Where no pinned reference reads a path at all (policies (i), (j),
(k), (m) below) the rule is macTEM's own and is restated here in Python: it is held to the truth hand-written in the
plants, not to an independent reader.

References (versions and source hashes asserted below, as tools/parity/export-parity/reference.py does for dm.py):
  DM       ncempy 1.16 `fileDM(...).allTags` for the tag maps (the sha256 of ncempy/io/dm.py pinned); RosettaSciIO
           049e7d70 `rsciio/digitalmicrograph/_api.py` -- `ImageObject.get_mapping()`, RosettaSciIO's own method,
           applied to those tags (below, "How the DM mapping is applied"); dateutil for the date text (through it).
  FEI SEM  RosettaSciIO 049e7d70 `rsciio.tiff.file_reader` on the file: its `mapping_fei` (beam_energy kV, dwell_time
           s, General.date / General.time, microscope) applied to its original_metadata; the detector name from the
           same original_metadata (`fei_metadata.Detectors.Name`; mapped by no reference, so labelled unvalidated).
  Velox    tifffile 2026.9.20 for tag 34683's text, xml.etree for the XML (xml.parsers.expat for the guard, policy
           (m)); the two conversions RosettaSciIO applies to
           the same schema (`rsciio/emd/_emd_velox.py:938-945`: AccelerationVoltage / 1e3, CameraLength * 1e3) are
           EXTRACTED FROM THAT FILE by ast and run as written -- not retyped. Every other Velox field has no published
           reader: the registered path is read from the XML text, the value labelled unvalidated.
  MRC      mrcfile 1.5.4: `MrcFile.indexed_extended_header` with its own FEI1 / FEI2 dtype (the byte order follows the
           machine stamp: dtypes.get_ext_header_dtype), the four bitmasks. The date is the one place mrcfile says
           too little: override (h) below.

How the DM mapping is applied. `rsciio.digitalmicrograph._api` imports `memmap_distributed` from `rsciio.utils.file`,
whose only job is dask; dask is not in the lock and `get_mapping` never calls it. DEVIATION: the module
`rsciio.utils.file` is replaced in sys.modules by an empty stand-in carrying a `memmap_distributed = None` before
`_api` is imported; `ImageObject.get_mapping` and the helpers it calls (`_get_date`, `_get_time`, `_get_mode`,
`_get_microscope_name`) are then RosettaSciIO's own, unmodified (their file's sha256 is pinned here). RosettaSciIO
returns a mapping {path in original_metadata: (target, function)}; it is HyperSpy that applies it, and HyperSpy is not in
the lock, so `apply_mapping` below does the join: walk the path through the tag tree, key by key, with HyperSpy's key
normalisation (spaces become "_", every other non-word character is dropped; applied to the mapping's keys AND the
tag names, so "exposure (s)" meets the mapping's "exposure_s"), call the mapping's function, keep a non-None result;
an exception inside a function is "no value" (HyperSpy would stop; either way nothing is invented). Only the join is
this script's; every function applied is RosettaSciIO's.

Overrides, each named where it is applied (the rules, AcquisitionMetadata.swift a-g):
  (b) a strictly positive quantity stored as 0, negative or non-finite is not recorded (RosettaSciIO would map the 0);
      in every format after the unit conversion (a stored 5e-324 V is 0.0 kV, a 1.7e308 m is inf mm) — one named
      exception, the DM dwell (see its branch);
  (c) a DM camera length only in STEM (Illumination Mode starts "STEM") or TEM + DIFFRACTION (from Indicated
      Magnification): RosettaSciIO maps `STEM Camera Length` in every other mode too (SEM files: junk 0 / 1). A Velox
      camera length only where ProjectorMode is Diffraction or OperatingMode is STEM: RosettaSciIO's EMD mapping
      (`_emd_velox.py:942-945`) applies no mode gate. An MRC camera length is shown as stored, with the note that the
      mode is not checked (no pinned reader or real file settles it);
  (d) a DM camera length is "mm (assumed)": the file stores no unit;
  (e) the date is `YYYY-MM-DD HH:MM:SS` (RosettaSciIO's two isoformat strings joined), noted "local time, zone not
      stored" (Velox, DM, FEI SEM) or "clock of the writer, zone not stored" (MRC); "month-first order assumed" when
      both of a DM date's first two fields are <= 12 (a FEI SEM date is month-first by format: no order note). A date
      without a time, or a time without a date, is NOT recorded in DM and FEI SEM (RosettaSciIO maps the date alone);
  (f) two stored copies differing by more than 1e-6 relative keep the other in otherCopy; a second Velox start stamp
      (a timestamp) is kept when it differs at the shown second, and a year before 1990 makes it an unset field, not
      a copy -- the Velox XML schema postdates 1990, and the sentinel form is inferred from same-schema EMD files
      (no Velox STEM TIFF exists here);
  (g) the Indicated magnification, never the Actual;
  (h) the MRC Timestamp is an OLE automation date, days since 1899-12-30: the registration's choice, which OVERRIDES
      mrcfile's comment "days after 1/1/1900" (dtypes.py:108; mrcfile never converts the field). The evidence is
      executable (`check_epoch_evidence`): on every real record whose int64 "Acquisition time stamp" (unix microseconds,
      UTC) is set, OLE minus unix is at most 14 h and a whole number of quarter hours, and the 1900-01-01 and 1904
      epochs fail that test;
  (i) a Velox exposure is the ExposureTime of the Detectors/* element whose DetectorName equals BinaryResult/Detector
      (macTEM policy: no published reader reads the TIFF path; RosettaSciIO's EMD mapping also finds a detector by
      name), never another detector's;
  (j) a Velox ProjectorMode / OperatingMode that opens the camera-length gate is matched without regard to case (macTEM
      policy: the registration states no case, no pinned reader reads ProjectorMode); the mode shown is the stored text;
  (k) see (f), the second start stamp;
  (l) an MRC mode is the stored Instrument-mode int32 as text, an MRC exposure the Integration time, both "unvalidated"
      (mrcfile lays the fields out; no published reader reads them);
  (m) a Velox document is read only if a guard passes (macTEM policy): a tag of at most 4 MiB, element depth at most 64,
      at most 1 MiB of character data, no entity declaration, well-formed; a string value over 256 characters is not
      recorded. A refused document reads empty. (The real Ceta XML: 14 KB, depth 6.)
  FEI SEM INI: tifffile's `read_fei_metadata` is the reference as it stands (a repeated key takes its last line, an
  empty one included; a repeated section replaces the earlier one) -- no override.
  DM instrument is RosettaSciIO's own: get_mapping maps the whole tag group to `_get_microscope_name` (first of
  `Session Info.Microscope`, `Microscope Info.Name`, `Microscope Info.Microscope` that is neither falsy nor "[]";
  only where a "Microscope Info" group exists, _api.py:820-837, :963, :1004-1011), and its value is the expectation
  as RosettaSciIO returns it. The one override is (a): RosettaSciIO returns a whitespace-only text as written (a
  truthy string); the registered rule treats it as empty, so the same mapping is applied to the tags with every
  string trimmed. A difference between the two readings is printed (it needs a whitespace-only name).
A mode, an exposure and the rest are the registered paths; see the functions.

Notes, exact texts: "local time, zone not stored" (a Velox, DM or FEI SEM date), "clock of the writer, zone not
stored" (an MRC date), "mm (assumed)" (DM camera length), "month-first order assumed" (DM date), "unvalidated: the
mode is not checked" (MRC camera length), "unvalidated: no published reader reads it" (a value whose path no pinned
reference maps), joined with "; " in that order.

Slice S-b (the DM wiring and tag 65027): the manifest gains `reads`, the cases of
AcquisitionMetadata.read(path:) end to end. For a real DM object: its ImageList number `n` (C1: the object the open shows),
ncempy's tag maps of that object after two NAMED normalisations (C2: `c2_maps`), and the expectation the S-a case already
holds (C3). For a DM4 file the plants wrote (C4): the maps and truth they declare, which ncempy's parse of the same file has
to confirm (one named step for the NUL a uint16 string keeps there). For a TIFF holding a DM tag stream in tag 65027 (C5):
ncempy's reading of the same bytes written to a temp file, put through the DM rules. The policies that no pinned reference
reads are restated here, as the Velox ones are: the registered object rule (`primary_object`), the order FEI SEM, Velox,
DM, and that only a BYTE (type 1) block is read.

Before any reading counts, the reference has to reproduce every PLANTED truth that make_fixture.py wrote (by hand, from
the rules): a reference that disagrees with the plant exits 1, loudly -- that is a reference check, never a pass. It also
checks, on the real files, what the readings rest on: the MRC bit assignment against every record and against the wrong
assignments (`bit_evidence`), the MRC epoch against the int64 stamp (`check_epoch_evidence`), and the hand-written
prediction for the DM-saved TIFF's tag 65027 (`PREDICTED_65027`, registered before the code).

Writes <out>/manifest.json (contract: README.md; `owner` says how many of the owner's six Ceta TIFFs were provisioned and
are cases) and <out>/expected.txt (the evidence lines above and the expected values of every real file, for a reader).
"""
import ast
import hashlib
import importlib.metadata
import json
import logging
import math
import os
import re
import struct
import sys
import tempfile
import types
import warnings
import zipfile
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta
from xml.parsers import expat

import numpy as np
import tifffile
import mrcfile
from mrcfile import dtypes as mrc_dtypes
from ncempy.io import dm

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = os.path.join(HERE, "..", "..", "lib", "references-lock.txt")
PYTHON_MINOR = "3.14"
NCEMPY = "1.16"
DM_PY_SHA256 = "09edae58936747ae5c01437f0afb3bbee177746e3e30040b90817e24a47daa75"
TIFFFILE = "2026.9.20"
MRCFILE = "1.5.4"
RSCIIO_COMMIT = "049e7d70"
REGISTRY_SHA256 = "31417482938f80160be2c03525ba58dd810c7f16b1790f597470ece8dd0b1bcb"
RSCIIO_SOURCES = {   # sha256 of the RosettaSciIO sources this script runs or extracts from (commit 049e7d70)
    "rsciio/digitalmicrograph/_api.py": "a97cacf159869e436f2b1c051efd505bf68ac2241722e7e7f74688092a4efe8b",
    "rsciio/tiff/_api.py": "d53a6bc3256e3b8fe38d7c7e0ec061554aee86346701c024ee6de1dfeeaa8f2a",
    "rsciio/emd/_emd_velox.py": "1a3e12f2d550c5378c5e3ee0e02c963f0ef547af9dd4bde9bd1c2ee2df56a8e3",
}

LOCAL = "local time, zone not stored"
WRITER = "clock of the writer, zone not stored"
MM = "mm (assumed)"
MONTH_FIRST = "month-first order assumed"
NOMODE = "unvalidated: the mode is not checked"
UNVAL = "unvalidated: no published reader reads it"
# The Velox document guard (policy (m)) and the second-stamp floor (policy (f)/(k)).
MAX_TAG_BYTES = 4 * 1024 * 1024
MAX_DEPTH = 64
MAX_CHARS = 1024 * 1024
MAX_VALUE = 256
FLOOR_YEAR = 1990
FIELDS = ["highTensionKV", "magnification", "cameraLengthMM", "detector", "dwellUS", "exposureS", "acquired",
          "instrument", "mode"]

# Real files. DM: (path under rsciio/tests/data); every one holds exactly one non-thumbnail 2D object, except the stack
# builder's file, which holds one 3-D object (the metadata rules read ImageTags and do not depend on the pixel dimensions).
# The 2 x 2 per-type GMS files (test-N.dm4/.dm3) carry no ImageTags at all: test-1.dm4 stands for them.
DM_FILES = [
    "digitalmicrograph/2D/test_STEM_image.dm3",
    "digitalmicrograph/2D/test_diffraction_pattern.dm3",
    "digitalmicrograph/2D/test_diffraction_pattern_tags_removed.dm3",
    "digitalmicrograph/2D/multi_signal.dm3",
    "digitalmicrograph/2D/test-MonarcCL_mono-image.dm4",
    "tiff/test_dm_image_um_unit.dm3",
    "digitalmicrograph/Fei HAADF-DE_location.dm3",
    "digitalmicrograph/Fei HAADF-FR_location.dm3",
    "digitalmicrograph/Fei HAADF-MX_location.dm3",
    "digitalmicrograph/Fei HAADF-UK_location.dm3",
    "digitalmicrograph/2D/test-1.dm4",
]
# The one real file whose acquisition tags sit under ImageTags.source.Tags at creation. (97 keys): the stack-builder
# fallback is gated on it (and on its planted twins).
DM_STACK_FILES = [("digitalmicrograph/test_stackbuilder_imagestack.dm3", 3)]
FEI_ZIP = "tiff/tiff_FEI_Helios.zip"
FEI_FILES = [  # member, case
    ("FEI-Helios-Ebeam-16bits.tif", "rsciio-fei-helios-ebeam-16bit"),
    ("FEI-Helios-Ebeam-8bits.tif", "rsciio-fei-helios-ebeam-8bit"),
    ("FEI-Helios-navcam.tif", "rsciio-fei-helios-navcam"),
    ("FEI-Helios-navcam-with-no-IRBeam.tif", "rsciio-fei-helios-navcam-no-irbeam"),
    ("FEI-Helios-navcam-with-no-IRBeam-bad-floats.tif", "rsciio-fei-helios-navcam-no-irbeam-bad-floats"),
]
MRC_FILES = [("mrc/HAADFscan.mrc", "rsciio-haadfscan"), ("mrc/4DSTEMscan.mrc", "rsciio-4dstemscan")]
OWNER_FILES = ["Camera Ceta 1305 17500 x 20260605 Ceta.tif", "Camera Ceta 1306 28500 x 20260605 Ceta.tif",
               "Camera Ceta 1309 36000 x 20260605 Ceta.tif", "Camera Ceta 1620 630 kx 20260605 Ceta.tif",
               "Camera Ceta 1623 1.05 Mx 20260605 Ceta.tif", "Camera Ceta 1631 1.05 Mx 20260605 Ceta.tif"]
# The owner's files are gitignored: they gate where they are provisioned (the only real Velox data), and are skipped,
# with a printed line and a count in the summary, where they are not.
# DM-saved TIFFs: the ImageTags tree is in tag 65027 (a DM4 byte stream whose root group IS the ImageTags). The stack file's
# block is an empty tree (0 tags, padded to 512 bytes).
DM_TIFF_65027 = [("tiff/test_loading_image_saved_with_DM.tif", "rsciio-dm-tiff-65027"),
                 ("tiff/test_loading_image_saved_with_DM_stack.tif", "rsciio-dm-tiff-65027-stack")]

warnings.filterwarnings("ignore", message="Setting the dtype on a NumPy array has been deprecated")
logging.disable(logging.CRITICAL)   # RosettaSciIO warns about the planted unparseable dates and the Helios pixel size


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


# ------------------------------------------------------------------------------------------------ the pins -------
def check_reference(root):
    python = "%d.%d" % sys.version_info[:2]
    if python != PYTHON_MINOR:
        fail(f"Python {python} is not the pinned {PYTHON_MINOR}")
    pins = {}
    for line in open(LOCK):
        m = re.match(r"^([A-Za-z0-9_.-]+)==(\S+)\s*$", line)
        if m:
            pins[m.group(1).lower()] = m.group(2)
    for package, want in (("ncempy", NCEMPY), ("tifffile", TIFFFILE), ("mrcfile", MRCFILE)):
        if pins.get(package) != want or importlib.metadata.version(package) != want:
            fail(f"{package} pinned {pins.get(package)}, installed {importlib.metadata.version(package)}, expected {want}")
    if tifffile.__version__ != TIFFFILE or mrcfile.__version__ != MRCFILE:
        fail("the tifffile / mrcfile imported is not the pinned one")
    for package in ("numpy", "python-dateutil", "python-box"):
        if importlib.metadata.version(package) != pins.get(package):
            fail(f"{package} {importlib.metadata.version(package)} is not the pinned {pins.get(package)}")
    if sha256_file(dm.__file__) != DM_PY_SHA256:
        fail(f"{dm.__file__} is not the pinned ncempy/io/dm.py (sha256 {DM_PY_SHA256[:16]}...)")
    if sha256_file(os.path.join(root, "rsciio", "tests", "registry.txt")) != REGISTRY_SHA256:
        fail("rsciio/tests/registry.txt is not the pinned file (References/rosettasciio is not the lock)")
    for rel, want in RSCIIO_SOURCES.items():
        if sha256_file(os.path.join(root, rel)) != want:
            fail(f"{rel} is not the file RosettaSciIO {RSCIIO_COMMIT} holds (sha256 {want[:16]}...)")
    return pins


def registry(root):
    reg = {}
    for line in open(os.path.join(root, "rsciio", "tests", "registry.txt")):
        m = re.match(r"^'([^']+)'\s+([0-9a-f]{64})\s*$", line)
        if m:
            reg[m.group(1)] = m.group(2)
    return reg


def import_rsciio(root):
    """-> (rsciio.tiff.file_reader, rsciio.digitalmicrograph._api, Box). See the module docstring for the one stand-in."""
    sys.path.insert(0, root)
    from rsciio.tiff import file_reader           # imports as it is: no stand-in needed
    stand_in = types.ModuleType("rsciio.utils.file")
    stand_in.memmap_distributed = None            # DEVIATION: dask is not in the lock; get_mapping never calls it
    sys.modules["rsciio.utils.file"] = stand_in
    import rsciio.digitalmicrograph._api as dm_api
    from box import Box
    for module in (dm_api, sys.modules["rsciio.tiff._api"]):
        if not os.path.realpath(module.__file__).startswith(os.path.realpath(root) + os.sep):
            fail(f"{module.__file__} is not under the pinned RosettaSciIO tree {root}")
    return file_reader, dm_api, Box


# ------------------------------------------------------------------------------------------------ small rules -----
def positive(v):
    """Rule (b): a strictly positive finite quantity, or None."""
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) and v > 0 else None


def text(s):
    """Rule (a): the string without surrounding whitespace, or None when nothing is left."""
    if s is None:
        return None
    s = str(s).strip()
    return s or None


def reading(value, *, mm=False, local=False, writer=False, month=False, nomode=False, unval=False, other=None):
    """One recorded value; notes joined in the registered order."""
    notes = [n for n, on in ((LOCAL, local), (WRITER, writer), (MM, mm), (MONTH_FIRST, month), (NOMODE, nomode),
                             (UNVAL, unval)) if on]
    return {"value": value, "note": "; ".join(notes) if notes else None, "otherCopy": other}


def differing(first, second):
    """Rule (f): `second` when it differs from `first` by more than 1e-6 relative, else None."""
    if second is None or not math.isfinite(second):
        return None
    scale = max(abs(first), abs(second))
    return second if scale > 0 and abs(first - second) > 1e-6 * scale else None


def blank():
    return {f: None for f in FIELDS}


# ------------------------------------------------------------------------------------------------ the DM join -----
def norm_key(key):
    """HyperSpy's DictionaryTreeBrowser key normalisation, as far as these paths need it."""
    return re.sub(r"[^0-9A-Za-z_]", "", str(key).replace(" ", "_"))


def nested_from_flat(flat):
    """{"a.b.c": v} -> {"a": {"b": {"c": v}}}; a tag name that is a leaf in one place and a group in another fails."""
    root = {}
    for key, val in flat.items():
        parts = key.split(".")
        d = root
        for p in parts[:-1]:
            d = d.setdefault(p, {})
            if not isinstance(d, dict):
                fail(f"tag path {key!r}: {p!r} is both a value and a group")
        if isinstance(d.get(parts[-1]), dict):
            fail(f"tag path {key!r} is both a value and a group")
        d[parts[-1]] = val
    return root


def apply_mapping(mapping, original):
    """The join RosettaSciIO leaves to HyperSpy: {target: function(value)} for every mapping path present.
    -> (results, errors) where errors lists (path, exception) of functions that raised (no value)."""
    out, errors = {}, []
    for path, (target, function) in mapping.items():
        node, found = original, True
        for part in path.split("."):
            if not hasattr(node, "keys"):
                found = False
                break
            hits = [k for k in node.keys() if norm_key(k) == norm_key(part)]
            if len(hits) > 1:
                fail(f"mapping path {path!r}: {part!r} matches several tag names {hits}")
            if not hits:
                found = False
                break
            node = node[hits[0]]
        if not found:
            continue
        try:
            value = function(node) if function else node
        except Exception as e:                     # a parser given text it cannot read: no value
            errors.append((path, repr(e)))
            continue
        if value is not None:
            out[target] = value
    return out, errors


def short_targets(results):
    """'Acquisition_instrument.TEM.beam_energy' -> 'instr.beam_energy'; one of TEM / SEM per object (asserted)."""
    out, scopes = {}, set()
    for target, value in results.items():
        m = re.match(r"^Acquisition_instrument\.(TEM|SEM)\.(.+)$", target)
        if m:
            scopes.add(m.group(1))
            out["instr." + m.group(2)] = value
        else:
            out[target] = value
    if len(scopes) > 1:
        fail(f"RosettaSciIO maps one object to both TEM and SEM: {sorted(scopes)}")
    return out


class DMReference:
    """RosettaSciIO's DM mapping applied to ncempy's tag maps, then the registered overrides."""

    def __init__(self, dm_api, Box):
        self.api, self.Box = dm_api, Box

    def rsciio(self, nested):
        """-> (mapped targets, errors). `nested` is the ImageTags tree."""
        image = self.api.ImageObject({"ImageTags": nested}, None)
        mapping = image.get_mapping()
        original = {"ImageList": {"TagGroup0": {"ImageTags": image.imdict.ImageTags}}}
        results, errors = apply_mapping(mapping, original)
        return short_targets(results), errors

    def expected(self, numbers, strings):
        """-> (the nine fields, a list of printed notes about where the registered rule differs from RosettaSciIO)."""
        flat = {**numbers, **strings}
        nested = nested_from_flat(flat)
        rs, errors = self.rsciio(nested)
        said = []
        # The stack builder keeps the acquisition tags under ImageTags.source.Tags at creation. RosettaSciIO then
        # reads ONLY that copy; the registration reads the top level and falls back to it. Both present: refused here.
        prefix = "source.Tags at creation." if ("source" in nested and "Tags at creation" in nested["source"]) else ""
        if prefix:
            top = [k for k in flat if not k.startswith("source.") and
                   k.split(".")[0] in ("Microscope Info", "DigiScan", "DataBar", "Acquisition")]
            if top:
                fail(f"an object with both a source.Tags at creation copy and top-level acquisition tags {top[:3]}")
        N = lambda name: numbers.get(prefix + name)
        S = lambda name: strings.get(prefix + name)
        out = blank()

        ill, img = text(S("Microscope Info.Illumination Mode")), text(S("Microscope Info.Imaging Mode"))
        diffraction_tem = ill == "TEM" and img == "DIFFRACTION"
        stem = ill is not None and ill.startswith("STEM")

        # high tension: RosettaSciIO Voltage / 1e3 (kV); override (b)
        ht = positive(rs.get("instr.beam_energy"))
        if rs.get("instr.beam_energy") is not None and ht is None:
            said.append(f"high tension: RosettaSciIO {rs['instr.beam_energy']!r} kV, registered: not recorded (b)")
        if ht is not None:
            out["highTensionKV"] = reading(ht)

        # magnification: RosettaSciIO's Indicated Magnification outside TEM + DIFFRACTION (g: never Actual); override (b)
        mag = positive(rs.get("instr.magnification"))
        if mag is not None:
            out["magnification"] = reading(mag)

        # camera length: override (c) -- only in STEM or TEM + DIFFRACTION; (d) "mm (assumed)"; (b)
        cl_rs = rs.get("instr.camera_length")
        cl = positive(cl_rs) if (diffraction_tem or stem) else None
        if cl_rs is not None and cl is None:
            said.append(f"camera length: RosettaSciIO {cl_rs!r}, registered: not recorded "
                        f"(mode {ill!r}/{img!r}: not STEM, not TEM diffraction; or not positive) (b)(c)")
        if cl is not None:
            out["cameraLengthMM"] = reading(cl, mm=True)

        # detector: no RosettaSciIO mapping reads Acquisition.Device.Name -> unvalidated
        det = text(S("Acquisition.Device.Name"))
        if det is not None:
            out["detector"] = reading(det, unval=True)

        # dwell: DigiScan.Sample Time is us (RosettaSciIO / 1e6 -> s; back x 1e6); override (b). EXCEPTION, named: (b)
        # is tested on RosettaSciIO's seconds here, while the Swift tests the us as stored (it converts nothing); the
        # two differ only below ~2.5e-318 us or at DBL_MAX — no plant and no real file (3.5, 10, 30000 us) is there.
        dwell_s = positive(rs.get("instr.dwell_time"))
        if dwell_s is not None:
            out["dwellUS"] = reading(dwell_s * 1e6)

        # exposure: Detector.exposure (s) first, the DataBar copy second (rule f). RosettaSciIO maps the first only,
        # and only outside DigiScan: asserted equal where it does.
        e1, e2 = positive(N("Acquisition.Parameters.Detector.exposure (s)")), positive(N("DataBar.Exposure Time (s)"))
        if "instr.Camera.exposure" in rs and positive(rs["instr.Camera.exposure"]) != e1:
            fail(f"exposure: RosettaSciIO {rs['instr.Camera.exposure']!r} is not the registered first copy {e1!r}")
        if e1 is not None:
            out["exposureS"] = reading(e1, other=differing(e1, e2))
        elif e2 is not None:
            out["exposureS"] = reading(e2)

        # date: RosettaSciIO's dateutil reading of DataBar.Acquisition Date / Time (e). OVERRIDE (e): RosettaSciIO maps
        # the date alone when no time reads; the registered rule needs both, or the date is not recorded.
        date, time_ = rs.get("General.date"), rs.get("General.time")
        if date is not None and time_ is None:
            said.append(f"acquired: RosettaSciIO maps the date {date!r} alone, registered: not recorded (e)")
        if date is not None and time_ is not None:
            raw = strings.get(prefix + "DataBar.Acquisition Date", "")
            m = re.match(r"^\s*(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})\s*$", raw)
            ambiguous = False
            if m:
                a, b = int(m.group(1)), int(m.group(2))
                ambiguous = a <= 12 and b <= 12
                month, day = (a, b) if a <= 12 else (b, a)
                if date[5:7] != f"{month:02d}" or date[8:10] != f"{day:02d}":
                    fail(f"date {raw!r}: dateutil read {date}, month first unless the first field exceeds 12 says "
                         f"{month}/{day}")
            else:
                fail(f"date {raw!r} is not a D/M/Y or M/D/Y text: the order rule is not defined for it")
            out["acquired"] = reading(date + " " + time_, local=True, month=ambiguous)

        # instrument: RosettaSciIO's `_get_microscope_name` through get_mapping (Session Info.Microscope, then
        # Microscope Info.Name, then Microscope Info.Microscope; falsy and "[]" passed over; only with a "Microscope
        # Info" group): its value IS the expectation. OVERRIDE (a): RosettaSciIO returns a whitespace-only text as
        # written; the registered rule treats it as empty, so the same mapping reads the tags with every string
        # trimmed. Where the two readings differ it is printed, never silent.
        trimmed, _ = self.rsciio(nested_from_flat({**numbers, **{k: v.strip() for k, v in strings.items()}}))
        name = text(trimmed.get("instr.microscope"))
        if name is not None:
            out["instrument"] = reading(name)
        if text(rs.get("instr.microscope")) != name:
            said.append(f"instrument: RosettaSciIO {rs.get('instr.microscope')!r}, registered (a) {name!r}")

        # mode: the stored Illumination Mode and Imaging Mode joined by " · "
        parts = [p for p in (ill, img) if p]
        if parts:
            out["mode"] = reading(" · ".join(parts))
        return out, said, errors


# ------------------------------------------------------------------------------------------------ ncempy tags -----
def ncempy_tags(path):
    with dm.fileDM(path, on_memory=True) as f:
        return dict(f.allTags)


def dm_objects(tags):
    """-> [(ImageList number, number of dimensions)] of the non-thumbnail objects (Thumbnails.k.ImageIndex is 0-based)."""
    thumbs = {int(v) + 1 for k, v in tags.items() if re.match(r"^\.Thumbnails\.\d+\.ImageIndex$", k)}
    dims = {}
    for k in tags:
        m = re.match(r"^\.ImageList\.(\d+)\.ImageData\.Dimensions\.\d+$", k)
        if m:
            dims[int(m.group(1))] = dims.get(int(m.group(1)), 0) + 1
    return [(n, d) for n, d in sorted(dims.items()) if n not in thumbs]


def dm_maps(tags, n):
    """The {numbers, strings} maps the Swift function takes: ImageTags of object n, keys relative to
    "ImageList.n.ImageTags.". A scalar number (or boolean) is a number, a string a string, anything else (arrays,
    structs) is not carried."""
    return maps_under(tags, f".ImageList.{n}.ImageTags.")


def block_maps(tags):
    """The same maps for a BARE tag stream (tag 65027): its root group is the ImageTags, so ncempy's keys carry only the
    leading "." of the nameless root and the Swift `tagTree(data:)` keys have none."""
    return maps_under(tags, ".")


def maps_under(tags, prefix):
    """ncempy's `allTags` entries under `prefix`, key relative to it: a string a string, a scalar number or boolean a
    number as a float; arrays and structs are not carried."""
    numbers, strings = {}, {}
    for k, v in tags.items():
        if not k.startswith(prefix):
            continue
        key = k[len(prefix):]
        if isinstance(v, str):
            strings[key] = v
        elif isinstance(v, (bool, np.bool_, int, float, np.integer, np.floating)):
            x = float(v)
            if not math.isfinite(x):
                fail(f"{k}: a non-finite number cannot be written to the manifest")
            numbers[key] = x
    return numbers, strings


ARRAY_ARTIFACT = re.compile(r"\.(arraySize|arrayOffset|arrayType)$")


def c2_maps(numbers, strings):
    """C2 (slice S-b): ncempy's maps of one object (or of a bare tag stream), put through exactly two NAMED
    normalisations into what mac4DSTEM's tag walker (`imageTagNumbers` / `imageTagStrings`, `tagTree`) has to return,
    key for key and value for value:
      (i)  RE-DECODING OF LABELS. ncempy decodes a label byte by byte as ISO Latin-1 (`chr(byte)`, dm.py `_bin2str`).
           The walker decodes the label's bytes as UTF-8 when they are valid UTF-8 and as Latin-1 otherwise
           (DM4Experiment.swift `Cursor.string`, mac4DSTEM 5b696589: the lone 0xB5 byte DigitalMicrograph writes in
           "Emission Current (µA)" is not UTF-8). So each ncempy key is re-encoded to its Latin-1 bytes and decoded
           as UTF-8 where that is valid, and kept as ncempy has it where it is not. REGISTERED as "UTF-8 from the
           Latin-1 bytes" (the walker of be10cce0 made U+FFFD of the lone 0xB5); the re-sync to 5b696589 brought the
           upstream fix, so on the real files this step changes no key, and it is gated on a planted UTF-8 label.
      (ii) ARRAY ARTIFACTS. For every array of 1000 bytes or more ncempy stores three NUMBERS of its own (`X.arraySize`,
           `X.arrayOffset`, `X.arrayType`: where it left the array unread; dm.py `_readArrayData`). They are no tags of
           the file and the walker has none: dropped.
    Nothing else is normalised: a value, a key set or a string that differs after these two steps is a divergence to be
    named, not absorbed (ncempy keeps U+0000 in a uint16 string, reads short arrays of other types as text and a type-11
    tag as uint64; none is on a real file, all are on planted bytes and are not gated).
    -> (numbers, strings, {"redecoded": keys (i) changed, "artifacts": keys (ii) dropped})."""
    report = {"redecoded": 0, "artifacts": 0}

    def redecode(key):                                                   # step (i)
        try:
            raw = key.encode("latin-1")
        except UnicodeEncodeError:
            fail(f"tag label {key!r} holds a character no byte decodes to: ncempy's labels are Latin-1")
        try:
            out = raw.decode("utf-8")
        except UnicodeDecodeError:
            out = key                                                    # not UTF-8: the Latin-1 text, as the walker keeps it
        report["redecoded"] += out != key
        return out
    out_n, out_s = {}, {}
    for source, target in ((numbers, out_n), (strings, out_s)):
        for key, value in source.items():
            if target is out_n and ARRAY_ARTIFACT.search(key):          # step (ii)
                report["artifacts"] += 1
                continue
            if target is out_s and ARRAY_ARTIFACT.search(key):
                fail(f"{key!r}: an array artifact of ncempy is a string, not the number step (ii) drops")
            new = redecode(key)
            if new in target:
                fail(f"two labels re-decode to {new!r}: the re-decoding would lose a tag")
            target[new] = value
    if set(out_n) & set(out_s):
        fail(f"keys in both maps after the re-decoding: {sorted(set(out_n) & set(out_s))[:3]}")
    return out_n, out_s, report


def primary_object(tags):
    """The registered object rule (ImageOpening.swift OBJECT RULE: the first image, the mixed-unit spectrum image, the Format tag), restated on ncempy's tags: the first
    object in file order that is not the thumbnail, has exactly two dimensions larger than one, whose two axes do not
    carry two different units, and whose `Meta Data.Format` is not "Spectrum image". -> its ImageList number, or None.
    macTEM's own rule (no pinned reference has it): held to the planted files' hand-written truth, and to the 11 real
    2-D files, whose object is the only non-thumbnail 2-D one."""
    thumbs = {int(v) + 1 for k, v in tags.items() if re.match(r"^\.Thumbnails\.\d+\.ImageIndex$", k)}
    dims = {}
    for k, v in tags.items():
        m = re.match(r"^\.ImageList\.(\d+)\.ImageData\.Dimensions\.(\d+)$", k)
        if m:
            dims.setdefault(int(m.group(1)), {})[int(m.group(2))] = int(v)
    for n in sorted(dims):
        if n in thumbs or tags.get(f".ImageList.{n}.ImageData.DataType") == 23:    # the thumbnail list, an RGBA preview
            continue
        big = [i for i in sorted(dims[n]) if dims[n][i] > 1]
        if len(big) != 2:
            continue
        units = [tags.get(f".ImageList.{n}.ImageData.Calibrations.Dimension.{i}.Units") or "" for i in big]
        if units[0] and units[1] and units[0] != units[1]:                              # an axis with no unit is uncalibrated
            continue
        if tags.get(f".ImageList.{n}.ImageTags.Meta Data.Format") == "Spectrum image":
            continue
        return n
    return None


def raw_65027(path):
    """-> the bytes of the first directory's tag 65027 whatever its type, or None; and its TIFF type."""
    with tifffile.TiffFile(path) as t:
        tags = t.pages[0].tags
        tag = tags.get(65027)
        return (None, None) if tag is None else (bytes(tag.value), int(tag.dtype))


def entry_extent(path, code):
    """-> (type, count, value offset) of the first directory's entry `code`, parsed straight from the bytes of a classic
    TIFF, or None when the entry is absent. tifffile drops an entry whose value lies outside the file (with a warning), so
    it cannot say whether a plant overruns the file or simply has no such tag."""
    with open(path, "rb") as fh:
        data = fh.read()
    order = {b"II": "<", b"MM": ">"}[data[:2]]
    if struct.unpack(order + "H", data[2:4])[0] != 42:
        fail(f"{path}: not a classic TIFF")
    (directory,) = struct.unpack(order + "I", data[4:8])
    (n,) = struct.unpack(order + "H", data[directory:directory + 2])
    for i in range(n):
        at = directory + 2 + 12 * i
        tag, dtype, count, offset = struct.unpack(order + "HHII", data[at:at + 12])
        if tag == code:
            return dtype, count, offset
    return None


def tiff_block(path):
    """The DM tag stream the registered rule reads from a TIFF, or None when it reads none. macTEM's policy (no pinned
    reference reads this path): the order FEI SEM (34680, 34682), Velox (34683), DM -- the block is read only when none
    of the three exists -- only a BYTE (TIFF type 1) block, and only a block that lies wholly inside the file (a count of
    more than 4 bytes is read from its offset: offset + count at most the file's size)."""
    extent = entry_extent(path, 65027)
    if extent is not None and extent[0] == 1 and extent[1] > 4 and extent[2] + extent[1] > os.path.getsize(path):
        return None
    with tifffile.TiffFile(path) as t:
        if any(code in t.pages[0].tags for code in (34680, 34682, 34683)):
            return None
    raw, dtype = raw_65027(path)
    return raw if dtype == 1 else None


def block_reading(dmref, raw, scratch):
    """ncempy's reading of the stream `raw` written to the file `scratch`, through the DM rules. -> (fields, (numbers,
    strings) or None when ncempy cannot parse it, in which case nothing is recorded)."""
    with open(scratch, "wb") as fh:
        fh.write(raw)
    try:
        tags = ncempy_tags(scratch)
    except Exception:
        return blank(), None
    numbers, strings = block_maps(tags)
    return dmref.expected(numbers, strings)[0], (numbers, strings)


def patch_tag_id(src, dst, code, new_code):
    """A copy of the TIFF `src` whose first-directory entry `code` is renamed `new_code` (an entry of the same size, so
    nothing else moves)."""
    with tifffile.TiffFile(src) as t:
        tag, order = t.pages[0].tags[code], t.byteorder
    data = bytearray(open(src, "rb").read())
    old = struct.pack(order + "H", code)
    if bytes(data[tag.offset:tag.offset + 2]) != old:
        fail(f"{src}: tag {code}'s entry is not where tifffile says (offset {tag.offset})")
    data[tag.offset:tag.offset + 2] = struct.pack(order + "H", new_code)
    with open(dst, "wb") as fh:
        fh.write(data)


def rsciio_parse_check(dm_api, Box, ref, path, n, nested, rs_from_ncempy):
    """RosettaSciIO's own parser reads the same object: its mapped values must equal those from ncempy's tags."""
    with open(path, "rb") as f:
        reader = dm_api.DigitalMicrographReader(f)
        reader.parse_file()
        group = reader.tags_dict["ImageList"][f"TagGroup{n - 1}"]
        image = dm_api.ImageObject(group, f)
        mapping = image.get_mapping()
        original = {"ImageList": {"TagGroup0": {"ImageTags": image.imdict.ImageTags}}}
        results, _ = apply_mapping(mapping, original)
    own = short_targets(results)
    for key in sorted(set(own) | set(rs_from_ncempy)):
        a, b = own.get(key), rs_from_ncempy.get(key)
        same = (a == b) or (isinstance(a, float) and isinstance(b, float) and math.isclose(a, b, rel_tol=1e-12))
        if not same:
            fail(f"{os.path.basename(path)} ImageList.{n}: RosettaSciIO's own parser maps {key} to {a!r}, "
                 f"ncempy's tags map it to {b!r}")


# ------------------------------------------------------------------------------------------------ FEI SEM -------
def fei_expected(file_reader, path):
    """RosettaSciIO's mapping_fei on its original_metadata (+ the registered rules). -> (fields, said)."""
    d = file_reader(path)[0]
    om = d["original_metadata"]
    rs, errors = apply_mapping(d["mapping"], om)
    rs = short_targets(rs)
    out, said = blank(), [f"{p}: {e}" for p, e in errors]
    ht = positive(rs.get("instr.beam_energy"))            # RosettaSciIO: float(Beam.HV) * 1e-3, None when not a float
    if ht is not None:
        out["highTensionKV"] = reading(ht)
    # Scan.Dwelltime is s. RosettaSciIO maps it with NO function: a text such as "notafloat" would pass through
    # as text. OVERRIDE (a): unparseable is not recorded, so it goes through float() here before the x 1e6 and (b).
    try:
        dwell_us = positive(float(rs.get("instr.dwell_time")) * 1e6)   # (b) on the converted number
    except (TypeError, ValueError):
        dwell_us = None
    if rs.get("instr.dwell_time") is not None and dwell_us is None:
        said.append(f"dwell: RosettaSciIO maps {rs['instr.dwell_time']!r}; registered: not recorded (a)(b)")
    if dwell_us is not None:
        out["dwellUS"] = reading(dwell_us)
    # (e) as for DM: a date without a time, or a time without a date, is not recorded. The [User] Date is month-first by
    # format -- dateutil reads "05/06/2022" as May 6, as mapping_fei does -- so the note is "local time" and no more.
    date, time_ = rs.get("General.date"), rs.get("General.time")
    if (date is None) != (time_ is None):
        said.append(f"acquired: RosettaSciIO maps {date or time_!r} alone, registered: not recorded (e)")
    if date is not None and time_ is not None:
        out["acquired"] = reading(date + " " + time_, local=True)
    name = text(rs.get("instr.microscope"))               # System.SystemType, read as written (a quote mark included)
    if name is not None:
        out["instrument"] = reading(name)
    try:
        det = text(om["fei_metadata"]["Detectors"]["Name"])   # mapped by no reference
    except KeyError:
        det = None
    if det is not None:
        out["detector"] = reading(det, unval=True)
    return out, said


# ------------------------------------------------------------------------------------------------ Velox ----------
def velox_conversions(root):
    """RosettaSciIO's HT and camera-length conversions, EXTRACTED from rsciio/emd/_emd_velox.py and compiled as
    written. -> {key: (function, line, source)}."""
    path = os.path.join(root, "rsciio", "emd", "_emd_velox.py")
    src = open(path).read()
    found = {}
    for node in ast.walk(ast.parse(src)):
        if isinstance(node, ast.Dict):
            for k, v in zip(node.keys, node.values):
                if isinstance(k, ast.Constant) and k.value in ("Optics.AccelerationVoltage", "Optics.CameraLength"):
                    lam = v.elts[1]
                    if not isinstance(lam, ast.Lambda):
                        fail(f"{k.value}: RosettaSciIO's function is not a lambda any more")
                    found[k.value] = (eval(compile(ast.Expression(lam), path, "eval"), {}), lam.lineno,
                                      ast.get_source_segment(src, lam))
    if set(found) != {"Optics.AccelerationVoltage", "Optics.CameraLength"}:
        fail(f"_emd_velox.py: found conversions for {sorted(found)}")
    if found["Optics.AccelerationVoltage"][2] != "lambda x: float(x) / 1e3" or \
            found["Optics.CameraLength"][2] != "lambda x: float(x) * 1e3":
        fail(f"_emd_velox.py's conversions are no longer / 1e3 and * 1e3: {[v[2] for v in found.values()]}")
    return found


def iso_local(s):
    """'2026-06-05T13:05:31.000' -> '2026-06-05 13:05:31' (the file's own clock; seconds truncated); None if not ISO."""
    s = text(s)
    if s is None:
        return None
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is not None:
        fail(f"{s!r} carries a time zone: 'zone not stored' would be false")
    return dt.strftime("%Y-%m-%d %H:%M:%S")


class _Refused(Exception):
    pass


def velox_guard(raw):
    """Policy (m): is this Velox document read at all? -> ("ok", None), ("refused", why) or ("unreadable", None) (not
    well-formed). Expat decodes and lexes as libxml2 does for the Swift guard: a tag over 4 MiB, an element depth over
    64, more than 1 MiB of character data and any entity declaration refuse the document before anything is expanded."""
    data = raw.encode("utf-8") if isinstance(raw, str) else bytes(raw)
    if len(data) > MAX_TAG_BYTES:
        return "refused", f"{len(data)} bytes"
    state = {"depth": 0, "chars": 0, "why": None}

    def refuse(why):
        state["why"] = why
        raise _Refused()

    def start(name, attributes):
        state["depth"] += 1
        if state["depth"] > MAX_DEPTH:
            refuse(f"depth over {MAX_DEPTH}")

    def end(name):
        state["depth"] -= 1

    def characters(chunk):
        state["chars"] += len(chunk)
        if state["chars"] > MAX_CHARS:
            refuse(f"over {MAX_CHARS} characters")

    def entity(*args):
        refuse("an entity declaration")
    parser = expat.ParserCreate()
    parser.StartElementHandler, parser.EndElementHandler, parser.CharacterDataHandler = start, end, characters
    parser.EntityDeclHandler = parser.UnparsedEntityDeclHandler = entity
    try:
        parser.Parse(data, True)
    except _Refused:
        return "refused", state["why"]
    except expat.ExpatError:
        return "unreadable", None
    return "ok", None


def velox_expected(path, conversions):
    """-> fields, or the string "unreadable" when tag 34683's text is not XML. A tag the guard refuses reads empty."""
    with tifffile.TiffFile(path) as t:
        tags = t.pages[0].tags
        if 34683 not in tags:
            return blank()
        raw = tags[34683].value
    verdict, _ = velox_guard(raw)
    if verdict == "unreadable":
        return "unreadable"
    if verdict == "refused":
        return blank()
    try:
        root = ET.fromstring(raw.encode("utf-8") if isinstance(raw, str) else raw)
    except ET.ParseError:
        return "unreadable"

    def value(path_):
        """Rule (a) and policy (m): the trimmed text of the first element at the path; None when empty or over 256."""
        e = root.find("./" + path_)
        t = None if e is None else text(e.text)
        return None if t is not None and len(t) > MAX_VALUE else t

    def convert(key, v):
        try:
            return conversions[key][0](v)
        except (TypeError, ValueError):
            return None
    out = blank()
    ht = positive(convert("Optics.AccelerationVoltage", value("Optics/AccelerationVoltage")))   # V / 1e3 -> kV
    if ht is not None:
        out["highTensionKV"] = reading(ht)
    mag = positive(value("Optics/NominalMagnification"))
    if mag is not None:
        out["magnification"] = reading(mag, unval=True)
    # rule (c): the camera length is real in diffraction or STEM (RosettaSciIO applies no gate: DEVIATION); policy (j):
    # the two modes are matched without regard to case; m * 1e3 -> mm (RosettaSciIO)
    projector, mode = value("Optics/ProjectorMode"), value("Optics/OperatingMode")
    if (projector is not None and projector.lower() == "diffraction") or (mode is not None and mode.lower() == "stem"):
        cl = positive(convert("Optics.CameraLength", value("Optics/CameraLength")))
        if cl is not None:
            out["cameraLengthMM"] = reading(cl)
    det = value("BinaryResult/Detector")
    if det is not None:
        out["detector"] = reading(det, unval=True)
        # policy (i): the exposure of the Detectors/* element that names this detector, never another detector's
        for element in root.findall("./Detectors/*"):
            named = element.find("DetectorName")
            if named is None or text(named.text) != det:
                continue
            exposed = element.find("ExposureTime")
            exposure = positive(None if exposed is None else exposed.text)
            if exposure is not None:
                out["exposureS"] = reading(exposure, unval=True)
                break
    # dwell: the dwell path of a Velox STEM TIFF is unobserved (no such file exists here): not recorded, whatever
    # ScanSettings/FrameTime holds (a scan setting, not a dwell)
    first, second = iso_local(value("Acquisition/AcquisitionStartDatetime")), \
        iso_local(value("Acquisition/AcquisitionDatetime"))
    if second is not None and int(second[:4]) < FLOOR_YEAR:     # policy (f)/(k): an unset second stamp, not a copy
        second = None
    if first is not None:
        out["acquired"] = reading(first, local=True, unval=True, other=second if second not in (None, first) else None)
    model = value("Instrument/InstrumentModel")
    if model is not None:
        out["instrument"] = reading(model, unval=True)
    if mode is not None:
        out["mode"] = reading(mode, unval=True)
    return out


def frame_time(path):
    with tifffile.TiffFile(path) as t:
        tags = t.pages[0].tags
        if 34683 not in tags:
            return None
        root = ET.fromstring(tags[34683].value)
    e = root.find("./ScanSettings/FrameTime")
    return positive(e.text) if e is not None else None


# ------------------------------------------------------------------------------------------------ MRC ------------
def derive_bits(dtype, unused_bits=6, shift=0):
    """{field: (bitmask number, bit, width)}: bit i of Bitmask k is the i-th field after that bitmask, the 48-byte
    'Unused range' counting 6 bits (so each of bitmasks 1-3 covers exactly 32 fields). `unused_bits` and `shift` are
    for `bit_evidence` only: they build the WRONG assignments the real files have to refute."""
    assign, mask, bit = {}, None, 0
    for name in dtype.names:
        if name.startswith("Bitmask"):
            mask, bit = int(name.split()[1]), 0
            continue
        if name in ("Metadata size", "Metadata version"):
            continue
        width = unused_bits if name == "Unused range" else 1
        assign[name] = (mask, bit + shift, width)
        bit += width
    return assign


def check_layout(layout):
    """The plant's hand-typed offsets and bit positions against mrcfile's dtype -> problems."""
    problems = []
    dt2 = mrc_dtypes.fei2_dtype_big_endian
    for name, off in layout["offsets"].items():
        if dt2.fields[name][1] != off:
            problems.append(f"offset of {name!r}: plant {off}, mrcfile {dt2.fields[name][1]}")
    bits = derive_bits(dt2)
    for name, (k, b) in layout["bits"].items():
        if bits[name][:2] != (k, b):
            problems.append(f"bit of {name!r}: plant {(k, b)}, derived {bits[name][:2]}")
    if layout["records"] != {"FEI2": dt2.itemsize, "FEI1": mrc_dtypes.fei1_dtype_big_endian.itemsize}:
        problems.append(f"record sizes {layout['records']} differ from mrcfile's")
    spans = {}
    for name, (k, b, width) in bits.items():
        spans[k] = spans.get(k, 0) + width
    if spans != {1: 32, 2: 32, 3: 32, 4: 17}:     # bitmasks 1-3 cover exactly 32 bits each, the 4th 17 fields
        problems.append(f"the derived bit spans per bitmask are {spans}, not 32, 32, 32 and 17")
    return problems


def real_records(paths):
    """-> [(file name, every extended-header record)]."""
    out = []
    for path in paths:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            with mrcfile.open(path, mode="r", permissive=True) as m:
                out.append((os.path.basename(path), np.array(m.indexed_extended_header)))
    return out


def is_blank(v):
    return (len(bytes(v).strip(b"\0")) == 0) if isinstance(v, (bytes, np.bytes_)) else v == 0


def violations(records, assign, only=None):
    """The (record, field) pairs whose bits are ALL unset -- a bit outside its 32-bit mask counts as unset -- while the
    field is not blank: a field the writer did not fill holds nothing, so each pair is a wrong assignment."""
    n = 0
    for _, recs in records:
        for rec in recs:
            masks = {k: int(rec[f"Bitmask {k}"]) for k in (1, 2, 3, 4)}
            for name, (k, b, width) in assign.items():
                if name == "Unused range" or (only is not None and name not in only):
                    continue
                if not any(0 <= b + j < 32 and (masks[k] >> (b + j)) & 1 for j in range(width)) \
                        and not is_blank(rec[name]):
                    n += 1
    return n


# The fields AcquisitionMetadata.mrc reads (their bits are what the reader's constants must equal).
MRC_READ_FIELDS = ("Timestamp", "Microscope type", "HT", "Instrument mode", "Magnification", "Camera length",
                   "Integration time", "Camera name", "STEM Detector name", "Dwell time", "Detector commercial name")


def bit_evidence(paths):
    """What the real MRC records say about the bit rule. -> (pairs checked, lines to print). Fails when the derived
    assignment is contradicted by a record, or when a WRONG assignment is not (anti-vacuity: every wrong width of the
    'Unused range' and every global shift has to leave some field non-blank under an unset bit).
    The check is one-sided: it can only see a field that is non-blank under an unset bit, so a field the real
    records never fill (or fill in one record) gets little or no evidence from it."""
    records = real_records(paths)
    dtype = records[0][1].dtype
    truth_ = derive_bits(dtype)
    pairs = sum(len(recs) for _, recs in records) * (len(truth_) - 1)     # every field but the 'Unused range'
    bad = violations(records, truth_)
    if bad:
        fail(f"the derived bit assignment is contradicted by {bad} (record, field) pairs of the real MRCs")
    lines, refuted = [], {}
    for width in [w for w in range(0, 10) if w != 6]:
        refuted[f"Unused range of {width} bits"] = violations(records, derive_bits(dtype, unused_bits=width))
    for shift in (-3, -2, -1, 1, 2, 3):
        refuted[f"every bit shifted by {shift:+d}"] = violations(records, derive_bits(dtype, shift=shift))
    survived = [k for k, v in refuted.items() if v == 0]
    if survived:
        fail(f"the real MRCs do not refute these wrong bit assignments: {survived}")
    lines.append(f"bit rule: the derived assignment has 0 violations over {pairs} (record, field) pairs; each of "
                 f"{len(refuted)} wrong ones (Unused range of 0-9 bits but 6, every bit shifted by 1-3 either way) "
                 f"has {min(refuted.values())} to {max(refuted.values())}")
    pinned, unpinned = [], []
    for name in MRC_READ_FIELDS:
        k, b, width = truth_[name]
        caught = []
        for shift in (-3, -2, -1, 1, 2, 3):
            if b + shift < 0 or b + shift + width > 32:
                continue                                  # the shifted bit would leave the field's own mask
            if violations(records, {name: (k, b + shift, width)}, only={name}):
                caught.append(f"{shift:+d}")
        (pinned if caught else unpinned).append(f"{name} (bit {b} of mask {k}): " + (" ".join(caught) or "none"))
    lines.append("bit of a read field against a shift of that bit alone, the shifts a real record refutes:")
    lines += ["    " + x for x in pinned + unpinned]
    return pairs, lines


def check_epoch_evidence(paths):
    """Override (h). Of the real records whose int64 'Acquisition time stamp' (unix microseconds, UTC) is set, OLE minus
    unix is at most 14 h and a whole number of quarter hours on the 1899-12-30 epoch, and not on 1900-01-01 or 1904-01-01.
    -> (records checked, the offsets seen in seconds, lines to print)."""
    epochs = {"1899-12-30": datetime(1899, 12, 30), "1900-01-01": datetime(1900, 1, 1),
              "1904-01-01": datetime(1904, 1, 1)}
    unix = datetime(1970, 1, 1)

    def plausible(seconds):    # a time zone: at most 14 h from UTC, in whole quarter hours (the OLE float is good to ~1 us)
        return abs(seconds) <= 14 * 3600 and abs(seconds / 900 - round(seconds / 900)) * 900 <= 1e-3
    tally = {name: [0, 0] for name in epochs}
    offsets = {}
    for fname, recs in real_records(paths):
        bits = derive_bits(recs.dtype)
        for rec in recs:
            def written(field):
                k, b, _ = bits[field]
                return bool((int(rec[f"Bitmask {k}"]) >> b) & 1)
            if not (written("Timestamp") and written("Acquisition time stamp")):
                continue
            micros, days = int(rec["Acquisition time stamp"]), float(rec["Timestamp"])
            if micros <= 0 or not days > 0:
                continue
            utc = unix + timedelta(microseconds=micros)
            for name, epoch in epochs.items():
                seconds = ((epoch + timedelta(days=days)) - utc).total_seconds()
                tally[name][0 if plausible(seconds) else 1] += 1
                if name == "1899-12-30":
                    offsets[(fname, round(seconds))] = offsets.get((fname, round(seconds)), 0) + 1
    n = sum(tally["1899-12-30"])
    if n == 0:
        fail("no real MRC record has both its Timestamp and its int64 Acquisition time stamp set: the epoch has no "
             "evidence")
    if tally["1899-12-30"][1] != 0:
        fail(f"the 1899-12-30 epoch puts {tally['1899-12-30'][1]} of {n} records further than 14 h or off a quarter "
             f"hour from their own UTC stamp")
    for name in ("1900-01-01", "1904-01-01"):
        if tally[name][0] != 0:
            fail(f"the epoch {name} also passes the zone test on {tally[name][0]} records: the test cannot tell it apart")
    lines = [f"epoch (h): 1899-12-30 + Timestamp minus the UTC int64 stamp is {off:+d} s on {count} records of {fname}"
             for (fname, off), count in sorted(offsets.items())]
    lines.append(f"epoch (h): on those {n} records the epochs 1900-01-01 and 1904-01-01 each fail the zone test "
                 f"(at most 14 h, whole quarter hours) on every one")
    return n, sorted(offsets), lines


def cstring(v):
    return bytes(v).split(b"\0")[0].decode("ascii", errors="replace")


def mrc_expected(path):
    """mrcfile's FEI extended header (record 0) with the bitmasks. -> fields; "unreadable" when mrcfile cannot read
    the file or interpret its extended header although exttyp says FEI1 / FEI2; blank for any other exttyp."""
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            m = mrcfile.open(path, mode="r", permissive=True)
            exttyp = bytes(m.header.exttyp)
            if exttyp not in (b"FEI1", b"FEI2"):
                return blank()
            records = m.indexed_extended_header
    except Exception:
        return "unreadable"
    if records is None or len(records) == 0:
        return "unreadable"
    rec = records[0]
    bits = derive_bits(records.dtype)

    def written(field):
        k, b, _ = bits[field]
        return bool((int(rec[f"Bitmask {k}"]) >> b) & 1)

    out = blank()
    # Override (b): the number is tested AFTER its unit conversion (a stored 5e-324 V is 0.0 kV, a 1.7e308 m is inf mm).
    if written("HT"):
        ht = positive(float(rec["HT"]) / 1e3)                      # V -> kV
        if ht is not None:
            out["highTensionKV"] = reading(ht)
    if written("Magnification"):
        mag = positive(float(rec["Magnification"]))
        if mag is not None:
            out["magnification"] = reading(mag)
    if written("Camera length"):                                   # override (c): shown as stored, mode not checked
        cl = positive(float(rec["Camera length"]) * 1e3)            # m -> mm
        if cl is not None:
            out["cameraLengthMM"] = reading(cl, nomode=True)
    # detector: the STEM detector's name, else the camera's, else the detector's commercial name (the last, FEI2 only)
    for field in ("STEM Detector name", "Camera name", "Detector commercial name"):
        if field in records.dtype.names and written(field) and text(cstring(rec[field])):
            out["detector"] = reading(text(cstring(rec[field])))
            break
    if written("Dwell time"):
        dwell = positive(float(rec["Dwell time"]) * 1e6)            # s -> us
        if dwell is not None:
            out["dwellUS"] = reading(dwell)
    if written("Timestamp"):
        days = positive(float(rec["Timestamp"]))                    # OLE days since 1899-12-30: override (h)
        if days is not None:
            dt = datetime(1899, 12, 30) + timedelta(days=days)
            out["acquired"] = reading(dt.strftime("%Y-%m-%d %H:%M:%S"), writer=True)
    if written("Microscope type") and text(cstring(rec["Microscope type"])):
        out["instrument"] = reading(text(cstring(rec["Microscope type"])))
    # override (l): the camera's Integration time (s) is the exposure, the Instrument mode int32 the mode as text
    if written("Integration time"):
        exposure = positive(float(rec["Integration time"]))
        if exposure is not None:
            out["exposureS"] = reading(exposure, unval=True)
    if written("Instrument mode"):
        out["mode"] = reading(str(int(rec["Instrument mode"])), unval=True)   # 0 is a stored value
    return out


# ------------------------------------------------------------------------------------------------ compare / write -
def same_reading(a, b):
    """Two readings (or None) equal: text exactly, numbers to 1e-12 relative (the plant is hand arithmetic; the harness
    compares real files to 1e-9)."""
    if a is None or b is None:
        return a is None and b is None
    if a["note"] != b["note"]:
        return False
    for x, y in ((a["value"], b["value"]), (a["otherCopy"], b["otherCopy"])):
        if isinstance(x, str) or isinstance(y, str) or x is None or y is None:
            if x != y:
                return False
        elif not math.isclose(x, y, rel_tol=1e-12, abs_tol=0.0):
            return False
    return True


def entry_of(field, r):
    if r is None:
        return {"field": field, "kind": "absent"}
    return {"field": field, "kind": "value", "value": r["value"], "note": r["note"], "otherCopy": r["otherCopy"]}


def describe(fields):
    lines = []
    for f in FIELDS:
        r = fields[f]
        if r is None:
            lines.append(f"    {f:<14} not recorded")
        else:
            extra = f"  [{r['note']}]" if r["note"] else ""
            extra += f"  other copy {r['otherCopy']!r}" if r["otherCopy"] is not None else ""
            lines.append(f"    {f:<14} {r['value']!r}{extra}")
    return "\n".join(lines)


PREDICTED_65027 = {   # WRITTEN before the code (slice S-b, "Predicted"), by hand from the port, never from a run
    "highTensionKV": reading(200.0),                                  # Microscope Info.Voltage 200000 V
    "magnification": reading(51.0),                                   # Indicated 51; the Actual 83 is ignored
    "cameraLengthMM": None,                                           # TEM + IMAGING; the STEM Camera Length 255 is stale
    "detector": reading("BM-UltraScan", unval=True),
    "dwellUS": None,
    "exposureS": reading(0.5),
    "acquired": reading("2015-07-20 18:48:25", local=True),           # 20 > 12: no order note
    "instrument": reading("FEI Tecnai"),
    "mode": reading("TEM · IMAGING"),
}


def make_read(name, kind, expected, *, path, reference, object=None, shown=None, maps=None, maps_from=None, block=None,
              isolate=False, mutants=None, comment=""):
    """One case of AcquisitionMetadata.read(path:) end to end. `object`: the ImageList number whose tags the expectation
    is read from (DM); `shown`: the ImageList number the open shows (None when it shows none); `maps`: the numbers and
    strings the tag walker has to return for `object`; `block`: (path of the tag-65027 stream written out, numbers,
    strings) for the walker's `tagTree` on the bare stream. `isolate`: the harness runs the case in a child process (a
    case on which the reader could trap)."""
    return {"name": name, "kind": kind, "path": path, "reference": reference, "isolate": isolate,
            "expected": [entry_of(f, expected[f]) for f in FIELDS], "object": object, "shown": shown,
            "maps": None if maps is None else {"numbers": maps[0], "strings": maps[1]}, "mapsFrom": maps_from,
            "block": None if block is None else {"path": block[0], "numbers": block[1], "strings": block[2]},
            "mutants": mutants or {}, "comment": comment}


def main(planted_dir, root, owner_dir, out):
    check_reference(root)
    file_reader, dm_api, Box = import_rsciio(root)
    dmref = DMReference(dm_api, Box)
    conversions = velox_conversions(root)
    os.makedirs(out, exist_ok=True)
    planted = json.load(open(os.path.join(planted_dir, "planted.json")))
    problems, cases, log, reads = [], [], [], []
    work = os.path.join(out, "work")
    os.makedirs(work, exist_ok=True)

    # ------------------------------------------------ the layout the plant typed against mrcfile's dtype
    for p in check_layout(planted["layout"]):
        problems.append("planted layout: " + p)

    def abspath(name):
        return os.path.abspath(os.path.join(planted_dir, name))

    def make_case(name, fmt, expected, *, path=None, numbers=None, strings=None, reference,
                  outcome="values", mutants=None, extra=None, comment=""):
        return {"name": name, "format": fmt, "path": path, "numbers": numbers, "strings": strings,
                "reference": reference, "outcome": outcome,
                "expected": [entry_of(f, expected[f]) for f in FIELDS],
                "mutants": mutants or {}, "extra": extra or {}, "comment": comment}

    # ------------------------------------------------ planted: the reference must reproduce the plant
    for c in planted["cases"]:
        name, fmt, tr = c["name"], c["format"], c["truth"]
        bad = lambda msg: problems.append(f"planted {name}: {msg}")
        outcome, extra = c["outcome"], dict(c["extra"])
        mutants = {}
        for mutation, m in c["mutants"].items():
            mutants[mutation] = ({"path": abspath(m["file"])} if "file" in m
                                 else {"numbers": m["numbers"], "strings": m["strings"]})
        path = abspath(c["file"]) if c["file"] else None
        if fmt == "dm":
            got, said, errors = dmref.expected(c["numbers"], c["strings"])
            reference = "rsciio+registration"
        elif fmt == "tiff":
            name_is_fei = name.startswith("planted-fei-sem")
            if name_is_fei:
                got, said = fei_expected(file_reader, path)
                reference = "rsciio"
            else:
                got = velox_expected(path, conversions)
                reference = "rsciio+registration"
                if got == "unreadable":
                    if outcome != "nilOrThrows":
                        bad("tag 34683 is not XML but the plant expects values")
                    got = blank()
                if "frameTimeS" in extra:
                    ft = frame_time(path)
                    if ft != extra["frameTimeS"]:
                        bad(f"FrameTime {ft} is not the planted {extra['frameTimeS']}")
        elif fmt == "mrc":
            got = mrc_expected(path)
            reference = "mrcfile"
            if got == "unreadable":
                if outcome != "nilOrThrows":
                    bad("mrcfile cannot read what the plant says it can")
                got = blank()
            elif outcome == "nilOrThrows":
                # mrcfile read it: its reading must be nothing recorded (the plant says nothing is invented)
                if any(got[f] is not None for f in FIELDS):
                    bad(f"mrcfile reads values from a file the plant expects to be refused: {got}")
        else:
            bad(f"unknown format {fmt}")
            continue
        for f in FIELDS:
            if not same_reading(got[f], tr[f]):
                bad(f"{f}: the reference reads {got[f]} but the plant says {tr[f]}")
        cases.append(make_case(name, fmt, tr, path=path, numbers=c["numbers"], strings=c["strings"],
                               reference=reference, outcome=outcome, mutants=mutants, extra=extra,
                               comment=c["comment"]))

    # ------------------------------------------------ planted: read(path:) end to end (S-b); the reference must reproduce the plant
    for c in planted["reads"]:
        name, fmt, tr = c["name"], c["format"], c["truth"]
        bad = lambda msg: problems.append(f"planted {name}: {msg}")
        path = abspath(c["file"])
        mutants = {m: {"path": abspath(v["file"])} for m, v in c["mutants"].items()}
        object_, shown, maps, block = None, None, None, None
        if fmt == "dm4":
            tags = ncempy_tags(path)
            object_ = c["object"]
            shown = object_ if c["openable"] else None
            if primary_object(tags) != shown:
                bad(f"the registered object rule picks ImageList.{primary_object(tags)}, the plant says {shown}")
            if object_ is None:
                got = blank()
            else:
                numbers, strings = dm_maps(tags, object_)
                # Named step (iii), PLANTED FILES ONLY: ncempy keeps the NUL unit of a uint16 string (a fixed-width GMS
                # field), where the walker drops every zero unit. The plant wrote NULs at exactly the keys `nul` lists.
                stray = [k for k, v in strings.items()
                         if v.endswith("\0") != (k in c["nul"]) or v.count("\0") != v.endswith("\0")]
                if stray:
                    bad(f"NUL units where the plant put none, or none where it did: {stray}")
                strings = {k: v.replace("\0", "") for k, v in strings.items()}
                numbers, strings, _ = c2_maps(numbers, strings)
                if (numbers, strings) != (c["numbers"], c["strings"]):
                    bad("ncempy's maps of the shown object are not the maps the plant declares")
                got = dmref.expected(c["numbers"], c["strings"])[0]
                maps = (c["numbers"], c["strings"])
            reference = "ncempy+rsciio+registration"
        elif fmt == "mrc":
            got, reference = mrc_expected(path), "mrcfile"
            if got == "unreadable":
                bad("mrcfile cannot read what the plant says it can")
                continue
        elif fmt == "tiff":
            if c["via"] == "velox":
                got, reference = velox_expected(path, conversions), "rsciio+registration"
            elif c["via"] == "fei":
                got, reference = fei_expected(file_reader, path)[0], "rsciio"
            elif c["via"] == "dm-block":
                if c.get("entry") is not None:   # a hand-written entry: its bytes have to be the geometry the plant declares
                    declared = c["entry"]
                    found = entry_extent(path, 65027)
                    if found != (declared["type"], declared["count"], declared["offset"]):
                        bad(f"the entry of tag 65027 reads {found}, the plant declares {declared}")
                    if os.path.getsize(path) != declared["size"]:
                        bad(f"the file is {os.path.getsize(path)} bytes, the plant declares {declared['size']}")
                    if declared["offset"] + declared["count"] <= declared["size"]:
                        bad("the plant is meant to overrun the file and does not")
                raw = tiff_block(path)
                got, reference = blank(), "ncempy+rsciio+registration"
                if raw is not None:
                    got, parsed = block_reading(dmref, raw, os.path.join(work, name + ".65027.dm4"))
                    if parsed is not None and c["block"] is not None:
                        block = (os.path.abspath(os.path.join(work, name + ".65027.dm4")),) + parsed
            else:
                bad(f"unknown via {c['via']}")
                continue
            if c["block"] is not None:           # the declared stream is what ncempy parses from the TIFF's tag 65027
                raw_any, _ = raw_65027(path)
                with open(os.path.join(work, name + ".declared.dm4"), "wb") as fh:
                    fh.write(raw_any)
                declared = c2_maps(*block_maps(ncempy_tags(os.path.join(work, name + ".declared.dm4"))))[:2]
                if declared != (c["block"]["numbers"], c["block"]["strings"]):
                    bad("ncempy's maps of tag 65027 are not the maps the plant declares")
        else:
            bad(f"unknown format {fmt}")
            continue
        for f in FIELDS:
            if not same_reading(got[f], tr[f]):
                bad(f"{f}: the reference reads {got[f]} but the plant says {tr[f]}")
        reads.append(make_read(name, {"dm4": "dm", "tiff": "tiff", "mrc": "mrc"}[fmt], tr, path=path, reference=reference,
                               object=object_, shown=shown, maps=maps,
                               maps_from=None if maps is None else "the maps the plant declares", block=block,
                               isolate=bool(c.get("isolate")), mutants=mutants, comment=c["comment"]))

    # ------------------------------------------------ real files
    reg = registry(root)
    data = os.path.join(root, "rsciio", "tests", "data")

    def trusted(rel):
        path = os.path.join(data, rel)
        if reg.get(rel) != sha256_file(path):
            fail(f"{rel} does not match rsciio/tests/registry.txt")
        return path

    # DM
    for rel, ndim in [(rel, 2) for rel in DM_FILES] + DM_STACK_FILES:
        path = trusted(rel)
        tags = ncempy_tags(path)
        objs = [(n, d) for n, d in dm_objects(tags) if d == ndim]
        if len(objs) != 1:
            fail(f"{rel}: {len(objs)} non-thumbnail {ndim}-D objects; the harness expects exactly one")
        n = objs[0][0]
        numbers, strings = dm_maps(tags, n)
        fields, said, errors = dmref.expected(numbers, strings)
        if any(x.startswith("instrument:") for x in said):    # on a real file the instrument IS get_mapping's value
            fail(f"{rel}: the registered instrument differs from get_mapping's: {[x for x in said if x.startswith('instrument:')]}")
        rs, _ = dmref.rsciio(nested_from_flat({**numbers, **strings}))
        rsciio_parse_check(dm_api, Box, dmref, path, n, None, rs)
        name = "dm-" + re.sub(r"[^A-Za-z0-9_]+", "-", os.path.basename(rel)).strip("-") + f"-IL{n}"
        cases.append(make_case(name, "dm", fields, numbers=numbers, strings=strings, reference="ncempy+rsciio",
                               comment=f"{rel} ImageList.{n}"))
        # S-b. C1: the object the open shows is `n` for the 2-D files and none for the 3-D stack builder's (the open
        # refuses it: the file goes through the walker's list and the DM rules); C2: ncempy's maps of the object after the
        # two named steps; C3: the same expectation, through read(path:).
        shown = n if ndim == 2 else None
        if primary_object(tags) != shown:
            problems.append(f"{rel}: the registered object rule (restated) picks ImageList.{primary_object(tags)}, "
                            f"the harness expects {shown}")
        c2n, c2s, c2rep = c2_maps(numbers, strings)
        reads.append(make_read(name, "dm", fields, path=os.path.abspath(path), reference="ncempy+rsciio", object=n,
                               shown=shown, maps=(c2n, c2s),
                               maps_from="ncempy allTags, steps (i) and (ii) of c2_maps",
                               comment=f"{rel} ImageList.{n}"))
        log.append((name, fields, said + [f"error: {p}: {e}" for p, e in errors]
                    + [f"C2: ImageList.{n} {len(c2n)} numbers, {len(c2s)} strings; step (i) re-decoded "
                       f"{c2rep['redecoded']} keys, step (ii) dropped {c2rep['artifacts']}"]))

    # FEI SEM
    work = os.path.join(out, "work")
    os.makedirs(work, exist_ok=True)
    zpath = trusted(FEI_ZIP)
    with zipfile.ZipFile(zpath) as z:
        z.extractall(work)
    for member, name in FEI_FILES:
        path = os.path.join(work, member)
        fields, said = fei_expected(file_reader, path)
        cases.append(make_case(name, "tiff", fields, path=os.path.abspath(path), reference="rsciio",
                               comment=f"{FEI_ZIP}:{member}"))
        log.append((name, fields, said))

    # MRC
    mrc_paths = []
    for rel, name in MRC_FILES:
        path = trusted(rel)
        mrc_paths.append(path)
        fields = mrc_expected(path)
        if fields == "unreadable":
            fail(f"mrcfile cannot read {rel}")
        cases.append(make_case(name, "mrc", fields, path=os.path.abspath(path), reference="mrcfile",
                               comment=f"{rel}, record 0"))
        log.append((name, fields, []))
    bit_pairs, bit_lines = bit_evidence(mrc_paths)
    epoch_records, _, epoch_lines = check_epoch_evidence(mrc_paths)

    # C5. A DM-saved TIFF holds its whole ImageTags tree in tag 65027 (type 1): a DM4 byte stream whose root group IS the
    # ImageTags. The expectation is ncempy's reading of the same bytes written to a temp file (`block_reading`) put through
    # the DM rules -- not read from the TIFF by any pinned reader, so macTEM's policy: none of 34680, 34682, 34683, type 1.
    # The first file also carries a hand-written prediction, registered before the code (PREDICTED_65027).
    for rel, name in DM_TIFF_65027:
        path = trusted(rel)
        with tifffile.TiffFile(path) as t:
            present = [code for code in (34680, 34682, 34683, 65027) if code in t.pages[0].tags]
        if present != [65027]:
            fail(f"{rel}: expected tag 65027 and none of 34680, 34682, 34683; found {present}")
        raw = tiff_block(path)
        if raw is None:
            fail(f"{rel}: tag 65027 is not a type-1 block")
        block_path = os.path.abspath(os.path.join(work, name + ".65027.dm4"))
        fields, parsed = block_reading(dmref, raw, block_path)
        if parsed is None:
            fail(f"ncempy cannot parse the tag 65027 block of {rel}")
        bn, bs = parsed
        if not name.endswith("-stack"):
            if bn.get("Microscope Info.Voltage") != 200000.0:
                fail(f"{rel}: tag 65027 no longer holds a DM tag tree stating Microscope Info.Voltage 200000.0 V")
            for f in FIELDS:
                if not same_reading(fields[f], PREDICTED_65027[f]):
                    problems.append(f"{rel}: the registered prediction of {f} is {PREDICTED_65027[f]}, the reference "
                                    f"reads {fields[f]}")
        elif bn or bs:
            fail(f"{rel}: the stack's tag 65027 block was registered as an empty tree, ncempy reads {len(bn)} numbers "
                 f"and {len(bs)} strings")
        c2n, c2s, c2rep = c2_maps(bn, bs)
        mutants = {}
        if not name.endswith("-stack"):       # M5: the tag renamed 65028, so the reader meets a file without it
            twin = os.path.abspath(os.path.join(work, name + ".tiff-65027-skipped.tif"))
            patch_tag_id(path, twin, 65027, 65028)
            mutants["tiff-65027-skipped"] = {"path": twin}
        reads.append(make_read(name, "tiff", fields, path=os.path.abspath(path), reference="ncempy+rsciio+registration",
                               block=(block_path, c2n, c2s), mutants=mutants,
                               comment=f"{rel}: tag 65027 ({len(raw)} bytes)"))
        log.append((name, fields, [f"tag 65027: {len(raw)} bytes, {len(bn)} numbers and {len(bs)} strings (ncempy); "
                                   f"step (i) re-decoded {c2rep['redecoded']} keys, step (ii) dropped {c2rep['artifacts']}"]))

    # the owner's Ceta TIFFs: the only real Velox data; each gates where provisioned
    owner_present = 0
    for fname in OWNER_FILES:
        path = os.path.join(owner_dir, fname) if owner_dir != "-" else ""
        name = "owner-" + re.sub(r"[^A-Za-z0-9]+", "-", fname.replace(" Ceta.tif", "")).strip("-").lower()
        if not path or not os.path.isfile(path):
            print(f"  skip  {name}: {fname} not found; supply it in References/example_files/ (gitignored) to gate "
                  f"on it")
            continue
        fields = velox_expected(path, conversions)
        if fields == "unreadable":
            fail(f"{fname}: tag 34683 is not XML")
        owner_present += 1
        cases.append(make_case(name, "tiff", fields, path=os.path.abspath(path), reference="rsciio+registration",
                               comment=fname))
        log.append((name, fields, []))

    if problems:
        print("reference.py: THE REFERENCE DISAGREES WITH THE PLANT / ITS OWN CHECKS:", file=sys.stderr)
        for p in problems:
            print("  - " + p, file=sys.stderr)
        sys.exit(1)

    with open(os.path.join(out, "manifest.json"), "w") as fh:
        json.dump({"ncempy": NCEMPY, "rsciio": RSCIIO_COMMIT, "tifffile": TIFFFILE, "mrcfile": MRCFILE,
                   "owner": {"expected": len(OWNER_FILES), "present": owner_present}, "cases": cases,
                   "reads": reads}, fh, indent=1, ensure_ascii=False)
    with open(os.path.join(out, "expected.txt"), "w") as fh:
        for line in bit_lines + epoch_lines:
            fh.write(line + "\n")
        for name, fields, said in log:
            fh.write(f"{name}\n{describe(fields)}\n")
            for s in said:
                fh.write(f"    ({'S-b' if s.startswith(('C2:', 'tag 65027:')) else 'rule vs RosettaSciIO'}) {s}\n")
    for name, fields, said in log:
        for s in said:
            print(f"  note  {name}: {s}")
    for line in bit_lines + epoch_lines:
        print(f"reference.py: {line}")
    planted_n = len(planted["cases"])
    print(f"reference.py: {len(cases)} cases ({planted_n} planted, {len(cases) - planted_n} real, of which "
          f"{owner_present} of {len(OWNER_FILES)} owner Ceta TIFFs); {len(reads)} read(path:) cases "
          f"({len(planted['reads'])} planted, {len(reads) - len(planted['reads'])} real); the reference reproduces "
          f"every planted truth")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
