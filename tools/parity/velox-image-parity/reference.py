#!/usr/bin/env python3
"""Truth for tools/parity/velox-image-parity: the reference's reading of every case.

    reference.py <planted-dir> <rsciio-root> <owner-dir-or-"-"> <out-dir>

Three independent readings of every Velox file, which must agree before any of them counts:

  rule     the registered object rule (archive: roadmap-registrations-2026-10-15.md V1-3a), written here from the raw JSON that h5py reads: an entry of
           Data/Image (a group holding a rank-3 `Data` and a `Metadata`, in h5py's key order) is a CANDIDATE when its
           BinaryResult.DetectorIndex resolves in the Detectors table to a DetectorType other than "AnalyticalDetector"
           and its stored type is an integer of 1-8 bytes or a float of 4 or 8 bytes (not compound); the first candidate
           whose BinaryResult.Detector is "HAADF" opens, else the first candidate; none: noImage; not Velox (no Version
           dataset, a Version whose format is not "Velox", or not HDF5 at all): notVelox. Calibration as stored: scale =
           PixelSize.width / .height, unit = PixelUnitX / PixelUnitY, origin = -Offset / PixelSize (exact rational
           arithmetic), nil when the size is absent or not positive; voltage = Optics.AccelerationVoltage.
  h5py     the raw frames (every frame the harness reads) and the raw strings, h5py 3.16.0.
  rsciio   RosettaSciIO 049e7d70 `rsciio.emd.file_reader(select_type="images")`, References/rosettasciio put on sys.path:
           frame 0 as float32, and each axis's scale and offset converted back to the file's own unit with pint (RosettaSciIO
           puts X's unit on both axes). Parity, not truth: the planted files carry truth by construction.

Before any reading counts: the files are the pinned ones (sha256 against rsciio/tests/registry.txt), the planted files are
the ones make_fixture.py wrote, and rule, h5py and rsciio reproduce every planted truth. A disagreement exits 1 here,
loudly: that is a reference check, never a pass. Writes <out>/manifest.json (contract: README.md) and one .f32 per frame.

rsciio needs `pint` (its unit conversion) and python-dateutil, and tests that `sparse` is importable before it reads an
EDS spectrum image, whatever select_type says; with select_type="images" it never imports it. The check is satisfied here
by a stub module that raises on any use, so a read that did reach sparse would fail loudly (the real package pulls in
numba and llvmlite, which the image path does not need).
"""
import hashlib
import importlib.machinery
import importlib.metadata
import json
import os
import re
import sys
import types
import zipfile
import zoneinfo
from datetime import datetime, timezone
from fractions import Fraction

import h5py
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = os.path.join(HERE, "..", "..", "lib", "references-lock.txt")
PYTHON_MINOR = "3.14"
REGISTRY_SHA256 = "31417482938f80160be2c03525ba58dd810c7f16b1790f597470ece8dd0b1bcb"
RSCIIO_COMMIT = "049e7d70"
WANT = {"h5py": "3.16.0", "numpy": "2.5.4", "python-dateutil": "2.9.0.post0", "pint": "0.26.1"}
ANALYTICAL = "AnalyticalDetector"
MAX_PIXELS = 1 << 28       # SpectroKit's cap on one image (VeloxEMDReader.maximumPixels): a larger one is refused when read
SCALE_REL = 1e-12          # registered P1 band: scale, relative, in the file's own unit
ORIGIN_ABS = 1e-9          # registered P1 band: origin, pixels
ZONE = "Pacific/Auckland"  # the zone the harness shows a date in to check the zone conversion, whatever this Mac's clock is

ZIPS = ["fei_emd_files.zip", "velox_EELS_EDS.zip", "velox_emd_v11_elementSelection.zip", "velox_emd_version11.zip"]
LOOSE_VELOX = ["FFTComplexEven.emd", "FFTComplexOdd.emd", "fei_example_complex_fft.emd", "fei_example_dpc_titles.emd",
               "fei_example_tem_stack.emd"]
