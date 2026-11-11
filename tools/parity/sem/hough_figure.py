#!/usr/bin/env python3
"""Figure F8 of the SEM program's north star: the Hough-indexed IPF-Z map of nickel_ebsd_large (Ni, pyEBSDindex through
kikuchipy, PC from the file's mean) — the reference map (bundle m4/hough-indexing-nickel-large) beside the map TEMCore's
`HoughIndexer` computed on the app's own corrected patterns, and the misorientation between them.

    python -I hough_figure.py --bundle references/m4/hough-indexing-nickel-large [--ours ci.log] --out F8.png

`--ours` is the 55 x 75 x 3 float32 Bunge Euler array (radians) the unit test `testFigureF8HoughIndexedMapOfTheDemoScan`
writes to $TMPDIR/macTEM-F8-euler-ours.f32, or a text file (the CI log) holding the base64 line it prints. Without it the
figure shows the reference map only. Colours: orix's IPF colour key (TSL) along the sample z direction, m-3m.
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


def load_ours(path: Path, shape) -> np.ndarray:
    data = path.read_bytes()
    n = int(np.prod(shape))
    if len(data) != 4 * n:
        text = data.decode("utf-8", errors="replace")
        match = re.search(r"F8 ours euler float32 base64: *([A-Za-z0-9+/=]+)", text)
        if not match:
            raise SystemExit(f"{path}: neither a raw {shape} float32 array nor the test's base64 line")
        data = base64.b64decode(match.group(1))
    return np.frombuffer(data, dtype="<f4").reshape(shape).astype(np.float64)


def main() -> int:
    from orix.plot import IPFColorKeyTSL
    from orix.quaternion import Orientation, Rotation, symmetry
    from orix.vector import Vector3d

    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--bundle", type=Path, required=True)
    ap.add_argument("--ours", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    q = load_ref(args.bundle, "quaternion")
    phase = load_ref(args.bundle, "phase")
    rows, cols = phase.shape
    key = IPFColorKeyTSL(symmetry.Oh, direction=Vector3d.zvector())
    ref_o = Orientation(q.reshape(-1, 4), symmetry.Oh)
    ref_rgb = key.orientation2color(ref_o).reshape(rows, cols, 3)
    ref_rgb[phase < 0] = 0
    panels = [("pyEBSDindex 0.3.10.1 via kikuchipy 0.13.1", ref_rgb, None)]
    if args.ours:
        eu = load_ours(args.ours, (rows, cols, 3))
        ours_o = Orientation(Rotation.from_euler(eu.reshape(-1, 3)).data, symmetry.Oh)
        rgb = key.orientation2color(ours_o).reshape(rows, cols, 3)
        mis = np.degrees(ours_o.angle_with(ref_o)).reshape(rows, cols)
        within = float((mis[phase >= 0] < 1).mean())
        panels.append(("macEM HoughIndexer (app's background chain)", rgb, None))
        panels.append((f"misorientation, degrees ({100 * within:.2f} % under 1°)", mis, "viridis"))
    fig, axes = plt.subplots(1, len(panels), figsize=(4.6 * len(panels), 3.9), squeeze=False)
    for ax, (title, img, cmap) in zip(axes[0], panels):
        if cmap:
            im = ax.imshow(img, cmap=cmap, vmin=0, vmax=max(1.0, float(img.max())))
            fig.colorbar(im, ax=ax, fraction=0.035)
        else:
            ax.imshow(img)
        ax.set_title(title, fontsize=9)
        ax.set_axis_off()
    indexed = int((phase >= 0).sum())
    fig.suptitle(f"F8: Hough-indexed IPF-Z map of nickel_ebsd_large\nNi (m-3m), {indexed} of {phase.size} points indexed",
                 fontsize=10)
    fig.tight_layout()
    fig.savefig(args.out, dpi=150)
    print(f"hough_figure: wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
