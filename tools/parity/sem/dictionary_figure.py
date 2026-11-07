#!/usr/bin/env python3
"""Figure F9 of the SEM program's north star: the IPF-Z map of nickel_ebsd_large dictionary-indexed against the Ni 20 kV master
pattern (m-3m sampled at 4 deg, the F15 detector) — kikuchipy's best matches (the bundle m4/dictionary-indexing-nickel-ebsd-large)
beside the ones TEMCore's `DictionaryIndexing` found on the app's own corrected patterns, the NCC score maps, and the points
whose best match differs.

    python -I dictionary_figure.py --bundle references/m4/dictionary-indexing-nickel-ebsd-large [--ours ci.log] --out F9.png

`--ours` is the 4125 int32 best simulation indices the unit test `testFigureF9WholeScanIndexedAgainstTheNickelDictionary`
writes to $TMPDIR/macTEM-F9-ours.i32, or a text file (the CI log) holding the base64 line it prints. The indices map to
rotations through orix's own sample (the same order the bundle's indices use); colours by orix's `IPFColorKeyTSL` along z.
Needs the pinned stack (tools/parity/sem/setup.sh) for orix.
"""

import argparse
import base64
import json
import re
from pathlib import Path

import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402


def load_ref(bundle: Path, name: str) -> np.ndarray:
    entry = json.loads((bundle / "manifest.json").read_text())["arrays"][name]
    return np.fromfile(bundle / entry["file"], dtype=entry["dtype"]).reshape(entry["shape"])


def load_ours(path: Path, count: int) -> np.ndarray:
    data = path.read_bytes()
    if len(data) != 4 * count:
        text = data.decode("utf-8", errors="replace")
        match = re.search(r"F9 ours best simulation indices int32 base64: *([A-Za-z0-9+/=]+)", text)
        if not match:
            raise SystemExit(f"{path}: neither {count} raw int32 values nor the test's base64 line")
        data = base64.b64decode(match.group(1))
    return np.frombuffer(data, dtype="<i4").astype(np.int64)


def main() -> int:
    from orix.crystal_map import Phase
    from orix.plot import IPFColorKeyTSL
    from orix.quaternion import Orientation
    from orix.sampling import get_sample_fundamental
    from orix.vector import Vector3d

    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--bundle", type=Path, required=True)
    ap.add_argument("--ours", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    manifest = json.loads((args.bundle / "manifest.json").read_text())
    values = manifest["values"]
    shape = (55, 75)
    phase = Phase(name="ni", space_group=225)
    rot = get_sample_fundamental(resolution=values["resolution"], point_group=phase.point_group, method="cubochoric")
    assert rot.size == values["dictionary_size"], (rot.size, values["dictionary_size"])
    key = IPFColorKeyTSL(phase.point_group, direction=Vector3d.zvector())

    def ipf(indices: np.ndarray) -> np.ndarray:
        ori = Orientation(rot[indices].data, symmetry=phase.point_group)
        return key.orientation2color(ori).reshape(*shape, 3)

    ref_idx = load_ref(args.bundle, "ncc_simulation_indices")[:, 0].astype(np.int64)
    ref_scores = load_ref(args.bundle, "ncc_scores")[:, 0].reshape(shape)
    panels = [("IPF-Z, kikuchipy 0.13.1", ipf(ref_idx), None),
              (f"NCC score, kikuchipy ({ref_scores.min():.3f} to {ref_scores.max():.3f})", ref_scores, "gray")]
    if args.ours:
        ours = load_ours(args.ours, ref_idx.size)
        same = ours == ref_idx
        panels.insert(1, ("IPF-Z, macEM", ipf(ours), None))
        panels.append((f"best match differs: {int((~same).sum())} of {same.size}", (~same).reshape(shape).astype(float), "magma"))
        print(f"best match equal at {int(same.sum())} of {same.size} points")
    fig, axes = plt.subplots(1, len(panels), figsize=(3.6 * len(panels), 3.4), squeeze=False)
    for ax, (title, img, cmap) in zip(axes[0], panels):
        ax.imshow(img, cmap=cmap)
        ax.set_title(title, fontsize=9)
        ax.set_xticks([])
        ax.set_yticks([])
    fig.suptitle("F9: nickel_ebsd_large dictionary-indexed against the Ni 20 kV master pattern (m-3m, 4°)", fontsize=10)
    fig.tight_layout()
    fig.savefig(args.out, dpi=150)
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