LOOSE_OTHER = ["Si100_1x1x3-zStart5.43.emd", "Si100_1x1x3-zStart6.7875.emd", "Si100_2D_3D_DPC_potential_2slices.emd",
               "Si100_2x1x1_3D.emd", "Si100_3D.emd", "Si100_4D.emd", "example_axis_len_1.emd",
               "example_bytes_string_metadata.emd", "example_image.emd", "example_metadata.emd",
               "example_object_dtype_data.emd", "example_signal.emd", "example_spectrum.emd",
               "py4DSTEM_size2x3x4x5_bf20x30.h5"]
OWNER = ["Camera Ceta 1305 17500 x 20260605.emd", "Camera Ceta 1306 28500 x 20260605.emd",
         "Camera Ceta 1309 36000 x 20260605.emd"]


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def slug(text):
    return re.sub(r"[^A-Za-z0-9.-]+", "_", text).strip("_")


def check_reference(root):
    python = "%d.%d" % sys.version_info[:2]
    if python != PYTHON_MINOR:
        fail(f"Python {python} is not the pinned {PYTHON_MINOR}")
    pins = {}
    for line in open(LOCK):
        m = re.match(r"^([A-Za-z0-9_.-]+)==(\S+)\s*$", line)
        if m:
            pins[m.group(1).lower()] = m.group(2)
    for package, version in WANT.items():
        have = importlib.metadata.version(package)
        if have != version:
            fail(f"{package} {have} is not the pinned {version}")
        if package in pins and pins[package] != version:
            fail(f"{package}: tools/lib/references-lock.txt pins {pins[package]}, this harness pins {version}")
        if package not in pins:
            fail(f"{package}=={version} is not in tools/lib/references-lock.txt")
    if sha256_file(os.path.join(root, "rsciio", "tests", "registry.txt")) != REGISTRY_SHA256:
        fail("rsciio/tests/registry.txt is not the pinned file (References/rosettasciio is not the lock)")
    stub = types.ModuleType("sparse")
    stub.__spec__ = importlib.machinery.ModuleSpec("sparse", None)

    def used(name):
        raise AssertionError(f"the sparse stub was used ({name}): select_type='images' reached the EDS stream reader")
    stub.__getattr__ = used
    sys.modules["sparse"] = stub
    sys.path.insert(0, root)
    import rsciio
    from rsciio.emd import file_reader, _api
    from rsciio.emd._emd_velox import FeiEMDReader
    from rsciio.utils._units import convert_units
    if not os.path.realpath(rsciio.__file__).startswith(os.path.realpath(root) + os.sep):
        fail(f"rsciio was imported from {rsciio.__file__}, not the pinned checkout {root}")
    mapping = FeiEMDReader()._get_mapping(map_selected_element=False, parse_individual_EDS_detector_metadata=False)
    return file_reader, _api, convert_units, mapping


def registry(root):
    reg = {}
    for line in open(os.path.join(root, "rsciio", "tests", "registry.txt")):
        m = re.match(r"^'([^']+)'\s+([0-9a-f]{64})\s*$", line)
        if m:
            reg[m.group(1)] = m.group(2)
    return reg


# ------------------------------------------------------------------------------------- the rule, from raw JSON
def raw_metadata(group):
    """Column 0 of an entry's Metadata as JSON, cut at the first NUL (the reader's own cut)."""
    return json.loads(bytes(group["Metadata"][:, 0]).split(b"\0")[0].decode("utf-8"))


def num(v):
    """A JSON number or a decimal string as a float; None when it is neither (the reader's jsonDouble)."""
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v)
        except ValueError:
            return None
    return None


def dtype_kind(dtype):
    """'compound' | the type name of an integer of 1-8 bytes or a float of 4/8 bytes | 'other' (not readable)."""
    if dtype.names:
        return "compound"
    if dtype.kind in "iu" and dtype.itemsize in (1, 2, 4, 8):
        return str(np.dtype(dtype.kind + str(dtype.itemsize)))
    if dtype.kind == "f" and dtype.itemsize in (4, 8):
        return str(np.dtype("f" + str(dtype.itemsize)))
    return "other"


