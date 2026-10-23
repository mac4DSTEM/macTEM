#!/usr/bin/env python3
"""The numpy/scipy reference of tools/parity/hrtem-filter-parity (archive: roadmap-registrations-2026-10-15.md "V1-6b HRTEM filters", ADR 014; V1-6c, ADR 015).

    reference.py <planted-dir> <out-dir>

A functional re-implementation of the registration's steps A1-A6 (float64 from the float32 pixels), written from that
description alone. Reads `<planted-dir>/<name>.in.f32`, `.lattice.f64`, `planted.json` (from plants.py); writes
`<out-dir>/manifest.json` and `<name>.<key>.f64` (raw little-endian float64 n x n row-major, keys M0 S c1 M W a w absf
wiener flags lattice, written as `files` names them (W, w, a, M under distinct names: macOS is case-insensitive); flags as 0/1; a, w and every spectrum in the SHIFTED frame, DC at (n/2, n/2)) and copies each
input to `<out-dir>/<name>.in.f32`. Self-checks first-class: exit 1 on any failure.

V1-6c additions (the float64 reading above is unchanged). Each case's params come from planted.json (DEFAULTS fill what it
omits). Per case, three readings of the same steps: "f64" (the reading), "f32m" (the Float32 emulation of the registration:
every forward transform on (x - mean(x)) as complex64 via scipy.fft.fft2 on float32 input, workers=1; the DC bin then set in
float64 to sum(x) (sum(I*E) for M); the inverse = real(ifft2(complex64 masked spectrum, DC zeroed)) in float32 + mean(I) *
mask(0) in float64; every other step float64) and "f32p" (plain complex64 transforms, no mean removal). manifest.json gains, per
case, `dev_f32m` and `dev_f32p` (deviation per quantity from the float64 reading), `flag_diffs`, `p2` (energy ratios, kept
amplitudes) and `stop_rule`; top level `bands` (3 x the largest deviation) and `switch_to_double` (the emulated pass-1 c error
above 0.05 points).
"""
import json
import math
import os
import shutil
import sys
import time

import numpy as np
import scipy
import scipy.fft
from scipy.ndimage import map_coordinates, median_filter

DEFAULTS = {"delta": 5.0, "step": 2.0, "cycles": 99, "smoothing": True, "order": 4, "ro": 0.3, "pct": 0.0}
NANGLES = 512
CLEAN_MARGIN = 1e-3
FILES = ["M0", "S", "c1", "M", "W", "a", "w", "absf", "wiener", "flags", "lattice"]
# File names differ from the keys where two keys differ only in case: macOS volumes are case-insensitive, and W (the
# spectrum) and w (the Wiener mask) once overwrote each other (found by the Swift side, 2026-10-13).
FILE_NAME = {"W": "spectrum", "w": "wienermask", "a": "absfmask", "M": "background"}


def sh(x):
    return np.fft.fftshift(x)


def radius(n):
    ax = np.arange(n, dtype=np.float64) - n // 2
    return np.hypot(ax[:, None], ax[None, :])


def edge_window(n, r):
    return 1.0 / (1.0 + 0.414 * (r / (0.4 * n)) ** 24)


