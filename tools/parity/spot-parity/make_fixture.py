#!/usr/bin/env python3
"""Planted lattices and their truth for tools/parity/spot-parity (archive: roadmap-registrations-2026-10-15.md V1-6 "Slice C, the spot's d-spacing").

    make_fixture.py <out-dir>

Each case is a float32 image (raw little-endian, row-major, x fastest: `<case>.in.f32`):
    x[y, x] = DC + A cos(2 pi (kx x/w + ky y/h) + phase)  [+ A2 cos(...) second lattice]  [+ N(0, sigma), seeded]
(kx, ky) are signed frequency INDICES (non-integers are sub-bin offsets). The study's plant is reused
(archive: spot-dspacing-study-2026-10-12.md): scales 0.0123 nm (x) / 0.0246 nm (y), spot amplitude 1, DC 10, a weak
second lattice (0.3) at least 6 bins from the spot, its Friedel partner and the DC (off-bin, so it never sits in the
spot's 5 x 5 window). The spot's planted d0 = 1 / sqrt((kx/(w dx))^2 + (ky/(h dy))^2).

Grid (P1): sizes 64, 128, 256, 512, 256x128, 96x128 x spot at 5 bins and 0.1/0.25/0.4 Nyquist (k = rel * min(w,h)/2, at
least 5; a duplicate k within a size is dropped), direction alternating 20/70 deg, the sub-bin offset (ox, oy) cycling
through {0, 0.25, 0.5}, the click cycling through offsets of 0, 1 and 2 bins (Chebyshev) from the true maximum.
Tier "noisy" (P3): sigma 1, N >= 256, k >= 0.1 Nyquist, fixed seeds. DC 1000 cases (dc1000-*) make a missing mean
subtraction leak into the spot's window. One refusal (spot within 3 bins of the centre), one neighbour case (second spot
3 bins away, amplitude 0.4 -> 16 % of the power).

The click is the true maximum (argmax of the windowed power near the plant, computed here with numpy) plus the click
offset; reference.py recomputes everything independently and fails if the snap does not return the true maximum.
planted.json: per case the plant, d0, kind, tier, the true maximum (true_row, true_col) and the click.
"""
import json
import math
import os
import sys

import numpy as np

SX, SY = 0.0123, 0.0246
OFFSETS = [(0.0, 0.0), (0.25, 0.25), (0.5, 0.0), (0.25, 0.5), (0.0, 0.5), (0.5, 0.5), (0.25, 0.0), (0.0, 0.25)]
CLICKS = [(0, 0), (1, 0), (0, -1), (1, 1), (-2, 1), (2, 0), (0, 2), (-1, -2), (1, -1)]   # Chebyshev 0, 1 or 2
SHAPES = [(64, 64), (128, 128), (256, 256), (512, 512), (128, 256), (128, 96)]            # (h, w); names are w x h


def spot_k(w, h, rel, angle_deg, ox, oy):
    """The spot's (kx, ky) in index units: k bins at the angle, rounded, plus the sub-bin offset."""
    k = max(5.0, rel * 0.5 * min(w, h)) if rel > 0 else 5.0
    a = math.radians(angle_deg)
    return round(k * math.cos(a)) + ox, round(k * math.sin(a)) + oy


def second_lattice(w, h, kx, ky):
    m = 0.5 * min(w, h)
    for fx, fy in [(-0.30, 0.28), (0.35, -0.22), (-0.22, -0.31), (0.12, 0.36)]:
        sx, sy = fx * m + 0.37, fy * m + 0.61
        if abs(sx) > w / 2 - 3 or abs(sy) > h / 2 - 3:
            continue
        if min(math.hypot(sx - kx, sy - ky), math.hypot(sx + kx, sy + ky), math.hypot(sx, sy)) >= 6.0:
            return sx, sy
    raise SystemExit("make_fixture: no second-lattice position for %dx%d spot (%g, %g)" % (w, h, kx, ky))