def inspect(path):
    """The rule over one file: {"velox": bool, "error", "entries": [...], "opened": index or None, "all_keys": [...]}."""
    try:
        f = h5py.File(path, "r")
    except OSError:
        return {"velox": False, "error": "notVelox", "entries": [], "opened": None, "all_keys": [], "why": "not HDF5"}
    with f:
        version = None
        if isinstance(f.get("Version"), h5py.Dataset):
            try:
                v = f["Version"][()]
                version = json.loads((v[0] if getattr(v, "shape", ()) else v).decode("utf-8"))
            except Exception:
                version = None
        if not isinstance(version, dict) or version.get("format") != "Velox":
            return {"velox": False, "error": "notVelox", "entries": [], "opened": None, "all_keys": [],
                    "why": f"Version {version!r}"}
        images = f.get("Data/Image")
        all_keys = list(images.keys()) if images is not None else []
        entries = []
        for name in all_keys:
            g = images[name]
            if not isinstance(g, h5py.Group) or "Data" not in g or "Metadata" not in g or g["Data"].ndim != 3:
                continue
            ds = g["Data"]
            try:
                meta = raw_metadata(g)
            except ValueError:      # JSON or UTF-8 that does not decode: the file is damaged, not short of images
                return {"velox": True, "error": "unreadable", "entries": [], "opened": None, "all_keys": all_keys,
                        "why": f"the Metadata of {name} is not JSON"}
            if not isinstance(meta, dict):
                return {"velox": True, "error": "unreadable", "entries": [], "opened": None, "all_keys": all_keys,
                        "why": f"the Metadata of {name} is not a JSON object"}
            br = meta.get("BinaryResult") or {}
            detectors = {}
            for key, d in (meta.get("Detectors") or {}).items():
                m = re.fullmatch(r"Detector-(\d+)", key)
                if m and isinstance(d, dict):
                    detectors[int(m.group(1))] = d
            idx = num(br.get("DetectorIndex"))
            idx = None if idx is None else int(round(idx))
            kind = dtype_kind(ds.dtype)
            resolved = detectors.get(idx) if idx is not None else None
            _bn = br.get("Detector") if isinstance(br.get("Detector"), str) else ""
            if resolved is not None and _bn and resolved.get("DetectorName") != _bn:   # REMEDY (Gate B): the name wins
                _alt = [d for _, d in sorted(detectors.items()) if d.get("DetectorName") == _bn]
                if _alt:
                    resolved = _alt[0]
            dtype_ok = kind not in ("compound", "other")
            candidate = bool(dtype_ok and resolved is not None
                             and (resolved.get("DetectorType") if isinstance(resolved.get("DetectorType"), str) else "") != ANALYTICAL)
            h, w, n = ds.shape
            entries.append({
                "id": name, "detector": br.get("Detector") if isinstance(br.get("Detector"), str) else "",
                "table_name": resolved.get("DetectorName") if resolved else None,
                "indexed": resolved is not None,
                "analytical": bool(resolved is not None and resolved.get("DetectorType") == ANALYTICAL),
                "type": resolved.get("DetectorType") if resolved is not None and isinstance(resolved.get("DetectorType"), str) else None,
                "dtype": kind, "candidate": candidate, "shape": [h, w, n], "meta": meta,
                "chunks": list(ds.chunks) if ds.chunks else None})
        cands = [i for i, e in enumerate(entries) if e["candidate"]]
        haadf = [i for i in cands if entries[i]["detector"] == "HAADF"]
        opened = haadf[0] if haadf else (cands[0] if cands else None)
        error = "noImage" if opened is None else ("unreadable" if entries[opened]["shape"][0] * entries[opened]["shape"][1] > MAX_PIXELS else None)
        return {"velox": True, "error": error, "entries": entries,
                "opened": opened, "all_keys": all_keys}


