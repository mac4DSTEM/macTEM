# The DM4 writer that makes the planted-truth fixture (make_fixture.py). macTEM's own since 2026-10-15: copied from
# mac4DSTEM 7d6fdbd1 (tools/demo-edx/dm4_writer.py), which no longer has it.
"""tools/demo-edx/dm4_writer.py — a minimal DM4 (Gatan DigitalMicrograph) writer.

Grammar, as read by mac4DSTEM's `DM4Reader` / `DM4Experiment` and RosettaSciIO
(`digitalmicrograph/_api.py`): tag headers and the tag-directory counts are
BIG-endian, tag DATA is LITTLE-endian (byte-order field = 1), DM4 sizes are 8
bytes, an empty label means "unnamed, numbered one-based by position".

  file   = u32be version(4) | u64be root-length | u32be byte-order(1) | group | u64 0
  group  = u8 sorted | u8 open | u64be nTags | tag*
  tag    = u8 type(20 group / 21 data) | u16be labelLen | label | u64be tagSize | body
  body(21) = "%%%%" | u64be nInfo | u64be info[nInfo] | data (little-endian)
  info   = [typeCode]                     a scalar
           [20, elemTypeCode, length]     an array (a string is an array of ushort)

Type codes (struct fields too; 11 = int64, as in the owner's Spectrum Image Rect / Unique Image ID structs): 2 int16, 3 int32, 4 uint16, 5 uint32, 6 float32, 7 float64, 8 bool/uint8.
Strings are ushort arrays (what GMS writes); type-18 string tags are NOT used (DM4Reader
desyncs on them, see laneB report 2). Calibration Origin/Scale are float32, as in the real
GMS EDS file (RosettaSciIO reads 0.004999999888 for a 5 eV channel).
"""
import struct
from typing import List, Tuple, Union

import numpy as np

_CODES = {"i16": (2, "<i2"), "i32": (3, "<i4"), "u16": (4, "<u2"), "u32": (5, "<u4"),
          "i64": (11, "<i8"), "f32": (6, "<f4"), "f64": (7, "<f8"), "u8": (8, "<u1")}


class Group:
    def __init__(self, label: str = "", children=None):
        self.label = label
        self.children = list(children or [])

    def add(self, node):
        self.children.append(node)
        return node

    def group(self, label: str = "") -> "Group":
        return self.add(Group(label))

    def value(self, label, kind, v):
        return self.add(Value(label, kind, v))

    def string(self, label, s):
        return self.add(Array(label, "u16", np.frombuffer(s.encode("utf-16-le"), dtype="<u2")))

    def struct(self, label, kind, values):
        """A type-15 struct of equal-typed fields (info [15, 0, n, 0, code, ...]); how the owner's files store the rect and IDs."""
        return self.add(Struct(label, kind, list(values)))

    def array(self, label, kind, a):
        return self.add(Array(label, kind, np.ascontiguousarray(a)))


class Value:
    def __init__(self, label, kind, v):
        self.label, self.kind, self.v = label, kind, v


class Struct:
    def __init__(self, label, kind, values):
        self.label, self.kind, self.values = label, kind, values


class Array:
    def __init__(self, label, kind, a):
        self.label, self.kind, self.a = label, kind, a


Chunks = Tuple[List[Union[bytes, memoryview]], int]


def _cat(parts) -> Chunks:
    chunks, n = [], 0
    for c in parts:
        chunks.extend(c[0]); n += c[1]
    return chunks, n


def _b(b: bytes) -> Chunks:
    return [b], len(b)


def _tag(kind_byte: int, label: str, body: Chunks) -> Chunks:
    lab = label.encode("utf-8")
    head = struct.pack(">BH", kind_byte, len(lab)) + lab + struct.pack(">Q", body[1])
    return _cat([_b(head), body])


def _data_body(info, payload: Chunks) -> Chunks:
    head = b"%%%%" + struct.pack(">Q", len(info)) + b"".join(struct.pack(">Q", i) for i in info)
    return _cat([_b(head), payload])


def _encode(node) -> Chunks:
    if isinstance(node, Group):
        kids = [_encode(c) for c in node.children]
        head = struct.pack(">BBQ", 1, 0, len(kids))
        return _tag(20, node.label, _cat([_b(head)] + kids))
    if isinstance(node, Value):
        code, dt = _CODES[node.kind]
        payload = np.asarray(node.v, dtype=dt).tobytes()
        return _tag(21, node.label, _data_body([code], _b(payload)))
    if isinstance(node, Struct):
        code, dt = _CODES[node.kind]
        info = [15, 0, len(node.values)] + [x for _ in node.values for x in (0, code)]
        payload = np.asarray(node.values, dtype=dt).tobytes()
        return _tag(21, node.label, _data_body(info, _b(payload)))
    if isinstance(node, Array):
        code, dt = _CODES[node.kind]
        a = np.asarray(node.a, dtype=dt)
        mv = memoryview(a).cast("B")
        return _tag(21, node.label, _data_body([20, code, a.size], ([mv], len(mv))))
    raise TypeError(node)


def write_dm4(path: str, root: Group) -> int:
    """Writes `root` (its children are the file's top-level tags). Returns the file size."""
    kids = [_encode(c) for c in root.children]
    group = _cat([_b(struct.pack(">BBQ", 1, 0, len(kids)))] + kids)
    total = 16 + group[1] + 8
    with open(path, "wb") as f:
        f.write(struct.pack(">IQI", 4, total - 16 - 8, 1))   # root length: the group (see report)
        for c in group[0]:
            f.write(c)
        f.write(b"\0" * 8)
    return total


def image_object(*, name: str, dtype: str, dims, data: np.ndarray, calibrations,
                 unique_id, image_tags: Group, brightness_units: str = "") -> Group:
    """One `ImageList` entry. `dims` is DM order, FASTEST FIRST; `data` is already the flat
    memory array (first dimension fastest = C order of the reversed dims). `calibrations` is
    one (origin, scale, units) per dim."""
    obj = Group()
    data_g = obj.group("ImageData")
    cal = data_g.group("Calibrations")
    b = cal.group("Brightness")
    b.value("Origin", "f32", 0.0); b.value("Scale", "f32", 1.0); b.string("Units", brightness_units)
    dg = cal.group("Dimension")
    for o, s, u in calibrations:
        g = dg.group("")
        g.value("Origin", "f32", o); g.value("Scale", "f32", s); g.string("Units", u)
    cal.value("DisplayCalibratedUnits", "u8", 1)
    code = {"u8": 6, "i16": 1, "f32": 2, "i32": 7, "u16": 10, "u32": 11, "f64": 12, "rgba": 23}[dtype]
    data_g.value("DataType", "i32", code)
    dm = data_g.group("Dimensions")
    for d in dims:
        dm.value("", "u32", d)
    if dtype == "rgba":
        data_g.array("Data", "u8", data)
        data_g.value("PixelDepth", "i32", 4)
    else:
        data_g.array("Data", dtype, data)
        data_g.value("PixelDepth", "i32", {"u8": 1, "i16": 2, "u16": 2}.get(dtype, 4 if dtype != "f64" else 8))
    obj.add(image_tags)
    obj.string("Name", name)
    uid = obj.group("UniqueID")
    for v in unique_id:
        uid.value("", "i32", v)
    return obj
