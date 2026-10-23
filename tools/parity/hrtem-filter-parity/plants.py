#!/usr/bin/env python3
"""Planted images for tools/parity/hrtem-filter-parity (archive: roadmap-registrations-2026-10-15.md "V1-6b HRTEM filters", slice E; V1-6c: fresh seeds, more cases).

    plants.py <out-dir>

Writes, per case, `<name>.in.f32` (raw little-endian float32, n x n, row-major) and `<name>.lattice.f64` (the planted
zero-mean lattice truth, float64, zeros where none), and `planted.json` (per case the tier, n, seed, wave list, continuum
spec, ramp). Seeds are fixed here: SEED0 = 20261015 (V1-6d; V1-6c's 20261014 and V1-6b's 20261013 are seen), case seed = SEED0 + 1000 * tier_index + n.

Image = DC 1000 + lattice + continuum + white noise sigma 5 (tier-dependent):
  lattice  three cosine waves, amplitudes uniform 20..80, random phases, plus each one's second harmonic at half
           amplitude. Wave = A cos(2 pi (kx col + ky row) / n + phase), kx the column frequency, ky the row frequency
           (bins). Every wave's |k| (harmonics included) is inside Ro * n / 2 = 0.15 n and the fundamental is above 4 bins.
  continuum random-phase, Hermitian (the unit-modulus phases of a seeded real white field's FFT), with exactly isotropic
           |F|(k) = ring(k) + power(k): ring = 0.3 exp(-(k - 0.08 n)^2 / (2 (0.03 n)^2)), power = k^-1.5 (k >= 1), DC 0,
           all scaled so the real-space rms is 15. The scaled profile at integer k = 0..n/2 is recorded.
Tiers: bin; offbin (the three fundamentals at half-integer frequencies; a harmonic is 2k, so it is on a bin); noise
(continuum + noise + DC); ramp (bin + a non-periodic linear ramp 0..200 across the columns); nyquist (bin + a wave of
amplitude 30 at (kx, ky) = (n/2, 0), phase 0: on the column axis at Nyquist). Degenerate at n = 128: lattice-clean (DC +
lattice) and constant (all 1000). Each tier at n = 128, 256, 250: 5 x 3 + 2 = 17 cases.
V1-6c adds: offbin0 / offbin25 / offbin50 (the three fundamentals at integer + 0, 0.25, 0.5 bins on both axes; harmonics 2k) at
n = 128 and 256; and parameter cases on the `bin` plant (same image and seed as bin-n; tier "param", `param` the case's
name): pct5 pct20 nosmooth order1 order8 ro1 step5 delta20 cycles3 at n = 128 and 256, each one parameter changed from the
defaults. The nyquist tier's truth ("lattice") is the in-band lattice only; its r = n/2 wave stays in the input and is
recorded as "nyquist_wave". Every case carries "params" (the filter's) in planted.json. Pixel scale 0.0123 nm (metadata).
"""
import json
import math
import os
import sys

import numpy as np

SEED0 = 20261015
SIZES = [128, 256, 250]
TIERS = ["bin", "offbin", "noise", "ramp", "nyquist"]
PIXEL_NM = 0.0123
DC = 1000.0
NOISE_SIGMA = 5.0
CONT_RMS = 15.0
RING_AMP, RING_C, RING_W, POW_EXP = 0.3, 0.08, 0.03, -1.5
DEFAULT_PARAMS = {"delta": 5.0, "step": 2.0, "cycles": 99, "smoothing": True, "order": 4, "ro": 0.3, "pct": 0.0}
PARAM_CASES = {"pct5": {"pct": 5.0}, "pct20": {"pct": 20.0}, "nosmooth": {"smoothing": False}, "order1": {"order": 1},
               "order8": {"order": 8}, "ro1": {"ro": 1.0}, "step5": {"step": 5.0}, "delta20": {"delta": 20.0},
               "cycles3": {"cycles": 3}}
OFFSETS = {"offbin0": 0.0, "offbin25": 0.25, "offbin50": 0.5}
RO = 0.3  # the smoothing radius the lattice must stay inside: RO * n / 2


def case_list():
    cs = [(f"{t}-{n}", t, n) for t in TIERS for n in SIZES]
    cs += [("lattice-clean-128", "lattice-clean", 128), ("constant-128", "constant", 128)]
    cs += [(f"{t}-{n}", t, n) for t in OFFSETS for n in (128, 256)]
    cs += [(f"{p}-{n}", "param:" + p, n) for p in PARAM_CASES for n in (128, 256)]
    return cs


def seed_of(tier, n):
    if tier.startswith("param:"):
        tier = "bin"  # a parameter case is the bin plant of its size
    ti = (TIERS + ["lattice-clean", "constant"] + list(OFFSETS)).index(tier)
    return SEED0 + 1000 * ti + n