def calibration(meta):
    """The registered calibration read from the raw JSON: x, y axes ({scale, units, origin} or None) and the voltage."""
    br = meta.get("BinaryResult") or {}
    size = br.get("PixelSize") or {}
    w, h = num(size.get("width")), num(size.get("height"))
    off = br.get("Offset") or {}
    ox, oy = num(off.get("x")), num(off.get("y"))
    if ox is None or oy is None:
        offset = None
    else:
        offset = (str(off.get("x")), str(off.get("y")))

    def axis(size_value, size_text, unit, offset_text):
        if size_value is None or not np.isfinite(size_value) or size_value <= 0:
            return None
        return {"scale": size_value, "units": unit if isinstance(unit, str) else "",
                "origin": 0.0 if offset_text is None else float(-Fraction(offset_text) / Fraction(size_text))}
    return (axis(w, str(size.get("width")), br.get("PixelUnitX"), offset and offset[0]),
            axis(h, str(size.get("height")), br.get("PixelUnitY"), offset and offset[1]),
            num((meta.get("Optics") or {}).get("AccelerationVoltage")))


def local_text(seconds, zone=None):
    """Unix seconds as 'YYYY-MM-DD HH:MM:SS' on this Mac's clock (zone None) or on `zone`'s, whole seconds truncated."""
    when = datetime.fromtimestamp(int(np.floor(seconds)), tz=zoneinfo.ZoneInfo(zone) if zone else None)
    return when.strftime("%Y-%m-%d %H:%M:%S")


def metadata_rule(entry):
    """V1-4a, the `.emd` sentence, from the raw JSON: high tension (V -> kV), the detector (BinaryResult.Detector), the
    instrument (InstrumentModel), the start date (Unix seconds, shown on a clock), the dwell (s -> us) only when the entry's
    detector is a ScanningDetector; absent, empty or not positive is None."""
    meta = entry["meta"]

    def positive(v):
        return v if v is not None and np.isfinite(v) and v > 0 else None

    def text(v):
        return v.strip() if isinstance(v, str) and v.strip() else None
    volts = positive(num((meta.get("Optics") or {}).get("AccelerationVoltage")))
    start = num(((meta.get("Acquisition") or {}).get("AcquisitionStartDatetime") or {}).get("DateTime"))
    dwell = positive(num((meta.get("Scan") or {}).get("DwellTime")))
    scanning = entry["type"] == "ScanningDetector"
    return {"highTensionKV": None if volts is None else volts / 1e3,
            "detector": text((meta.get("BinaryResult") or {}).get("Detector")),
            "instrument": text((meta.get("Instrument") or {}).get("InstrumentModel")),
            "acquired": None if start is None else local_text(start),
            "acquiredZone": None if start is None else local_text(start, ZONE),
            "acquiredUTC": None if start is None else local_text(start, "UTC"),
            "dwellUS": dwell * 1e6 if scanning and dwell is not None else None}


def rsciio_metadata(sig, mapping):
    """RosettaSciIO's own: the beam energy through `_get_mapping`'s Optics.AccelerationVoltage lambda, the title, the date."""
    om, general = sig["original_metadata"], sig["metadata"]["General"]
    volts = (om.get("Optics") or {}).get("AccelerationVoltage")
    date, clock = general.get("date"), general.get("time")
    return {"beamEnergyKV": None if volts is None else mapping["Optics.AccelerationVoltage"][1](volts),
            "title": general.get("title"),
            "acquired": None if date is None or clock is None else f"{date} {clock[:8]}"}


def expected_notes(entry, k):
    n = entry["shape"][2]
    out = [f"frame {k + 1} of {n}"] if n > 1 else []
    if entry["dtype"] in ("int32", "uint32", "int64", "uint64", "float64"):
        out.append(f"stored as {entry['dtype']}, rounded to Float32")
    return out


def source_of(entry):
    return f"Data/Image/{entry['id']}" + (f" · {entry['detector']}" if entry["detector"] else "")


