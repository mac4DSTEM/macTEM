#!/usr/bin/env python3
"""Figures F11 and F12 of the SEM program's north star from DefDAP 1.3.1 on orix-data's whole Ti map (fetched): F11 the
grain map (boundaries 10 degrees, grains of at least 10 points, each grain a colour, regions under 10 points white)
with the grain size histogram; F12 the KAM map (symmetric, 5 degree threshold, the port's default; DefDAP's own KAM
ignores symmetry, D-SEM-55) and the GOS map (mean GROD angle per grain), in degrees. The numbers are the bundles'
`m5/grains-ti-full`; this script draws them from the same functions grain_cases.py runs.

    python -I -B grain_figure.py --data References/sem-data --out-f11 F11.png --out-f12 F12.png
"""

import argparse
import sys
from pathlib import Path

import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
sys.path.insert(0, str(HERE))
import grain_cases as G  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data", type=Path, default=HERE.parent.parent.parent / "References" / "sem-data")
    ap.add_argument("--out-f11", type=Path, required=True)
    ap.add_argument("--out-f12", type=Path, required=True)
    args = ap.parse_args()
    G._defdap()
    table = np.loadtxt(args.data / "orix" / "Ti_orientations.ctf", skiprows=1)
    h, w = len(np.unique(table[:, 10])), len(np.unique(table[:, 9]))
    m = G._map((h, w), 0.25, [G._ti_phase()], np.ones((h, w)), np.deg2rad(table[:, :3]))
    q = G._quats(m)
    with G._quiet():
        m.data.generate("grain_boundaries", misori_tol=G.BOUNDARY_DEGREES)
        m.data.generate("grains", min_grain_size=G.MIN_GRAIN_SIZE)
        m.calc_grain_mis_ori()
    grains = np.asarray(m.data.grains)
    kam = G._symmetric_kam(q, np.ones((h, w), dtype=np.int32), [m.phases[0].crystal_structure.symmetries],
                           np.deg2rad(G.KAM_THRESHOLD_DEGREES))
    gos_map = np.full((h, w), np.nan)
    sizes = []
    for g in m:
        pts = np.asarray(g.data.point)
        gos_map[pts[:, 1], pts[:, 0]] = np.degrees(np.mean(2 * np.arccos(np.asarray(g.mis_ori_list))))
        sizes.append(len(g))
    extent = (0, w * 0.25, h * 0.25, 0)

    rng = np.random.default_rng(7)
    colours = rng.uniform(0.15, 0.95, size=(grains.max() + 1, 3))
    rgb = np.ones((h, w, 3))
    ok = grains > 0
    rgb[ok] = colours[grains[ok]]
    fig, ax = plt.subplots(1, 2, figsize=(12, 4.6), gridspec_kw={"width_ratios": [1.6, 1]})
    ax[0].imshow(rgb, extent=extent, interpolation="nearest")
    ax[0].set_title(f"F11 grains of the Ti map: {len(m)} grains (DefDAP 1.3.1, 10°, ≥ 10 points)")
    ax[0].set_xlabel("x (µm)")
    ax[0].set_ylabel("y (µm)")
    ecd = 2 * np.sqrt(np.array(sizes) * 0.25 ** 2 / np.pi)
    ax[1].hist(ecd, bins=20, color="#4878a8")
    ax[1].set_xlabel("equivalent circle diameter (µm)")
    ax[1].set_ylabel("grains")
    ax[1].set_title("grain sizes")
    fig.tight_layout()
    fig.savefig(args.out_f11, dpi=150)

    fig, ax = plt.subplots(1, 2, figsize=(13, 4.6))
    im = ax[0].imshow(np.degrees(kam), extent=extent, cmap="viridis", vmin=0, vmax=G.KAM_THRESHOLD_DEGREES, interpolation="nearest")
    ax[0].set_title(f"F12 KAM (symmetric, 5° threshold), mean {np.nanmean(np.degrees(kam)):.2f}°")
    fig.colorbar(im, ax=ax[0], label="KAM (°)")
    im = ax[1].imshow(gos_map, extent=extent, cmap="magma", interpolation="nearest")
    ax[1].set_title(f"F12 GOS per grain, max {np.nanmax(gos_map):.2f}°")
    fig.colorbar(im, ax=ax[1], label="GOS (°)")
    for a in ax:
        a.set_xlabel("x (µm)")
        a.set_ylabel("y (µm)")
    fig.tight_layout()
    fig.savefig(args.out_f12, dpi=150)
    print(f"grain_figure.py: {len(m)} grains; F11 {args.out_f11}, F12 {args.out_f12}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
