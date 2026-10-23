"""marks_reference.py — the truth for the marks of tools/parity/sidecar-parity (archive: roadmap-registrations-2026-10-15.md V1-2 slice B, the core: `SessionMarks`,
`SessionRestore`, `SessionSave`). Imported by reference.py, whose helpers it uses (`__main__`).

    plan(ref)                 the plan the Swift harness reads (manifest["marks"]) and the sidecars h5py writes for it
                              (<ref>/planted-marks/*.mactem.h5)
    readback(ref, out, check) what h5py finds in the sidecars Swift wrote (<out>/marks/*.mactem.h5, <out>/marks-save/)

Independence. The truth is derived here from the planted doubles, which the plan gives as IEEE-754 bit patterns, never as
text: a distance is the square root of an exact sum of squares (Fraction arithmetic, a 200-bit integer square root, one
rounding to a double), the angle is `atan2(|cross|, dot)` of the exact vectors (scaled by the axes when both are calibrated
in one unit), a scale or a coordinate counts only if `float(text)` is bit-equal to the planted double, and the number of a
result counts if it is within 1e-12 of the truth, relative. h5py reads every node of the lineage Swift wrote and checks its
kind, id, the exact set of keys, the coordinates, the width, the object, the frame, every result and `recorded`; Swift then
restores those files, and the sidecars h5py wrote below, with `SessionRestore` and must reach the marks the plan states
(kinds, ids, points bit for bit, widths, how many nodes are kept and not drawn, the verdict, the calibration note), or the
refusal the plan names, naming the node (a coordinate outside the grammar `-?digits(.digits)?(e[+-]?digits)?`, a point
outside the image by the inclusive bounds, a width that is not plain digits 1 to 25, a missing key). The sentence for a
refusal is written the same way on both sides (`mark.badCoordinate s2 x1 0x1p3`).
"""
import json
import math
import os
import re
import struct
import sys
from fractions import Fraction

import h5py

BASE_MS = 1_791_900_000_000
OBJECT = "ImageList.2 · HAADF"
GRAMMAR = re.compile(r"-?[0-9]+(\.[0-9]+)?(e[+-]?[0-9]+)?")


def R():
    return sys.modules["__main__"]


def bits(x):
    return struct.pack(">d", x).hex()


def frombits(hex_):
    return struct.unpack(">d", bytes.fromhex(hex_))[0]


def sqrt_exact(q):
    """The double nearest to the square root of the non-negative Fraction `q` (a 200-bit integer square root first)."""
    if q == 0:
        return 0.0
    n = (q.numerator << 400) // q.denominator
    return float(Fraction(math.isqrt(n), 1 << 200))


def axis(scale, units):
    return None if scale is None else {"scale": bits(scale), "units": units}


def calibrated(a):
    return a is not None and a["units"] != "" and math.isfinite(frombits(a["scale"])) and frombits(a["scale"]) > 0


def shared_scales(ax, ay):
    if calibrated(ax) and calibrated(ay) and ax["units"] == ay["units"]:
        return Fraction(frombits(ax["scale"])), Fraction(frombits(ay["scale"])), ax["units"]
    return None


def truth_results(kind, pts, ax, ay, samples):
    """The `results` of a mark node: {key: ("num", float) | ("str", text) | ("bits", hex) | ("int", n)}; None for no key."""
    out = {}
    P = [(Fraction(x), Fraction(y)) for x, y in pts]
    shared = shared_scales(ax, ay)
    if kind in ("distance", "profile"):
        dx, dy = P[1][0] - P[0][0], P[1][1] - P[0][1]
        out["pixels"] = ("num", sqrt_exact(dx * dx + dy * dy))
        if shared:
            sx, sy, unit = shared
            out["length"] = ("num", sqrt_exact((dx * sx) ** 2 + (dy * sy) ** 2))
            out["unit"] = ("str", unit)
        if kind == "profile" and samples is not None:
            out["samples"] = ("int", samples)
    else:
        sx, sy = (shared[0], shared[1]) if shared else (Fraction(1), Fraction(1))
        ux, uy = (P[0][0] - P[1][0]) * sx, (P[0][1] - P[1][1]) * sy
        vx, vy = (P[2][0] - P[1][0]) * sx, (P[2][1] - P[1][1]) * sy
        if not (ux == 0 and uy == 0) and not (vx == 0 and vy == 0):
            cross, dot = ux * vy - uy * vx, ux * vx + uy * vy
            out["degrees"] = ("num", math.atan2(abs(float(cross)), float(dot)) * 180 / math.pi)
            out["plane"] = ("str", "physical" if shared else "pixel")
    if calibrated(ax):
        out["scale_x"] = ("bits", ax["scale"])
        out["unit_x"] = ("str", ax["units"])
    if calibrated(ay):
        out["scale_y"] = ("bits", ay["scale"])
        out["unit_y"] = ("str", ay["units"])
    return out