def f32_bits_equal(a, b):
    a, b = np.ascontiguousarray(a, dtype=np.float32), np.ascontiguousarray(b, dtype=np.float32)
    return a.shape == b.shape and np.array_equal(a.view(np.uint32), b.view(np.uint32))


# --------------------------------------------------------------------------------------------- rsciio's reading
def rsciio_reading(file_reader, convert_units, path, info):
    """-> (signals, per entry index -> {"frames": [2D float32 frames rsciio read], "x": {...}, "y": {...}}) in file order."""
    signals = file_reader(path, select_type="images")
    if len(signals) != len(info["all_keys"]):
        raise RuntimeError(f"rsciio read {len(signals)} signals for {len(info['all_keys'])} image groups")
    out = {}
    for key, sig in zip(info["all_keys"], signals):
        out[key] = sig
    return out


def rsciio_axes(sig, entry, convert_units):
    """x, y as {scale, origin} in the file's own PixelUnitX (RosettaSciIO puts X's unit on both axes)."""
    meta = entry["meta"]
    raw_unit = (meta.get("BinaryResult") or {}).get("PixelUnitX", "")
    axes = {a["name"]: a for a in sig["axes"]}
    ax, ay = axes["x"], axes["y"]

    def back(value, unit):
        return float(convert_units(value, unit, raw_unit)) if raw_unit and unit else float(value)
    sx, sy = back(ax["scale"], ax["units"]), back(ay["scale"], ay["units"])
    ox, oy = back(ax["offset"], ax["units"]), back(ay["offset"], ay["units"])
    return {"x": {"scale": sx, "origin": 0.0 if ox == 0 else -ox / sx},
            "y": {"scale": sy, "origin": 0.0 if oy == 0 else -oy / sy}}


def rsciio_frame0(sig):
    data = np.asarray(sig["data"])
    if data.dtype.names or np.iscomplexobj(data):
        return None
    return (data[0] if data.ndim == 3 else data), (data.shape[0] if data.ndim == 3 else 1)


