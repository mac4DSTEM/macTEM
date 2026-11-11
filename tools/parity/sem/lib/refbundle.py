"""Reference bundles: how tools/parity/sem writes what the Python stack computed, and how check.py reads it back.

A bundle is one folder under tools/parity/sem/references/<milestone>/<case>/: a `manifest.json` and one raw binary
file per array. The manifest is the contract the Swift side (macTEMTests/SEMParityReference.swift) reads:

    {
      "schema": 1,
      "case": "m1/read-nordif",
      "milestone": 1,
      "reference": {"package": "kikuchipy", "version": "0.13.1", "function": "kikuchipy.load"},
      "stack": {"python": "3.14.6", "numpy": "2.5.4", ...},
      "inputs": [{"path": "fixtures/nordif/Pattern.dat", "sha256": "..."}],
      "values": {"navigation_shape": [3, 3], "dtype": "uint8", ...},          exact (JSON equality)
      "scalars": {"mean_intensity": {"value": 97.1, "rtol": 1e-12, "atol": 0}},
      "arrays": {"first_pattern": {"file": "first_pattern.bin", "dtype": "uint8", "shape": [60, 60],
                                    "sha256": "...", "rtol": 0, "atol": 0}}
    }

Arrays are little-endian, C order, no header; `dtype` is one of uint8, uint16, int32, int64, float32, float64. A
tolerance of 0/0 is an exact comparison; otherwise numpy's assert_allclose rule, |a - b| <= atol + rtol * |b|, with the
reference as b. The JSON is written sorted and indented so a regenerated bundle diffs cleanly in git.

An array of rotations may carry three more keys, always together: "symmetry" (an orix point group name, "m-3m"),
"rotation" (what a row holds: "quaternion", orix's Rotation.data, last axis 4; or "euler_bunge_radians", its
Rotation.to_euler(), last axis 3) and "angle_tolerance_degrees". The drift gate then compares that array point by point
by the misorientation angle under the point group, not element by element: pyEBSDindex fits in float32 under numba
fastmath, so a re-emit on another CPU can hand another of the symmetry-equivalent rotations of one orientation (#434),
and the orientation is the claim. rtol and atol stay the element tolerance for the readers that want one.
"""

from __future__ import annotations

import hashlib
import json
import platform
import sys
from pathlib import Path

import numpy as np

SCHEMA = 1
DTYPES = {"uint8", "uint16", "int32", "int64", "float32", "float64"}
ORIENTATION_KEYS = ("symmetry", "rotation", "angle_tolerance_degrees")
ROTATIONS = {"quaternion": 4, "euler_bunge_radians": 3}   # what a row of an orientation array holds, and its width


def sha256_of_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_of_array(a: np.ndarray) -> str:
    """The sha256 of the array's bytes in C order, little-endian, in its own dtype (the exact fingerprint)."""
    a = np.ascontiguousarray(a)
    if a.dtype.byteorder == ">":
        a = a.astype(a.dtype.newbyteorder("<"))
    return hashlib.sha256(a.tobytes(order="C")).hexdigest()


