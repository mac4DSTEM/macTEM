#!/usr/bin/env python3
"""Figure F15 of the SEM program's north star: the Ni 20 kV master pattern (kikuchipy's in-package uint8 copy, square
Lambert projection, upper hemisphere) and the patterns it projects onto the north-star detector (60 x 60 px, sample tilt
70 deg, PC (0.4214, 0.2142, 0.5013)) for the three orientations of bundle `m6/project-master-pattern-ni` — kikuchipy's
`EBSDMasterPattern.get_patterns` beside TEMCore's `MasterPatternProjection`, and their difference in grey levels.

    python3 -I master_pattern_figure.py --references references --ours F15.u8 --out F15.png

`--ours` is the 3 x 60 x 60 uint8 array the unit test `testFigureF15NickelMasterPatternOnTheNorthStarDetector` writes to
$TMPDIR/macTEM-F15-ours.u8, or a text file holding the three base64 lines it prints. Without `--ours` the figure shows the
master pattern and the reference patterns only. Reads the committed bundles; no kikuchipy needed.
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

SHAPE = (3, 60, 60)


def load_array(bundle: Path, name: str) -> np.ndarray:
    manifest = json.loads((bundle / "manifest.json").read_text())
    entry = manifest["arrays"][name]
    return np.frombuffer((bundle / entry["file"]).read_bytes(), dtype=entry["dtype"]).reshape(entry["shape"])


def load_ours(path: Path) -> np.ndarray:
    data = path.read_bytes()
    if len(data) != int(np.prod(SHAPE)):
        text = data.decode("utf-8", errors="replace")
        lines = re.findall(r"F15 ours pattern \d+ uint8 base64: *([A-Za-z0-9+/=]+)", text)
        if len(lines) != SHAPE[0]:
            raise SystemExit(f"{path}: neither a raw {SHAPE} uint8 array nor three base64 lines")
        data = b"".join(base64.b64decode(line) for line in lines)
    return np.frombuffer(data, dtype=np.uint8).reshape(SHAPE)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--references", type=Path, default=Path(__file__).resolve().parent / "references")
    ap.add_argument("--fixture", type=Path, default=None, help="the Ni master pattern .h5 (needs h5py) to draw its upper hemisphere")
    ap.add_argument("--ours", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    bundle = args.references / "m6" / "project-master-pattern-ni"
    ref = load_array(bundle, "patterns_uint8")
    euler = load_array(bundle, "euler_deg")
    ours = load_ours(args.ours) if args.ours else None
    rows = 3 if ours is not None else 1
    fig, axes = plt.subplots(rows, 4, figsize=(12, 3.2 * rows), squeeze=False)
    master = None
    if args.fixture is not None:
        import h5py

        with h5py.File(args.fixture, "r") as f:
            master = np.asarray(f["EMData/EBSDmaster/mLPNH"][0, 0])
    for r in range(rows):
        ax = axes[r, 0]
        if r == 0 and master is not None:
            ax.imshow(master, cmap="gray")
            ax.set_title("Ni 20 kV master pattern\n(Lambert, upper)", fontsize=9)
        ax.axis("off")
    for i in range(3):
        title = "(%.1f, %.1f, %.1f)°" % tuple(euler[i])
        axes[0, i + 1].imshow(ref[i], cmap="gray", vmin=0, vmax=255)
        axes[0, i + 1].set_title(f"kikuchipy {title}", fontsize=9)
        axes[0, i + 1].axis("off")
        if ours is not None:
            axes[1, i + 1].imshow(ours[i], cmap="gray", vmin=0, vmax=255)
            axes[1, i + 1].set_title(f"macTEM {title}", fontsize=9)
            axes[1, i + 1].axis("off")
            diff = ours[i].astype(int) - ref[i].astype(int)
            im = axes[2, i + 1].imshow(diff, cmap="coolwarm", vmin=-1, vmax=1)
            axes[2, i + 1].set_title(f"difference: max |d| {np.abs(diff).max()}, {np.count_nonzero(diff)} px", fontsize=9)
            axes[2, i + 1].axis("off")
    if ours is not None:
        fig.colorbar(im, ax=axes[2, 1:].tolist(), shrink=0.8, label="grey levels")
    fig.suptitle("F15: Ni master pattern projected onto the north-star detector (60 x 60, PC 0.4214 0.2142 0.5013, 70° tilt)", fontsize=10)
    fig.savefig(args.out, dpi=150, bbox_inches="tight")
    print(f"master_pattern_figure.py: wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