def make_waves(rng, n, offset):
    """Three waves (+ second harmonics at half amplitude); fundamentals integer + `offset` bins on both axes."""
    kmax = 0.075 * n  # the harmonic (2k) must stay inside 0.15 n
    chosen = []
    while len(chosen) < 3:
        kx, ky = (int(v) for v in rng.integers(-int(kmax) - 1, int(kmax) + 2, size=2))
        kx, ky = kx + offset, ky + offset
        k = math.hypot(kx, ky)
        if not (4.0 < k <= kmax):
            continue
        bad = False
        for (jx, jy) in chosen:
            for (ax, ay) in ((jx, jy), (2 * jx, 2 * jy)):
                for (bx, by) in ((kx, ky), (2 * kx, 2 * ky)):
                    if (ax, ay) == (bx, by) or (ax, ay) == (-bx, -by):
                        bad = True
            if math.hypot(kx - jx, ky - jy) < 2.0 or math.hypot(kx + jx, ky + jy) < 2.0:
                bad = True
        if not bad:
            chosen.append((kx, ky))
    waves = []
    for kx, ky in chosen:
        amp = float(rng.uniform(20.0, 80.0))
        ph = float(rng.uniform(0.0, 2.0 * math.pi))
        ph2 = float(rng.uniform(0.0, 2.0 * math.pi))
        waves.append({"kx": kx, "ky": ky, "amp": amp, "phase": ph, "harmonic": False})
        waves.append({"kx": 2 * kx, "ky": 2 * ky, "amp": amp / 2.0, "phase": ph2, "harmonic": True})
    return waves


def lattice_from(waves, n):
    row = np.arange(n, dtype=np.float64)[:, None]
    col = np.arange(n, dtype=np.float64)[None, :]
    out = np.zeros((n, n))
    for w in waves:
        out += w["amp"] * np.cos(2.0 * math.pi * (w["kx"] * col + w["ky"] * row) / n + w["phase"])
    return out


def continuum_profile(K, n):
    ring = RING_AMP * np.exp(-((K - RING_C * n) ** 2) / (2.0 * (RING_W * n) ** 2))
    power = np.zeros_like(K)
    m = K >= 1.0
    power[m] = K[m] ** POW_EXP
    return ring + power


def make_continuum(rng, n):
    white = rng.standard_normal((n, n))
    F = np.fft.fft2(white)
    phase = F / np.abs(F)
    k1 = np.fft.fftfreq(n) * n
    K = np.hypot(k1[:, None], k1[None, :])
    amp = continuum_profile(K, n)
    field = np.fft.ifft2(phase * amp).real
    scale = CONT_RMS / math.sqrt(float(np.mean(field**2)))
    ks = np.arange(0, n // 2 + 1, dtype=np.float64)
    spec = {"ring_amp": RING_AMP, "ring_centre_bins": RING_C * n, "ring_width_bins": RING_W * n,
            "power_exponent": POW_EXP, "scale": scale, "rms": CONT_RMS,
            "profile_k": ks.tolist(), "profile": (scale * continuum_profile(ks, n) * 1.0).tolist(),
            "note": "profile = |F| of the unnormalised-fft2 convention divided by n^2 (ifft2 amplitude) is scale*profile(k)"}
    return field * scale, spec


def make_case(name, tier, n):
    seed = seed_of(tier, n)
    params = dict(DEFAULT_PARAMS)
    param_name = None
    if tier.startswith("param:"):
        param_name = tier[6:]
        params.update(PARAM_CASES[param_name])
        tier = "bin"
    rng = np.random.default_rng(seed)
    img = np.full((n, n), DC)
    lattice = np.zeros((n, n))
    waves, cont, ramp, nyq = [], None, False, None
    NOISY = ("bin", "offbin", "noise", "ramp", "nyquist") + tuple(OFFSETS)
    if tier in ("bin", "offbin", "ramp", "nyquist", "lattice-clean") + tuple(OFFSETS):
        offset = 0.5 if tier == "offbin" else OFFSETS.get(tier, 0.0)
        waves = make_waves(rng, n, offset)
        lattice = lattice_from(waves, n)  # the in-band truth
        img = img + lattice
        lattice = lattice - lattice.mean()
        if tier == "nyquist":
            nyq = {"kx": n // 2, "ky": 0, "amp": 30.0, "phase": 0.0}
            img = img + lattice_from([dict(nyq)], n)  # in the input, not in the truth
    if tier in NOISY:
        field, cont = make_continuum(rng, n)
        img = img + field
    if tier in NOISY:
        img = img + NOISE_SIGMA * rng.standard_normal((n, n))
    if tier == "ramp":
        ramp = True
        img = img + np.linspace(0.0, 200.0, n)[None, :]
    return img.astype(np.float32), lattice, {"name": name, "tier": ("param" if param_name else tier), "plant": tier,
                                            "param": param_name, "params": params, "nyquist_wave": nyq,
                                            "n": n, "seed": seed, "pixel_nm": PIXEL_NM,
                                            "dc": DC, "noise_sigma": NOISE_SIGMA if tier not in ("lattice-clean", "constant") else 0.0,
                                            "waves": waves, "continuum": cont, "ramp": 200.0 if ramp else None}


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    planted = {"seed0": SEED0, "cases": []}
    for name, tier, n in case_list():
        img, lattice, meta = make_case(name, tier, n)
        img.astype("<f4").tofile(os.path.join(out, f"{name}.in.f32"))
        lattice.astype("<f8").tofile(os.path.join(out, f"{name}.lattice.f64"))
        planted["cases"].append(meta)
    with open(os.path.join(out, "planted.json"), "w") as f:
        json.dump(planted, f, indent=1)
    print(f"planted {len(planted['cases'])} cases in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
