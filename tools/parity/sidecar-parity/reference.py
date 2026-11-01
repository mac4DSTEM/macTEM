#!/usr/bin/env python3
"""Truth for tools/parity/sidecar-parity: h5py 3.16.0 against macTEM's session sidecar (the file layer, then the fixed-length strings).

    reference.py plant <ref-dir>               plant every input and write its truth: <ref-dir>/manifest.json, the pixel
                                               sets (pixels/*.f32) and the sidecars h5py writes (planted/*.mactem.h5)
    reference.py readback <ref-dir> <out-dir>  read with h5py what the Swift harness wrote (<out-dir>/swift/ and
                                               <out-dir>/swift-written.json) and write <out-dir>/readback.json: one
                                               {name, ok, detail} per check, which the harness prints and counts

What is independent here. The sidecar's four root attributes are read and written by h5py, never by the library Swift calls
(h5py ships its own HDF5). The fixed-length-string rule: each attribute Swift writes must be a SCALAR FIXED-LENGTH string, null-padded
(H5T_STR_NULLPAD), UTF-8, as many bytes as the text (1 for an empty text: HDF5 has no size 0), and the storage byte-equal to
the text; h5py reads the type with its own low-level calls (class, variable-or-not, size, pad, character set) and the
storage with a numpy `S` buffer of the stored size (which keeps every byte). h5py writes every sidecar it plants the same
way, through the low-level API (the high-level one gives ASCII for numpy's `S` and cannot say NULLTERM or UTF-8), except
the deliberate variable-length plants: each of the four attributes variable-length in an otherwise valid sidecar, and the
archived hang file (tools/parity/sidecar-parity/fixtures/hangcase-flip.mactem.h5, pinned by its SHA-256, which h5py's
own read spins forever on: proved here by a child process killed at its deadline). A text over 60 000 bytes needs the
newest file format to be an attribute (h5py's default format caps an attribute message at 64 KiB), so those plants are
written with libver="latest"; Swift's own files carry no such option. The JSON is parsed by Python's json module, whose
canonical form (sorted keys, no spaces, no escaping of non-ASCII or "/") is checked against the text Swift wrote. A
coordinate or a measurement is a STRING in the lineage; it counts only if `float(text)` is bit-equal to the planted double,
which is given here as its IEEE-754 bit pattern, never as decimal text. A recorded date counts only if it is the planted
integer, a JSON integer and not a float. The lineage the Swift writer must produce is derived here from the operations by
`simulate`, a second implementation of the registered rules (ids from next_id, never reused and not spent by a refused add;
replace in place, never of a removed node; a deleted mark leaves no node; a cited node is kept with a `removed` date and
goes with its last citer, and every removed node only it cited goes too). The cascade is a walk over the edges from the
live nodes; `simulate_checked` holds it to the slow formulation of the rule on every plan short enough for it. The dates
the plan plants are checked on exact fractions (the nearest millisecond, a tie away from zero). The pixels' fingerprint is
hashlib.sha256 over the float32 little-endian bytes (numpy), cross-checked here over the uint32 words packed by struct. The
name limit (255 UTF-16 code units) is checked against the scratch volume itself. The fuzz (P3) is planned here:
the three sessions whose files are mutated (a marks session, a lineage of about 60 KB, one of 2 000 nodes) are ordinary
sessions of the plan, checked by h5py like the rest; the mutation schedule is the manifest's `fuzz` block.

Before anything is read back, a reference check proves the plants are what the plan says (h5py reads each planted attribute
as the kind it was meant to be: a fixed-length string is fixed-length, with the pad and the character set asked for; a
variable-length one is variable-length; the invalid UTF-8 is invalid; the truncated file does not open in h5py either; the
hang file hangs in h5py). A disagreement exits 1 here, loudly: that is a reference check, never a pass.
"""
import errno
import hashlib
import importlib.metadata
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import unicodedata
from fractions import Fraction

import h5py
import numpy as np
from h5py import h5a, h5s, h5t

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import marks_reference
import dense_fuzz

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = os.path.join(HERE, "..", "..", "lib", "references-lock.txt")
PYTHON_MINOR = "3.14"
WANT = {"h5py": "3.16.0", "numpy": "2.5.4"}

IDENTITY = "mactem_session_schema"
MIN_READER = "mactem_min_reader_schema"
SOURCE = "mactem_source"
LINEAGE = "mactem_lineage"
ATTRIBUTES = [IDENTITY, MIN_READER, SOURCE, LINEAGE]
SUFFIX = ".mactem.h5"
CAP = 4 << 20                 # the registered 4 MiB cap on a stored string
MAX_NODES = 2000
TOTAL_CAP = 60_000            # the text cap: the most text the writer puts in the four attributes together
MAX_NEXT_ID = 1_000_000
MS0 = 1_791_900_000_123       # a planted date, milliseconds since 1970

# The evidence for the fixed-length strings: a sidecar (all four attributes variable-length) with one byte of a global-heap object size flipped, on
# which a variable-length H5Aread spins forever. Pinned by content, so a changed fixture file is a reference failure.
HANG_FILE = os.path.join(HERE, "fixtures", "hangcase-flip.mactem.h5")
HANG_SHA256 = "2a3824563398c2e8213f8282809d908383314c72aced3deb06300c81be6d543e"
HANG_DEADLINE = 6             # seconds h5py is given to read it; it never returns
DENSE_ABOVE = 65_000          # a text over this is in dense storage (the switch is at about 65,499 bytes: the sheet's measurement)
LATEST_ABOVE = 60_000         # an attribute text over this many bytes needs libver="latest" (h5py's default caps a message at 64 KiB)


def fail(message):
    print(f"FAIL: reference check: {message}", file=sys.stderr)
    sys.exit(1)


def check_reference():
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
        if pins.get(package) != version:
            fail(f"{package}=={version} is not what tools/lib/references-lock.txt pins ({pins.get(package)})")