def result_text(value):
    kind, v = value
    return repr(frombits(v)) if kind == "bits" else (repr(v) if kind == "num" else str(v))


KEYS = (("x1", "y1"), ("x2", "y2"), ("x3", "y3"))


def mark(kind, *points, width=1, samples=None):
    return {"kind": kind, "points": [(float(x), float(y)) for x, y in points], "width": width, "samples": samples}


# ---------------------------------------------------------------- the sessions Swift writes (h5py reads them back)

def swift_sessions():
    nm = axis(0.5, "nm"), axis(2.0, "nm")
    mixed = axis(0.5, "nm"), axis(0.002, "µm")
    return [
        {"id": "aniso", "file_name": "mk-aniso.dm4", "object": OBJECT, "width": 64, "height": 48, "x": nm[0], "y": nm[1],
         "marks": [mark("distance", (2.5, 1.25), (30.75, 17.5)),
                   mark("distance", (0.1, 0.2), (0.1, 0.2)),
                   mark("angle", (10.5, 3.25), (4.0, 12.75), (34.25, 20.5)),
                   mark("angle", (5, 5), (5, 5), (20, 9)),                     # a zero-length arm: no angle
                   mark("angle", (14, 11), (10, 10), (6, 11)),                 # right in nanometres, not in pixels
                   mark("profile", (1.5, 2.0), (60.25, 40.75), width=7, samples=83),
                   mark("distance", (-0.5, -0.5), (63.5, 47.5)),
                   mark("profile", (3, 3), (3, 3), width=25, samples=1)]},
        {"id": "mixed", "file_name": "mk-mixed.tif", "object": OBJECT, "width": 64, "height": 48, "x": mixed[0], "y": mixed[1],
         "marks": [mark("distance", (2.5, 1.25), (30.75, 17.5)),
                   mark("angle", (10.5, 3.25), (4.0, 12.75), (34.25, 20.5)),
                   mark("profile", (1.5, 2.0), (60.25, 40.75), width=3, samples=61)]},
        {"id": "uncal", "file_name": "mk-uncal.mrc", "object": "", "width": 64, "height": 48, "x": None, "y": None,
         "marks": [mark("distance", (0, 0), (3, 4)), mark("angle", (10.5, 3.25), (4.0, 12.75), (34.25, 20.5)),
                   mark("profile", (0, 0), (63, 0), width=1, samples=64)]},
        {"id": "xonly", "file_name": "mk-xonly.emd", "object": OBJECT, "width": 64, "height": 48, "x": axis(0.25, "nm"), "y": None,
         "marks": [mark("distance", (2.5, 1.25), (30.75, 17.5)), mark("angle", (10.5, 3.25), (4.0, 12.75), (34.25, 20.5))]},
        {"id": "big", "file_name": "mk-big.dm4", "object": OBJECT, "width": 33_554_432, "height": 33_554_432,
         "x": axis(1e-12, "m"), "y": axis(1e-12, "m"),
         "marks": [mark("distance", (1e-300, 5e-324), (33.333333333333336, 16777217.5)),
                   mark("distance", (-0.0, 0.1), (33554431.5, 33554431.5)),
                   mark("angle", (0.1, 0.2), (16777217.5, 3), (1e-5, 2.0000000000000004)),
                   mark("profile", (7.000000000000001, 2.5), (8.5, 1e7), width=11, samples=10_000_000)]},
    ]