class Builder:
    def __init__(self, out, file_reader, convert_units, mapping):
        self.out, self.file_reader, self.convert_units, self.mapping = out, file_reader, convert_units, mapping
        self.cases, self.problems = [], []
        self.max_scale_rel, self.max_origin = 0.0, 0.0
        self.max_scale_rel_all = 0.0

    def frame_file(self, name, k, array):
        p = os.path.abspath(os.path.join(self.out, f"{name}.frame{k}.f32"))
        np.ascontiguousarray(array.astype("<f4")).tofile(p)
        return p

    def add(self, name, path, group, tag, diagnostic=False, planted=None, use_rsciio=True):
        bad = lambda msg: self.problems.append(f"{name}: {msg}")
        info = inspect(path)
        entries = [{k: v for k, v in e.items() if k not in ("meta",)} for e in info["entries"]]
        case = {"name": name, "path": os.path.abspath(path), "group": group, "tag": tag, "diagnostic": diagnostic,
                "entries": entries, "refused": info["error"] is not None}
        if planted is not None:
            self.check_planted_structure(path, info, planted, bad)
        if info["error"] is not None:
            case.update(kind="refusal", error=info["error"])
            if use_rsciio and info["velox"]:
                try:
                    self.file_reader(path, select_type="images")
                except Exception as e:           # a refused Velox file RosettaSciIO cannot read as an image either
                    print(f"  note  {name}: RosettaSciIO raised {type(e).__name__} on this refused file")
            self.cases.append(case)
            return
        e = info["entries"][info["opened"]]
        n = e["shape"][2]
        x, y, voltage = calibration(e["meta"])
        case.update(kind="image", opened=info["opened"], id=e["id"], source=source_of(e), frame_count=n,
                    width=e["shape"][1], height=e["shape"][0], dtype=e["dtype"], chunks=e["chunks"],
                    x=x, y=y, voltage=voltage, key_position=info["all_keys"].index(e["id"]),
                    key_count=len(info["all_keys"]), detector=e["detector"])
        case["metadata"] = {"rule": metadata_rule(e), "rsciio": None}
        # h5py: the frames the harness reads (0, 1 and the last), as float32
        with h5py.File(path, "r") as f:
            ds = f[f"Data/Image/{e['id']}/Data"]
            wanted = sorted({0, 1, n - 1} & set(range(n)))
            frames = []
            for k in wanted:
                arr = ds[:, :, k].astype(np.float32)
                frames.append({"index": k, "pixels": self.frame_file(name, k, arr),
                               "notes": expected_notes(e, k)})
            case["frames"] = frames
            h5 = {k: ds[:, :, k].astype(np.float32) for k in wanted}
        # rsciio: parity on frame 0 (and every frame it read), the scale and the offset
        case["rsciio"] = None
        if use_rsciio:
            try:
                sigs = rsciio_reading(self.file_reader, self.convert_units, path, info)
            except Exception as err:
                bad(f"RosettaSciIO could not read the file: {type(err).__name__}: {err}")
                sigs = None
            if sigs is not None:
                sig = sigs[e["id"]]
                case["metadata"]["rsciio"] = rsciio_metadata(sig, self.mapping)
                got = rsciio_frame0(sig)
                if got is None:
                    bad("RosettaSciIO reads the opened entry as complex or compound data")
                else:
                    frame0, frames_read = got
                    if not f32_bits_equal(frame0.astype(np.float32), h5[0]):
                        bad("RosettaSciIO's frame 0 as float32 differs from h5py's")
                    data = np.asarray(sig["data"])
                    if data.ndim == 3:
                        if data.shape[0] != n:
                            bad(f"RosettaSciIO read {data.shape[0]} frames of {n}")
                        for k, arr in h5.items():
                            if not f32_bits_equal(data[k].astype(np.float32), arr):
                                bad(f"RosettaSciIO's frame {k} differs from h5py's")
                    axes = rsciio_axes(sig, e, self.convert_units)
                    for name_axis, ours in (("x", x), ("y", y)):
                        theirs = axes[name_axis]
                        if ours is None:
                            continue
                        rel = abs(ours["scale"] - theirs["scale"]) / abs(theirs["scale"])
                        dist = abs(ours["origin"] - theirs["origin"])
                        self.max_scale_rel_all = max(self.max_scale_rel_all, rel)
                        if not diagnostic:
                            self.max_scale_rel = max(self.max_scale_rel, rel)
                            self.max_origin = max(self.max_origin, dist)
                        if rel > SCALE_REL:
                            bad(f"{name_axis} scale: rule {ours['scale']!r}, RosettaSciIO {theirs['scale']!r} (rel {rel:.3g})")
                        if dist > ORIGIN_ABS:
                            bad(f"{name_axis} origin: rule {ours['origin']!r}, RosettaSciIO {theirs['origin']!r}")
                    case["rsciio"] = axes
        self.cases.append(case)

    def check_planted_structure(self, path, info, planted, bad):
        """The rule, h5py and the file must reproduce the planted truth (written by hand in make_fixture.py)."""
        if planted["kind"] == "refusal":
            if info["error"] != planted["error"]:
                bad(f"the rule says {info['error']!r}, planted {planted['error']!r}")
            return
        if info["error"] is not None:
            bad(f"the rule refuses ({info['error']}), planted: opens {planted['opens']}")
            return
        got = [(e["id"], e["detector"], e["candidate"], e["dtype"], e["shape"]) for e in info["entries"]]
        want = [(e["id"], e["detector"], e["candidate"], e["dtype"], e["shape"]) for e in planted["entries"]]
        if got != want:
            bad(f"the rule's entries {got} are not the planted {want}")
        e = info["entries"][info["opened"]]
        if e["id"] != planted["opens"]:
            bad(f"the rule opens {e['id']}, planted {planted['opens']}")
        if source_of(e) != planted["source"]:
            bad(f"source {source_of(e)!r} is not the planted {planted['source']!r}")
        x, y, voltage = calibration(e["meta"])
        for label, got_axis, want_axis in (("x", x, planted["x"]), ("y", y, planted["y"])):
            if (got_axis is None) != (want_axis is None):
                bad(f"{label} axis {got_axis} is not the planted {want_axis}")
            elif got_axis is not None and (got_axis["scale"] != want_axis["scale"] or got_axis["units"] != want_axis["units"]
                                           or abs(got_axis["origin"] - want_axis["origin"]) > ORIGIN_ABS):
                bad(f"{label} axis {got_axis} is not the planted {want_axis}")
        if voltage != planted["voltage"]:
            bad(f"voltage {voltage!r} is not the planted {planted['voltage']!r}")
        with h5py.File(path, "r") as f:
            ds = f[f"Data/Image/{e['id']}/Data"]
            for k, want_frame in enumerate(planted["frames"]):
                if not f32_bits_equal(ds[:, :, k].astype(np.float32), np.array(want_frame, dtype=np.float32)):
                    bad(f"frame {k} of the file is not the planted frame")
        rule = metadata_rule(e)
        for key, want in planted["metadata"].items():
            have = rule["acquiredUTC"] if key == "acquiredUTC" else rule[key]
            if have != want and not (isinstance(have, float) and isinstance(want, float) and abs(have - want) <= 1e-12 * abs(want)):
                bad(f"metadata {key}: {have!r} is not the planted {want!r}")
        for k in range(e["shape"][2]):
            if expected_notes(e, k) != planted["notes"][k]:
                bad(f"notes of frame {k}: {expected_notes(e, k)} are not the planted {planted['notes'][k]}")