def canon(obj):
    """Python's canonical JSON: sorted keys, no spaces, non-ASCII and "/" written as they are."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def bits_of(x):
    return struct.pack(">d", x).hex()


def S(text):
    return ("s", text)


def D(x):
    return ("d", float(x))


def spec(value):
    kind, v = value
    return {"s": v} if kind == "s" else {"d": bits_of(v)}


def text_of(value):
    kind, v = value
    return v if kind == "s" else repr(v)


# ---------------------------------------------------------------- the pixels

def pixel_sets():
    """name -> (width, height, float32 little-endian array). The fingerprint is a property of the bytes alone."""
    six = np.array([1.0, -2.5, 0.0, 3.1415927, 1e-30, 16777216.0], dtype="<f4")
    six_ulp = six.copy().view("<u4")
    six_ulp[3] += 1                                  # one unit in the last place of one pixel
    special = np.array([0x00000000, 0x80000000, 0x00000001, 0x7F7FFFFF, 0xFF800000, 0x7FC00001, 0x3F800000, 0xBF800001],
                       dtype="<u4").view("<f4")      # +0, -0, the least subnormal, the largest, -inf, a NaN with a payload
    grid = np.random.default_rng(20261013).standard_normal((128, 256)).astype("<f4")
    return {
        "six": (3, 2, six),
        "six-tall": (2, 3, six.copy()),              # the same bytes, another shape
        "six-ulp": (3, 2, six_ulp.view("<f4")),
        "special": (4, 2, special),
        "grid": (256, 128, grid.reshape(-1)),
        "ramp-a": (2, 2, np.array([0, 10, 20, 40], dtype="<f4")),
        "ramp-b": (2, 2, np.array([5, 25, 45, 85], dtype="<f4")),   # 2a + 5: the same picture once normalised
    }


def fingerprint(array):
    data = array.astype("<f4").tobytes()
    words = array.astype("<f4").view("<u4")
    again = hashlib.sha256(b"".join(struct.pack("<I", int(w)) for w in words)).hexdigest()
    first = sha(data)
    if first != again:
        fail("the two fingerprint computations disagree")
    return first


# ---------------------------------------------------------------- the lineage, as the registered rules say

def survivors(nodes):
    """Every live node and every removed node that a surviving node cites, directly or through other removed nodes: what is
    left once no removed node is uncited. A walk over the edges from the live nodes (the Swift code counts citations instead)."""
    by_id = {n["id"]: n for n in nodes}
    keep = {n["id"] for n in nodes if "removed" not in n}
    stack = list(keep)
    while stack:
        for e in by_id[stack.pop()]["inputs"]:
            if e["step"] in by_id and e["step"] not in keep:
                keep.add(e["step"])
                stack.append(e["step"])
    return [n for n in nodes if n["id"] in keep]


def simulate(ops, orphan_loop=False):
    """The nodes and next_id the registered rules give for `ops` (ids never reused and not spent by a refused add; replace in
    place, never of a removed node; a deleted mark has no node; a cited node is kept with `removed` and goes with its last
    citer, and every removed node only it cited goes too). `orphan_loop` takes the cascade from the slow formulation the
    rules read as (delete a removed node nothing cites, again and again), which `simulate_checked` holds the walk to."""
    next_id, nodes = 1, []

    def cited(node_id):
        return any(e["step"] == node_id for n in nodes for e in n["inputs"])

    for op in ops:
        if op["op"] == "add":
            nodes.append({"id": f"s{next_id}", "kind": op["kind"], "parameters": op["parameters"],
                          "results": op["results"], "inputs": op.get("inputs", []), "external": [], "recorded": op["ms"]})
            next_id += 1
        elif op["op"] == "add_refused":
            # an input naming a removed node, or no node at all: refused by name, nothing minted, nothing changed
            for e in op["inputs"]:
                if any(n["id"] == e["step"] and "removed" not in n for n in nodes):
                    fail(f"add_refused names the live node {e['step']}")
            if op["refusal"]["name"] != "danglingInput" or op["refusal"]["step"] != op["inputs"][0]["step"] \
                    or op["refusal"]["from"] != f"s{next_id}":
                fail(f"add_refused: the refusal {op['refusal']} is not danglingInput of the first input from s{next_id}")
        elif op["op"] == "replace":
            node = next(n for n in nodes if n["id"] == op["id"] and "removed" not in n)
            node["parameters"], node["results"], node["recorded"] = op["parameters"], op["results"], op["ms"]
        elif op["op"] == "replace_refused":
            if not any(n["id"] == op["id"] and "removed" in n for n in nodes):
                fail("replace_refused must name a removed node")
        elif op["op"] == "remove":
            index = next(i for i, n in enumerate(nodes) if n["id"] == op["id"])
            if cited(op["id"]):
                nodes[index].setdefault("removed", op["ms"])
            else:
                del nodes[index]
                if orphan_loop:
                    while True:
                        orphan = next((i for i, n in enumerate(nodes) if "removed" in n and not cited(n["id"])), None)
                        if orphan is None:
                            break
                        del nodes[orphan]
                else:
                    nodes[:] = survivors(nodes)
        else:
            fail(f"unknown operation {op['op']}")
    return nodes, next_id


def simulate_checked(ops):
    """`simulate`, and for a plan short enough for the slow formulation (cubic) the same answer from it."""
    nodes, next_id = simulate(ops)
    if len(ops) <= 200 and simulate(ops, orphan_loop=True) != (nodes, next_id):
        fail("the two formulations of the removal rule disagree on a planted session")
    return nodes, next_id


def round_half_away(x):
    """A Fraction rounded to the nearest integer, a tie away from zero (the registered rule for a recorded date)."""
    n = (abs(x) + Fraction(1, 2)) // 1
    return int(n) if x >= 0 else -int(n)


CLAMP = 9_000_000_000_000_000          # a date no millisecond count within this can hold is clamped to it; NaN is 0
SPECIAL_DATES = {"+inf": CLAMP, "-inf": -CLAMP, "nan": 0}


def check_op_date(op):
    """The plan's own consistency: the recorded value an operation states is what the registered rounding gives for the
    date it plants (nearest millisecond, a tie away from zero), computed here on exact fractions."""
    if "at" in op and round_half_away(Fraction(op["at"])) != op["ms"]:
        fail(f"the date {op['at']!r} ms rounds to {round_half_away(Fraction(op['at']))}, not the planted {op['ms']}")
    if "at_special" in op and SPECIAL_DATES.get(op["at_special"]) != op["ms"]:
        fail(f"the date {op['at_special']} clamps to {SPECIAL_DATES.get(op['at_special'])}, not the planted {op['ms']}")


def node_json(node):
    out = {"external": [], "id": node["id"], "inputs": [dict(e) for e in node["inputs"]], "kind": node["kind"],
           "parameters": {k: text_of(v) for k, v in node["parameters"]}, "recorded": node["recorded"],
           "results": {k: text_of(v) for k, v in node["results"]}}
    if "removed" in node:
        out["removed"] = node["removed"]
    return out


def lineage_text(nodes, next_id):
    return canon({"version": 1, "next_id": next_id, "nodes": [node_json(n) for n in nodes]})


def node_spec(node):
    """A node as the harness reads it: every string as it is stored, the doubles also as their planted bit patterns."""
    coords = {}
    for group in ("parameters", "results"):
        for k, v in node[group]:
            if v[0] == "d":
                coords[f"{group}.{k}"] = bits_of(v[1])
    return {"id": node["id"], "kind": node["kind"],
            "parameters": [{"k": k, **spec(v)} for k, v in node["parameters"]],
            "results": [{"k": k, **spec(v)} for k, v in node["results"]],
            "inputs": [dict(e) for e in node["inputs"]], "recorded": node["recorded"], "removed": node.get("removed"),
            "stored_parameters": {k: text_of(v) for k, v in node["parameters"]},
            "stored_results": {k: text_of(v) for k, v in node["results"]}, "coords": coords}


def op_spec(op):
    out = {"op": op["op"], "ms": op["ms"]}
    check_op_date(op)
    for key in ("id", "kind", "at", "at_special", "refusal"):
        if key in op:
            out[key] = op[key]
    for key in ("parameters", "results"):
        if key in op:
            out[key] = [{"k": k, **spec(v)} for k, v in op[key]]
    if "inputs" in op:
        out["inputs"] = op["inputs"]
    return out


def add(kind, parameters, results, ms, inputs=None):
    return {"op": "add", "kind": kind, "parameters": parameters, "results": results, "ms": ms, "inputs": inputs or []}


MARKS_OPS = [
    add("distance",
        [("x1", D(0.1)), ("y1", D(1e-300)), ("x2", D(-0.0)), ("y2", D(16777217.5)),
         ("object", S("ImageList.2 · HAADF")), ("frame", S("frame 1 of 3"))],
        [("length", D(29.75)), ("unit", S("Å")), ("scale_x", D(0.0123)), ("scale_unit", S("µm"))], MS0),
    add("angle",
        [("x1", D(5e-324)), ("y1", D(1.7976931348623157e308)), ("x2", D(0.30000000000000004)),
         ("y2", D(123456789.12345679)), ("x3", D(2.2250738585072014e-308)), ("y3", D(9007199254740991.0))],
        [("angle", D(89.99999999999999)), ("unit", S("°"))], MS0 + 1),
    add("profile",
        [("x1", D(1e16)), ("y1", D(1e15)), ("x2", D(1e-5)), ("y2", D(100.0)), ("width", S("5"))],
        [("samples", S("123")), ("unit", S("µm")), ("reciprocal_unit", S("1/nm"))], MS0 + 2),
    add("distance", [("x1", D(1.5)), ("y1", D(2.5)), ("x2", D(3.5)), ("y2", D(4.5))], [("length", D(2.8284271247461903))],
        MS0 + 3),
    {"op": "remove", "id": "s4", "ms": MS0 + 4},
    add("export", [("format", S("csv"))], [("rows", S("123"))], MS0 + 5, inputs=[{"step": "s3", "role": "profile"}]),
    {"op": "remove", "id": "s3", "ms": MS0 + 6},
    add("distance", [("x1", D(10.5)), ("y1", D(20.0)), ("x2", D(40.25)), ("y2", D(20.0))], [("length", D(29.75)),
                                                                                         ("unit", S("nm"))], MS0 + 7),
    {"op": "replace", "id": "s1", "ms": MS0 + 8,
     "parameters": [("x1", D(-2.5e-7)), ("y1", D(1e-300)), ("x2", D(0.1)), ("y2", D(-0.0)),
                    ("object", S("ImageList.2 · HAADF")), ("frame", S("frame 1 of 3"))],
     "results": [("length", D(1.0e-7)), ("unit", S("Å"))]},
]

UNICODE_OPS = [
    add("distance", [("x1", D(0.5)), ("y1", D(0.25)), ("x2", D(2.0)), ("y2", D(8.0)),
                     ("note", S('He said "hi"\\ back\nline\ttab /slash ✓ Å µ · é')),
                     ("controls", S("\x00\x01\x08\x0c\r\x1f\x7f\u2028\ufeff")), ("Å", S("angstrom key")), ("µ-key", S("micro key")),
                     ("\U0001F52C", S("astral key"))],
        [("unit", S("Å")), ("length", D(7.75)), ("scale_unit", S("µm")), ("emoji", S("☆ \U0001F52C"))], MS0 + 100),
]


def refused_add(kind, parameters, results, ms, inputs, step, from_id):
    """An add that must be refused: an input naming a removed node (or a missing one). `from_id` is the id it would have minted."""
    return {"op": "add_refused", "kind": kind, "parameters": parameters, "results": results, "ms": ms, "inputs": inputs,
            "refusal": {"name": "danglingInput", "step": step, "from": from_id}}


KEPT_OPS = [
    add("distance", [("x1", D(1.0)), ("y1", D(2.0)), ("x2", D(3.0)), ("y2", D(4.0))], [("length", D(2.8284271247461903))], MS0),
    add("profile", [("x1", D(0.5)), ("y1", D(0.5)), ("x2", D(9.5)), ("y2", D(0.5)), ("width", S("3"))], [("samples", S("10"))], MS0 + 1),
    add("export", [("format", S("csv"))], [("rows", S("10"))], MS0 + 2, inputs=[{"step": "s2", "role": "profile"}]),
    {"op": "remove", "id": "s2", "ms": MS0 + 3},       # cited by s3: kept, with the removed date MS0 + 3
    # a removed node is kept only for the nodes that already cite it: a new node may not cite it, nor a node that is not there,
    # and the refused add spends no id (the next add below is s4)
    refused_add("export", [("format", S("png"))], [("bytes", S("1"))], MS0 + 4, [{"step": "s2", "role": "profile"}], "s2", "s4"),
    refused_add("export", [("format", S("png"))], [("bytes", S("1"))], MS0 + 4, [{"step": "s99", "role": "profile"}], "s99", "s4"),
    {"op": "replace_refused", "id": "s2", "ms": MS0 + 5, "parameters": [("x1", D(7.0))], "results": [("samples", S("1"))]},
    {"op": "remove", "id": "s2", "ms": MS0 + 6},       # a second removal keeps the first date
]
CASCADE_OPS = KEPT_OPS + [
    add("export", [("format", S("png"))], [("bytes", S("1"))], MS0 + 7, inputs=[{"step": "s3", "role": "export"}]),
    {"op": "remove", "id": "s3", "ms": MS0 + 8},       # cited by s4: kept
    {"op": "remove", "id": "s4", "ms": MS0 + 9},       # s4 goes, then s3 (removed, no citer), then s2 (removed, no citer)
]
LINE = [("x1", D(0.0)), ("y1", D(0.0)), ("x2", D(1.0)), ("y2", D(1.0))]


def dated(ms, **when):
    return {**add("distance", LINE, [("length", D(1.4142135623730951))], ms), **when}


DATES_OPS = [      # a Date is recorded as the NEAREST integer millisecond, before and after 1970, a tie away from zero
    dated(MS0 + 1, at=MS0 + 0.7),
    dated(MS0, at=MS0 + 0.3),
    dated(-1001, at=-1000.7),
    # ties, exact in binary (62.5 ms is 1/16 s): half-to-even would record 62, -62 and 312, -312
    dated(63, at=62.5), dated(-63, at=-62.5), dated(313, at=312.5), dated(-313, at=-312.5),
    # a date no millisecond count can hold is clamped to +-9e15 (the Int64 conversion stays defined), NaN is 0
    dated(CLAMP, at_special="+inf"), dated(-CLAMP, at_special="-inf"), dated(0, at_special="nan"),
]


CHAIN_LENGTH = 250             # 1999 nodes (the cascade's 19 s regression) are SessionLineageTests'; the writer holds a sidecar to 60,000 bytes


def chain_ops(length=CHAIN_LENGTH):
    """A chain s1 <- s2 <- ... <- s<length>, every node but the last removed (each is cited by the next, so all are kept), then a
    new live node s<length + 1>, then the last of the chain removed: it is uncited, goes, and the whole chain of removed
    nodes goes with it (1998 removals cascade). The Swift sweep is one pass; its first version took 19 s over this."""
    ops = [add("distance", [("x1", D(0.0))], [("length", D(0.0))], MS0)]
    for i in range(2, length + 1):
        ops.append(add("export", [("n", S(str(i)))], [], MS0 + i, inputs=[{"step": f"s{i - 1}", "role": "chain"}]))
    ops += [{"op": "remove", "id": f"s{i}", "ms": MS0 + length + i} for i in range(1, length)]
    ops.append(add("distance", [("x1", D(1.0))], [("length", D(1.0))], MS0 + 2 * length))
    ops.append({"op": "remove", "id": f"s{length}", "ms": MS0 + 2 * length + 1})
    return ops


LONG_MICRO = "µ" * 245


MANY_NODES = 200               # the writer's 60,000-byte cap leaves room for about 250 such nodes, not the 2 000 of the node cap


def many_ops():
    rng = np.random.default_rng(20261013 + 1)
    ops = []
    for i in range(MANY_NODES):
        coords = [float(rng.choice([-1.0, 1.0]) * 10.0 ** rng.uniform(-300, 300)) for _ in range(4)]
        coords[i % 4] = float(rng.standard_normal() * 1000.0)
        ops.append(add("distance", [("x1", D(coords[0])), ("y1", D(coords[1])), ("x2", D(coords[2])), ("y2", D(coords[3]))],
                       [("length", D(abs(coords[2] - coords[0]))), ("unit", S("nm"))], MS0 + 1000 * i + (i * 37) % 1000))
    return ops


def fuzz_ops(n):
    """n marks of the simplest kind, for the fuzz's two larger files: about 158 bytes of lineage text a node, so 380 nodes
    are about 60 KB (within the checksummed object header: compact storage, a text up to about 65,499 bytes) and 2 000 about 315 KB (dense storage)."""
    return [add("distance", [("x0", D(10.5)), ("y0", D(20.25))], [("length", S("3.2 nm"))], 1_760_000_000_000) for _ in range(n)]


# P3: three sidecars Swift writes (sessions of this plan), mutated and read, each read in its own process with a
# deadline. Every byte of the small file x {xor 0xFF, bit 0, set to 0}; every 61st byte of the 60 KB file and every 997th of
# the 315 KB file x {xor 0xFF, bit 0}; 16 truncations of each (to N * k / 16 bytes, k = 0..15). Pass: no hang, no crash
# (a signal), every read the written contents or a named refusal, and no silent change (a read that succeeds with other
# contents) on the files `gated`: those whose text is within about 65,499 bytes, which the checksummed object header holds (the fixed-length rule's
# second opinion measured none); the 315 KB file's text is in dense storage, not checksummed: its silent changes are
# counted, not gated.
FUZZ = {
    "deadline": 10, "workers": 6, "truncations": 16, "text_limit": 65536,
    "files": [
        {"session": "marks", "modes": ["xor", "bit0", "zero"], "stride": 1, "gated": True},
        {"session": "fuzz-60k", "modes": ["xor", "bit0"], "stride": 61, "gated": True},
        # The dense-storage refusal: a dense-storage file (h5py plants it; the writer refuses to) is refused by name, so it is read as that refusal
        {"session": "fuzz-315k", "modes": ["xor", "bit0"], "stride": 997, "gated": True, "planted": True, "dense": True},
    ],
    # P3: the structure-aware fuzz of h5py's dense sidecars (dense_fuzz.py): filled in by `plant` (files, mutation lists)
    "structure": [], "forged": [],
}
DENSE_BASES = (("dense-70k", 70_000), ("dense-65600", 65_600), ("dense-100k", 100_000))


def check_fuzz_plan(session_list):
    """The plan's own consistency: the gated files' texts are within 65,499 bytes and the 60 KB one is about 60 KB, the other
    ungated file's lineage is over 65,499 bytes; the marks session is a few KB."""
    by_id = {s["id"]: s for s in session_list}
    by_id["fuzz-315k"] = dense_fuzz_session()
    limit = FUZZ["text_limit"]
    for entry in FUZZ["files"]:
        session = by_id[entry["session"]]
        texts = [len(canon(session["expect"]["identity"]).encode("utf-8"))]
        lineage = len(lineage_text_of(session).encode("utf-8"))
        if not entry.get("dense") and max(texts + [lineage]) >= limit:
            fail(f"fuzz file {entry['session']} is not dense but holds a text of {max(texts + [lineage])} bytes (limit {limit})")
        if entry.get("dense") and lineage <= limit:
            fail(f"fuzz file {entry['session']} is dense but its lineage is only {lineage} bytes (over {limit} expected)")
    sizes = {e["session"]: len(lineage_text_of(by_id[e["session"]]).encode("utf-8")) for e in FUZZ["files"]}
    if not (1_000 <= sizes["marks"] <= 8_000 and 55_000 <= sizes["fuzz-60k"] < limit and 290_000 <= sizes["fuzz-315k"] <= 330_000):
        fail(f"the fuzz files' lineage texts are {sizes}; expected a few KB, about 60 KB and about 315 KB")
    return sizes