def session_node_id(index):
    return f"s{index + 1}"


def expected_nodes(session):
    ax, ay = session["x"], session["y"]
    nodes = []
    for i, m in enumerate(session["marks"]):
        parameters = {"object": ("str", session["object"]), "frame": ("str", "0")}
        for (kx, ky), (x, y) in zip(KEYS, m["points"]):
            parameters[kx] = ("bits", bits(x))
            parameters[ky] = ("bits", bits(y))
        if m["kind"] == "profile":
            parameters["width"] = ("str", str(m["width"]))
        nodes.append({"id": session_node_id(i), "kind": m["kind"], "parameters": parameters,
                      "results": truth_results(m["kind"], m["points"], ax, ay, m["samples"]), "recorded": BASE_MS + 1000 * i})
    return nodes


def digest_of(label):
    import hashlib
    return hashlib.sha256(label.encode()).hexdigest()


def session_plan(session):
    return {"id": session["id"], "file_name": session["file_name"], "object": session["object"], "width": session["width"],
            "height": session["height"], "byte_size": 123_456, "digest": digest_of(session["id"]), "x": session["x"], "y": session["y"],
            "marks": [{"kind": m["kind"], "points": [[bits(x), bits(y)] for x, y in m["points"]], "width": m["width"],
                       "samples": m["samples"], "recorded": BASE_MS + 1000 * i} for i, m in enumerate(session["marks"])]}


# ---------------------------------------------------------------- the sidecars h5py writes (Swift restores them)

class Case:
    def __init__(self, name, attrs, opened, expect, save=None):
        self.name, self.attrs, self.opened, self.expect, self.save = name, attrs, opened, expect, save


def py_node(index, kind, pts, ax, ay, *, width=1, obj=OBJECT, frame="0", removed=None, samples=None, drop=(), override=None,
            results=True, node_id=None):
    parameters = {"object": obj, "frame": frame}
    for (kx, ky), (x, y) in zip(KEYS, pts):
        parameters[kx], parameters[ky] = repr(x), repr(y)
    if kind == "profile":
        parameters["width"] = str(width)
    for key in drop:
        parameters.pop(key, None)
    parameters.update(override or {})
    res = {}
    if results and kind in ("distance", "angle", "profile"):
        res = {k: result_text(v) for k, v in truth_results(kind, pts, ax, ay, samples).items()}
    node = {"external": [], "id": node_id or f"s{index}", "inputs": [], "kind": kind, "parameters": parameters,
            "recorded": BASE_MS + index, "results": res}
    if removed is not None:
        node["removed"] = removed
    return node


def lineage_of(nodes, version=1):
    return R().canon({"version": version, "next_id": len(nodes) + 1, "nodes": nodes})


def identity_text(file_name="mk-case.dm4", obj=OBJECT, width=64, height=48, digest=None, byte_size=1000):
    return R().canon(R().identity_obj(file_name, byte_size, obj, width, height, digest or digest_of("case")))


def opened_of(file_name="mk-case.dm4", obj=OBJECT, width=64, height=48, digest=None, byte_size=1000, x=None, y=None):
    return {"file_name": file_name, "object": obj, "width": width, "height": height, "digest": digest or digest_of("case"),
            "byte_size": byte_size, "x": x, "y": y}


def drawn_marks(nodes, ids):
    """The marks the plan says a restore draws, from the nodes h5py wrote: the planted doubles by their bit patterns."""
    by_id = {n["id"]: n for n in nodes}
    out = []
    for node_id in ids:
        node = by_id[node_id]
        count = 3 if node["kind"] == "angle" else 2
        pts = [[bits(float(node["parameters"][kx])), bits(float(node["parameters"][ky]))] for kx, ky in KEYS[:count]]
        width = int(node["parameters"]["width"]) if node["kind"] == "profile" else 1
        out.append({"id": node_id, "kind": node["kind"], "points": pts, "width": width})
    return out


