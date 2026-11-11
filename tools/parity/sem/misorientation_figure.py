#!/usr/bin/env python3
"""Figure F7 of the SEM program's north star: the misorientation angle distribution of orix-data's Ti map, the
disorientation angles of every horizontal and vertical pair of neighbours (622) on 1-degree bins, from the committed
bundle m3/ti-neighbour-misorientations-full (orix 0.15.0), beside TEMCore's counts.

    python3 -I misorientation_figure.py --ours F7.txt --out F7.png

`--ours` is the text the unit test `testFigureF7NeighbourMisorientationHistogramOfTheTiMap` writes to
$TMPDIR/macTEM-F7-ours.txt (edge, count per line). Without it the figure shows the reference alone.
"""

import argparse
import json
from pathlib import Path

import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = Path(__file__).resolve().parent


def load(case: str, name: str) -> np.ndarray:
    d = HERE / "references" / case
    m = json.loads((d / "manifest.json").read_text())
    e = m["arrays"][name]
    return np.frombuffer((d / e["file"]).read_bytes(), dtype=np.dtype(e["dtype"]).newbyteorder("<")).reshape(e["shape"])


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ours", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()
    case = "m3/ti-neighbour-misorientations-full"
    edges, counts = load(case, "edges_degrees"), load(case, "counts")
    centres = 0.5 * (edges[:-1] + edges[1:])
    fig, ax = plt.subplots(figsize=(8, 4.2), dpi=150)
    ax.bar(centres, counts, width=1.0, color="#1f77b4", alpha=0.55, label="orix 0.15.0 (reference)")
    title = "F7: neighbour misorientation angles, Ti (622), 381 x 507"
    if a.ours:
        rows = [line.split("\t") for line in a.ours.read_text().splitlines() if line.strip()]
        ours = np.array([int(r[1]) for r in rows])
        ax.step(edges, np.append(ours, ours[-1]), where="post", color="#d62728", lw=1.0, label="macEM TEMCore")
        title += "  |  counts equal" if np.array_equal(ours, counts) else f"  |  {int(np.sum(ours != counts))} bins differ"
    ax.set_yscale("log")
    ax.set_xlabel("Disorientation angle (degrees), 1-degree bins")
    ax.set_ylabel("Neighbour pairs")
    ax.set_xlim(0, 94)
    ax.set_title(title, fontsize=10)
    ax.legend(frameon=False)
    fig.tight_layout()
    fig.savefig(a.out)


if __name__ == "__main__":
    main()
