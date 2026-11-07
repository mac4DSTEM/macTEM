#!/usr/bin/env python3
"""Figure F5 of the SEM program's north star: the moving-screen projection centre of the silicon patterns si_in (0 mm)
and si_out5mm (5 mm further out), kikuchipy's tutorial and test points (Hjelen et al. 1991). Three panels as kikuchipy's
`PCCalibrationMovingScreen.plot`: each pattern (static and dynamic background divided, as the tutorial) with its marked
zone axes, and the out -> in lines crossing at (PCx, PCy), with kikuchipy's PC and the one TEMCore computed.

    References/sem-venv/bin/python -I tools/parity/sem/detector_figure.py --data References/sem-data \
        --ours "0.5054497 0.8623947 0.5035647" --out F5.png

`--ours` is the "F5 ours tests-5-tsl: pc x y z" line `testMovingScreenPCOfSiliconAsKikuchipy` prints (the three numbers,
or the whole line). Without it the figure shows kikuchipy's PC only. The text block lists both and the difference.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

POINTS_IN = [(109, 131), (390, 139), (246, 232), (129, 228), (364, 237)]
POINTS_OUT = [(77, 146), (424, 156), (246, 269), (104, 265), (392, 276)]
PX_SIZE = 46 / 508  # mm, kikuchipy's tests


def processed(path: Path) -> np.ndarray:
    import kikuchipy as kp

    s = kp.load(str(path))
    s.remove_static_background("divide", show_progressbar=False)
    s.remove_dynamic_background("divide", show_progressbar=False)
    s.normalize_intensity(dtype_out="float32", show_progressbar=False)
    return np.asarray(s.data).squeeze()


def parse_ours(text: str | None):
    if not text:
        return None
    m = re.search(r"pc\s+([-0-9.eE]+)\s+([-0-9.eE]+)\s+([-0-9.eE]+)", text) or re.search(r"([-0-9.eE]+)[ ,]+([-0-9.eE]+)[ ,]+([-0-9.eE]+)", text)
    if not m:
        raise SystemExit(f"--ours: no three numbers in {text!r}")
    return np.array([float(g) for g in m.groups()])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data", type=Path, default=Path(__file__).resolve().parents[3] / "References" / "sem-data")
    ap.add_argument("--ours", help="TEMCore's PC (TSL) for the five test points")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    import kikuchipy as kp

    folder = args.data / "silicon_ebsd_moving_screen"
    p_in, p_out = processed(folder / "si_in.h5"), processed(folder / "si_out5mm.h5")
    cal = kp.detectors.PCCalibrationMovingScreen(p_in, p_out, POINTS_IN, POINTS_OUT, delta_z=5, px_size=PX_SIZE)
    ref = cal.pc
    ours = parse_ours(args.ours)
    ny, nx = cal.shape

    fig, axes = plt.subplots(1, 3, figsize=(15, 5.4), layout="constrained")
    for k, (data, title) in enumerate([(p_in, "si_in (0 mm)"), (p_out, "si_out5mm (+5 mm)")]):
        ax, pts = axes[k], cal.points[k]
        ax.imshow(data, cmap="gray", vmin=-3, vmax=3)
        for (x1, y1), (x2, y2) in zip(cal.lines_start[k], cal.lines_end[k]):
            ax.plot([x1, x2], [y1, y2], color="#e8b23a", lw=0.8)
        ax.scatter(pts[:, 0], pts[:, 1], s=40, c=[f"C{i}" for i in range(len(pts))], zorder=3)
        ax.set_title(title)
        ax.set_axis_off()
    ax = axes[2]
    ax.imshow(p_in, cmap="gray", vmin=-3, vmax=3, alpha=0.5)
    for (xo, yo), (xi, yi) in zip(cal.lines_out_in_start, cal.lines_out_in_end):
        t = np.array([-3.0, 3.0])
        ax.plot(xo + t * (xi - xo) * 4, yo + t * (yi - yo) * 4, color="#4a90d9", lw=0.8)
    ax.scatter(cal.pxy_all[:, 0], cal.pxy_all[:, 1], s=12, c="#4a90d9", zorder=3, label="estimates (point pairs)")
    ax.scatter([ref[0] * nx], [(1 - ref[1]) * ny], marker="+", s=200, c="#d0021b", zorder=4, label="kikuchipy PC")
    if ours is not None:
        ax.scatter([ours[0] * nx], [(1 - ours[1]) * ny], marker="x", s=120, c="#2ca02c", zorder=5, label="macEM (TEMCore) PC")
    ax.set_xlim(0, nx)
    ax.set_ylim(ny, 0)
    ax.set_title("out → in lines cross at (PCx, PCy)")
    ax.legend(loc="lower right", fontsize=8)
    ax.set_axis_off()
    lines = [f"kikuchipy 0.13.1  PC (TSL) = ({ref[0]:.6f}, {ref[1]:.6f}, {ref[2]:.6f})  DD = {ref[2] * ny * PX_SIZE:.3f} mm"]
    if ours is not None:
        d = np.abs(ours - ref) / np.abs(ref)
        lines.append(f"macEM TEMCore     PC (TSL) = ({ours[0]:.6f}, {ours[1]:.6f}, {ours[2]:.6f})  max rel. diff {d.max():.1e} (tolerance 1e-5)")
    fig.suptitle("F5  moving-screen projection centre, Si, Δz = 5 mm, 5 zone axes (Hjelen et al. 1991)\n" + "\n".join(lines),
                 fontsize=10, family="monospace")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.out, dpi=130)
    print(f"detector_figure.py: wrote {args.out}; kikuchipy PC {ref}" + (f", ours {ours}" if ours is not None else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