def planted_cases():
    r = R()
    IDENT, MINR, SRC, LIN = r.IDENTITY, r.MIN_READER, r.SOURCE, r.LINEAGE
    ax, ay = axis(0.5, "nm"), axis(2.0, "nm")
    cases = []

    def attrs(source, lineage, minr="1"):
        out = [(IDENT, "str", "1"), (MINR, "str", minr)]
        if source is not None:
            out.append((SRC, "str", source))
        if lineage is not None:
            out.append((LIN, "str", lineage))
        return out

    def add(name, nodes, *, opened=None, source=None, expect=None, save="same", lineage=None, version=1):
        opened = opened or opened_of(x=ax, y=ay)
        text = lineage if lineage is not None else lineage_of(nodes, version)
        if isinstance(expect, dict) and "restored" in expect and not expect["restored"].get("readOnly"):
            expect["restored"]["marks"] = drawn_marks(nodes, expect["restored"]["ids"])
        elif isinstance(expect, dict) and "restored" in expect:
            expect["restored"]["marks"] = []
        cases.append(Case(name, attrs(source if source is not None else identity_text(opened["file_name"], opened["object"],
                          opened["width"], opened["height"], opened["digest"], opened["byte_size"]), text), opened, expect, save))

    def restored(ids, kept=0, verdict="adopt", calib=False, read_only=False):
        return {"restored": {"ids": ids, "kept": kept, "verdict": verdict, "calibrationDiffers": calib, "readOnly": read_only,
                             "marks": []}}

    pts2 = [(2.5, 1.25), (30.75, 17.5)]
    pts3 = [(10.5, 3.25), (4.0, 12.75), (34.25, 20.5)]
    good = lambda i: py_node(i, "distance", pts2, ax, ay)
    # --- restored: the three kinds in node order, their points and width; the rest kept, not drawn
    nodes = [py_node(1, "distance", pts2, ax, ay), py_node(2, "angle", pts3, ax, ay), py_node(3, "profile", pts2, ax, ay, width=7, samples=40),
             py_node(4, "export", [], ax, ay, results=False), py_node(5, "distance", pts2, ax, ay, removed=BASE_MS + 99),
             py_node(6, "distance", pts2, ax, ay, obj="ImageList.9"), py_node(7, "distance", pts2, ax, ay, frame="1"),
             py_node(8, "fft", [], ax, ay, results=False)]
    nodes[3]["parameters"] = {"size": "256"}
    nodes[7]["parameters"] = {"x1": "junk"}
    add("restore-three-kinds-and-kept", nodes, expect=restored(["s1", "s2", "s3"], kept=5))
    add("restore-edges-and-zero-length", [py_node(1, "distance", [(-0.5, -0.5), (63.5, 47.5)], ax, ay),
                                          py_node(2, "distance", [(63.5, -0.5), (63.5, -0.5)], ax, ay),
                                          py_node(3, "angle", [(-0.5, 47.5), (-0.5, 47.5), (63.5, 47.5)], ax, ay),
                                          py_node(4, "profile", [(0, 0), (1, 1)], ax, ay, width=1, samples=2),
                                          py_node(5, "profile", [(0, 0), (1, 1)], ax, ay, width=25, samples=2)],
        expect=restored(["s1", "s2", "s3", "s4", "s5"]))
    add("restore-awkward-doubles", [py_node(1, "distance", [(1e-300, 5e-324), (33.333333333333336, 16.5)], ax, ay),
                                    py_node(2, "distance", [(-0.0, 0.1), (63.49999999999999, 47.49999999999999)], ax, ay),
                                    py_node(3, "distance", [(1e-05, 1.5e-07), (2.5e-5, 4.2e-1)], ax, ay)],
        expect=restored(["s1", "s2", "s3"]))
    add("restore-extra-keys-tolerated", [{**good(1), "parameters": {**good(1)["parameters"], "note": "kept", "x9": "junk"}}],
        expect=restored(["s1"]))
    add("restore-empty-lineage", [], expect=restored([]))
    # --- the calibration note (P3 of the registration's restore): recorded scales against the opened axes
    for name, ox, oy, differs in [("same", ax, ay, False), ("x-scale", axis(0.25, "nm"), ay, True), ("y-unit", ax, axis(2.0, "µm"), True),
                                  ("swapped", ay, ax, True), ("opened-uncalibrated", None, None, True),
                                  ("opened-x-only", ax, None, True)]:
        add(f"calibration-{name}", [py_node(1, "distance", pts2, ax, ay)], opened=opened_of(x=ox, y=oy),
            expect=restored(["s1"], calib=differs))
    add("calibration-recorded-none-opened-none", [py_node(1, "distance", pts2, None, None)], opened=opened_of(),
        expect=restored(["s1"], calib=False))
    add("calibration-recorded-none-opened-has", [py_node(1, "distance", pts2, None, None)], opened=opened_of(x=ax, y=ay),
        expect=restored(["s1"], calib=True))
    add("calibration-removed-node-is-not-judged", [py_node(1, "distance", pts2, ax, ay, removed=BASE_MS)], opened=opened_of(x=None, y=None),
        expect=restored([], kept=1, calib=False))
    # --- P3: the verdict, through the restore
    base = [py_node(1, "distance", pts2, ax, ay)]
    add("verdict-other-object", base, opened=opened_of(obj="ImageList.3", x=ax, y=ay), source=identity_text(),
        expect={"refused": "otherImage"}, save=None)
    add("verdict-other-width", base, opened=opened_of(width=65, x=ax, y=ay), source=identity_text(), expect={"refused": "otherImage"}, save=None)
    add("verdict-other-height", base, opened=opened_of(height=49, x=ax, y=ay), source=identity_text(), expect={"refused": "otherImage"}, save=None)
    add("verdict-pixels-differ", base, opened=opened_of(digest=digest_of("other"), x=ax, y=ay), source=identity_text(),
        expect=restored(["s1"], verdict="adoptPixelsDiffer"))
    add("verdict-name-only", base, opened=opened_of(file_name="renamed.dm4", x=ax, y=ay), source=identity_text(),
        expect=restored(["s1"], verdict="adoptRenamed:mk-case.dm4"))
    add("verdict-byte-size-never-decides", base, opened=opened_of(byte_size=999_999, x=ax, y=ay), source=identity_text(),
        expect=restored(["s1"]))
    add("verdict-pixels-and-name", base, opened=opened_of(file_name="renamed.dm4", digest=digest_of("other"), x=ax, y=ay),
        source=identity_text(), expect=restored(["s1"], verdict="adoptPixelsDiffer"))
    add("verdict-before-a-bad-node", [py_node(1, "distance", [(900, 1), (2, 2)], ax, ay)], opened=opened_of(obj="ImageList.3", x=ax, y=ay),
        source=identity_text(), expect={"refused": "otherImage"}, save=None)
    # --- P2: refusals by name, never a partial restore
    cases.append(Case("missing-source", attrs(None, lineage_of(base)), opened_of(x=ax, y=ay), {"refused": "missingSource"}, None))
    cases.append(Case("missing-lineage", attrs(identity_text(), None), opened_of(x=ax, y=ay), {"refused": "missingLineage"}, None))
    cases.append(Case("identity-malformed", attrs("{}", lineage_of(base)), opened_of(x=ax, y=ay), {"refused": "identity.malformed"}, None))
    cases.append(Case("identity-zero-width", attrs(identity_text(width=0), lineage_of(base)), opened_of(x=ax, y=ay),
                      {"refused": "identity.invalid width"}, None))
    cases.append(Case("lineage-malformed", attrs(identity_text(), "[]"), opened_of(x=ax, y=ay), {"refused": "lineage.malformed"}, None))
    cases.append(Case("lineage-cycle", attrs(identity_text(), r.canon({"version": 1, "next_id": 3, "nodes": [
        {**good(1), "inputs": [{"step": "s2", "role": "a"}]}, {**good(2), "inputs": [{"step": "s1", "role": "a"}]}]})),
        opened_of(x=ax, y=ay), {"refused": "lineage.cycle"}, None))
    # a bad node among good ones: the first, the middle, the last; the refusal names that node and what is wrong with it
    def bad(name, node, sentence):
        for place, order in (("middle", [good(1), node, good(3)]),):
            add(f"{name}", [dict(n, id=f"s{i + 1}") for i, n in enumerate(order)], expect={"refused": sentence}, save=sentence)
    for key in ("x1", "y1", "x2", "y2", "object", "frame"):
        bad(f"missing-{key}", py_node(2, "distance", pts2, ax, ay, drop=(key,)), f"mark.missingKey s2 {key}")
    # object and frame are looked at first: a node without them is a missing key, not "another object"
    for key in ("x3", "y3"):
        bad(f"missing-{key}", py_node(2, "angle", pts3, ax, ay, drop=(key,)), f"mark.missingKey s2 {key}")
    bad("missing-width", py_node(2, "profile", pts2, ax, ay, drop=("width",)), "mark.missingKey s2 width")
    for label, text in [("hex", "0x1p3"), ("leading-point", ".5"), ("plus", "+1"), ("trailing-point", "1."), ("bare-exponent", "1e"),
                        ("not-finite-exponent", "1e999"), ("nan", "nan"), ("inf", "inf"), ("minus-only", "-"), ("empty", ""),
                        ("space-before", " 1"), ("space-after", "1 "), ("arabic-digit", "١"), ("underscore", "1_0"),
                        ("double-sign", "--1"), ("upper-e", "1E2"), ("comma", "1,5")]:
        bad(f"grammar-{label}", py_node(2, "distance", pts2, ax, ay, override={"x1": text}), f"mark.badCoordinate s2 x1 {text}")
    bad("grammar-on-y2", py_node(2, "distance", pts2, ax, ay, override={"y2": "+7"}), "mark.badCoordinate s2 y2 +7")
    bad("grammar-on-angle-x3", py_node(2, "angle", pts3, ax, ay, override={"x3": ".5"}), "mark.badCoordinate s2 x3 .5")
    for label, pts, point in [("x-below", [(-0.51, 1), (2, 2)], 1), ("x-above", [(1, 1), (63.51, 2)], 2), ("y-below", [(1, -0.51), (2, 2)], 1),
                              ("y-above", [(1, 1), (2, 47.51)], 2), ("x-far", [(1e9, 1), (2, 2)], 1), ("x-negative", [(-4, 1), (2, 2)], 1),
                              ("x-equals-width", [(64, 1), (2, 2)], 1), ("y-equals-height", [(1, 1), (2, 48)], 2)]:
        bad(f"outside-{label}", py_node(2, "distance", pts, ax, ay), f"mark.outsideImage s2 {point}")
    bad("outside-angle-third-point", py_node(2, "angle", [(1, 1), (2, 2), (70, 3)], ax, ay), "mark.outsideImage s2 3")
    bad("outside-profile", py_node(2, "profile", [(1, 1), (2, 99)], ax, ay, width=3), "mark.outsideImage s2 2")
    for label, text in [("zero", "0"), ("leading-zero", "03"), ("double-zero", "00"), ("too-wide", "26"), ("three-digits", "100"),
                        ("text", "x"), ("negative", "-1"), ("decimal", "1.0"), ("plus", "+5"), ("empty", ""), ("space", " 5")]:
        bad(f"width-{label}", py_node(2, "profile", pts2, ax, ay, width=3, override={"width": text}), f"mark.badWidth s2 {text}")
    add("bad-width-first", [py_node(1, "profile", pts2, ax, ay, override={"width": "03"}), good(2), good(3)],
        expect={"refused": "mark.badWidth s1 03"}, save="mark.badWidth s1 03")
    add("bad-width-last", [good(1), good(2), py_node(3, "profile", pts2, ax, ay, override={"width": "03"})],
        expect={"refused": "mark.badWidth s3 03"}, save="mark.badWidth s3 03")
    add("two-bad-nodes-first-named", [good(1), py_node(2, "distance", pts2, ax, ay, override={"x1": "+1"}),
                                      py_node(3, "profile", pts2, ax, ay, override={"width": "0"})],
        expect={"refused": "mark.badCoordinate s2 x1 +1"}, save="mark.badCoordinate s2 x1 +1")
    # a bad node that is not a mark this image draws is not judged: another kind, removed, another object, another frame
    add("unjudged-bad-nodes", [good(1), py_node(2, "export", [], ax, ay, results=False, override={"x1": "junk"}),
                               py_node(3, "distance", pts2, ax, ay, removed=BASE_MS, override={"x1": "junk"}),
                               py_node(4, "distance", pts2, ax, ay, obj="ImageList.9", override={"x1": "junk"}),
                               py_node(5, "distance", pts2, ax, ay, frame="1", override={"x1": "junk"})],
        expect=restored(["s1"], kept=4))
    # a lineage of a newer version restores no marks and is read-only
    cases.append(Case("read-only-lineage", attrs(identity_text(), r.canon({"version": 2, "next_id": 4, "nodes": {"s1": [1, 2, 3]}})),
                      opened_of(x=ax, y=ay), restored([], read_only=True), "readOnly"))
    return cases