def dense_fuzz_session():
    """The fuzz's third file (about 315 KB of lineage text, dense storage): a plan session like the others, but Swift's writer
    refuses it since the text cap, so h5py writes it (plant) and the fuzz reads and mutates that file."""
    w, h, arr = pixel_sets()["ramp-a"]
    obj = identity_obj("fuzz-315k.tif", 100, "o", w, h, fingerprint(arr))
    nodes, next_id = simulate_checked(fuzz_ops(2000))
    return {"id": "fuzz-315k", "sidecar_name": "fuzz-315k.tif" + SUFFIX,
            "expect": {"identity": obj, "next_id": next_id, "nodes": [node_spec(n) for n in nodes]}}


def plant_dense_fuzz_file(ref):
    session = dense_fuzz_session()
    directory = os.path.join(ref, "fuzz-planted")
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, session["sidecar_name"])
    source, lineage = canon(session["expect"]["identity"]), lineage_text_of(session)
    write_h5(path, [(IDENTITY, "str", "1"), (MIN_READER, "str", "1"), (SOURCE, "str", source), (LINEAGE, "str", lineage)],
             options={"libver": "latest"})
    return {"file": "fuzz-planted/" + session["sidecar_name"], "source_json": source, "lineage_json": lineage}


def lineage_text_of(session):
    """The lineage text the plan expects of a session (its nodes are in the manifest's form: back to the canonical JSON)."""
    nodes = []
    for n in session["expect"]["nodes"]:
        node = {"external": [], "id": n["id"], "inputs": n["inputs"], "kind": n["kind"],
                "parameters": n["stored_parameters"], "recorded": n["recorded"], "results": n["stored_results"]}
        if n["removed"] is not None:
            node["removed"] = n["removed"]
        nodes.append(node)
    return canon({"version": 1, "next_id": session["expect"]["next_id"], "nodes": nodes})


def nfc(text):
    return unicodedata.normalize("NFC", text)


def nfd(text):
    return unicodedata.normalize("NFD", text)


def identity_obj(file_name, byte_size, obj, width, height, digest):
    return {"byte_size": byte_size, "file_name": file_name, "height": height, "object": obj, "pixel_sha256": digest,
            "width": width}


def sessions(pixels):
    def ident(name, size, obj, pix):
        w, h, arr = pixels[pix]
        return ({"file_name": name, "byte_size": size, "object": obj, "pixels": pix},
                identity_obj(nfc(name), size, obj, w, h, fingerprint(arr)))

    out = []
    for sid, source_name, ops, pix, size, obj in [
        ("marks", "SCAN.DM4", MARKS_OPS, "six", 9_876_543_210, "ImageList.2 · HAADF"),
        ("unicode", nfd("Å-scan µm.TIF"), UNICODE_OPS, "special", 12_345, "Series/frame 1 of 3"),
        ("many", "many.mrc", many_ops(), "grid", 2_097_152, ""),
        ("empty", "empty.emd", [], "special", 0, "Ceta · BM"),
        ("kept", "kept.tif", KEPT_OPS, "ramp-a", 100, "o"),
        ("cascade", "cascade.tif", CASCADE_OPS, "ramp-a", 100, "o"),
        ("dates", "dates.tif", DATES_OPS, "ramp-b", 100, "o"),
        ("chain", "chain.tif", chain_ops(CHAIN_LENGTH), "ramp-a", 100, "o"),
        # a sidecar name of exactly 255 UTF-16 units that is 500 bytes (245 × "µ" and the suffix): the file system takes it
        ("longname", LONG_MICRO, [add("distance", LINE, [("length", D(1.4142135623730951))], MS0)], "ramp-b", 100, "o"),
        # the fuzz's two larger files (FUZZ above): ordinary sessions, so h5py checks them like the rest
        ("fuzz-60k", "fuzz-60k.tif", fuzz_ops(380), "ramp-a", 100, "o"),
    ]:
        ident_spec, ident_json = ident(source_name, size, obj, pix)
        nodes, next_id = simulate_checked(ops)
        out.append({"id": sid, "source_name": source_name, "sidecar_name": source_name + SUFFIX, "identity": ident_spec,
                    "ops": [op_spec(op) for op in ops],
                    "expect": {"identity": ident_json, "next_id": next_id, "nodes": [node_spec(n) for n in nodes]}})
    return out


# ---------------------------------------------------------------- the sidecars h5py writes

# Attribute kinds a plant can ask for (a fixed-length string is the sidecar's own form):
#   str       a fixed-length string, NULLPAD, UTF-8, as long as the text (1 byte for an empty text)      value: text
#   invalid   the same with bytes that are not UTF-8                                                       value: bytes
#   bytes     the same with any bytes (a NUL inside, then more text)                                       value: bytes
#   padded    NULLPAD, UTF-8, `size` bytes of storage: the data, then NULs                                value: (bytes, size)
#   nullterm  NULLTERM, UTF-8, the data and one NUL                                                       value: bytes
#   ascii     NULLPAD, ASCII (what numpy's S dtype gives)                                                 value: bytes
#   farray    a fixed-length string in a rank-1 space of one element                                      value: text
#   fnull     a fixed-length string type in a null dataspace (no element)
#   vl        a scalar variable-length UTF-8 string (slice A's form: the global heap)                     value: text
#   vlbytes   the same with bytes that are not UTF-8                                                      value: bytes
#   array     a variable-length string in a rank-1 space of one element                                  value: text
#   vlnull    a variable-length string type in a null dataspace
#   int       a 32-bit integer
FIXED_KINDS = ("str", "invalid", "bytes", "padded", "nullterm", "ascii")
VARIABLE_KINDS = ("vl", "vlbytes", "array", "vlnull")


def fixed_shape(kind, value):
    """(data, storage size, pad, character set) of a fixed-length kind: what the plant must be, and what verify_attr proves."""
    if kind == "str":
        data = value.encode("utf-8")
        return data, max(len(data), 1), h5t.STR_NULLPAD, h5t.CSET_UTF8
    if kind in ("invalid", "bytes"):
        return value, max(len(value), 1), h5t.STR_NULLPAD, h5t.CSET_UTF8
    if kind == "padded":
        return value[0], value[1], h5t.STR_NULLPAD, h5t.CSET_UTF8
    if kind == "nullterm":
        return value, len(value) + 1, h5t.STR_NULLTERM, h5t.CSET_UTF8
    if kind == "ascii":
        return value, max(len(value), 1), h5t.STR_NULLPAD, h5t.CSET_ASCII
    fail(f"{kind} is not a fixed-length kind")


def put_string(f, name, data, size, pad, cset, space=None):
    """A fixed-length string attribute through h5py's low-level API: `size` bytes of storage holding `data`, then NULs, the
    pad and the character set as asked. A null dataspace holds no element, so nothing is written to it."""
    tid = h5t.C_S1.copy()
    tid.set_size(size)
    tid.set_cset(cset)
    tid.set_strpad(pad)
    space = space if space is not None else h5s.create(h5s.SCALAR)
    attr = h5a.create(f.id, name.encode("utf-8"), tid, space)
    if space.get_simple_extent_type() == h5s.NULL:
        return
    shape = space.shape if space.get_simple_extent_type() == h5s.SIMPLE else ()
    cells = np.frombuffer(bytearray(data.ljust(size, b"\0")), dtype=f"S{size}").reshape(shape)
    attr.write(cells, mtype=tid)


def make_attr(f, name, kind, value):
    if kind in FIXED_KINDS:
        data, size, pad, cset = fixed_shape(kind, value)
        put_string(f, name, data, size, pad, cset)
    elif kind == "farray":
        data = value.encode("utf-8")
        put_string(f, name, data, max(len(data), 1), h5t.STR_NULLPAD, h5t.CSET_UTF8, space=h5s.create_simple((1,)))
    elif kind == "fnull":
        put_string(f, name, b"", 1, h5t.STR_NULLPAD, h5t.CSET_UTF8, space=h5s.create(h5s.NULL))
    elif kind == "vl":
        f.attrs.create(name, data=value, dtype=h5py.string_dtype("utf-8"))
    elif kind == "vlbytes":
        f.attrs.create(name, data=np.array(value, dtype=object), dtype=h5py.string_dtype("utf-8"))
    elif kind == "array":
        f.attrs.create(name, data=np.array([value], dtype=object), dtype=h5py.string_dtype("utf-8"))
    elif kind == "int":
        f.attrs.create(name, data=np.int32(value))
    elif kind == "vlnull":
        f.attrs.create(name, data=h5py.Empty(h5py.string_dtype("utf-8")))
    else:
        fail(f"unknown attribute kind {kind}")


def value_size(kind, value):
    if kind in FIXED_KINDS:
        return fixed_shape(kind, value)[1]
    return len(value) if isinstance(value, (str, bytes)) else 0


def write_h5(path, attrs, datasets=(), options=None):
    options = dict(options or {})
    if "libver" not in options and any(value_size(kind, value) > LATEST_ABOVE for _, kind, value in attrs):
        options["libver"] = "latest"          # an attribute message over 64 KiB needs the newest format (dense storage)
    with h5py.File(path, "w", **options) as f:
        for name, kind, value in attrs:
            make_attr(f, name, kind, value)
        for name in datasets:
            f.create_dataset(name, data=np.arange(4, dtype="<i4"))


def stored_bytes(aid):
    """Every byte of a fixed-length scalar string's storage, padding included (numpy's S buffer keeps them all; only its
    item accessor strips trailing NULs)."""
    t = aid.get_type()
    cells = np.zeros(aid.shape or (), dtype=f"S{t.get_size()}")
    aid.read(cells, mtype=t)
    return cells.tobytes()


