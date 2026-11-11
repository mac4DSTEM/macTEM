#!/usr/bin/env python
"""tools/parity/sem/lib/refbundle_selftest.py — the drift gate's comparison checked on its own, before the emit (#434).

    python -I -B tools/parity/sem/lib/refbundle_selftest.py

Writes small pairs of bundles (a committed one and a fresh one) with refbundle.Bundle into a scratch folder and runs
compare_bundles on them. An orientation array, quaternions or Bunge Euler angles in radians, whose fresh copy holds
another of the 24 cubic equivalents of one point's orientation agrees under "symmetry": "m-3m" and is flagged without
the keys (element by element at the Hough bundles' 0.02); a real 2 degree rotation at one point is flagged with them and
a 0.5 degree one passes a 1 degree bound; a NaN row (an unindexed point) matches a NaN row and not a number; keys that
come apart between the two bundles, or that do not fit the array, are refused. Plain Python on the stack's numpy and
orix, no pytest: exit 0 when every check holds, 1 with a line per failed check.
"""

from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))   # -I leaves the script's folder off sys.path
from refbundle import Bundle, compare_bundles  # noqa: E402

LOOSE = {"rtol": 0.0, "atol": 2e-2}   # the Hough bundles' element tolerance on rotations
CUBIC = {"symmetry": "m-3m", "angle_tolerance_degrees": 1.0}
GRID = (5, 6)
TWIN_AT = (3, 2)       # the point whose fresh rotation is another cubic equivalent
TURN_AT = (1, 4)       # the point whose fresh rotation is turned by a real angle
NAN_AT = (4, 5)        # the unindexed point, NaN in both bundles
# The m-3m operator #434 found between the committed and the fresh row 39, column 14 of m4/hough-indexing-nickel-large.
OPERATOR = [0.5, -0.5, 0.5, 0.5]

failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(("ok   " if ok else "FAIL ") + label + ("" if ok else f": {detail}"))
    if not ok:
        failures.append(label)


def rotations(rng) -> np.ndarray:
    """Unit quaternions on the grid with a >= 0, as pyEBSDindex hands them."""
    q = rng.normal(size=(*GRID, 4))
    q /= np.sqrt(np.sum(q * q, axis=-1, keepdims=True))
    return np.where(q[..., :1] < 0, -q, q)


def twin(q: np.ndarray) -> np.ndarray:
    from orix.quaternion import Rotation

    t = (Rotation(OPERATOR) * Rotation(q)).data.reshape(4)
    return -t if t[0] < 0 else t


def turned(q: np.ndarray, degrees: float) -> np.ndarray:
    from orix.quaternion import Rotation

    axis = np.array([1.0, 2.0, 3.0]) / np.sqrt(14.0)
    return (Rotation.from_axes_angles(axis, np.deg2rad(degrees)) * Rotation(q)).data.reshape(4)


def euler(q: np.ndarray) -> np.ndarray:
    """orix's Bunge Euler angles in radians of every row; the unindexed point stays NaN."""
    from orix.quaternion import Rotation

    held = ~np.isnan(q).any(axis=-1)
    e = np.full((*q.shape[:-1], 3), np.nan)
    e[held] = Rotation(q[held]).to_euler()
    return e


def worst_degrees(line: str, at: tuple[int, int]) -> float | None:
    """The angle an orientation drift line reports at its worst point, when that point is `at`."""
    m = re.search(rf"worst at \[{at[0]}, {at[1]}\]: ([0-9.e+-]+) degrees", line)
    return float(m.group(1)) if m else None


def element_worst_at(line: str, at: tuple[int, int]) -> bool:
    """An element by element drift line whose worst element lies in the row at `at`."""
    return "drifts in" in line and f"worst at [{at[0]}, {at[1]}, " in line


def pair(root: Path, label: str, committed: np.ndarray, fresh: np.ndarray, keys: dict | None,
         fresh_keys: dict | None = None) -> list[str]:
    """compare_bundles on two one-array bundles; `fresh_keys` defaults to the committed bundle's keys."""
    keys = keys or {}
    fresh_keys = keys if fresh_keys is None else fresh_keys
    for side, data, k in (("committed", committed, keys), ("fresh", fresh, fresh_keys)):
        b = Bundle(f"selftest/{label}", 4, "orix", "refbundle_selftest", root / side)
        b.input(Path(__file__), "lib/refbundle_selftest.py")
        b.array("rotations", data, **LOOSE, **k)
        b.write()
    return compare_bundles(root / "committed" / "selftest" / label, root / "fresh" / "selftest" / label)