def plan(ref):
    """The marks plan for manifest.json, and the sidecars h5py writes for it."""
    r = R()
    directory = os.path.join(ref, "planted-marks")
    os.makedirs(directory, exist_ok=True)
    out = {"sessions": [session_plan(s) for s in swift_sessions()], "planted": []}
    for case in planted_cases():
        path = os.path.join(directory, case.name + r.SUFFIX)
        r.write_h5(path, case.attrs)
        with h5py.File(path, "r") as f:
            if sorted(f.attrs.keys()) != sorted(a[0] for a in case.attrs):
                r.fail(f"{path}: the root holds {sorted(f.attrs.keys())}")
        for name, kind, value in case.attrs:
            r.verify_attr(path, name, kind, value)
        out["planted"].append({"name": case.name, "file": "planted-marks/" + case.name + r.SUFFIX, "opened": case.opened,
                               "expect": case.expect, "save": case.save})
    names = [p["name"] for p in out["planted"]]
    if len(set(names)) != len(names):
        r.fail("two planted mark cases share a name")
    # the planted doubles round-trip through repr (the Python half of what Swift's shortest text must satisfy)
    for s in swift_sessions():
        for m in s["marks"]:
            for x, y in m["points"]:
                for v in (x, y):
                    if bits(float(repr(v))) != bits(v):
                        r.fail(f"repr does not round-trip {v!r}")
    return out


