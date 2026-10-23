#!/usr/bin/env python3
"""Planted images and their truth for tools/parity/fft-parity.

    make_fixture.py <out-dir>

Each case is a float32 image (raw little-endian, row-major, x fastest: `<case>.in.f32`) built from DC + plane waves
    x[y, x] = DC + sum_i A_i cos(2 pi (kx_i x / w + ky_i y / h) + phase_i)  [+ N(0, sigma) noise, seeded]
with (kx, ky) signed frequency INDICES: integers are bin-centred (the DFT puts all of A*w*h/2 into one bin and its
Friedel partner), non-integers are off-bin (leakage). planted.json holds the truth reference.py must reproduce:
per case width, height, scale_x, scale_y, units ("nm" or "" = uncalibrated), the waves, dc, noise {seed, sigma} or null,
crop {row, col, height, width} or null, crop_of (the uncropped case's name) or null.

Slices B and D add kind "profile" (a planted ring: ring {q0, sigma, amplitude}, bin_width null = the default) and
kind "ifft" (two off-bin lattices A, B in `waves` with a "lattice" tag; `spots` the mask, `mask_lattice` the one masked);
the existing cases are kind "spectrum".

Sizes exercise every FFT2D path (archive: roadmap-registrations-2026-10-15.md V1-6 slice A): 128 x 96, 125 x 243, 127 x 50, 250 x 250. Crop cases carry the
whole image of their parent (same pixels, same waves) and the crop; their waves are not bin-centred after cropping,
so reference.py plants no peak checks on them.
"""
import json
import os
import sys

import numpy as np

SX, SY = 0.0123, 0.0246   # nm per pixel, anisotropic (y is twice x)


def wave(kx, ky, amp, phase):
    return {"kx": kx, "ky": ky, "amplitude": amp, "phase": phase}


def case(name, w, h, waves, *, sx=SX, sy=SY, units="nm", dc=1000.0, noise=None, crop=None, crop_of=None,
         kind="spectrum", **extra):
    return {"name": name, "kind": kind, "width": w, "height": h, "scale_x": sx, "scale_y": sy, "units": units,
            "waves": waves, "dc": dc, "noise": noise, "crop": crop, "crop_of": crop_of, **extra}


def crop(row, col, height, width):
    return {"row": row, "col": col, "height": height, "width": width}


def cases():
    p128 = case("p128x96", 128, 96, [wave(10, -7, 100.0, 0.3), wave(23.4, 5.7, 60.0, 1.1)])
    p125 = case("p125x243", 125, 243,
                [wave(6, -9, 100.0, 0.7), wave(-17.3, 31.6, 60.0, 2.0), wave(0, 4, 30.0, 0.0)])
    p127 = case("p127x50", 127, 50, [wave(9, 3, 100.0, 1.9), wave(20.5, -6.25, 50.0, 0.4)])
    p250 = case("p250x250", 250, 250,
                [wave(12, -20, 100.0, 0.1), wave(33.7, 8.4, 60.0, 2.7), wave(31, 17, 40.0, 5.0)])
    n128 = case("n128x96-noise", 128, 96, [wave(15, 6, 100.0, 0.9), wave(-31.5, 12.25, 40.0, 3.0)],
                noise={"seed": 20261012, "sigma": 10.0})
    u125 = case("u125x243-uncal", 125, 243, [wave(8, 11, 100.0, 0.2), wave(-22.6, -5.3, 50.0, 1.4)],
                sx=1.0, sy=1.0, units="")
    out = [p128, p125, p127, p250, n128, u125]
    for parent, nm, c in [
        (p250, "c250-crop-even", crop(17, 33, 60, 100)),
        (p250, "c250-crop-odd", crop(11, 29, 61, 101)),
        (p128, "c128x96-crop-even", crop(10, 20, 40, 64)),
        (p128, "c128x96-crop-odd", crop(5, 7, 31, 45)),
    ]:
        out.append(dict(parent, name=nm, crop=c, crop_of=parent["name"]))
    return out + profile_cases() + ifft_cases()