def main() -> int:
    from orix.quaternion import Rotation, symmetry

    check("the operator of #434 is an element of m-3m", bool(np.isclose(np.abs(symmetry.Oh.dot(Rotation(OPERATOR))).max(), 1.0)))
    rng = np.random.default_rng(434)
    q = rotations(rng)
    q[NAN_AT] = np.nan
    q_twin = q.copy()
    q_twin[TWIN_AT] = twin(q[TWIN_AT])
    q_two = q.copy()
    q_two[TURN_AT] = turned(q[TURN_AT], 2.0)
    q_half = q.copy()
    q_half[TURN_AT] = turned(q[TURN_AT], 0.5)
    q_number = q.copy()
    q_number[NAN_AT] = [1.0, 0.0, 0.0, 0.0]
    check("the twin moves the elements beyond the element tolerance",
          float(np.max(np.abs(q_twin[TWIN_AT] - q[TWIN_AT]))) > LOOSE["atol"])
    e = euler(q)
    e_twin, e_two, e_number = euler(q_twin), euler(q_two), euler(q_number)
    check("the twin moves the Euler angles beyond the element tolerance",
          float(np.max(np.abs(e_twin[TWIN_AT] - e[TWIN_AT]))) > LOOSE["atol"])
    quat = {**CUBIC, "rotation": "quaternion"}
    bunge = {**CUBIC, "rotation": "euler_bunge_radians"}

    with tempfile.TemporaryDirectory(prefix="refbundle-selftest-") as tmp:
        root = Path(tmp)
        out = pair(root, "same", q, q.copy(), quat)
        check("a bundle agrees with itself under the keys", out == [], "; ".join(out))
        out = pair(root, "twin-keys", q, q_twin, quat)
        check("a cubic twin at one point agrees under the keys", out == [], "; ".join(out))
        out = pair(root, "twin-plain", q, q_twin, None)
        check("a cubic twin at one point is flagged without the keys",
              len(out) == 1 and element_worst_at(out[0], TWIN_AT), "; ".join(out) or "no line")
        out = pair(root, "two-degrees", q, q_two, quat)
        angle = worst_degrees(out[0], TURN_AT) if len(out) == 1 else None
        check("a real 2 degree rotation at one point is flagged under the keys",
              angle is not None and abs(angle - 2.0) < 1e-6 and "drifts at 1 of 30 points" in out[0], "; ".join(out) or "no line")
        out = pair(root, "half-degree", q, q_half, quat)
        check("a 0.5 degree rotation is within a 1 degree bound", out == [], "; ".join(out))
        out = pair(root, "nan-number", q, q_number, quat)
        check("a NaN row against a number is flagged",
              len(out) == 1 and f"worst at {list(NAN_AT)}" in out[0] and "without a rotation" in out[0], "; ".join(out) or "no line")
        out = pair(root, "number-nan", q_number, q, quat)
        check("a number against a NaN row is flagged", len(out) == 1 and f"worst at {list(NAN_AT)}" in out[0], "; ".join(out) or "no line")
        zero = q.copy()
        zero[NAN_AT] = 0.0
        out = pair(root, "zero-number", zero, q_number, quat)
        check("a zero quaternion against a rotation is flagged (orix would call it 0 degrees)",
              len(out) == 1 and "without a rotation" in out[0], "; ".join(out) or "no line")
        out = pair(root, "euler-twin-keys", e, e_twin, bunge)
        check("Euler angles: a cubic twin at one point agrees under the keys", out == [], "; ".join(out))
        out = pair(root, "euler-twin-plain", e, e_twin, None)
        check("Euler angles: a cubic twin at one point is flagged without the keys",
              len(out) == 1 and element_worst_at(out[0], TWIN_AT), "; ".join(out) or "no line")
        out = pair(root, "euler-two-degrees", e, e_two, bunge)
        angle = worst_degrees(out[0], TURN_AT) if len(out) == 1 else None
        check("Euler angles: a real 2 degree rotation at one point is flagged under the keys",
              angle is not None and abs(angle - 2.0) < 1e-6, "; ".join(out) or "no line")
        out = pair(root, "euler-nan-number", e, e_number, bunge)
        check("Euler angles: a NaN row against a number is flagged", len(out) == 1 and "without a rotation" in out[0],
              "; ".join(out) or "no line")
        out = pair(root, "keys-dropped", q, q.copy(), quat, fresh_keys={})
        check("a fresh bundle that drops the keys is flagged", len(out) == 1 and "orientation keys" in out[0],
              "; ".join(out) or "no line")
        out = pair(root, "keys-moved", q, q.copy(), quat, fresh_keys={**quat, "angle_tolerance_degrees": 2.0})
        check("a fresh bundle with another bound is flagged", len(out) == 1 and "orientation keys" in out[0],
              "; ".join(out) or "no line")
        refused = [
            ("a quaternion key on rows of 3", e, quat),
            ("an Euler key on rows of 4", q, bunge),
            ("a point group orix does not name", q, {**quat, "symmetry": "cubic"}),
            ("one key without the others", q, {"symmetry": "m-3m"}),
            ("a bound of 0 degrees", q, {**quat, "angle_tolerance_degrees": 0.0}),
        ]
        for label, data, keys in refused:
            try:
                Bundle("selftest/refused", 4, "orix", "refbundle_selftest", root / "refused").array("rotations", data, **LOOSE, **keys)
                check(f"Bundle.array refuses {label}", False, "no ValueError")
            except ValueError:
                check(f"Bundle.array refuses {label}", True)

    if failures:
        print(f"refbundle_selftest: {len(failures)} of the checks failed")
        return 1
    print("refbundle_selftest: the drift gate's comparison holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