# ---------------------------------------------------------------- read back what Swift wrote

def check_value(check, name, text, want):
    """A stored number or string against its truth: ("num", x) within 1e-12 relative; ("bits", hex) bit-equal; ("str", s); ("int", n)."""
    kind, v = want
    if text is None:
        return check(False, name, "absent")
    if kind in ("num", "bits"):
        if not GRAMMAR.fullmatch(text):
            return check(False, name, f"{text!r} is outside the coordinate grammar")
        got = float(text)
        if kind == "bits":
            return check(bits(got) == v, name, f"{text!r} is {bits(got)}, planted {v} ({frombits(v)!r})")
        ok = got == v if v == 0 else abs(got - v) <= 1e-12 * abs(v)
        return check(ok, name, f"{text!r} against the closed form {v!r}")
    if kind == "int":
        return check(re.fullmatch(r"[0-9]+", text) is not None and int(text) == v, name, f"{text!r} against {v}")
    return check(text == v, name, f"{text!r} against {v!r}")


def readback(ref, out, check):
    r = R()
    manifest = json.load(open(os.path.join(ref, "manifest.json"), encoding="utf-8"))
    try:
        written = {s["id"]: s for s in json.load(open(os.path.join(out, "swift-marks-written.json"), encoding="utf-8"))["sessions"]}
    except (OSError, ValueError) as error:
        check(False, "h5py mk reads swift-marks-written.json", f"the harness's write step left no record: {error}")
        return 0
    n = 0
    for session in swift_sessions():
        sid = session["id"]
        record = written.get(sid)
        if record is None or record.get("error"):
            check(False, f"h5py mk {sid} file", f"Swift did not write it: {record.get('error') if record else 'no record'}")
            continue
        n += 1
        path = os.path.join(out, "marks", record["file"])
        try:
            f = h5py.File(path, "r")
        except OSError as error:
            check(False, f"h5py mk {sid} opens", str(error))
            continue
        with f:
            check(sorted(f.attrs.keys()) == sorted(r.ATTRIBUTES) and len(f.keys()) == 0, f"h5py mk {sid} attributes",
                  f"root attributes {sorted(f.attrs.keys())}")
            texts = {}
            for attr in r.ATTRIBUTES:
                want = {r.SOURCE: record["source_json"], r.LINEAGE: record["lineage_json"], r.IDENTITY: "1", r.MIN_READER: "1"}[attr]
                facts = r.attribute_facts(f, attr)
                problems = {k: v for k, v in r.attribute_problems(facts, want).items() if v is not None}
                check(not problems, f"h5py mk {sid} {attr}", "; ".join(f"{k}: {v}" for k, v in problems.items()))
                texts[attr] = r.stored_text(facts) if "stored" in facts and "type" not in problems else None
        # the identity
        try:
            identity = json.loads(texts[r.SOURCE])
        except (TypeError, ValueError) as error:
            check(False, f"h5py mk {sid} source json", str(error))
            continue
        plan_ = next(p for p in manifest["marks"]["sessions"] if p["id"] == sid)
        want_identity = {"file_name": r.nfc(plan_["file_name"]), "byte_size": plan_["byte_size"], "object": plan_["object"],
                         "width": plan_["width"], "height": plan_["height"], "pixel_sha256": plan_["digest"]}
        check(identity == want_identity, f"h5py mk {sid} source json", f"{identity} vs the planted {want_identity}")
        check(r.canon(identity) == texts[r.SOURCE], f"h5py mk {sid} source canonical", "not Python's canonical form")
        # the lineage: one node per mark, every key and number
        try:
            lineage = json.loads(texts[r.LINEAGE], parse_float=r.no_float)
        except ValueError as error:
            check(False, f"h5py mk {sid} lineage json", str(error))
            continue
        check(r.canon(lineage) == texts[r.LINEAGE], f"h5py mk {sid} lineage canonical", "not Python's canonical form")
        want_nodes = expected_nodes(session)
        check(lineage.get("version") == 1 and lineage.get("next_id") == len(want_nodes) + 1, f"h5py mk {sid} lineage header",
              f"version {lineage.get('version')}, next_id {lineage.get('next_id')}; {len(want_nodes) + 1} expected")
        nodes = lineage.get("nodes", [])
        if not check(len(nodes) == len(want_nodes), f"h5py mk {sid} node count", f"{len(nodes)} nodes, {len(want_nodes)} planted"):
            continue
        for got, want in zip(nodes, want_nodes):
            label = f"h5py mk {sid} {want['id']}"
            check(got.get("id") == want["id"] and got.get("kind") == want["kind"], f"{label} fields",
                  f"id {got.get('id')} kind {got.get('kind')}; planted {want['id']} {want['kind']}")
            check(got.get("inputs") == [] and got.get("external") == [] and "removed" not in got, f"{label} links",
                  f"inputs {got.get('inputs')}, external {got.get('external')}, removed {got.get('removed')}")
            check(type(got.get("recorded")) is int and got.get("recorded") == want["recorded"], f"{label} recorded",
                  f"{got.get('recorded')!r} vs {want['recorded']}")
            for group in ("parameters", "results"):
                stored = got.get(group, {})
                check(sorted(stored.keys()) == sorted(want[group].keys()), f"{label} {group} keys",
                      f"{sorted(stored.keys())} vs the closed form's {sorted(want[group].keys())}")
                for key, value in want[group].items():
                    check_value(check, f"{label} {group} {key}", stored.get(key), value)
    # the save: the changed-on-disk rule, read by h5py
    saved = os.path.join(out, "marks-save")
    if os.path.isdir(saved):
        meta = json.load(open(os.path.join(out, "swift-marks-save.json"), encoding="utf-8"))
        for entry in meta["files"]:
            path = os.path.join(saved, entry["file"])
            try:
                with h5py.File(path, "r") as f:
                    facts = r.attribute_facts(f, r.LINEAGE)
                    got = r.stored_text(facts) if "stored" in facts else None
            except OSError as error:
                check(False, f"h5py mk save {entry['name']}", str(error))
                continue
            check(got == entry["lineage"], f"h5py mk save {entry['name']}", "the lineage on disk is not the one the last accepted save wrote")
    return n
