#!/usr/bin/env python3
"""Figure F14 of the SEM program's north star: kikuchipy's geometrical simulation of the nickel's {111}, {200}, {220} and
{311} bands and their zone axes on pattern (0, 0) of `nickel_ebsd_large` (bundle `m6/geometrical-simulation-nickel`), beside
TEMCore's `GeometricalKikuchiSimulation` of the same orientation and projection centre.

    python3 -I simulation_figure.py --pattern ../../../DemoData/nickel_ebsd_large/patterns_v2.h5 --ours test.log --out F14.png

`--ours` is a text file holding the two base64 lines the unit test `testFigureF14GeometricalSimulationOfTheNickelAsKikuchipy`
prints ("F14 ours lines ...", "F14 ours zone axes ..."). Without `--ours` the figure shows the reference only. `--pattern`
needs h5py; without it the lines are drawn on a blank 60 x 60 frame.
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


def load_array(bundle: Path, name: str) -> np.ndarray:
    manifest = json.loads((bundle / "manifest.json").read_text())
    entry = manifest["arrays"][name]
    return np.frombuffer((bundle / entry["file"]).read_bytes(), dtype=entry["dtype"]).reshape(entry["shape"])


def load_ours(path: Path) -> tuple[np.ndarray, np.ndarray]:
    text = path.read_text(errors="replace")
    lines = re.search(r"F14 ours lines float64 base64: *([A-Za-z0-9+/=]*)", text)
    axes = re.search(r"F14 ours zone axes float64 base64: *([A-Za-z0-9+/=]*)", text)
    if not lines or not axes:
        raise SystemExit(f"{path}: no 'F14 ours' lines")
    return (np.frombuffer(base64.b64decode(lines.group(1)), dtype="<f8").reshape(-1, 4),
            np.frombuffer(base64.b64decode(axes.group(1)), dtype="<f8").reshape(-1, 2))


def draw(ax, pattern, lines, axes_px, labels, title):
    ax.imshow(pattern, cmap="gray")
    for x0, y0, x1, y1 in lines:
        ax.plot([x0, x1], [y0, y1], color="#d62728", lw=1)
    ax.scatter(axes_px[:, 0], axes_px[:, 1], s=14, facecolor="white", edgecolor="black", lw=0.6, zorder=3)
    for (x, y), label in zip(axes_px, labels):
        ax.text(x, y - 1.2, label, color="white", fontsize=5, ha="center", va="bottom")
    ax.set_xlim(-0.5, pattern.shape[1] - 0.5)
    ax.set_ylim(pattern.shape[0] - 0.5, -0.5)
    ax.set_title(title, fontsize=9)
    ax.axis("off")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--references", type=Path, default=Path(__file__).resolve().parent / "references")
    ap.add_argument("--pattern", type=Path, default=None, help="nickel_ebsd_large/patterns_v2.h5 (needs h5py)")
    ap.add_argument("--ours", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    bundle = args.references / "m6" / "geometrical-simulation-nickel"
    manifest = json.loads((bundle / "manifest.json").read_text())
    labels = manifest["values"]["p0_0_zone_axes_labels"]
    ref_lines = load_array(bundle, "p0_0_lines_px")
    ref_axes = load_array(bundle, "p0_0_zone_axes_px")
    pattern = np.zeros((60, 60))
    if args.pattern is not None:
        import h5py

        with h5py.File(args.pattern, "r") as f:
            pattern = np.asarray(f["Scan 1/EBSD/Data/patterns"][0])
    ours = load_ours(args.ours) if args.ours else None
    cols = 2 if ours is not None else 1
    fig, axs = plt.subplots(1, cols, figsize=(4.2 * cols, 4.4), squeeze=False)
    draw(axs[0, 0], pattern, ref_lines, ref_axes, labels, f"kikuchipy: {len(ref_lines)} bands, {len(ref_axes)} zone axes")
    if ours is not None:
        lines, axes_px = ours
        dl = np.abs(lines - ref_lines).max() if lines.shape == ref_lines.shape else float("nan")
        da = np.abs(axes_px - ref_axes).max() if axes_px.shape == ref_axes.shape else float("nan")
        draw(axs[0, 1], pattern, lines, axes_px, labels if len(axes_px) == len(labels) else [],
             f"macTEM: max |d| lines {dl:.1e} px, zone axes {da:.1e} px")
    fig.suptitle("F14: geometrical simulation of nickel_ebsd_large, pattern (0, 0)", fontsize=10)
    fig.savefig(args.out, dpi=200, bbox_inches="tight")
    print(f"simulation_figure.py: wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