def dq(w, h, sx, sy):
    """Frequency-pixel sizes, the exact expression both sides use (fft-bd contract)."""
    return 1.0 / (w * sx), 1.0 / (h * sy)


def ring(q0, sigma, amp=100.0):
    return {"q0": q0, "sigma": sigma, "amplitude": amp}


def profile_cases():
    """Slice B: a planted ring amp * exp(-r^2 / 2 sigma^2) * cos(2 pi q0 r), r the physical radius from the image
    centre ((w-1)/2, (h-1)/2) with each axis's own scale. q0 (1/nm) is chosen so the ring's profile peak falls in the
    bin holding q0 for both bin widths (a bin narrower than a frequency pixel is sparse: scanned, not assumed)."""
    out = []
    for nm, w, h, q0, sg in [("pr128x96", 128, 96, 8.06, 2.0), ("pr125x243", 125, 243, 7.70, 2.0)]:
        dqx, dqy = dq(w, h, SX, SY)
        for suffix, given in [("", None), ("-half", min(dqx, dqy) / 2)]:
            out.append(case(nm + suffix, w, h, [], kind="profile", dc=1000.0, ring=ring(q0, sg), bin_width=given))
    # uncalibrated: scale 1, frequencies in 1/px
    out.append(case("pru125x243-uncal", 125, 243, [], sx=1.0, sy=1.0, units="", kind="profile", dc=1000.0,
                    ring=ring(0.098, 20.0), bin_width=None))
    return out


# Slice D: lattice A strong, lattice B weak, both off-bin (non-integer frequency indices, 0.1 from a bin: a rectangular
# DFT leaks ~1/d per axis, so a mask of radius 2.5-3 recovers a lattice to > 0.99 only for a small offset). |ky| < 25.
LATTICE_A = [(9.1, 3.9), (-4.1, 7.9)]
LATTICE_B = [(21.9, -9.1), (-15.1, 10.9)]
AMP_A, AMP_B = 100.0, 20.0


def ifft_cases():
    out = []
    for size, (w, h) in [("128x96", (128, 96)), ("127x50", (127, 50))]:
        waves = [dict(wave(kx, ky, AMP_A, 0.3 + 0.9 * n), lattice="A") for n, (kx, ky) in enumerate(LATTICE_A)] + \
                [dict(wave(kx, ky, AMP_B, 1.7 + 0.8 * n), lattice="B") for n, (kx, ky) in enumerate(LATTICE_B)]
        for lat, pts, r, e in [("A", LATTICE_A, 2.5, 2.0), ("B", LATTICE_B, 3.0, 0.0)]:
            spots = [{"kx": kx, "ky": ky, "r": r, "e": e} for kx, ky in pts]
            out.append(case("if%s-%s" % (lat, size), w, h, waves, kind="ifft", dc=1000.0, spots=spots,
                            mask_lattice=lat))
    return out


def image(c):
    w, h = c["width"], c["height"]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    img = np.full((h, w), c["dc"], dtype=np.float64)
    if c.get("ring"):
        rg = c["ring"]
        dx = c["scale_x"] if c["units"] else 1.0
        dy = c["scale_y"] if c["units"] else 1.0
        rr = np.sqrt(((xx - (w - 1) / 2) * dx) ** 2 + ((yy - (h - 1) / 2) * dy) ** 2)
        img += rg["amplitude"] * np.exp(-rr ** 2 / (2 * rg["sigma"] ** 2)) * np.cos(2 * np.pi * rg["q0"] * rr)
    for v in c["waves"]:
        img += v["amplitude"] * np.cos(2 * np.pi * (v["kx"] * xx / w + v["ky"] * yy / h) + v["phase"])
    if c["noise"]:
        rng = np.random.default_rng(c["noise"]["seed"])
        img += rng.normal(0.0, c["noise"]["sigma"], size=(h, w))
    return img.astype("<f4")


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    cs = cases()
    for c in cs:
        image(c).tofile(os.path.join(out, c["name"] + ".in.f32"))
    with open(os.path.join(out, "planted.json"), "w") as f:
        json.dump({"cases": cs}, f, indent=1)
    print("make_fixture: %d cases in %s" % (len(cs), out))


if __name__ == "__main__":
    main()
