#!/usr/bin/env python3
"""Figure F4 of the SEM program (plan.md, milestone 2): pattern (0, 0) of nickel_ebsd_large through kikuchipy's guide
filter, a Gaussian lowpass (cutoff 22, width 10) times highpass (cutoff 3, width 2) transfer function applied in the
frequency domain with shift=True — kikuchipy's reference pattern beside the one TEMCore's `PatternFilters` computed, and
their difference in grey levels.

    python3 -I filter_figure.py --bundle references/m2/fft-filter-nickel-ebsd-large --ours F4.u8 --out F4.png

`--ours` is the 60 x 60 uint8 array the unit test `testFigureF4PatternZeroAfterFFTFilter` writes to
$TMPDIR/macTEM-F4-ours.u8, or a text file holding the base64 line it prints. Without `--ours` the figure shows the raw
pattern, the transfer function and the reference F4 only.
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
    entry = json.loads((bundle / "manifest.json").read_text())["arrays"][name]
    return np.fromfile(bundle / entry["file"], dtype=entry["dtype"]).reshape(entry["shape"])


def load_ours(path: Path, shape) -> np.ndarray:
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
    ap.add_argument("--bundle", type=Path, required=True)
    ap.add_argument("--ours", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    raw = load_array(args.bundle, "patterns").reshape(-1, 60, 60)[0]
    transfer = load_array(args.bundle, "transfer_function")
    reference = load_array(args.bundle, "frequency_shift").reshape(raw.shape)
    panels = [("raw pattern (0, 0)", raw, "gray", (0, 255)),
              ("transfer function (lowpass x highpass, centred)", transfer, "viridis", (0, 1)),
              ("reference F4 (kikuchipy 0.13.1)", reference, "gray", (0, 255))]
    if args.ours:
        ours = load_ours(args.ours, raw.shape)
        diff = ours.astype(int) - reference.astype(int)
        off = int((diff != 0).sum())
        panels.append(("macTEM (TEMCore PatternFilters)", ours, "gray", (0, 255)))
        panels.append((f"difference: {off} of {diff.size} px off, max {np.abs(diff).max()} grey level(s)", diff, "coolwarm", (-2, 2)))
    fig, axes = plt.subplots(1, len(panels), figsize=(3.2 * len(panels), 3.6))
    for ax, (name, image, cmap, (lo, hi)) in zip(np.atleast_1d(axes), panels):
        im = ax.imshow(image, cmap=cmap, vmin=lo, vmax=hi, interpolation="nearest")
        ax.set_title(name, fontsize=8)
        ax.set_xticks([]); ax.set_yticks([])
        fig.colorbar(im, ax=ax, fraction=0.046, pad=0.03)
    fig.suptitle("F4: nickel_ebsd_large pattern (0, 0), FFT filter in the frequency domain (shift=True)", fontsize=9)
    fig.tight_layout()
    fig.savefig(args.out, dpi=150)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
