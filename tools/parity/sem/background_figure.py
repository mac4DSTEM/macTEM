#!/usr/bin/env python3
"""Figure F2 of the SEM program's north star: pattern (0, 0) of nickel_ebsd_large after static (subtract) and dynamic
(subtract, frequency domain, std = width / 8, truncate 4) background removal — kikuchipy's reference pattern beside the
pattern TEMCore's `PatternProcessing` computed, and their difference in grey levels.

    python3 -I background_figure.py --fixtures ../../../macTEMTests/Fixtures/sem/background --ours F2.u8 --out F2.png

`--ours` is the 60 x 60 uint8 array the unit test `testFigureF2PatternZeroAfterStaticAndDynamicBackground` writes to
$TMPDIR/macTEM-F2-ours.u8, or a text file holding the base64 line it prints. Without `--ours` the figure shows the raw pattern,
the pattern after the static background and the reference F2 only.
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


def load_u8(folder, name, shape):
    return np.frombuffer((folder / f"{name}.u8").read_bytes(), dtype=np.uint8).reshape(shape)


def load_ours(path, shape):
    data = path.read_bytes()
    if len(data) != shape[0] * shape[1]:
        text = data.decode("utf-8", errors="replace")
        match = re.search(r"base64\): *([A-Za-z0-9+/=]+)", text) or re.search(r"([A-Za-z0-9+/=]{100,})", text)
        if not match:
            raise SystemExit(f"{path}: neither a raw {shape} uint8 array nor a base64 line")
        data = base64.b64decode(match.group(1))
    return np.frombuffer(data, dtype=np.uint8).reshape(shape)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fixtures", type=Path, required=True)
    ap.add_argument("--ours", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    manifest = json.loads((args.fixtures / "manifest.json").read_text())
    shape = tuple(manifest["pattern_shape"])
    raw = load_u8(args.fixtures, "p0_0_raw", shape)
    after_static = load_u8(args.fixtures, "p0_0_static_subtract", shape)
    reference = load_u8(args.fixtures, "p0_0_dynamic_frequency_subtract", shape)
    panels = [("raw pattern (0, 0)", raw, "gray"), ("after static background", after_static, "gray"),
              ("reference F2 (kikuchipy 0.13.1)", reference, "gray")]
    title = "F2: nickel_ebsd_large pattern (0, 0), static subtract then dynamic subtract (frequency, std 7.5, truncate 4)"
    if args.ours:
        ours = load_ours(args.ours, shape)
        diff = ours.astype(int) - reference.astype(int)
        off = int((diff != 0).sum())
        panels.append((f"macTEM (TEMCore PatternProcessing)", ours, "gray"))
        panels.append((f"difference: {off} of {diff.size} px off by {np.abs(diff).max()} grey level(s)", diff, "coolwarm"))
    fig, axes = plt.subplots(1, len(panels), figsize=(3.2 * len(panels), 3.6))
    for ax, (name, image, cmap) in zip(np.atleast_1d(axes), panels):
        if cmap == "coolwarm":
            im = ax.imshow(image, cmap=cmap, vmin=-2, vmax=2, interpolation="nearest")
        else:
            im = ax.imshow(image, cmap=cmap, vmin=0, vmax=255, interpolation="nearest")
        ax.set_title(name, fontsize=8)
        ax.set_xticks([]); ax.set_yticks([])
        fig.colorbar(im, ax=ax, fraction=0.046, pad=0.03)
    fig.suptitle(title, fontsize=9)
    fig.tight_layout()
    fig.savefig(args.out, dpi=150)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