def attribute_facts(f, name):
    """What h5py's low-level calls say an attribute is: absent, or its shape, string class, variable-or-not, size, pad, set
    and (fixed-length scalar) its storage bytes."""
    if name not in f.attrs:
        return {"absent": True}
    aid = f.attrs.get_id(name)
    t = aid.get_type()
    facts = {"absent": False, "shape": aid.shape, "space": aid.get_space().get_simple_extent_type()}
    facts["string"] = isinstance(t, h5t.TypeStringID)
    if facts["string"]:
        facts.update(variable=bool(t.is_variable_str()), size=t.get_size(), pad=t.get_strpad(), cset=t.get_cset())
        if not facts["variable"] and aid.shape == ():
            facts["stored"] = stored_bytes(aid)
    return facts


def verify_attr(path, name, kind, value):
    """Reference check: h5py reads the planted attribute as the kind it was meant to be."""
    with h5py.File(path, "r") as f:
        facts = attribute_facts(f, name)
        if kind in FIXED_KINDS:
            data, size, pad, cset = fixed_shape(kind, value)
            ok = facts["shape"] == () and facts["string"] and not facts["variable"] and facts["size"] == size \
                and facts["pad"] == pad and facts["cset"] == cset and facts["stored"] == data.ljust(size, b"\0")
            if kind == "invalid":
                try:
                    data.decode("utf-8")
                    ok = False                       # the plant must be invalid UTF-8
                except UnicodeDecodeError:
                    pass
        elif kind == "farray":
            ok = facts["shape"] == (1,) and facts["string"] and not facts["variable"]
        elif kind == "fnull":
            ok = facts["shape"] is None and facts["space"] == h5s.NULL and facts["string"] and not facts["variable"]
        elif kind == "vl":
            aid = f.attrs.get_id(name)
            ok = facts["shape"] == () and facts["string"] and facts["variable"] and facts["cset"] == h5t.CSET_UTF8 \
                and f.attrs[name] == value
        elif kind == "vlbytes":
            aid = f.attrs.get_id(name)
            ok = facts["shape"] == () and facts["string"] and facts["variable"] \
                and f.attrs[name].encode("utf-8", "surrogateescape") == value
            try:
                value.decode("utf-8")
                ok = False                       # the plant must be invalid UTF-8
            except UnicodeDecodeError:
                pass
        elif kind == "array":
            ok = facts["shape"] == (1,) and facts["string"] and facts["variable"]
        elif kind == "vlnull":
            ok = facts["shape"] is None and facts["space"] == h5s.NULL and facts["string"] and facts["variable"]
        else:
            ok = facts["shape"] == () and not facts["string"] and f.attrs.get_id(name).dtype.kind == "i"
        if not ok:
            fail(f"{path}: attribute {name} is not the planted {kind} ({facts})")


def refusal(case, **kw):
    return {"name": case, **kw}


def contents(schema, min_reader, source, lineage):
    """What a read must hand back, as lengths and digests (a 4 MiB string is not copied into the manifest)."""
    out = {"outcome": "contents", "schema": schema, "min_reader": min_reader}
    for key, text in (("source", source), ("lineage", lineage)):
        if text is None:
            out[key + "_bytes"], out[key + "_sha256"] = None, None
        else:
            data = text if isinstance(text, bytes) else text.encode("utf-8")
            out[key + "_bytes"], out[key + "_sha256"] = len(data), sha(data)
    return out


def refused(**kw):
    return {"outcome": "refusal", "refusal": kw}


def lineage_decoded(text, nodes, next_id):
    return {"outcome": "decoded", "next_id": next_id, "nodes": [node_spec(n) for n in nodes], "canonical": text}


def identity_decoded(obj):
    return {"outcome": "decoded", "file_name": nfc(obj["file_name"]), "byte_size": obj["byte_size"],
            "object": obj["object"], "width": obj["width"], "height": obj["height"],
            "pixel_sha256": obj["pixel_sha256"], "canonical": canon({**obj, "file_name": nfc(obj["file_name"])})}


def chain(n, next_id, extra=None):
    """A lineage JSON of n bare nodes s1..sn (no inputs)."""
    nodes = [{"external": [], "id": f"s{i}", "inputs": [], "kind": "distance", "parameters": {}, "recorded": MS0 + i,
              "results": {}} for i in range(1, n + 1)]
    return canon({"version": 1, "next_id": next_id, "nodes": nodes, **(extra or {})})


def bare_node(node_id, inputs=(), kind="distance"):
    return {"external": [], "id": node_id, "inputs": [{"role": "r", "step": s} for s in inputs], "kind": kind,
            "parameters": {}, "recorded": MS0, "results": {}}


def lineage_of(nodes, next_id):
    return canon({"version": 1, "next_id": next_id, "nodes": nodes})