def rot(X, n, r):
    """512-angle average of bilinear samples at rho = 0..n/2-1, then linear in r (clamped beyond n/2-1: DEVIATION)."""
    rho = np.arange(n // 2, dtype=np.float64)
    th = 2.0 * np.pi * np.arange(NANGLES) / NANGLES
    rows = n // 2 + rho[None, :] * np.cos(th)[:, None]
    cols = n // 2 + rho[None, :] * np.sin(th)[:, None]
    P = map_coordinates(X, [rows, cols], order=1, mode="nearest").mean(axis=0)
    return np.interp(r, rho, P)


def butterworth(n, r, ro, order):
    return 1.0 / (1.0 + 0.414 * (r / (ro * (n / 2))) ** (2 * order))


def apply_mask(I, mask):
    F = sh(np.fft.fft2(I))
    return np.fft.ifft2(np.fft.ifftshift(F * mask)).real


def fwd(x, mode):
    """Unshifted forward transform of a real float64 array as complex128 (a complex64 transform cast up in the f32 modes).
    f64: numpy's. f32m: of (x - mean) in complex64, then the DC bin set in float64 to sum(x). f32p: of x in complex64."""
    if mode == "f64":
        return np.fft.fft2(x)
    if mode == "f32m":
        F = scipy.fft.fft2((x - x.mean()).astype(np.float32), workers=1).astype(np.complex128)
        F[0, 0] = x.sum()
        return F
    return scipy.fft.fft2(x.astype(np.float32), workers=1).astype(np.complex128)


def apply_mask_mode(I, F, mask, mode):
    """real(IFFT(F * mask)), F the unshifted forward transform of I from `fwd`, mask in the shifted frame."""
    n = I.shape[0]
    G = F * np.fft.ifftshift(mask)
    if mode == "f64":
        return np.fft.ifft2(G).real
    if mode == "f32m":
        G[0, 0] = 0.0
        out = scipy.fft.ifft2(G.astype(np.complex64), workers=1).real.astype(np.float64)
        return out + I.mean() * mask[n // 2, n // 2]
    return scipy.fft.ifft2(G.astype(np.complex64), workers=1).real.astype(np.float64)


def hrtem_filter(I32, p, mode="f64"):
    I = np.asarray(I32, dtype=np.float64)
    n = I.shape[0]
    r = radius(n)
    E = edge_window(n, r)
    sumIE = abs(np.sum(I * E))
    sumI = abs(np.sum(I))
    if mode == "f32e":  # diagnostic variant, not the registration's: the window's own mean term in float64
        Id = I - I.mean()
        FM = fwd(Id * E, "f32m") + I.mean() * np.fft.fft2(E)
        mode = "f32m"
    else:
        FM = fwd(I * E, mode)
    M = np.abs(sh(FM))  # A1
    M0 = M.copy()
    S = median_filter(M, size=3, mode="nearest")
    flags = np.zeros((n, n), dtype=bool)
    disk = r < n / 2
    pos = S > 0
    safeS = np.where(pos, S, 1.0)
    t, passes, d = 1.0, 0, 0.0  # A2
    flags_pp, margin_pp, c1 = [], [], None
    cs, flag_sets, ts = [], [], []
    while d < p["delta"] and passes < p["cycles"]:
        A = rot(M, n, r)
        c = np.where(pos, np.maximum((S - A) / safeS * 100.0, 0.0), 0.0)
        new = (c > 100.0 - t) & disk & pos  # S = 0 is never flagged (DEVIATION)
        flags |= new
        M[flags] = A[flags]
        d = 100.0 * flags.sum() / (n * n)
        passes += 1
        flags_pp.append(int(flags.sum()))
        sel = disk & pos
        margin_pp.append(float(np.min(np.abs(c[sel] - (100.0 - t)))) if sel.any() else float("inf"))
        cs.append(c)
        flag_sets.append(flags.copy())
        ts.append(t)
        if passes == 1:
            c1 = c.copy()
        t += p["step"]
    M = rot(M, n, r)  # A3
    FI = fwd(I, mode)
    W = np.abs(sh(FI))
    Wpos = W > 0
    safeW = np.where(Wpos, W, 1.0)
    a = np.where(Wpos, np.maximum((W - M) / safeW, 0.0), 0.0)  # A4 (W = 0: 0, DEVIATION)
    R = int(math.floor(n / 2 * p["pct"] / 100.0 + 0.5))
    if R > 0:
        m = r < R
        a = np.where(m, (1.0 - r / R) * 0.1 + 0.05, a)
    w = np.where(Wpos, np.maximum(a * (W + M) / safeW, 0.0), 0.0)
    if p["smoothing"]:  # A5
        bw = butterworth(n, r, p["ro"], p["order"])
        a, w = a * bw, w * bw
    absf = apply_mask_mode(I, FI, a, mode)  # A6
    wiener = apply_mask_mode(I, FI, w, mode)
    return {"M0": M0, "S": S, "c1": c1, "M": M, "W": W, "a": a, "w": w, "absf": absf, "wiener": wiener,
            "flags": flags.astype(np.float64), "passes": passes, "flags_pp": flags_pp, "margin_pp": margin_pp,
            "final_delta": d, "sumIE": float(sumIE), "sumI": float(sumI),
            "dc_absf": 1.0 - sumIE / sumI, "dc_wiener": 1.0 - (sumIE / sumI) ** 2,
            "dc_const": 1.0 - float(E.sum()) / (n * n), "cs": cs, "flag_sets": flag_sets, "ts": ts, "disk": disk,
            "pos": pos, "r": r}


def stop_rule(res, p):
    """Which rule ended the loop: 'delta' (d >= delta), 'cycles' (passes == cycles), or 'both'."""
    byd = res["final_delta"] >= p["delta"]
    byc = res["passes"] >= p["cycles"]
    return "both" if byd and byc else "delta" if byd else "cycles" if byc else "none"


def deviations(ref, emu, I):
    """Per quantity, the deviation of the emulation `emu` from the float64 reading `ref`."""
    n = I.shape[0]
    r = ref["r"]
    disk, pos = ref["disk"], ref["pos"]
    sel = disk & pos
    out = {}
    # pass-1 c, max abs over the disk, percentage points (the same pass-1 conditions: S differs a little, so c over pos)
    out["c1"] = float(np.max(np.abs(emu["c1"] - ref["c1"])[sel])) if sel.any() and ref["c1"] is not None else 0.0
    for key in ("absf", "wiener"):
        peak = float(np.max(np.abs(ref[key])))
        out[key] = float(np.max(np.abs(emu[key] - ref[key]))) / peak if peak > 0 else float("nan")
    Wref = ref["W"]
    outside = r > 0
    for key in ("W", "M", "a", "w"):
        wt = Wref * outside
        den = float(np.sum(np.abs(ref[key]) * wt))
        num = float(np.sum(np.abs(emu[key] - ref[key]) * wt))
        out[key] = num / den if den > 1e-12 * max(float(np.sum(wt)), 1e-300) else float("nan")
    # mean(out) / mean(I) is the mask at DC; the exact value is the float64 reading's mask there (for pct = 0 the registered
    # 1 - |sum I.E| / |sum I|, checked in main)
    ra = emu["absf"].mean() / I.mean()
    rw = emu["wiener"].mean() / I.mean()
    out["dc"] = max(abs(ra - ref["a"][n // 2, n // 2]), abs(rw - ref["w"][n // 2, n // 2]))
    return out


def flag_diffs(ref, emu):
    """Per common pass: the bins whose cumulative flag differs; for each, the smallest float64 margin |c - (100 - t)| over
    passes up to this one, against the c deviation of this pass (and pass 1's)."""
    rows = []
    sel = ref["disk"] & ref["pos"]
    dev1 = float(np.max(np.abs(emu["cs"][0] - ref["cs"][0])[sel])) if ref["cs"] else 0.0
    mm = None
    for j in range(min(ref["passes"], emu["passes"])):
        m = np.abs(ref["cs"][j] - (100.0 - ref["ts"][j]))
        mm = m if mm is None else np.minimum(mm, m)
        diff = ref["flag_sets"][j] != emu["flag_sets"][j]
        devj = float(np.max(np.abs(emu["cs"][j] - ref["cs"][j])[sel]))
        nd = int(diff.sum())
        rows.append({"pass": j + 1, "differ": nd, "c_dev": devj, "c_dev_pass1": dev1,
                     "min_margin_of_differing": float(mm[diff].min()) if nd else None,
                     "unexplained_by_pass_dev": int((mm[diff] >= devj).sum()) if nd else 0,
                     "unexplained_by_pass1_dev": int((mm[diff] >= dev1).sum()) if nd else 0})
    return rows


def window_mask(n, centres, half=2.0):
    """Boolean n x n mask (unshifted FFT frame, index [row-freq, col-freq]) of bins within +-half of any (kx, ky) centre,
    each centre and its Friedel mirror."""
    k = np.fft.fftfreq(n) * n
    KY, KX = k[:, None], k[None, :]
    m = np.zeros((n, n), dtype=bool)
    for (kx, ky) in centres:
        for sg in (1, -1):
            cx, cy = sg * kx, sg * ky
            # bins are integers; wrap the continuous centre to the nearest representative on the fft grid
            dx = np.abs((KX - cx + n / 2) % n - n / 2)
            dy = np.abs((KY - cy + n / 2) % n - n / 2)
            m |= (dx <= half + 1e-9) & (dy <= half + 1e-9)
    return m


def p2_quantities(I, res, meta):
    """The P2 quantities on the float64 reading. Energy = sum |FFT|^2 (unnormalised fft2) over the region, DC bin excluded.
    Passband = r <= 0.15 n (the default Butterworth's Ro * n / 2 with Ro = 0.3), outside +-2 bins (square window in k) of
    every planted wave (harmonics included) and its Friedel mirror. Kept amplitude of a wave: |out FFT| / |in FFT| at its bin
    (integer kx, ky), and for every wave sqrt(window energy out / in) over its +-2-bin window (one side)."""
    n = I.shape[0]
    k = np.fft.fftfreq(n) * n
    R = np.hypot(k[:, None], k[None, :])
    waves = meta["waves"]
    centres = [(w["kx"], w["ky"]) for w in waves]
    peaks = window_mask(n, centres)
    band = (R <= 0.15 * n) & (R > 0)
    region = band & ~peaks
    FI = np.fft.fft2(I)
    out = {"_region": region}
    for key in ("absf", "wiener"):
        FO = np.fft.fft2(res[key])
        ein, eout = float(np.sum(np.abs(FI[region]) ** 2)), float(np.sum(np.abs(FO[region]) ** 2))
        out[f"energy_ratio_{key}"] = eout / ein if ein > 0 else None
        kept = []
        for w in waves:
            ix, iy = int(round(w["kx"])) % n, int(round(w["ky"])) % n
            kx_, ky_ = w["kx"], w["ky"]
            dx = np.abs((k[None, :] - kx_ + n / 2) % n - n / 2)
            dy = np.abs((k[:, None] - ky_ + n / 2) % n - n / 2)
            one = (dx <= 2 + 1e-9) & (dy <= 2 + 1e-9)
            ew_in = float(np.sum(np.abs(FI[one]) ** 2))
            ew_out = float(np.sum(np.abs(FO[one]) ** 2))
            rec = {"kx": kx_, "ky": ky_, "harmonic": w["harmonic"], "window_ratio": math.sqrt(ew_out / ew_in)}
            if float(kx_).is_integer() and float(ky_).is_integer():
                rec["bin_ratio"] = abs(FO[iy, ix]) / abs(FI[iy, ix])
            kept.append(rec)
        out[f"kept_{key}"] = kept
        if meta.get("nyquist_wave"):
            nw = meta["nyquist_wave"]
            out[f"nyquist_kept_{key}"] = abs(FO[0, nw["kx"] % n]) / abs(FI[0, nw["kx"] % n])
    out["passband_bins"] = int(region.sum())
    return out


def finite_json(x):
    """manifest.json for a strict JSON reader: a non-finite number (an undefined deviation, the constant image's) as null."""
    if isinstance(x, float):
        return x if math.isfinite(x) else None
    if isinstance(x, dict):
        return {k: finite_json(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [finite_json(v) for v in x]
    return x


def rms(x):
    return float(np.sqrt(np.mean(x * x)))


QUANTS = ["c1", "absf", "wiener", "W", "M", "a", "w", "dc"]


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    pdir, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    t0 = time.time()
    planted = json.load(open(os.path.join(pdir, "planted.json")))
    fails = []

    def check(ok, msg):
        if not ok:
            fails.append(msg)
            print("FAIL:", msg)

    # --- rot of a radially symmetric analytic field
    for n in (128, 250):
        r = radius(n)
        f = np.exp(-(r**2) / (2.0 * 20.0**2))
        g = rot(f, n, r)
        sel = r < n / 2 - 2
        e = float(np.max(np.abs(g - f)[sel]))
        print(f"self-check rot(gaussian 20 px) n={n}: max |rot - f| at r < n/2-2 = {e:.3e}")
        check(e < 1e-3, f"rot analytic n={n} err {e}")

    cases_out = []
    p2 = []
    devs = {"f32m": {}, "f32p": {}, "f32e": {}}  # mode -> case name -> deviations
    for meta in planted["cases"]:
        name, tier, n = meta["name"], meta["tier"], meta["n"]
        params = dict(DEFAULTS)
        params.update(meta.get("params", {}))
        I32 = np.fromfile(os.path.join(pdir, f"{name}.in.f32"), dtype="<f4").reshape(n, n)
        lattice = np.fromfile(os.path.join(pdir, f"{name}.lattice.f64"), dtype="<f8").reshape(n, n)
        res = hrtem_filter(I32, params)
        res["lattice"] = lattice
        I = I32.astype(np.float64)
        clean = all(m > CLEAN_MARGIN for m in res["margin_pp"])

        # stop rule: every earlier pass stopped short of delta, the last stopped by delta or cycles
        fl = res["flags_pp"]
        ds = [100.0 * f / (n * n) for f in fl]
        rule = stop_rule(res, params)
        check(all(x < params["delta"] for x in ds[:-1]), f"{name}: stop rule (early pass already >= delta)")
        check(ds[-1] >= params["delta"] or res["passes"] == params["cycles"], f"{name}: stop rule (end)")
        if meta.get("param") == "cycles3":
            check(res["passes"] == 3 and rule == "cycles" and ds[-1] < params["delta"],
                  f"{name}: cycles3 must stop by cycles with delta not reached (passes {res['passes']}, d {ds[-1]:.3f}, rule {rule})")
        # DC prediction
        ratio_a = res["absf"].mean() / I.mean()
        ratio_w = res["wiener"].mean() / I.mean()
        c0 = n // 2
        check(abs(ratio_a - res["a"][c0, c0]) < 1e-9, f"{name}: mean ratio {ratio_a} vs a(0) {res['a'][c0, c0]}")
        check(abs(ratio_w - res["w"][c0, c0]) < 1e-9, f"{name}: mean ratio {ratio_w} vs w(0) {res['w'][c0, c0]}")
        if params["pct"] == 0.0:  # the pickup completion's exact form (the taper replaces a(0) otherwise)
            check(abs(ratio_a - res["dc_absf"]) < 1e-9, f"{name}: dc_absf {ratio_a} vs {res['dc_absf']}")
            check(abs(ratio_w - res["dc_wiener"]) < 1e-9, f"{name}: dc_wiener {ratio_w} vs {res['dc_wiener']}")
        if tier == "constant":
            check(float(np.max(np.abs(res["absf"] - res["dc_absf"] * 1000.0))) < 1e-9 * 1000.0,
                  f"{name}: constant image absf != dc_absf * 1000")
            check(abs(res["dc_absf"] - res["dc_const"]) < 1e-9, f"{name}: constant: dc_absf != dc_const")
        # round trip with mask == 1
        rt = float(np.max(np.abs(apply_mask(I, np.ones((n, n))) - I)))
        check(rt < 1e-12, f"{name}: mask==1 round trip {rt}")
        # linearity (screen-clean cases only: a flag may flip under rounding otherwise)
        if clean and n in (128, 256):
            k = 3.7
            res_k = hrtem_filter((I * k).astype(np.float64), params)
            for key in ("absf", "wiener"):
                err = float(np.max(np.abs(res_k[key] - k * res[key]))) / max(float(np.max(np.abs(k * res[key]))), 1e-300)
                check(err < 1e-9, f"{name}: linearity {key} rel {err}")
        # P2 quantities, mean removed against the mean-removed lattice
        lat = lattice - lattice.mean()
        e_in, e_a, e_w = (rms((x - x.mean()) - lat) for x in (I, res["absf"], res["wiener"]))
        p2.append((name, tier, e_in, e_a, e_w))

        # V1-6c: the Float32 emulations, their deviations, the flag differences and the P2 quantities
        case_dev = {}
        fdiffs = {}
        for mode in ("f32m", "f32p"):
            emu = hrtem_filter(I32, params, mode)
            case_dev[mode] = deviations(res, emu, I)
            devs[mode][name] = case_dev[mode]
            fdiffs[mode] = flag_diffs(res, emu)
            check(all(math.isfinite(emu[k_].mean()) for k_ in ("absf", "wiener")), f"{name}: {mode} non-finite output")
        devs["f32e"][name] = deviations(res, hrtem_filter(I32, params, "f32e"), I)
        p2q = p2_quantities(I, res, meta) if res["passes"] > 0 else {}
        extra_files = {}
        # V1-6d: the region P2 gates, in numpy's unshifted fft2 frame (rows: ky, columns: kx), for the Swift outputs.
        if "_region" in p2q:
            np.asarray(p2q.pop("_region"), dtype="<f8").tofile(os.path.join(out, f"{name}.p2region.f64"))
            extra_files["p2region"] = f"{name}.p2region.f64"
        # V1-6d: the pass at which each bin was first flagged (0: never), and every (pass, bin, float64 margin) with a
        # margin below 5 points — the flags are compared per bin and per pass against these.
        first = np.zeros((n, n))
        near = []
        for j, (cj, fj, tj) in enumerate(zip(res["cs"], res["flag_sets"], res["ts"])):
            first[(first == 0) & fj] = j + 1
            m = np.abs(cj - (100.0 - tj))
            m = np.where(res["disk"] & res["pos"], m, np.inf)
            idx = np.flatnonzero(m.ravel() < 5.0)
            near.extend((j + 1, int(i), float(m.ravel()[i])) for i in idx)
        first.astype("<f8").tofile(os.path.join(out, f"{name}.firstpass.f64"))
        np.asarray(near, dtype="<f8").reshape(-1, 3).tofile(os.path.join(out, f"{name}.nearmargins.f64"))
        extra_files["firstpass"] = f"{name}.firstpass.f64"
        extra_files["nearmargins"] = f"{name}.nearmargins.f64"
        fm = fdiffs["f32m"]
        unexp = sum(x["unexplained_by_pass_dev"] for x in fm)
        print(f"{name:18s} passes={res['passes']:3d} stop={rule:6s} flags={fl[-1]:6d} ({res['final_delta']:.2f}%) "
              f"min_margin={min(res['margin_pp']):.3e} clean={clean} | f32m c1 {case_dev['f32m']['c1']:.2e} "
              f"absf {case_dev['f32m']['absf']:.1e} M {case_dev['f32m']['M']:.1e} dc {case_dev['f32m']['dc']:.1e} "
              f"flag-diff {sum(x['differ'] for x in fm)} (unexplained {unexp}) | f32p c1 {case_dev['f32p']['c1']:.2e}")

        for key in FILES:
            np.asarray(res[key], dtype="<f8").tofile(os.path.join(out, f"{name}.{FILE_NAME.get(key, key)}.f64"))
        shutil.copyfile(os.path.join(pdir, f"{name}.in.f32"), os.path.join(out, f"{name}.in.f32"))
        cases_out.append({"name": name, "tier": tier, "n": n, "params": params, "input": f"{name}.in.f32",
                          "passes": res["passes"], "flags_per_pass": fl, "margin_per_pass": res["margin_pp"],
                          "screen_clean": clean, "final_delta": res["final_delta"], "sumIE": res["sumIE"],
                          "sumI": res["sumI"], "dc_absf": res["dc_absf"], "dc_wiener": res["dc_wiener"],
                          "dc_const": res["dc_const"],
                          "files": {**{k: f"{name}.{FILE_NAME.get(k, k)}.f64" for k in FILES}, **extra_files},
                          "near_margin_count": len(near),
                          "stop_rule": rule, "dev_f32m": case_dev["f32m"], "dev_f32p": case_dev["f32p"],
                          "flag_diffs_f32m": fdiffs["f32m"], "flag_diffs_f32p": fdiffs["f32p"], "p2": p2q,
                          "plant": meta.get("plant", tier)})

    # --- cycles stops the loop (delta unreachable)
    for meta in planted["cases"]:
        if meta["name"] == "noise-128":
            I32 = np.fromfile(os.path.join(pdir, "noise-128.in.f32"), dtype="<f4").reshape(128, 128)
            res = hrtem_filter(I32, dict(DEFAULTS, delta=50.0, cycles=3))
            print(f"self-check cycles=3 delta=50 on noise-128: passes={res['passes']}")
            check(res["passes"] == 3, "cycles stop rule")
            res0 = hrtem_filter(I32, dict(DEFAULTS, cycles=0))
            check(res0["passes"] == 0, "cycles=0 runs no pass")

    # --- the float32 emulation: rms-weighting self-check (deviations of f64 against itself are zero)
    for meta in planted["cases"][:1]:
        I32 = np.fromfile(os.path.join(pdir, f"{meta['name']}.in.f32"), dtype="<f4").reshape(meta["n"], meta["n"])
        r0 = hrtem_filter(I32, DEFAULTS)
        z = deviations(r0, hrtem_filter(I32, DEFAULTS), I32.astype(np.float64))
        check(all(v == 0.0 for v in z.values() if v == v) or max(abs(v) for v in z.values()) < 1e-12, "self-deviation not zero")

    # --- bands
    def vals(mode, q, only=None):
        return [(nm, d[q]) for nm, d in devs[mode].items() if math.isfinite(d[q]) and (only is None or only(nm))]

    ns = {c["name"]: c["n"] for c in cases_out}
    gate = lambda nm: ns[nm] in (128, 256)
    bands, table = {}, []
    for q in QUANTS:
        vm = vals("f32m", q)
        vp = vals("f32p", q)
        mm_, mp_ = max(vm, key=lambda x: x[1]), max(vp, key=lambda x: x[1])
        mg = max(v for _, v in vals("f32m", q, gate))
        nd = lambda nm: not nm.startswith(("lattice-clean", "constant"))
        mnd = max(v for _, v in vals("f32m", q, nd))
        mpn = max(v for _, v in vals("f32p", q, nd))
        mex = max(v for _, v in vals("f32e", q))
        mexnd = max(v for _, v in vals("f32e", q, nd))
        nan_m = [nm for nm, d in devs["f32m"].items() if not math.isfinite(d[q])]
        bands[q] = 3.0 * mm_[1]
        table.append({"quantity": q, "max_mean_removed": mm_[1], "at": mm_[0], "max_mean_removed_128_256": mg, "max_mean_removed_no_degenerate": mnd,
                      "max_plain_no_degenerate": mpn, "max_windowaware_diagnostic": mex, "max_windowaware_no_degenerate": mexnd,
                      "max_plain": mp_[1], "plain_at": mp_[0], "band": bands[q], "nonfinite_cases": nan_m})
    print("\nBANDS (3 x max deviation of the Float32 emulation from the float64 reading, all %d cases; c1 in percentage points, dc absolute, others relative)" % len(cases_out))
    print(f"{'quantity':9s} {'max mean-removed':>18s} {'(128/256 only)':>15s} {'max plain':>12s} {'band':>11s}  worst case (f32m) / (plain)   [no lattice-clean/constant: f32m, plain | diagnostic window-aware all, no-degenerate]")
    for t_ in table:
        print(f"{t_['quantity']:9s} {t_['max_mean_removed']:18.3e} {t_['max_mean_removed_128_256']:15.3e} {t_['max_plain']:12.3e} "
              f"{t_['band']:11.3e}  {t_['at']} / {t_['plain_at']}   [{t_['max_mean_removed_no_degenerate']:.2e}, {t_['max_plain_no_degenerate']:.2e} | {t_['max_windowaware_diagnostic']:.2e}, {t_['max_windowaware_no_degenerate']:.2e}]" + (f"  non-finite: {t_['nonfinite_cases']}" if t_['nonfinite_cases'] else ""))
    c1m = max(v for _, v in vals("f32m", "c1"))
    c1p = max(v for _, v in vals("f32p", "c1"))
    c1nd = max(v for _, v in vals("f32m", "c1", lambda nm: not nm.startswith(("lattice-clean", "constant"))))
    c1pn = max(v for _, v in vals("f32p", "c1", lambda nm: not nm.startswith(("lattice-clean", "constant"))))
    print(f"  excluding lattice-clean-128 and constant-128: mean-removed max {c1nd:.3e}, plain max {c1pn:.3e} points")
    switch = c1m > 0.05
    print(f"emulated pass-1 c error: mean-removed max {c1m:.3e} points, plain max {c1p:.3e} points (V1-6b measured 0.010-0.45); "
          f"ratio plain/mean-removed {c1p / c1m:.1f}; exceeds 0.05 points: {switch} (V1-6c's switch; superseded by V1-6d, ADR 016: the products are gated, c is printed)")
    # flags
    tot = sum(x["differ"] for c in cases_out for x in c["flag_diffs_f32m"])
    unx = sum(x["unexplained_by_pass_dev"] for c in cases_out for x in c["flag_diffs_f32m"])
    unx1 = sum(x["unexplained_by_pass1_dev"] for c in cases_out for x in c["flag_diffs_f32m"])
    print(f"flag differences f32m (cumulative, over common passes): {tot} bins; unexplained by the pass's own c deviation {unx}, by pass 1's {unx1}")

    # P2 summary
    print("\nP2 energy ratios, output / input (passband r <= 0.15 n minus DC, outside +-2 bins of every planted wave and mirror), float64 reading")
    for c in cases_out:
        q = c["p2"]
        if q and c["params"] == DEFAULTS and q["energy_ratio_absf"] is not None:
            print(f"  {c['name']:18s} absf {q['energy_ratio_absf']:.4f}  wiener {q['energy_ratio_wiener']:.4f}")
    print("\nkept amplitude (window ratio sqrt(E_out/E_in) over +-2 bins), min-max over all waves, then over fundamentals; bin ratio (integer waves) min-max")
    for c in cases_out:
        q = c["p2"]
        if q and q.get("kept_absf") and c["params"] == DEFAULTS:
            for key in ("absf", "wiener"):
                kp = q[f"kept_{key}"]
                allw = [k_["window_ratio"] for k_ in kp]
                fund = [k_["window_ratio"] for k_ in kp if not k_["harmonic"]]
                binr = [k_["bin_ratio"] for k_ in kp if "bin_ratio" in k_]
                print(f"  {c['name']:18s} {key:7s} window all {min(allw):.3f}-{max(allw):.3f}  fund {min(fund):.3f}-{max(fund):.3f}"
                      + (f"  bin {min(binr):.3f}-{max(binr):.3f}" if binr else ""))
        if q and "nyquist_kept_absf" in q and c["params"] == DEFAULTS:
            print(f"  {c['name']:18s} nyquist kept: absf {q['nyquist_kept_absf']:.3e} wiener {q['nyquist_kept_wiener']:.3e}")
    print("\nstop rule per parameter case:")
    for c in cases_out:
        if c["params"] != DEFAULTS:
            print(f"  {c['name']:18s} passes {c['passes']:3d} d {c['final_delta']:.3f}% stopped by {c['stop_rule']}")

    noisy = [x for x in p2 if x[1] in ("bin", "offbin", "ramp", "nyquist")]
    print("RMS-vs-lattice (V1-6b's measure, printed only): absf closer than input:", sum(x[3] < x[2] for x in noisy), "of", len(noisy),
          "; wiener closer:", sum(x[4] < x[2] for x in noisy), "of", len(noisy))

    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(finite_json({"numpy": np.__version__, "scipy": scipy.__version__, "cases": cases_out, "bands": bands,
                   "band_table": table, "emulated_c1_max": c1m, "emulated_c1_max_plain": c1p, "switch_to_double": switch}),
                  f, indent=1)
    print(f"numpy {np.__version__} scipy {scipy.__version__}; {len(cases_out)} cases; {time.time() - t0:.1f} s")
    if fails:
        print(f"{len(fails)} self-check(s) FAILED")
        return 1
    print("self-checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