def main(planted_dir, root, owner_dir, out):
    file_reader, api, convert_units, mapping = check_reference(root)
    os.makedirs(out, exist_ok=True)
    reg = registry(root)
    data_dir = os.path.join(root, "rsciio", "tests", "data", "emd")

    def trusted(member):
        key = "emd/" + member
        if key not in reg:
            fail(f"{key} is not in rsciio/tests/registry.txt")
        if sha256_file(os.path.join(data_dir, member)) != reg[key]:
            fail(f"{key} does not match rsciio/tests/registry.txt")
        return os.path.join(data_dir, member)

    b = Builder(out, file_reader, convert_units, mapping)
    planted = json.load(open(os.path.join(planted_dir, "planted.json")))
    if planted["h5py"] != WANT["h5py"]:
        fail(f"planted files were written by h5py {planted['h5py']}, this run is {WANT['h5py']}")

    # ---------------- planted: the reference must reproduce the plant ----------------
    for c in planted["cases"]:
        path = os.path.join(planted_dir, c["file"])
        if sha256_file(path) != c["sha256"]:
            fail(f"{c['file']} is not the file make_fixture.py wrote")
        b.add(c["name"], path, "planted", "planted", planted=c, use_rsciio=c["rsciio"])
        if c["rsciio"] is False and c["kind"] == "refusal":
            # a planted non-Velox file: neither of RosettaSciIO's Velox test nor the rule may take it for Velox
            if c["error"] == "notVelox":
                try:
                    is_velox = api.is_EMD_Velox(path)
                except Exception:
                    is_velox = False
                if is_velox:
                    b.problems.append(f"{c['name']}: RosettaSciIO's is_EMD_Velox accepts the planted non-Velox file")

    # ---------------- RosettaSciIO's own files (sha256 against its registry) ----------------
    zdir = os.path.join(out, "zips")
    for zname in ZIPS:
        zpath = trusted(zname)
        dest = os.path.join(zdir, zname[:-4])
        os.makedirs(dest, exist_ok=True)
        with zipfile.ZipFile(zpath) as z:
            for member in z.namelist():
                if os.path.basename(member) != member or member.startswith("."):
                    fail(f"{zname} holds a member whose name is not a plain file name: {member!r}")
                with z.open(member) as src, open(os.path.join(dest, member), "wb") as dst:
                    dst.write(src.read())
        for member in sorted(os.listdir(dest)):
            if member.endswith(".emd"):
                p = os.path.join(dest, member)
                velox = api.is_EMD_Velox(p)
                if not velox:
                    b.problems.append(f"{member}: RosettaSciIO does not take a zip member for Velox")
                    continue
                b.add("rsciio-" + slug(member[:-4]), p, "rsciio-zip", "zip13")
    for member in LOOSE_VELOX:
        p = trusted(member)
        if not api.is_EMD_Velox(p):
            b.problems.append(f"{member}: RosettaSciIO does not take it for Velox")
            continue
        b.add("rsciio-" + slug(member[:-4]), p, "rsciio-loose", "loose-velox")
    for member in LOOSE_OTHER:
        p = trusted(member)
        if api.is_EMD_Velox(p):
            b.problems.append(f"{member}: RosettaSciIO takes a file the registration lists as non-Velox for Velox")
            continue
        b.add("rsciio-nonvelox-" + slug(os.path.splitext(member)[0]), p, "rsciio-nonvelox", "non-velox")

    # ---------------- the owner's Ceta .emd (diagnostic) ----------------
    ceta_pairs = {}
    for member in OWNER:
        p = os.path.join(owner_dir, member) if owner_dir != "-" else ""
        name = "owner-" + slug(member[:-4])
        if not p or not os.path.isfile(p):
            print(f"  skip  {name}: {member} not found; supply it in References/example_files/ (gitignored) to run this diagnostic")
            continue
        b.add(name, p, "owner", "ceta", diagnostic=True)
        tif = p[:-4] + " Ceta.tif"
        if os.path.isfile(tif):
            b.cases[-1]["tiff"] = os.path.abspath(tif)

    if b.problems:
        print("reference.py: the references disagree with the plant or with each other:", file=sys.stderr)
        for p in b.problems:
            print("  " + p, file=sys.stderr)
        sys.exit(1)

    # The DEVIATION (the y unit from PixelUnitY): inert wherever the file writes both units alike. Counted on the public files.
    lacking = []
    n_candidates = 0
    for c in b.cases:
        if c["group"] == "planted" or c["kind"] != "image" and not c["entries"]:
            continue
        with h5py.File(c["path"], "r") as f:
            for e in c["entries"]:
                if not e["candidate"]:
                    continue
                n_candidates += 1
                br = raw_metadata(f[f"Data/Image/{e['id']}"]).get("BinaryResult") or {}
                missing = [k for k in ("PixelSize", "PixelUnitX", "PixelUnitY", "Offset") if k not in br]
                if missing or br.get("PixelUnitX") != br.get("PixelUnitY"):
                    lacking.append(f"{c['name']} {e['id'][:8]}: lacks {missing}, units {br.get('PixelUnitX')!r}/{br.get('PixelUnitY')!r}")
    print(f"reference.py: {n_candidates} candidate entries in the public files; "
          + ("each carries PixelSize, Offset and the same PixelUnitX and PixelUnitY (the y-unit DEVIATION is inert on them)"
             if not lacking else f"{len(lacking)} lack one or differ in units: {lacking}"))

    manifest = {"rsciio": RSCIIO_COMMIT, "h5py": h5py.__version__, "numpy": np.__version__,
                "max_scale_rel": b.max_scale_rel, "max_origin": b.max_origin, "cases": b.cases}
    with open(os.path.join(out, "manifest.json"), "w") as fh:
        json.dump(manifest, fh)
    opened = sum(1 for c in b.cases if c["kind"] == "image")
    print(f"reference.py: {len(b.cases)} cases ({opened} open, {len(b.cases) - opened} refused); rule, h5py and RosettaSciIO "
          f"agree: max scale difference {b.max_scale_rel:.3g} relative, max origin difference {b.max_origin:.3g} px (gated cases)")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
