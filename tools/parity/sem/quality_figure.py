#!/usr/bin/env python3
"""Figure F3 of the SEM program's north star: the image quality (Krieger Lassen) and average neighbour dot product maps of
nickel_ebsd_large after static then dynamic background removal — kikuchipy's maps (the bundle m2/quality-nickel-ebsd-large)
beside the maps TEMCore's `PatternQuality` computed on the app's own corrected patterns, and their relative difference.

    python3 -I quality_figure.py --bundle references/m2/quality-nickel-ebsd-large --ours-iq ci.log --ours-adp ci.log --out F3.png

`--ours-iq` / `--ours-adp` are the 55 x 75 float32 arrays the unit test `testFigureF3QualityMapsAfterBackgroundRemoval` writes
to $TMPDIR/macTEM-F3-{iq,adp}-ours.f32, or a text file (the CI log) holding the base64 line it prints for that map. Without
them the figure shows kikuchipy's two maps only.
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


def load_ours(path: Path, name: str, shape) -> np.ndarray:
    data = path.read_bytes()
    if len(data) != 4 * shape[0] * shape[1]:
        text = data.decode("utf-8", errors="replace")
        match = re.search(rf"F3 ours {name} float32 base64: *([A-Za-z0-9+/=]+)", text)
        if not match:
            raise SystemExit(f"{path}: neither a raw {shape} float32 array nor the test's '{name}' base64 line")
        data = base64.b64decode(match.group(1))
    return np.frombuffer(data, dtype="<f4").reshape(shape).astype(np.float64)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--bundle", type=Path, required=True)
    ap.add_argument("--ours-iq", type=Path)
    ap.add_argument("--ours-adp", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    maps = [("iq", "Image quality", args.ours_iq), ("adp", "Average neighbour dot product", args.ours_adp)]
    have_ours = all(m[2] for m in maps)
    cols = 3 if have_ours else 1
    fig, axes = plt.subplots(2, cols, figsize=(4.2 * cols, 6.4), squeeze=False)
    for row, (name, title, ours_path) in enumerate(maps):
        ref = load_ref(args.bundle, name).astype(np.float64)
        lo, hi = float(ref.min()), float(ref.max())
        ax = axes[row][0]
        ax.imshow(ref, cmap="gray", vmin=lo, vmax=hi)
        ax.set_title(f"{title}\nkikuchipy 0.13.1 ({lo:.4f} to {hi:.4f})", fontsize=9)
        if have_ours:
            ours = load_ours(ours_path, name, ref.shape)
            rel = np.abs(ours - ref) / np.abs(ref)
            axes[row][1].imshow(ours, cmap="gray", vmin=lo, vmax=hi)
            axes[row][1].set_title(f"{title}\nmacEM (mean {ours.mean():.5f}, ref {ref.mean():.5f})", fontsize=9)
            im = axes[row][2].imshow(rel, cmap="magma")
            axes[row][2].set_title(f"relative difference\nmax {rel.max():.2e}, median {np.median(rel):.2e}", fontsize=9)
            fig.colorbar(im, ax=axes[row][2], fraction=0.035)
            print(f"{name}: max rel {rel.max():.3e}, p99 {np.quantile(rel, 0.99):.3e}, median {np.median(rel):.3e}")
        for ax in axes[row]:
            ax.set_xticks([])
            ax.set_yticks([])
    fig.suptitle("F3: nickel_ebsd_large (55 x 75) after static and dynamic background", fontsize=10)
    fig.tight_layout()
    fig.savefig(args.out, dpi=150)
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