def planted_cases(pixels, out_dir):
    """Every sidecar h5py writes, with what the Swift reader must do with it."""
    marks_nodes, marks_next = simulate_checked(MARKS_OPS)
    valid_lineage = lineage_text(marks_nodes, marks_next)
    w, h, arr = pixels["six"]
    obj = identity_obj("Å-µ.dm4", 123_456_789_012, "ImageList.2 · HAADF", w, h, fingerprint(arr))
    valid_source = canon(obj)
    nfd_obj = {**obj, "file_name": nfd("Å-µ.dm4")}
    nfd_source = canon(nfd_obj)
    five = "x" * (5 << 20)
    big = "y" * CAP
    good = [(IDENTITY, "str", "1"), (MIN_READER, "str", "1"), (SOURCE, "str", valid_source), (LINEAGE, "str", valid_lineage)]
    plain = [(IDENTITY, "str", "1"), (MIN_READER, "str", "1"), (SOURCE, "str", "{}")]
    cases = []

    def case(name, attrs, read, lineage=None, source=None, write_over=None, datasets=(), raw=None, options=None, replaces=False,
             dense=False):
        # A sidecar with a variable-length attribute, or the hang file, is read by the harness in a child process with a
        # deadline (the library may spin on a damaged one), never in the gate's own process.
        child = isinstance(raw, tuple) or any(kind in VARIABLE_KINDS for _, kind, _ in attrs)
        cases.append({"name": name, "attrs": attrs, "datasets": datasets, "raw": raw, "options": options,
                      "read": read, "lineage": lineage, "source": source, "write_over": write_over,
                      "child": child, "replaces": replaces, "dense": dense})

    ok = lambda lin, src=valid_source, schema=1, minr=1: contents(schema, minr, src, lin)
    # The dense-storage refusal: a root whose attributes are in dense storage (h5py proves each plant is, DENSE below) is refused by name, on a read and
    # on the replace check of a write, before any attribute is opened
    dense_refusal = lambda: refused(name="denseAttributeStorage")
    # valid: read equal (byte for byte), decoded equal, re-encoded byte-equal to Python's canonical text
    case("valid", good, ok(valid_lineage), lineage_decoded(valid_lineage, marks_nodes, marks_next), identity_decoded(obj))
    case("valid-nfd-name", [(IDENTITY, "str", "1"), (MIN_READER, "str", "1"), (SOURCE, "str", nfd_source), (LINEAGE, "str", valid_lineage)],
         ok(valid_lineage, nfd_source), None, identity_decoded(nfd_obj))
    # the same four attributes in the other layouts a Python writer can produce: the newest object-header format, and 40 more
    # attributes beside them, which the newest format keeps in dense storage (a fractal heap) with a creation-order index
    extras = [(f"extra_{i:02d}", "str", f"value {i} Å µ") for i in range(4)]
    many_extras = [(f"extra_{i:02d}", "str", f"value {i} Å µ") for i in range(40)]
    case("valid-libver-latest", good, ok(valid_lineage), lineage_decoded(valid_lineage, marks_nodes, marks_next),
         identity_decoded(obj), options={"libver": "latest"})
    case("valid-compact-attributes-tracked-order", good + extras, ok(valid_lineage), lineage_decoded(valid_lineage, marks_nodes, marks_next),
         identity_decoded(obj), options={"libver": "latest", "track_order": True})
    # the same with 40 more: the library moves them to dense storage (a fractal heap and a B-tree), which macTEM does not write and refuses
    case("dense-attributes-tracked-order", good + many_extras, dense_refusal(), write_over=refusal("denseAttributeStorage"),
         options={"libver": "latest", "track_order": True}, dense=True)
    case("dense-attributes-many", good + many_extras, dense_refusal(), write_over=refusal("denseAttributeStorage"),
         options={"libver": "latest"}, dense=True)
    # dense is judged before an attribute is looked at: a dense file that is also foreign, of a newer minimum reader, or whose identity is
    # variable-length is refused as dense (each of the three, at 30,000 bytes instead, has its own refusal: foreign-bare,
    # newer-min-reader, vl-identity)
    dense_text = "d" * 70_000
    case("dense-foreign", [("title", "str", "hello"), (LINEAGE, "str", dense_text)], dense_refusal(),
         write_over=refusal("denseAttributeStorage"), dense=True)
    case("dense-newer-min-reader", [(IDENTITY, "str", "1"), (MIN_READER, "str", "2"), (SOURCE, "str", "{}"), (LINEAGE, "str", dense_text)],
         dense_refusal(), write_over=refusal("denseAttributeStorage"), dense=True)
    case("dense-variable-length-identity", [(IDENTITY, "vl", "1"), (MIN_READER, "str", "1"), (SOURCE, "str", "{}"), (LINEAGE, "str", dense_text)],
         dense_refusal(), write_over=refusal("denseAttributeStorage"), dense=True)
    # and what is not dense is not refused as dense: a root with no attributes at all is foreign, not dense
    case("foreign-no-attributes", [], refused(name="foreign"), datasets=("data",), write_over=refusal("foreign"))
    # a sidecar of a NEWER schema whose minimum reader is still 1 is read, but never written over: a replace would drop what this
    # build cannot parse and mark the file as the older schema (the bytes stay as they were)
    case("valid-newer-writer-same-min-reader", [(IDENTITY, "str", "2"), (MIN_READER, "str", "1"), (SOURCE, "str", valid_source),
                                               (LINEAGE, "str", valid_lineage)], ok(valid_lineage, valid_source, 2, 1),
         write_over=refusal("newerSchema", found=2, supported=1))
    case("newer-schema-with-future-attribute", [(IDENTITY, "str", "3"), (MIN_READER, "str", "1"), (SOURCE, "str", valid_source),
                                               (LINEAGE, "str", valid_lineage), ("mactem_future_marks", "str", "keep me")],
         ok(valid_lineage, valid_source, 3, 1), write_over=refusal("newerSchema", found=3, supported=1))
    case("valid-without-source-and-lineage", [(IDENTITY, "str", "1"), (MIN_READER, "str", "1")], ok(None, None))
    case("valid-empty-strings", [(IDENTITY, "str", "1"), (MIN_READER, "str", "1"), (SOURCE, "str", ""), (LINEAGE, "str", "")],
         ok("", ""), refused_l("malformed"), {"outcome": "refusal", "refusal": refusal("malformed")})
    # P2: a newer minimum reader is refused by name, before anything else is read
    case("newer-min-reader", [(IDENTITY, "str", "1"), (MIN_READER, "str", "2"), (SOURCE, "str", valid_source),
                              (LINEAGE, "str", valid_lineage)], refused(name="newerMinReader", found=2, supported=1),
         write_over=refusal("newerMinReader", found=2, supported=1))
    case("newer-min-reader-invalid-rest", [(IDENTITY, "str", "1"), (MIN_READER, "str", "2"),
                                           (SOURCE, "invalid", b"{\"a\":\"\xff\xfe\"}"), (LINEAGE, "ascii", b"{}")],
         refused(name="newerMinReader", found=2, supported=1), write_over=refusal("newerMinReader", found=2, supported=1))
    # P2: the minimum reader decides before the identity's own spelling is judged ("v2" is not the canonical form of a schema,
    # but a file that needs a newer reader is a newer file, not a garbled one); beside a minimum reader of 1 it IS garbled
    case("newer-min-reader-v2-identity", [(IDENTITY, "str", "v2"), (MIN_READER, "str", "2"), (SOURCE, "str", valid_source),
                                          (LINEAGE, "str", valid_lineage)], refused(name="newerMinReader", found=2, supported=1),
         write_over=refusal("newerMinReader", found=2, supported=1))
    case("garbled-identity-v2-min-reader-1", [(IDENTITY, "str", "v2"), (MIN_READER, "str", "1")],
         refused(name="malformedAttribute", attribute=IDENTITY), write_over=refusal("malformedAttribute", attribute=IDENTITY))
    case("newer-min-reader-and-writer", [(IDENTITY, "str", "5"), (MIN_READER, "str", "5"), (SOURCE, "array", "{}"),
                                         (LINEAGE, "int", 7)], refused(name="newerMinReader", found=5, supported=1))
    # foreign: no identity marker
    case("foreign-bare", [("title", "str", "hello"), (SOURCE, "str", "{}")], refused(name="foreign"),
         write_over=refusal("foreign"))
    case("foreign-lookalike", [(MIN_READER, "str", "1"), (SOURCE, "str", valid_source), (LINEAGE, "str", valid_lineage)],
         refused(name="foreign"), write_over=refusal("foreign"))
    case("foreign-datasets", [("version_major", "int", 1)], refused(name="foreign"), datasets=("data", "data2/frames"),
         write_over=refusal("foreign"))
    case("missing-min-reader", [(IDENTITY, "str", "1"), (SOURCE, "str", valid_source), (LINEAGE, "str", valid_lineage)],
         refused(name="missingAttribute", attribute=MIN_READER), write_over=refusal("missingAttribute", attribute=MIN_READER))
    case("garbled-identity", [(IDENTITY, "str", "01"), (MIN_READER, "str", "1")], refused(name="malformedAttribute", attribute=IDENTITY))
    case("garbled-min-reader", [(IDENTITY, "str", "1"), (MIN_READER, "str", "0")], refused(name="malformedAttribute", attribute=MIN_READER))
    # texts over the object header's 64 KiB are in dense storage, which the reader refuses by name before any attribute is looked at
    # (the dense-storage refusal): the writer's un-capped sizes of the plan, 65,600 B and 100 KB, and the 4 MiB texts, which
    # the reader's own 4 MiB cap (now unreachable) used to refuse as `stringTooLong`
    for label, size in (("65600", 65_600), ("100kb", 100_000)):
        case(f"lineage-{label}", plain + [(LINEAGE, "str", "y" * size)], dense_refusal(), write_over=refusal("denseAttributeStorage"), dense=True)
    case("lineage-5mib", plain + [(LINEAGE, "str", five)], dense_refusal(), write_over=refusal("denseAttributeStorage"), dense=True)
    case("lineage-4mib-exact", plain + [(LINEAGE, "str", big)], dense_refusal(), write_over=refusal("denseAttributeStorage"), dense=True)
    case("lineage-4mib-plus-1", plain + [(LINEAGE, "str", big + "y")], dense_refusal(), write_over=refusal("denseAttributeStorage"), dense=True)
    case("source-5mib", [(IDENTITY, "str", "1"), (MIN_READER, "str", "1"), (SOURCE, "str", five), (LINEAGE, "str", "{}")],
         dense_refusal(), write_over=refusal("denseAttributeStorage"), dense=True)
    # the stored text must be UTF-8 (the type is fixed-length now)
    case("invalid-utf8-lineage", plain + [(LINEAGE, "invalid", b"{\"a\":\"\xff\xfe\"}")], refused(name="invalidUTF8", attribute=LINEAGE))
    case("invalid-utf8-source", [(IDENTITY, "str", "1"), (MIN_READER, "str", "1"), (SOURCE, "invalid", b"\xc3\x28"), (LINEAGE, "str", "{}")],
         refused(name="invalidUTF8", attribute=SOURCE))
    # an ASCII-charset string (what numpy's S dtype writes) is read as it is: ASCII is a subset of UTF-8
    case("ascii-lineage", plain + [(LINEAGE, "ascii", b"{\"version\":1}")], contents(1, 1, "{}", "{\"version\":1}"))
    case("ascii-identity", [(IDENTITY, "ascii", b"1"), (MIN_READER, "str", "1")], contents(1, 1, None, None),
         write_over=None, replaces=True)
    # the NUL padding: the text is what lies before the first NUL, and after that NUL there may be nothing but NULs
    padded = b"{\"version\":1}"
    case("padded-lineage", plain + [(LINEAGE, "padded", (padded, len(padded) + 5))], contents(1, 1, "{}", padded.decode()))
    case("padded-markers", [(IDENTITY, "padded", (b"1", 4)), (MIN_READER, "padded", (b"1", 8)), (SOURCE, "padded", (b"{}", 6)),
                            (LINEAGE, "padded", (b"{}", 9))], contents(1, 1, "{}", "{}"))
    case("nullterm-lineage", plain + [(LINEAGE, "nullterm", padded)], contents(1, 1, "{}", padded.decode()))
    case("all-nul-lineage", plain + [(LINEAGE, "padded", (b"", 8))], contents(1, 1, "{}", ""))
    case("nul-then-text-lineage", plain + [(LINEAGE, "bytes", b"{\"a\":1}\x00junk")], refused(name="malformedAttribute", attribute=LINEAGE))
    case("nul-then-text-source", [(IDENTITY, "str", "1"), (MIN_READER, "str", "1"), (SOURCE, "bytes", b"{}\x00x"), (LINEAGE, "str", "{}")],
         refused(name="malformedAttribute", attribute=SOURCE))
    case("nul-first-lineage", plain + [(LINEAGE, "bytes", b"\x00{}")], refused(name="malformedAttribute", attribute=LINEAGE))
    case("nul-then-text-identity", [(IDENTITY, "bytes", b"1\x00x"), (MIN_READER, "str", "1")],
         refused(name="malformedAttribute", attribute=IDENTITY), write_over=refusal("malformedAttribute", attribute=IDENTITY))
    # not a scalar, not a string
    case("array-fixed-lineage", plain + [(LINEAGE, "farray", "{}")], refused(name="malformedAttribute", attribute=LINEAGE))
    case("array-lineage", plain + [(LINEAGE, "array", "{}")], refused(name="malformedAttribute", attribute=LINEAGE))
    case("null-dataspace-source", [(IDENTITY, "str", "1"), (MIN_READER, "str", "1"), (SOURCE, "fnull", None), (LINEAGE, "str", "{}")],
         refused(name="malformedAttribute", attribute=SOURCE))
    case("null-dataspace-vl-source", [(IDENTITY, "str", "1"), (MIN_READER, "str", "1"), (SOURCE, "vlnull", None), (LINEAGE, "str", "{}")],
         refused(name="malformedAttribute", attribute=SOURCE))
    case("integer-source", [(IDENTITY, "str", "1"), (MIN_READER, "str", "1"), (SOURCE, "int", 3), (LINEAGE, "str", "{}")],
         refused(name="malformedAttribute", attribute=SOURCE))
    # P2: a variable-length string is refused by name from its type, before any H5Aread (its heap is never parsed).
    # Each of the four attributes, variable-length in an otherwise valid sidecar. The identity's and the minimum reader's are
    # read by the write's replace check too, so a write over those is refused; the source and the lineage the replace never
    # reads, so a write over those replaces the file (and never touches the heap).
    def one_variable(which, kind="vl"):
        return [(a, kind if a == which else "str", v) for a, v in
                ((IDENTITY, "1"), (MIN_READER, "1"), (SOURCE, valid_source), (LINEAGE, valid_lineage))]

    case("vl-identity", one_variable(IDENTITY), refused(name="variableLengthString", attribute=IDENTITY),
         write_over=refusal("variableLengthString", attribute=IDENTITY))
    case("vl-min-reader", one_variable(MIN_READER), refused(name="variableLengthString", attribute=MIN_READER),
         write_over=refusal("variableLengthString", attribute=MIN_READER))
    case("vl-source", one_variable(SOURCE), refused(name="variableLengthString", attribute=SOURCE), replaces=True)
    case("vl-lineage", one_variable(LINEAGE), refused(name="variableLengthString", attribute=LINEAGE), replaces=True)
    case("vl-all-four", [(IDENTITY, "vl", "1"), (MIN_READER, "vl", "1"), (SOURCE, "vl", valid_source), (LINEAGE, "vl", valid_lineage)],
         refused(name="variableLengthString", attribute=IDENTITY), write_over=refusal("variableLengthString", attribute=IDENTITY))
    # the name is refused before the text is decoded (the invalid UTF-8 inside is never looked at)
    case("vl-invalid-utf8-lineage", plain + [(LINEAGE, "vlbytes", b"{\"a\":\"\xff\xfe\"}")],
         refused(name="variableLengthString", attribute=LINEAGE))
    # P2's order: a newer minimum reader is judged before any variable-length string behind it is touched
    case("newer-min-reader-vl-rest", [(IDENTITY, "str", "1"), (MIN_READER, "str", "2"), (SOURCE, "vl", valid_source), (LINEAGE, "vl", valid_lineage)],
         refused(name="newerMinReader", found=2, supported=1), write_over=refusal("newerMinReader", found=2, supported=1))
    # the archived hang file: all four attributes variable-length, one byte of a global-heap object size flipped, so that
    # H5Aread of any of them spins forever. Refused by name, from the first attribute's type, without a read.
    case("hangcase-flip", [], refused(name="variableLengthString", attribute=IDENTITY), raw=("copy", HANG_FILE),
         write_over=refusal("variableLengthString", attribute=IDENTITY))
    # P3: a file that cannot be opened is an error, never "no file"
    case("not-hdf5", [], refused(name="cannotOpen"), raw=bytes(range(256)) * 8, write_over=refusal("cannotOpen"))
    case("empty-file", [], refused(name="cannotOpen"), raw=b"", write_over=refusal("cannotOpen"))
    case("truncated", good, refused(name="cannotOpen"), raw="truncate", write_over=refusal("cannotOpen"))
    case("unreadable", good, refused(name="notPermitted"), raw="unreadable")
    case("absent", [], refused(name="cannotOpen"), raw="absent")
    # a link to nothing: it cannot be opened, so it is not ours to replace, and a write leaves the link and creates nothing
    case("dangling-link", [], refused(name="cannotOpen"), raw="dangling", write_over=refusal("cannotOpen"))
    # the lineage's own guards, each a named refusal of SessionLineage.decode (the file layer reads them fine)
    def lin(name, text, outcome):
        # A text over about 65,499 bytes is in dense storage and the file is refused: the decode is then checked on the
        # text itself, which the plant keeps beside the sidecar (`lineage_text`), as h5py would have read it
        if len(text.encode("utf-8")) > DENSE_ABOVE:
            case(name, plain + [(LINEAGE, "str", text)], dense_refusal(), outcome, write_over=refusal("denseAttributeStorage"), dense=True)
            cases[-1]["lineage_text"] = text
        else:
            case(name, plain + [(LINEAGE, "str", text)], contents(1, 1, "{}", text), outcome)

    lin("lineage-cycle", lineage_of([bare_node("s1", ["s2"]), bare_node("s2", ["s1"])], 3), refused_l("cycle"))
    lin("lineage-self-cycle", lineage_of([bare_node("s1", ["s1"])], 2), refused_l("cycle"))
    lin("lineage-long-cycle", lineage_of([bare_node("s1"), bare_node("s2", ["s1", "s4"]), bare_node("s3", ["s2"]),
                                          bare_node("s4", ["s3"])], 5), refused_l("cycle"))
    diamond = lineage_of([bare_node("s1"), bare_node("s2", ["s1"]), bare_node("s3", ["s1"]), bare_node("s4", ["s2", "s3"])], 5)
    lin("lineage-diamond", diamond, {"outcome": "decoded", "next_id": 5, "nodes": [], "canonical": diamond, "count": 4})
    # an input from outside the session (reserved) is kept, and written back as it was read
    external = {**bare_node("s1"), "external": [{"fingerprint": "0" * 64, "name": "structure.cif"}]}
    lin("lineage-external-kept", lineage_of([external], 2),
        {"outcome": "decoded", "next_id": 2, "nodes": [], "canonical": lineage_of([external], 2), "count": 1})
    lin("lineage-missing-input", lineage_of([bare_node("s1"), bare_node("s2", ["s9"])], 3), refused_l("danglingInput", step="s9", **{"from": "s2"}))
    lin("lineage-duplicate-ids", lineage_of([bare_node("s1"), bare_node("s1")], 2), refused_l("duplicateID", id="s1"))
    lin("lineage-next-id-over", lineage_of([], MAX_NEXT_ID + 1), refused_l("badNextID", next_id=MAX_NEXT_ID + 1))
    lin("lineage-next-id-zero", lineage_of([], 0), refused_l("badNextID", next_id=0))
    lin("lineage-next-id-at-bound", lineage_of([], MAX_NEXT_ID),
        {"outcome": "decoded", "next_id": MAX_NEXT_ID, "nodes": [], "canonical": lineage_of([], MAX_NEXT_ID), "exhausted": True})
    lin("lineage-id-not-below-next", lineage_of([bare_node("s5")], 5), refused_l("idNotBelowNextID", id="s5", next_id=5))
    lin("lineage-bad-id-leading-zero", lineage_of([bare_node("s01")], 5), refused_l("badID", id="s01"))
    lin("lineage-bad-id-prefix", lineage_of([bare_node("n1")], 5), refused_l("badID", id="n1"))
    lin("lineage-bad-id-plus", lineage_of([bare_node("s+1")], 5), refused_l("badID", id="s+1"))
    lin("lineage-bad-id-zero", lineage_of([bare_node("s0")], 5), refused_l("badID", id="s0"))
    lin("lineage-unknown-version", canon({"version": 2, "next_id": 3, "nodes": [{"id": "s1", "kind": "future", "shape": [1, 2]}],
                                          "extra": {"a": 1}}),
        {"outcome": "readOnly", "version": 2})
    lin("lineage-version-string", canon({"version": "1", "next_id": 1, "nodes": []}), refused_l("malformed"))
    lin("lineage-not-json", "this is not json", refused_l("malformed"))
    lin("lineage-wrong-shape", "[]", refused_l("malformed"))
    lin("lineage-missing-next-id", canon({"version": 1, "nodes": []}), refused_l("malformed"))
    lin("lineage-2000-nodes", chain(MAX_NODES, MAX_NODES + 1), {"outcome": "decoded", "next_id": MAX_NODES + 1, "nodes": [],
                                                              "canonical": chain(MAX_NODES, MAX_NODES + 1), "count": MAX_NODES})
    lin("lineage-2001-nodes", chain(MAX_NODES + 1, MAX_NODES + 2), refused_l("tooManyNodes", count=MAX_NODES + 1))
    lin("lineage-unknown-kind-kept", lineage_of([bare_node("s1", kind="hologram"), bare_node("s2", kind="export")], 3),
        {"outcome": "decoded", "next_id": 3, "nodes": [], "canonical": lineage_of([bare_node("s1", kind="hologram"), bare_node("s2", kind="export")], 3), "count": 2})
    lin("lineage-absent-collections", canon({"version": 1, "next_id": 2, "nodes": [{"id": "s1", "kind": "distance", "recorded": 5, "zzz": 1}],
                                              "unknown": True}),
        {"outcome": "decoded", "next_id": 2, "nodes": [], "canonical": lineage_of([{"external": [], "id": "s1", "inputs": [], "kind": "distance", "parameters": {}, "recorded": 5, "results": {}}], 2), "count": 1})
    # the identity's own guards
    def src(name, text, outcome):
        attrs = [(IDENTITY, "str", "1"), (MIN_READER, "str", "1"), (SOURCE, "str", text), (LINEAGE, "str", "{}")]
        if len(text.encode("utf-8")) > DENSE_ABOVE:
            case(name, attrs, dense_refusal(), None, outcome, write_over=refusal("denseAttributeStorage"), dense=True)
            cases[-1]["source_text"] = text
        else:
            case(name, attrs, contents(1, 1, text, "{}"), None, outcome)

    src("source-not-json", "this is not json", {"outcome": "refusal", "refusal": refusal("malformed")})
    over = canon({**obj, "object": "o" * 70000})
    src("source-over-64kib", over, {"outcome": "refusal", "refusal": refusal("tooLarge", bytes=len(over.encode("utf-8")))})
    src("source-zero-width", canon({**obj, "width": 0}), {"outcome": "refusal", "refusal": refusal("invalid", field="width")})
    src("source-negative-size", canon({**obj, "byte_size": -1}), {"outcome": "refusal", "refusal": refusal("invalid", field="byte_size")})
    src("source-upper-case-sha", canon({**obj, "pixel_sha256": obj["pixel_sha256"].upper()}),
        {"outcome": "refusal", "refusal": refusal("invalid", field="pixel_sha256")})
    src("source-missing-field", canon({k: v for k, v in obj.items() if k != "object"}), {"outcome": "refusal", "refusal": refusal("malformed")})
    return cases


