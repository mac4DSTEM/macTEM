#!/usr/bin/env python3
"""Figure F13 of the SEM program's north star on orix-data's whole Ti map (fetched): the pole figures {0001}, {10-10}
and {11-20} (upper hemisphere, orix's pole_density_function, 1 degree equal-area grid, sigma 5 degrees, mrd), the
IPF-Z density in 6/mmm's sector, and the ODF sections phi2 = 0 and 30 degrees (de la Vallee Poussin kernel, half-width
10 degrees, every tenth orientation), drawn as orix draws them (pcolormesh on the bin edges, magma). The numbers are the
bundle `m5/texture-ti-full`'s; this script draws them from the same functions texture_cases.py runs, and prints the
maxima the north star quotes.

    python -I -B texture_figure.py --data References/sem-data --out F13.png
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
import texture_cases as T  # noqa: E402


def main() -> int:
    from orix.measure import pole_density_function
    from orix.quaternion import Orientation
    from orix.quaternion.symmetry import D6, D6h
    from orix.vector import Vector3d

    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data", type=Path, default=HERE.parent.parent.parent / "References" / "sem-data")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    table = np.loadtxt(args.data / "orix" / "Ti_orientations.ctf", skiprows=1)
    O = Orientation.from_euler(np.deg2rad(table[:, :3]), D6)
    phase = T._phase("6/mmm", T.TI_LATTICE)

    fig, axes = plt.subplots(2, 3, figsize=(13, 8.6))
    for ax, (tag, family) in zip(axes[0], T.TI_FAMILIES.items()):
        hist, (x, y) = pole_density_function(T._sample_vectors(O, T._poles(phase, family)))
        pc = ax.pcolormesh(x, y, hist, cmap="magma")
        ax.add_patch(plt.Circle((0, 0), 1, fill=False, lw=0.8))
        ax.set_aspect("equal"), ax.set_axis_off()
        ax.set_title("{" + tag + "} pole figure, max %.2f mrd" % hist.max())
        fig.colorbar(pc, ax=ax, shrink=0.75)
        print(f"PF {{{tag}}}: max {hist.max():.4f} mrd")
    hist, (x, y) = pole_density_function(O * Vector3d.zvector(), symmetry=D6h)
    ax = axes[1][0]
    pc = ax.pcolormesh(x, y, hist, cmap="magma")
    ax.set_aspect("equal"), ax.set_axis_off()
    ax.set_title("IPF-Z density (6/mmm), max %.2f mrd" % hist.max())
    fig.colorbar(pc, ax=ax, shrink=0.75)
    print(f"IPF-Z: max {hist.max():.4f} mrd")
    sub = O[::10]
    for ax, phi2 in zip(axes[1][1:], (0.0, 30.0)):
        phi1, Phi, grid = T.section_grid(phi2, 360.0, 90.0)
        f = T.odf_values(sub, grid).reshape(len(phi1), len(Phi))
        pc = ax.pcolormesh(np.append(phi1, 360) - 2.5, np.append(Phi, 92.5) - 2.5, f.T, cmap="magma", shading="flat")
        ax.invert_yaxis()
        ax.set_xlabel("φ1 (°)"), ax.set_ylabel("Φ (°)")
        ax.set_title("ODF φ2 = %d°, max %.2f mrd" % (phi2, f.max()))
        fig.colorbar(pc, ax=ax, shrink=0.75)
        print(f"ODF phi2={phi2:.0f}: max {f.max():.4f} mrd at phi1 {phi1[np.argmax(f) // len(Phi)]:.0f}, Phi {Phi[np.argmax(f) % len(Phi)]:.0f}")
    fig.suptitle("F13 — Ti map (orix-data, 381 × 507, 622): pole figures, IPF density, ODF sections (orix 0.15.0)")
    fig.tight_layout()
    fig.savefig(args.out, dpi=110)
    return 0


if __name__ == "__main__":
    sys.exit(main())