def _jsonable(v):
    if isinstance(v, (np.integer,)):
        return int(v)
    if isinstance(v, (np.floating,)):
        return float(v)
    if isinstance(v, (np.bool_,)):
        return bool(v)
    if isinstance(v, np.ndarray):
        return [_jsonable(x) for x in v.tolist()]
    if isinstance(v, dict):
        return {str(k): _jsonable(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [_jsonable(x) for x in v]
    if isinstance(v, bytes):
        return v.decode("utf-8", "replace")
    return v


def stack_versions() -> dict:
    out = {"python": platform.python_version(), "numpy": np.__version__}
    for name in ("kikuchipy", "orix", "diffsims", "hyperspy", "exspy", "rsciio", "pyebsdindex", "h5py", "scipy"):
        try:
            mod = __import__(name)
            out[name] = getattr(mod, "__version__", "?")
        except Exception:  # noqa: BLE001 - a reference stack without the package records that
            out[name] = None
    return out


class Bundle:
    """One reference case being written."""

    def __init__(self, case: str, milestone: int, package: str, function: str, root: Path):
        import importlib

        self.case = case
        self.dir = root / case
        self.manifest = {
            "schema": SCHEMA,
            "case": case,
            "milestone": milestone,
            "reference": {
                "package": package,
                "version": getattr(importlib.import_module(package), "__version__", "?"),
                "function": function,
            },
            "stack": stack_versions(),
            "inputs": [],
            "values": {},
            "scalars": {},
            "arrays": {},
        }
        self._arrays: dict[str, np.ndarray] = {}

    def input(self, path: Path, label: str) -> None:
        self.manifest["inputs"].append({"path": label, "sha256": sha256_of_file(path)})

    def value(self, name: str, v) -> None:
        self.manifest["values"][name] = _jsonable(v)

    def scalar(self, name: str, v, rtol: float = 0.0, atol: float = 0.0) -> None:
        self.manifest["scalars"][name] = {"value": float(v), "rtol": rtol, "atol": atol}

    def array(self, name: str, a: np.ndarray, rtol: float = 0.0, atol: float = 0.0, note: str | None = None,
              symmetry: str | None = None, rotation: str | None = None, angle_tolerance_degrees: float | None = None) -> None:
        """One array and its element tolerance. With `symmetry`, `rotation` and `angle_tolerance_degrees` (all three, see
        the module's docstring) the drift gate compares it by orientation instead."""
        a = np.ascontiguousarray(a)
        if a.dtype.name not in DTYPES:
            raise ValueError(f"{self.case}/{name}: dtype {a.dtype.name} is not one the Swift loader reads ({sorted(DTYPES)})")
        if a.dtype.byteorder == ">":
            a = a.astype(a.dtype.newbyteorder("<"))
        entry = {
            "file": f"{name}.bin",
            "dtype": a.dtype.name,
            "shape": list(a.shape),
            "sha256": sha256_of_array(a),
            "rtol": rtol,
            "atol": atol,
        }
        if note:
            entry["note"] = note
        given = {"symmetry": symmetry, "rotation": rotation, "angle_tolerance_degrees": angle_tolerance_degrees}
        orientation = {k: v for k, v in given.items() if v is not None}
        problem = orientation_problem(orientation, entry["shape"])
        if problem:
            raise ValueError(f"{self.case}/{name}: {problem}")
        if orientation:
            orientation["angle_tolerance_degrees"] = float(orientation["angle_tolerance_degrees"])
        entry.update(orientation)
        self.manifest["arrays"][name] = entry
        self._arrays[name] = a

    def fingerprint(self, name: str, a: np.ndarray) -> None:
        """A large array kept as its exact fingerprint only (shape, dtype, sha256), no file."""
        a = np.ascontiguousarray(a)
        self.manifest["values"][name] = {"dtype": a.dtype.name, "shape": list(a.shape), "sha256": sha256_of_array(a)}

    def write(self) -> Path:
        self.dir.mkdir(parents=True, exist_ok=True)
        for old in self.dir.glob("*.bin"):
            old.unlink()
        for name, a in self._arrays.items():
            (self.dir / f"{name}.bin").write_bytes(a.tobytes(order="C"))
        text = json.dumps(self.manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
        (self.dir / "manifest.json").write_text(text, encoding="utf-8")
        return self.dir


def read_manifest(case_dir: Path) -> dict:
    return json.loads((case_dir / "manifest.json").read_text(encoding="utf-8"))


def read_array(case_dir: Path, entry: dict) -> np.ndarray:
    raw = (case_dir / entry["file"]).read_bytes()
    a = np.frombuffer(raw, dtype=np.dtype(entry["dtype"]).newbyteorder("<")).reshape(entry["shape"])
    return a


def all_cases(root: Path) -> list[Path]:
    return sorted(p.parent for p in root.rglob("manifest.json"))


def orientation_keys(entry: dict) -> dict:
    """The orientation keys an array entry carries (empty for an array compared element by element)."""
    return {k: entry[k] for k in ORIENTATION_KEYS if k in entry}


def point_group(name):
    """orix's point group of exactly that name ("m-3m", "432", "6/mmm"), looked up as compare_cases.py does; a
    ValueError for any other name, an EDAX alias among them."""
    from orix.crystal_map import Phase

    group = None
    if isinstance(name, str):
        try:
            group = Phase(point_group=name).point_group
        except ValueError:
            group = None
    if group is None or group.name != name:
        raise ValueError(f"symmetry {name!r} is not the name of an orix point group")
    return group


def orientation_problem(keys: dict, shape: list[int]) -> str | None:
    """Why an array entry's orientation keys cannot be used, or None: none of them, or all three with a point group orix
    names, a rotation ROTATIONS lists whose row width is the last axis, and a bound above 0 and below 180 degrees."""
    if not keys:
        return None
    if set(keys) != set(ORIENTATION_KEYS):
        return f"the orientation keys {', '.join(ORIENTATION_KEYS)} come together; the entry has {', '.join(sorted(keys))}"
    width = ROTATIONS.get(keys["rotation"]) if isinstance(keys["rotation"], str) else None
    if width is None:
        return f"rotation {keys['rotation']!r} is not one of {', '.join(ROTATIONS)}"
    if not shape or shape[-1] != width:
        return f"a {keys['rotation']} row has {width} elements; the array's shape is {shape}"
    bound = keys["angle_tolerance_degrees"]
    if isinstance(bound, bool) or not isinstance(bound, (int, float)) or not 0 < bound < 180:
        return f"angle_tolerance_degrees {bound!r} is not a number of degrees above 0 and below 180"
    try:
        point_group(keys["symmetry"])
    except ValueError as err:
        return str(err)
    return None


def _no_rotation(rows: np.ndarray, rotation: str) -> np.ndarray:
    """The rows that hold no rotation: a NaN or an infinity in them, or a quaternion of four zeros. orix's
    `angle_with` would hand 0 degrees for any of these (it turns a NaN angle into 0), so they are compared as values."""
    void = (~np.isfinite(rows)).any(axis=1)
    if rotation == "quaternion":
        void |= ~(rows != 0).any(axis=1)
    return void


def _orientations(rows: np.ndarray, rotation: str, group):
    from orix.quaternion import Orientation

    if rotation == "euler_bunge_radians":
        return Orientation.from_euler(rows, group)   # orix's defaults: radians, lab2crystal, Rotation.to_euler's inverse
    return Orientation(rows, group)


def orientation_drift(case: str, name: str, keys: dict, x: np.ndarray, y: np.ndarray) -> list[str]:
    """An orientation array compared point by point, x committed and y fresh: the misorientation angle of each row
    under the point group (orix's `Orientation.angle_with`, the smallest angle over the group's equivalents) is at most
    angle_tolerance_degrees, so a re-emit that hands another twin of the same orientation agrees. A row that holds no
    rotation (an unindexed point stored as NaN) matches the same row only, NaN matching NaN. One line, or none."""
    rotation = keys["rotation"]
    width = ROTATIONS[rotation]
    group = point_group(keys["symmetry"])
    bound = float(keys["angle_tolerance_degrees"])
    xr = x.astype(np.float64).reshape(-1, width)
    yr = y.astype(np.float64).reshape(-1, width)
    void = _no_rotation(xr, rotation) | _no_rotation(yr, rotation)
    unequal = ((xr != yr) & ~(np.isnan(xr) & np.isnan(yr))).any(axis=1)
    void_bad = void & unequal
    degrees = np.zeros(xr.shape[0])
    held = ~void
    if held.any():
        a = _orientations(xr[held], rotation, group)
        b = _orientations(yr[held], rotation, group)
        degrees[held] = np.rad2deg(a.angle_with(b))
    bad = void_bad | (degrees > bound)
    if not bad.any():
        return []
    k = int(np.flatnonzero(void_bad)[0]) if void_bad.any() else int(np.argmax(degrees))
    at = [int(i) for i in np.unravel_index(k, x.shape[:-1])]
    if void_bad[k]:
        worst = f"{xr[k].tolist()} committed, {yr[k].tolist()} fresh (a row without a rotation matches only itself)"
    else:
        worst = f"{float(degrees[k])!r} degrees between {xr[k].tolist()} committed and {yr[k].tolist()} fresh"
    return [f"{case}: array {name} drifts at {int(bad.sum())} of {xr.shape[0]} points by misorientation under "
            f"{keys['symmetry']} (bound {bound} degrees); worst at {at}: {worst}"]


def compare_bundles(committed: Path, fresh: Path) -> list[str]:
    """Every difference between a committed bundle and a freshly emitted one, as one line each; empty when they agree
    within the committed tolerances (an array with orientation keys within its misorientation bound, every other array
    element by element). The stack versions are compared too: a reference computed by another version is drift even
    when the numbers agree, because the pin is part of the claim."""
    a = read_manifest(committed)
    b = read_manifest(fresh)
    out: list[str] = []
    for key in ("case", "milestone", "reference", "inputs", "values"):
        if a.get(key) != b.get(key):
            out.append(f"{a['case']}: {key} differs:\n    committed {json.dumps(a.get(key), sort_keys=True)[:400]}\n    fresh     {json.dumps(b.get(key), sort_keys=True)[:400]}")
    for pkg in ("python", "numpy", a["reference"]["package"]):
        x, y = a["stack"].get(pkg), b["stack"].get(pkg)
        if pkg == "python":
            # The minor is the pin (setup.sh builds on 3.14); the patch level moves with the runner image and is
            # recorded, not compared (3.14.6 on the Mac, 3.14.10 on GitHub's runner, every number equal: 2026-11-06).
            x, y = ".".join(str(x).split(".")[:2]), ".".join(str(y).split(".")[:2])
        if x != y:
            out.append(f"{a['case']}: stack {pkg} {a['stack'].get(pkg)} committed, {b['stack'].get(pkg)} fresh")
    for name, s in a["scalars"].items():
        t = b["scalars"].get(name)
        if t is None:
            out.append(f"{a['case']}: scalar {name} missing from the fresh bundle")
            continue
        if abs(t["value"] - s["value"]) > s["atol"] + s["rtol"] * abs(s["value"]):
            out.append(f"{a['case']}: scalar {name} {s['value']!r} committed, {t['value']!r} fresh (rtol {s['rtol']}, atol {s['atol']})")
    if set(a["scalars"]) != set(b["scalars"]) or set(a["arrays"]) != set(b["arrays"]):
        out.append(f"{a['case']}: the set of scalars or arrays changed")
    for name, e in a["arrays"].items():
        f = b["arrays"].get(name)
        if f is None:
            continue
        if e["dtype"] != f["dtype"] or e["shape"] != f["shape"]:
            out.append(f"{a['case']}: array {name} is {e['dtype']}{e['shape']} committed, {f['dtype']}{f['shape']} fresh")
            continue
        keys = orientation_keys(e)
        if keys != orientation_keys(f):
            out.append(f"{a['case']}: array {name} has the orientation keys {json.dumps(keys, sort_keys=True)} committed, "
                       f"{json.dumps(orientation_keys(f), sort_keys=True)} fresh")
        problem = orientation_problem(keys, e["shape"])
        if problem:
            out.append(f"{a['case']}: array {name}: {problem}")
            continue
        x = read_array(committed, e)
        y = read_array(fresh, f)
        if sha256_of_array(x) != e["sha256"]:
            out.append(f"{a['case']}: array {name}: the committed file is not the manifest's sha256 (edited by hand?)")
        if keys:
            out += orientation_drift(a["case"], name, keys, x, y)
        elif e["rtol"] == 0 and e["atol"] == 0:
            floats = x.dtype.kind == "f"
            if not np.array_equal(x, y, equal_nan=floats):  # NaN matches NaN only, as the Swift loader compares
                n = int(np.count_nonzero((x != y) & ~(np.isnan(x) & np.isnan(y)))) if floats else int(np.count_nonzero(x != y))
                out.append(f"{a['case']}: array {name} is exact and differs in {n} of {x.size} elements")
        else:
            diff = np.abs(x.astype(np.float64) - y.astype(np.float64))
            bound = e["atol"] + e["rtol"] * np.abs(x.astype(np.float64))
            xf, yf = x.astype(np.float64), y.astype(np.float64)
            bad = (diff > bound) | (np.isnan(xf) != np.isnan(yf))
            if bad.any():
                # The worst element among those out of tolerance, a NaN against a number first: argmax over every
                # element would name a NaN-NaN pair, which agrees.
                excess = np.where(bad, np.nan_to_num(diff - bound, nan=np.inf), -np.inf)
                i = np.unravel_index(int(np.argmax(excess)), x.shape)
                out.append(f"{a['case']}: array {name} drifts in {int(bad.sum())} elements; worst at {[int(k) for k in i]}: "
                           f"{float(x[i])!r} committed, {float(y[i])!r} fresh (rtol {e['rtol']}, atol {e['atol']})")
    return out


def main_check(references: Path, fresh_root: Path) -> int:
    """Compare every committed bundle with its fresh twin; exit 1 on any drift or a missing twin."""
    problems: list[str] = []
    committed = all_cases(references)
    fresh = {p.relative_to(fresh_root): p for p in all_cases(fresh_root)}
    for c in committed:
        rel = c.relative_to(references)
        if rel not in fresh:
            problems.append(f"{rel}: committed, not emitted (missing data or a removed case)")
            continue
        problems += compare_bundles(c, fresh[rel])
    for rel in fresh:
        if not (references / rel / "manifest.json").exists():
            problems.append(f"{rel}: emitted, not committed (run emit.py --write and commit the bundle)")
    if problems:
        print("sem-parity: DRIFT")
        for p in problems:
            print("  " + p)
        return 1
    print(f"sem-parity: {len(committed)} reference bundles agree with the pinned stack")
    return 0


if __name__ == "__main__":
    sys.exit(main_check(Path(sys.argv[1]), Path(sys.argv[2])))