def refused_l(case, **kw):
    return {"outcome": "refusal", "refusal": {"name": case, **kw}}



def plant_hang_file(source, path):
    """Copy the archived hang file and prove it is what the plan says: the pinned bytes, four variable-length scalar
    attributes, and a read of one of them that h5py never finishes (a child process, killed by its PID at the deadline)."""
    source = os.path.abspath(source)
    if not os.path.isfile(source):
        fail(f"the hang file {source} is not there (ADR 021's evidence)")
    data = open(source, "rb").read()
    if sha(data) != HANG_SHA256:
        fail(f"{source} is not the pinned hang file (sha256 {sha(data)})")
    with open(path, "wb") as fh:
        fh.write(data)
    with h5py.File(path, "r") as f:
        if sorted(f.attrs.keys()) != sorted(ATTRIBUTES):
            fail(f"{path}: the root holds {sorted(f.attrs.keys())}")
        for name in ATTRIBUTES:
            facts = attribute_facts(f, name)
            if not (facts["shape"] == () and facts["string"] and facts["variable"]):
                fail(f"{path}: attribute {name} is not a scalar variable-length string ({facts})")
    child = subprocess.Popen([sys.executable, "-I", "-B", os.path.abspath(__file__), "hang-probe", path, SOURCE],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        child.wait(timeout=HANG_DEADLINE)
        fail(f"h5py read {SOURCE} of the hang file and returned (exit {child.returncode}); it is meant to spin forever")
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()


def dense_storage(path):
    """h5py's answer (HDF5's own bookkeeping): are the root's attributes in dense storage, a fractal heap and a B-tree index?"""
    with h5py.File(path, "r") as f:
        info = h5py.h5o.get_info(f.id)
        return info.meta_size.attr.heap_size > 0 or info.meta_size.attr.index_size > 0


def plant_files(cases, planted_dir):
    """Write every planted sidecar and prove with h5py that it is what the plan says."""
    os.makedirs(planted_dir, exist_ok=True)
    for c in cases:
        path = os.path.join(planted_dir, c["name"] + SUFFIX)
        c["file"] = "planted/" + c["name"] + SUFFIX
        raw = c["raw"]
        if raw == "absent":
            continue
        if isinstance(raw, tuple):
            plant_hang_file(raw[1], path)
            continue
        if raw == "dangling":
            os.symlink("no-such-file.h5", path)
            if not os.path.islink(path) or os.path.exists(path):
                fail(f"{path} is not a link to nothing")
            try:
                with h5py.File(path, "r"):
                    fail(f"{path} opens in h5py; it must not (a link to nothing)")
            except OSError:
                pass
            continue
        if raw == "truncate":
            write_h5(path, c["attrs"])
            data = open(path, "rb").read()
            with open(path, "wb") as fh:
                fh.write(data[: len(data) // 2])
        elif isinstance(raw, bytes):
            with open(path, "wb") as fh:
                fh.write(raw)
        else:
            write_h5(path, c["attrs"], c["datasets"], c["options"])
        if raw is None or raw == "unreadable":
            stored_dense = dense_storage(path)
            if stored_dense != c["dense"]:
                fail(f"{path}: h5py says the root's attributes are in {'dense' if stored_dense else 'compact'} storage; the plan says "
                     f"{'dense' if c['dense'] else 'compact'}")
            for key in ("lineage_text", "source_text"):
                if c.get(key) is not None:
                    text_path = path + "." + key.split("_")[0] + ".txt"
                    with open(text_path, "w", encoding="utf-8") as fh:
                        fh.write(c[key])
                    c[key + "_file"] = "planted/" + os.path.basename(text_path)
            with h5py.File(path, "r") as f:
                if sorted(f.attrs.keys()) != sorted(a[0] for a in c["attrs"]):
                    fail(f"{path}: the root holds {sorted(f.attrs.keys())}")
                if sorted(f.keys()) != sorted(d.split("/")[0] for d in c["datasets"]):
                    fail(f"{path}: the root holds the objects {sorted(f.keys())}")
            for name, kind, value in c["attrs"]:
                verify_attr(path, name, kind, value)
        if isinstance(raw, bytes) or raw == "truncate":
            if h5py.is_hdf5(path) and raw != "truncate":
                fail(f"{path} is not meant to be HDF5")
            try:
                with h5py.File(path, "r"):
                    fail(f"{path} opens in h5py; it must not (the planted file that cannot be opened)")
            except OSError:
                pass
        if raw == "unreadable":
            os.chmod(path, 0)
            if os.access(path, os.R_OK):
                c["raw"] = "readable-skip"       # running with enough privilege to read a mode-000 file: the plant is void
                os.chmod(path, 0o644)
                print("reference: running as a user that reads mode 000 files; the 'unreadable' case is skipped")
    cases[:] = [c for c in cases if c["raw"] != "readable-skip"]
    names = sorted(n for n in os.listdir(planted_dir) if not n.endswith(".txt"))
    want = sorted(c["name"] + SUFFIX for c in cases if c["raw"] != "absent")
    if names != want:
        fail(f"{planted_dir} holds {names}, expected {want}")


# ---------------------------------------------------------------- the URL rule and the verdict

def utf16_units(text):
    return len(text.encode("utf-16-le")) // 2


def fs_units(name):
    """The units the file system gets to count: Foundation hands a file name over decomposed ("Å" is two units, A and a
    combining ring), so the name is measured as NFD (255 UTF-16 units, not 255 bytes)."""
    return utf16_units(nfd(name))


def sized(letter, total, extra=""):
    """A source name that is `letter`s (then "a"s to fill the last unit) and `extra`, whose sidecar name is `total` units."""
    room = total - fs_units(SUFFIX) - fs_units(extra)
    count, rest = divmod(room, fs_units(letter))
    name = letter * count + "a" * rest + extra
    if fs_units(name + SUFFIX) != total:
        fail(f"{letter!r} cannot make a sidecar name of {total} units")
    return name


NAME_LETTERS = [("ASCII", "n", ".dm4"), ("µ", "µ", ""), ("日", "日", ""), ("emoji", "\U0001F52C", ""), ("Å", "Å", "")]


def check_name_limit(probe):
    """Reference check: the file system on which the harness will write takes a name of 255 UTF-16 units and refuses 256, for
    every letter above (as the name is handed over: decomposed). It is the measurement the rule stands on (APFS, 2026-10-13);
    a volume that answers otherwise is not the volume the rule was measured on, and the gate says so instead of passing."""
    os.makedirs(probe, exist_ok=True)
    try:
        for label, letter, extra in NAME_LETTERS:
            for total, want in ((255, None), (256, errno.ENAMETOOLONG)):
                path = os.path.join(probe, nfd(sized(letter, total, extra) + SUFFIX))
                try:
                    os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY))
                    os.unlink(path)
                    got = None
                except OSError as error:
                    got = error.errno
                if got != want:
                    fail(f"the volume of {probe} answers {got} for a sidecar name of {total} units ({label}); the rule "
                         f"(ADR 020 D1: accepted at 255, ENAMETOOLONG at 256) was measured on APFS")
    finally:
        shutil.rmtree(probe, ignore_errors=True)


def url_cases():
    cases = []
    for name in ["SCAN.DM4", "scan.dm4", "SCAN.TIF", "a.tif", "Image.Tiff", "x.emd", "SCAN.MRC", "no extension",
                 "dotted.name.v2.dm3", ".hidden", "with space .DM4", "my.mactem.h5.bak", "mactem.h5", "Å-scan µm.TIF",
                 nfd("Å-scan µm.TIF")]:
        cases.append({"label": name + (" (NFD)" if name != nfc(name) else ""), "path": name, "outcome": "name", "name": name + SUFFIX})
    # the limit is 255 UTF-16 code units of the sidecar's name, whatever the letters weigh in bytes: 255 are accepted (the µ,
    # 日 and emoji names are 500, 745 and 499 bytes), 256 are refused (an emoji is two units, a decomposed "Å" two)
    for label, letter, extra in NAME_LETTERS:
        ok, over = sized(letter, 255, extra), sized(letter, 256, extra)
        cases.append({"label": f"255 units ({label})", "path": ok, "outcome": "name", "name": ok + SUFFIX})
        cases.append({"label": f"256 units ({label})", "path": over, "outcome": "refusal",
                      "refusal": refusal("nameTooLong", units=256)})
    for name in ["SCAN.mactem.h5", "SCAN.DM4.mactem.h5", "scan.MACTEM.H5", "x.Mactem.h5"]:
        cases.append({"label": name, "path": name, "outcome": "refusal", "refusal": refusal("sourceIsASidecar", source=name)})
    cases.append({"label": "a URL that is not a file", "url": "https://example.com/scan.dm4", "outcome": "refusal",
                  "refusal": refusal("noSourceName")})
    cases.append({"label": "the root", "absolute": "/", "outcome": "refusal", "refusal": refusal("noSourceName")})
    return cases


def verdict_cases(pixels):
    def ident(pix, name="scan.dm4", obj="ImageList.2 · HAADF", size=1000):
        w, h, arr = pixels[pix]
        return {"file_name": name, "byte_size": size, "object": obj, "pixels": pix}

    cases = []

    def v(name, stored, opened, expect, **kw):
        cases.append({"name": name, "stored": stored, "opened": opened, "expect": expect, **kw})

    v("same image", ident("six"), ident("six"), {"kind": "adopt"})
    v("same image whatever the byte size", ident("six", size=1), ident("six", size=987654321), {"kind": "adopt"})
    v("same image, NFD against NFC name", ident("six", name=nfd("Å.tif")), ident("six", name=nfc("Å.tif")), {"kind": "adopt"})
    v("object differs", ident("six", obj="ImageList.2 · HAADF"), ident("six", obj="ImageList.3 · BF"), {"kind": "refuse"},
      names=["ImageList.2 · HAADF", "ImageList.3 · BF"])
    v("shape differs", ident("six"), ident("six-tall"), {"kind": "refuse"}, shapes=["3 × 2", "2 × 3"])
    v("object and pixels differ", ident("six"), ident("six-ulp", obj="other"), {"kind": "refuse"})
    v("pixels differ", ident("six"), ident("six-ulp"), {"kind": "adoptPixelsDiffer"})
    v("pixels differ and the name too", ident("six"), ident("six-ulp", name="renamed.dm4"), {"kind": "adoptPixelsDiffer"})
    v("only the name differs", ident("six"), ident("six", name="renamed.dm4"), {"kind": "adoptRenamed", "from": "scan.dm4"})
    v("normalised copy is another image", ident("ramp-a"), ident("ramp-b"), {"kind": "adoptPixelsDiffer"})
    return cases


# ---------------------------------------------------------------- plant

REPLACE_SOURCE, REPLACE_LINEAGE = '{"s":"new Å"}', '{"l":"new µ","n":2}'


def raw_writes():
    """What the writer is offered directly (not through the lineage): its limits, and a replace over a sidecar h5py wrote."""
    return [
        {"id": "nul-lineage", "source": "{}", "lineage": "a\u0000b", "outcome": "refusal", "refusal": refusal("embeddedNUL", attribute=LINEAGE)},
        {"id": "nul-source", "source": "a\u0000b", "lineage": "{}", "outcome": "refusal", "refusal": refusal("embeddedNUL", attribute=SOURCE)},
        {"id": "cap-plus-one-lineage", "source": "{}", "fill_attribute": "lineage", "fill_bytes": CAP + 1, "outcome": "refusal",
         "refusal": refusal("stringTooLong", attribute=LINEAGE, bytes=CAP + 1)},
        {"id": "cap-plus-one-source", "lineage": "{}", "fill_attribute": "source", "fill_bytes": CAP + 1, "outcome": "refusal",
         "refusal": refusal("stringTooLong", attribute=SOURCE, bytes=CAP + 1)},
        # The text cap: the four attributes' text together is at most 60,000 bytes (the two markers one byte each, the source "{}")
        {"id": "total-cap-exact-lineage", "source": "{}", "fill_attribute": "lineage", "fill_bytes": TOTAL_CAP - 4, "outcome": "written"},
        {"id": "total-cap-plus-one-lineage", "source": "{}", "fill_attribute": "lineage", "fill_bytes": TOTAL_CAP - 3, "outcome": "refusal",
         "refusal": refusal("sidecarTooLarge", bytes=TOTAL_CAP + 1)},
        {"id": "total-cap-plus-one-split", "source": "s" * 30_000, "fill_attribute": "lineage", "fill_bytes": TOTAL_CAP - 30_000 - 1,
         "outcome": "refusal", "refusal": refusal("sidecarTooLarge", bytes=TOTAL_CAP + 1)},
        # P1: every file from empty to within 100 bytes of the cap keeps its attributes in the object header (compact storage)
    ] + [
        {"id": f"size-{n}", "source": "{}", "fill_attribute": "lineage", "fill_bytes": n, "outcome": "written", "compact": True}
        for n in (0, 1, 1_000, 10_000, 30_000, 50_000, 59_000, 59_900, TOTAL_CAP - 4)
    ] + [
        {"id": "replace-valid", "from": "planted/valid-compact-attributes-tracked-order.mactem.h5", "source": REPLACE_SOURCE,
         "lineage": REPLACE_LINEAGE, "outcome": "written"},
    ]


def plant(ref):
    check_reference()
    os.makedirs(ref, exist_ok=True)
    pixels = pixel_sets()
    os.makedirs(os.path.join(ref, "pixels"), exist_ok=True)
    pixel_list = []
    for name, (w, h, arr) in pixels.items():
        if arr.size != w * h:
            fail(f"pixel set {name}: {arr.size} values for {w} x {h}")
        path = os.path.join(ref, "pixels", name + ".f32")
        with open(path, "wb") as fh:
            fh.write(arr.astype("<f4").tobytes())
        pixel_list.append({"name": name, "width": w, "height": h, "file": "pixels/" + name + ".f32", "sha256": fingerprint(arr)})
    if len({p["sha256"] for p in pixel_list if p["name"] not in ("six-tall",)}) != len(pixel_list) - 1:
        fail("two of the planted pixel sets that must differ share a fingerprint")
    if pixel_list[0]["sha256"] != next(p for p in pixel_list if p["name"] == "six-tall")["sha256"]:
        fail("six and six-tall must be the same bytes")
    # the doubles: float(repr(x)) is bit-equal to x, the Python half of what Swift's shortest round-trip text must satisfy
    for op in MARKS_OPS + UNICODE_OPS:
        for group in ("parameters", "results"):
            for k, v in op.get(group, []):
                if v[0] == "d" and bits_of(float(repr(v[1]))) != bits_of(v[1]):
                    fail(f"repr does not round-trip {v[1]!r}")
    check_name_limit(os.path.join(ref, "name-probe"))
    cases = planted_cases(pixels, ref)
    plant_files(cases, os.path.join(ref, "planted"))
    planted = [{k: c[k] for k in ("name", "file", "read", "lineage", "source", "write_over", "child", "replaces", "dense")} for c in cases]
    for p, c in zip(planted, cases):
        p["lineage_text_file"] = c.get("lineage_text_file")
        p["source_text_file"] = c.get("source_text_file")
        p["absent"] = c["raw"] == "absent"
        p["dangling"] = c["raw"] == "dangling"
    # the 2000-node and canonical texts are in the files; the manifest keeps lengths, digests and nodes
    manifest = {"h5py": h5py.__version__, "numpy": np.__version__, "pixels": pixel_list, "sessions": sessions(pixels),
                "planted": planted, "urls": url_cases(), "verdicts": verdict_cases(pixels), "raw_writes": raw_writes(),
                "limits": {"cap": CAP, "max_nodes": MAX_NODES, "max_next_id": MAX_NEXT_ID}, "fuzz": FUZZ,
                "marks": marks_reference.plan(ref)}
    fuzz_sizes = check_fuzz_plan(manifest["sessions"])
    dense = plant_dense_fuzz_file(ref)
    for entry in manifest["fuzz"]["files"]:
        if entry.get("planted"):
            entry.update(dense)
    if dense_storage(os.path.join(ref, dense["file"])) is not True:
        fail("the fuzz's dense file is not in dense storage")
    manifest["fuzz"]["structure"] = dense_fuzz.plan(os.path.join(ref, "dense-fuzz"), DENSE_BASES)
    manifest["fuzz"]["forged"] = dense_fuzz.forged_files(os.path.join(ref, "dense-fuzz"))
    with open(os.path.join(ref, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False)
    print(f"reference: planted {len(manifest['sessions'])} Swift sessions, {len(planted)} sidecars, {len(manifest['urls'])} "
          f"names, {len(manifest['verdicts'])} verdicts, {len(pixel_list)} pixel sets with h5py {h5py.__version__}, numpy {np.__version__}; "
          f"the fuzz's lineage texts {fuzz_sizes}")


# ---------------------------------------------------------------- read back what Swift wrote

FLOAT_TEXT = re.compile(r"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?")


class Checks:
    def __init__(self):
        self.items = []

    def __call__(self, ok, name, detail=""):
        self.items.append({"name": name, "ok": bool(ok), "detail": detail if not ok else ""})
        return bool(ok)


def attribute_problems(facts, text):
    """The fixed-length-string rule, P1, for an attribute Swift wrote with the text `text`: each of five properties is None when it holds, else the
    reason. type: a scalar fixed-length string (not variable-length, not an array, not another class). strpad: NULLPAD.
    charset: UTF-8. size: as many bytes of storage as the text's UTF-8 bytes (1 for an empty text). bytes: the storage
    byte-equal to the text (an empty text is one NUL), padding and all."""
    out = {"type": None, "strpad": None, "charset": None, "size": None, "bytes": None}
    if facts["absent"]:
        out["type"] = "absent"
        return out
    kinds = []
    if facts["shape"] != ():
        kinds.append(f"shape {facts['shape']}, not ()")
    if not facts["string"]:
        kinds.append("not a string")
    elif facts["variable"]:
        kinds.append("variable-length, not fixed-length")
    if kinds:
        out["type"] = "; ".join(kinds)
        return out
    data = text.encode("utf-8")
    want = data if data else b"\0"
    if facts["pad"] != h5t.STR_NULLPAD:
        out["strpad"] = f"pad {facts['pad']}, not NULLPAD ({h5t.STR_NULLPAD})"
    if facts["cset"] != h5t.CSET_UTF8:
        out["charset"] = f"character set {facts['cset']}, not UTF-8 ({h5t.CSET_UTF8})"
    if facts["size"] != len(want):
        out["size"] = f"{facts['size']} bytes of storage; the text is {len(data)} bytes ({len(want)} to store)"
    stored = facts["stored"]
    if stored != want:
        first = next((i for i in range(min(len(stored), len(want))) if stored[i] != want[i]), min(len(stored), len(want)))
        out["bytes"] = f"{len(stored)} bytes stored vs {len(want)} that Swift wrote; the first difference is at byte {first}"
    return out


def stored_text(facts):
    """The text a fixed-length attribute holds: its storage up to the first NUL (None if that is not UTF-8)."""
    data = facts["stored"].split(b"\0", 1)[0]
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def no_float(text):
    raise ValueError(f"a JSON number with a decimal point or exponent: {text}")


def check_nodes(check, sid, actual, expected):
    """Fields, coordinates, dates and removals of every node, against the plan. Few nodes: one check each; many: aggregated."""
    per_node = len(expected) <= 10
    problems = {"fields": [], "coordinates": [], "recorded": [], "removed": []}

    def record(kind, node_id, message):
        problems[kind].append(f"{node_id}: {message}")

    if [n.get("id") for n in actual] != [e["id"] for e in expected]:
        check(False, f"h5py {sid} lineage nodes compared", "the node ids differ, so the nodes' fields were not compared")
        return
    for a, e in zip(actual, expected):
        nid = e["id"]
        want_keys = {"external", "id", "inputs", "kind", "parameters", "recorded", "results"} | ({"removed"} if e["removed"] is not None else set())
        if set(a) != want_keys:
            record("fields", nid, f"keys {sorted(a)} vs {sorted(want_keys)}")
        if a.get("kind") != e["kind"]:
            record("fields", nid, f"kind {a.get('kind')!r} vs {e['kind']!r}")
        if a.get("inputs") != e["inputs"]:
            record("fields", nid, f"inputs {a.get('inputs')} vs {e['inputs']}")
        if a.get("external") != []:
            record("fields", nid, f"external {a.get('external')} vs []")
        for group in ("parameters", "results"):
            got = a.get(group)
            want = e[group]
            if not isinstance(got, dict) or set(got) != {x["k"] for x in want}:
                record("fields", nid, f"{group} keys {sorted(got) if isinstance(got, dict) else got} vs {[x['k'] for x in want]}")
                continue
            for item in want:
                k, text = item["k"], got[item["k"]]
                if not isinstance(text, str):
                    record("fields", nid, f"{group}.{k} is {type(text).__name__}, not a string")
                elif "s" in item:
                    if text.encode("utf-8") != item["s"].encode("utf-8"):
                        record("fields", nid, f"{group}.{k} {text!r} vs {item['s']!r}")
                else:
                    if not FLOAT_TEXT.fullmatch(text):
                        record("coordinates", nid, f"{group}.{k} {text!r} is not decimal number text")
                    elif bits_of(float(text)) != item["d"]:
                        record("coordinates", nid, f"{group}.{k} {text!r} is {bits_of(float(text))}, planted {item['d']}")
        rec = a.get("recorded")
        if type(rec) is not int or rec != e["recorded"]:
            record("recorded", nid, f"{rec!r} ({type(rec).__name__}) vs the planted integer {e['recorded']}")
        rem = a.get("removed")
        if e["removed"] is None:
            if "removed" in a:
                record("removed", nid, f"removed {rem!r} on a live node")
        elif type(rem) is not int or rem != e["removed"]:
            record("removed", nid, f"removed {rem!r} vs {e['removed']}")
    for kind, found in problems.items():
        if per_node:
            for e in expected:
                mine = [p for p in found if p.startswith(e["id"] + ":")]
                check(not mine, f"h5py {sid} {e['id']} {kind}", "; ".join(mine))
        else:
            check(not found, f"h5py {sid} {kind}", "; ".join(found[:3]) + (f" … ({len(found)} in all)" if len(found) > 3 else ""))


def readback(ref, out):
    check_reference()
    manifest = json.load(open(os.path.join(ref, "manifest.json"), encoding="utf-8"))
    pixels = {p["name"]: p for p in manifest["pixels"]}
    check = Checks()
    written_path = os.path.join(out, "swift-written.json")
    try:
        written = {r["id"]: r for r in json.load(open(written_path, encoding="utf-8"))["sessions"]}
    except (OSError, ValueError) as error:
        check(False, "h5py reads swift-written.json", f"the harness's write step left no record: {error}")
        written = {}
    directory = os.path.join(out, "swift")
    listing = sorted(os.listdir(directory)) if os.path.isdir(directory) else []
    want_names = sorted(s["sidecar_name"] for s in manifest["sessions"])
    got_nfc = sorted(nfc(n) for n in listing)
    # the registered name rule on the real file system: source name verbatim + .mactem.h5, and nothing else beside it
    check(got_nfc == sorted(nfc(n) for n in want_names), "h5py swift directory",
          f"{listing} vs the sidecars {want_names} (a stray or a renamed file)")
    for session in manifest["sessions"]:
        sid = session["id"]
        record = written.get(sid)
        if record is None or record.get("error"):
            check(False, f"h5py {sid} file", f"Swift did not write it: {record.get('error') if record else 'no record'}")
            continue
        name = session["sidecar_name"]
        match = [n for n in listing if nfc(n) == nfc(name)]
        check(bool(match), f"h5py {sid} file name", f"{listing} holds no {name!r}")
        if not match:
            continue
        path = os.path.join(directory, match[0])
        # A review (2026-10-14, finding 2): the writer sets the library-version bounds itself, so the file is in the latest format
        # whatever the library's default is: a superblock of version 2 or later (version 0 is the 'earliest' format, which cannot
        # hold a text over about 65,499 bytes) and version-2 object headers ("OHDR"; "OHDR" is absent from a version-1 header).
        raw = open(path, "rb").read()
        signature = b"\x89HDF\r\n\x1a\n"
        check(raw[:8] == signature and len(raw) > 8 and raw[8] >= 2, f"h5py {sid} superblock",
              f"superblock version {raw[8] if len(raw) > 8 else None}; the library-version bounds are (V18, LATEST), so 2 or later")
        check(b"OHDR" in raw, f"h5py {sid} object headers", "no version-2 object header (OHDR) in the file")
        try:
            f = h5py.File(path, "r")
        except OSError as error:
            check(False, f"h5py {sid} opens", str(error))
            continue
        with f:
            check(True, f"h5py {sid} opens")
            check(sorted(f.attrs.keys()) == sorted(ATTRIBUTES) and len(f.keys()) == 0, f"h5py {sid} attributes",
                  f"root attributes {sorted(f.attrs.keys())}, objects {sorted(f.keys())}")
            texts = {}
            for attr in ATTRIBUTES:
                swift_text = {SOURCE: record["source_json"], LINEAGE: record["lineage_json"],
                              IDENTITY: "1", MIN_READER: "1"}[attr]
                facts = attribute_facts(f, attr)
                problems = attribute_problems(facts, swift_text)
                for prop in ("type", "strpad", "charset", "size", "bytes"):
                    check(problems[prop] is None, f"h5py {sid} {attr} {prop}",
                          f"{problems[prop]} (want a scalar fixed-length NULLPAD UTF-8 string of the text's own length)")
                if problems["type"] is None and problems["bytes"] is None:
                    texts[attr] = stored_text(facts)
            check(texts.get(IDENTITY) == "1" and texts.get(MIN_READER) == "1", f"h5py {sid} markers",
                  f"identity {texts.get(IDENTITY)!r}, minimum reader {texts.get(MIN_READER)!r}; both are '1'")
        # the source identity
        want = session["expect"]["identity"]
        text = texts.get(SOURCE)
        if text is not None:
            try:
                got = json.loads(text, parse_float=no_float)
            except ValueError as error:
                got = None
                check(False, f"h5py {sid} source json", str(error))
            if got is not None:
                size = pixels[session["identity"]["pixels"]]
                ok = got == want and all(type(got.get(k)) is int for k in ("byte_size", "width", "height")) \
                    and got.get("pixel_sha256") == size["sha256"] and got.get("file_name") == nfc(session["identity"]["file_name"]) \
                    and got.get("file_name").encode("utf-8") == nfc(session["identity"]["file_name"]).encode("utf-8")
                check(ok, f"h5py {sid} source json", f"{got} vs the planted {want}")
                check(canon(got) == text, f"h5py {sid} source canonical", f"{text!r} is not Python's canonical form {canon(got)!r}")
        # the lineage
        text = texts.get(LINEAGE)
        if text is None:
            continue
        try:
            got = json.loads(text, parse_float=no_float)
        except ValueError as error:
            check(False, f"h5py {sid} lineage integers", str(error))
            continue
        check(True, f"h5py {sid} lineage integers")
        check(canon(got) == text, f"h5py {sid} lineage canonical",
              f"not Python's canonical form (sorted keys, no spaces, no escaping of non-ASCII): {text[:200]!r}")
        expect = session["expect"]
        check(isinstance(got, dict) and set(got) == {"version", "next_id", "nodes"} and got.get("version") == 1
              and type(got.get("version")) is int, f"h5py {sid} lineage version", f"keys/version of {sorted(got) if isinstance(got, dict) else got}")
        check(got.get("next_id") == expect["next_id"] and type(got.get("next_id")) is int, f"h5py {sid} lineage next_id",
              f"next_id {got.get('next_id')!r} vs {expect['next_id']} (ids are never reused)")
        actual = got.get("nodes", [])
        check([n.get("id") for n in actual] == [e["id"] for e in expect["nodes"]], f"h5py {sid} lineage node ids",
              f"{[n.get('id') for n in actual][:12]} vs {[e['id'] for e in expect['nodes']][:12]}")
        check_nodes(check, sid, actual, expect["nodes"])
    raw_directory = os.path.join(out, "swift-raw")
    for raw in manifest["raw_writes"]:
        rid = raw["id"]
        path = os.path.join(raw_directory, rid + SUFFIX)
        if raw["outcome"] == "refusal":
            check(not os.path.exists(path), f"h5py raw {rid} no file", f"{path} exists after a refused write")
            continue
        want = {IDENTITY: "1", MIN_READER: "1",
                SOURCE: raw["source"] if "source" in raw else "y" * raw["fill_bytes"],
                LINEAGE: raw["lineage"] if "lineage" in raw else "y" * raw["fill_bytes"]}
        try:
            f = h5py.File(path, "r")
        except OSError as error:
            check(False, f"h5py raw {rid} opens", str(error))
            continue
        with f:
            check(sorted(f.attrs.keys()) == sorted(ATTRIBUTES) and len(f.keys()) == 0, f"h5py raw {rid} attributes",
                  f"root attributes {sorted(f.attrs.keys())}, objects {sorted(f.keys())}")
            if raw.get("compact"):
                # P1: the attributes are in the object header, as messages (the header holds at least a message each of
                # the four attributes: h5py's object info counts them), and not in dense storage (no fractal heap and no B-tree
                # index for the root's attributes)
                info = h5py.h5o.get_info(f.id)
                check(info.num_attrs == 4 and info.hdr.nmesgs >= info.num_attrs, f"h5py raw {rid} attribute messages",
                      f"{info.num_attrs} attributes, {info.hdr.nmesgs} messages in the object header")
                check(info.meta_size.attr.heap_size == 0 and info.meta_size.attr.index_size == 0, f"h5py raw {rid} compact",
                      f"dense attribute storage: heap {info.meta_size.attr.heap_size} B, index {info.meta_size.attr.index_size} B")
            for attr in ATTRIBUTES:
                problems = {k: v for k, v in attribute_problems(attribute_facts(f, attr), want[attr]).items() if v is not None}
                check(not problems, f"h5py raw {rid} {attr}", "; ".join(f"{k}: {v}" for k, v in problems.items()))
    marks_files = marks_reference.readback(ref, out, check)
    # the file written beside the real one and left untouched
    with open(os.path.join(out, "readback.json"), "w", encoding="utf-8") as fh:
        json.dump({"h5py": h5py.__version__, "checks": check.items}, fh, ensure_ascii=False)
    failed = sum(1 for c in check.items if not c["ok"])
    print(f"reference: h5py read back {len(manifest['sessions'])} Swift sessions: {len(check.items)} checks, {failed} not passing")


def hang_probe(path, name):
    """The child of plant_hang_file: h5py reads one variable-length attribute. On the hang file it never returns."""
    with h5py.File(path, "r") as f:
        print(repr(f.attrs[name])[:60])


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "plant":
        plant(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "readback":
        readback(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "hang-probe":
        hang_probe(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