def d_of(w, h, dx, dy, kx, ky):
    return 1.0 / math.sqrt((kx / (w * dx)) ** 2 + (ky / (h * dy)) ** 2)


def case(name, w, h, spots, *, dc=10.0, sigma=0.0, seed=None, kind="spot", tier="clean", **extra):
    """spots[0] is the measured spot: {kx, ky, amplitude, phase}; any others are plants only."""
    return {"name": name, "kind": kind, "tier": tier, "width": w, "height": h, "scale_x": SX, "scale_y": SY,
            "units": "nm", "dc": dc, "spots": spots, "noise": {"seed": seed, "sigma": sigma} if sigma > 0 else None,
            "d0": d_of(w, h, SX, SY, spots[0]["kx"], spots[0]["ky"]), **extra}


def spot(kx, ky, amp=1.0, phase=0.4):
    return {"kx": kx, "ky": ky, "amplitude": amp, "phase": phase}


def grid_cases():
    out, n = [], 0
    for (h, w) in SHAPES:
        seen = set()
        for rel, tag in [(0, "k5"), (0.1, "k10"), (0.25, "k25"), (0.4, "k40")]:
            kb = max(5.0, rel * 0.5 * min(w, h)) if rel > 0 else 5.0
            if kb in seen:
                continue
            seen.add(kb)
            ox, oy = OFFSETS[n % len(OFFSETS)]
            ang = 20 if n % 2 == 0 else 70
            cl = CLICKS[n % len(CLICKS)]
            kx, ky = spot_k(w, h, rel, ang, ox, oy)
            sx, sy = second_lattice(w, h, kx, ky)
            name = "s%dx%d-%s-a%d-o%g_%g" % (w, h, tag, ang, ox, oy)
            out.append(case(name, w, h, [spot(kx, ky, 1.0, 0.4 + 0.3 * (n % 3)), spot(sx, sy, 0.3, 1.1)],
                            click=list(cl)))
            n += 1
    return out


def extra_cases():
    out = []
    # sub-bin offsets 0 / 0.25 / 0.5 on one size and every click offset 0/1/2 at 5 bins and 0.25 Nyquist
    for i, ((ox, oy), cl) in enumerate(zip([(0, 0), (0.25, 0.25), (0.5, 0.5), (0.5, 0.25)],
                                           [(2, 2), (0, 2), (-2, 0), (1, -2)])):
        kx, ky = spot_k(128, 128, 0.0, 70, ox, oy)
        sx, sy = second_lattice(128, 128, kx, ky)
        out.append(case("x128-k5-o%g_%g-c%d_%d" % (ox, oy, cl[0], cl[1]), 128, 128,
                        [spot(kx, ky, 1.0, 0.9), spot(sx, sy, 0.3, 1.1)], click=list(cl)))
    # DC 1000: a missing mean subtraction leaks the DC into the 5 x 5 window (study finding 3)
    for (h, w), cl in [((128, 128), (1, -1)), ((128, 256), (0, 2))]:
        kx, ky = spot_k(w, h, 0.0, 20, 0.25, 0.5)
        sx, sy = second_lattice(w, h, kx, ky)
        out.append(case("dc1000-%dx%d-k5" % (w, h), w, h, [spot(kx, ky, 1.0, 0.9), spot(sx, sy, 0.3, 1.1)],
                        dc=1000.0, click=list(cl)))
    # P3 noisy tier: sigma 1, N >= 256, k >= 0.1 Nyquist, fixed seeds
    seed = 20261012
    for N in (256, 512):
        for rel, tag in [(0.1, "k10"), (0.4, "k40")]:
            for rep in range(2):
                ox, oy = OFFSETS[(seed + rep) % len(OFFSETS)]
                kx, ky = spot_k(N, N, rel, 20 if rep == 0 else 70, ox, oy)
                sx, sy = second_lattice(N, N, kx, ky)
                out.append(case("noisy%d-%s-r%d" % (N, tag, rep), N, N,
                                [spot(kx, ky, 1.0, 0.4 + rep), spot(sx, sy, 0.3, 1.1)], sigma=1.0, seed=seed,
                                tier="noisy", click=list(CLICKS[(seed + rep) % len(CLICKS)])))
                seed += 1
    # refusal: a spot 2 bins right, 1 down from the centre (distance sqrt(5) <= 3)
    out.append(case("refuse-nearDC", 128, 128, [spot(2.0, 1.0, 1.0, 0.4)], kind="refusal", click=[1, 1]))
    # refusal: a spot 62 bins right on 128 columns snaps to column 126, inside 2 bins of the edge (C' review)
    out.append(case("refuse-nearEdge", 128, 128, [spot(62.0, 5.0, 1.0, 0.4)], kind="refusal", click=[0, 0]))
    out[-1]["error_expected"] = "nearEdge"
    # the DC radius at its boundary: (3, 0) bins is refused (distance 3), (3, 1) is measured (distance sqrt(10))
    out.append(case("refuse-dc-radius3", 128, 128, [spot(3.0, 0.0, 1.0, 0.4)], kind="refusal", click=[0, 0]))
    out.append(case("dc-radius-sqrt10", 256, 256, [spot(3.0, 1.0, 1.0, 0.4)], click=[0, 0], tier="noisy"))
    # neighbour: a second spot exactly 3 bins away along x, amplitude 0.4; the bias is bounded by the noisy band
    out.append(case("neighbour-3bins", 256, 256, [spot(20.0, 8.0, 1.0, 0.4), spot(23.0, 8.0, 0.4, 2.0)],
                    tier="noisy", click=[1, 0], neighbour_expected=True))
    return out


def image(c):
    w, h = c["width"], c["height"]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    img = np.full((h, w), c["dc"], dtype=np.float64)
    for v in c["spots"]:
        img += v["amplitude"] * np.cos(2 * np.pi * (v["kx"] * xx / w + v["ky"] * yy / h) + v["phase"])
    if c["noise"]:
        img += np.random.default_rng(c["noise"]["seed"]).normal(0.0, c["noise"]["sigma"], size=(h, w))
    return img.astype("<f4")


def power(x):
    h, w = x.shape
    x = x.astype(np.float64)
    x = (x - x.mean()) * np.outer(np.hanning(h), np.hanning(w))
    return np.abs(np.fft.fftshift(np.fft.fft2(x))) ** 2


def finish(c, img):
    """True maximum = argmax of the windowed power within 1 bin of the planted position; the click = it + the offset."""
    h, w = c["height"], c["width"]
    P = power(img)
    s = c["spots"][0]
    r0, c0 = h // 2 + int(round(s["ky"])), w // 2 + int(round(s["kx"]))
    blk = P[r0 - 1:r0 + 2, c0 - 1:c0 + 2]
    a, b = np.unravel_index(int(np.argmax(blk)), blk.shape)
    tr, tc = r0 - 1 + int(a), c0 - 1 + int(b)
    dr, dc = c["click"]
    c["true_row"], c["true_col"] = tr, tc
    c["click_row"], c["click_col"] = tr + dr, tc + dc
    c["click_offset"] = max(abs(dr), abs(dc))
    del c["click"]
    return c


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    cs = grid_cases() + extra_cases()
    names = [c["name"] for c in cs]
    assert len(set(names)) == len(names), "duplicate case names"
    done = []
    for c in cs:
        img = image(c)
        img.tofile(os.path.join(out, c["name"] + ".in.f32"))
        done.append(finish(c, img))
    with open(os.path.join(out, "planted.json"), "w") as f:
        json.dump({"cases": done}, f, indent=1)
    print("make_fixture: %d cases in %s" % (len(done), out))


if __name__ == "__main__":
    main()
