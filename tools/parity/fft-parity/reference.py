#!/usr/bin/env python3
"""Truth for tools/parity/fft-parity: numpy's centred spectrum, axes and checks against the plant.

    reference.py <planted-dir> <out-dir>

Reference = numpy 2.5.4 (pinned in tools/lib/references-lock.txt). For each case: x = the float32 pixels (cropped
first when the case has a crop) cast to float64; F = fftshift(fft2(x)); magnitude |F|, power |F|**2 (float64);
axis_x = fftshift(fftfreq(w, d = scale_x)), axis_y likewise (d = 1.0 when uncalibrated, unit "1/px", else "1/nm").
Writes <case>.mag.f64, .pow.f64, .ax.f64, .ay.f64 (little-endian float64), <case>.cropped.in.f32 for a crop case
(the cropped float32 pixels, for the Swift side's crop-equals-cropped-image check) and manifest.json (see
fft-contract in the session notes / README.md).

Before anything counts, numpy must agree with the PLANT (exit 1, loudly, on a disagreement -- never a pass):
  - the DC bin (h//2, w//2) equals dc * w * h;
  - every bin-centred wave (integer kx, ky) has its magnitude, within 1 % of A*w*h/2 (off-bin leakage; noise: 5 %), at (h//2 + ky,
    w//2 + kx) AND its Friedel partner (h//2 - ky, w//2 - kx), each a local maximum of the 3 x 3 neighbourhood, and
    axis_x[w//2 + kx] == kx / (w * d), axis_y likewise;
  - every off-bin wave: its nearest bin holds less than 0.9 * A*w*h/2 and no bin of the 5 x 5 window around it holds
    the bin-centred magnitude -- else the plant is wrong, not off-bin.
Crop cases get no peak checks (a cropped wave is no longer bin-centred); their `peaks` are [].

Slices B and D (archive: roadmap-registrations-2026-10-15.md V1-6 "Slices B and D"; every case has "kind": "spectrum" | "profile" | "ifft"):
  profile: dqx = 1.0 / (w * dx), dqy = 1.0 / (h * dy); shifted index (r, c) -> i = c - w//2, j = r - h//2;
    qx = i * dqx, qy = j * dqy, q = sqrt(qx*qx + qy*qy), k = floor(q / wb), wb = the case's bin width (null -> max(dqx,
    dqy)); P = |fftshift(fft2(x))|**2 in float64; mean[k] = bincount(k, P) / count[k] (0 where count is 0). Writes
    <case>.pmean.f64, <case>.pcount.i64; manifest bin_width, bin_width_given, ring_bin = floor(q0 / wb). Plant check:
    the argmax of mean[1:] (bin 0 excluded) is ring_bin.
  ifft: spots {kx, ky, r, e} (index units from the centre) and each Friedel partner (-kx, -ky): d = sqrt((i - kx)**2 +
    (j - ky)**2); m = 1 if d <= r, else 0.5 * (1 + cos(pi * (d - r) / e)) if e > 0 and d < r + e, else 0; M = max over
    all; result = ifft2(ifftshift(fftshift(fft2(x)) * M)). Writes <case>.ifft.f64 (the real part); manifest imag_max,
    real_max. Plant check: the result correlates > 0.99 with the planted component of the masked lattice, and the
    other lattice's correlation is below 0.1 (not dominant); the spots of the two lattices are further apart than
    r + e + 2 index units.
"""
import json
import math
import os
import sys

import numpy as np

NUMPY = "2.5.4"


def fail(msg):
    print("reference.py: FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


def spectrum(x):
    return np.fft.fftshift(np.fft.fft2(x))


def check_plant(c, mag, ax, ay):
    w, h, name = c["width"], c["height"], c["name"]
    d_x = c["scale_x"] if c["units"] else 1.0
    d_y = c["scale_y"] if c["units"] else 1.0
    tol = 0.05 if c["noise"] else 1e-2
    dc = mag[h // 2, w // 2]
    if abs(dc - c["dc"] * w * h) > tol * c["dc"] * w * h:
        fail("%s: DC bin %.6g, planted %.6g" % (name, dc, c["dc"] * w * h))
    peaks = []
    for v in c["waves"]:
        kx, ky, full = v["kx"], v["ky"], v["amplitude"] * w * h / 2
        if float(kx).is_integer() and float(ky).is_integer():
            kx, ky = int(kx), int(ky)
            for (r, q, sx_, sy_) in [(h // 2 + ky, w // 2 + kx, kx, ky), (h // 2 - ky, w // 2 - kx, -kx, -ky)]:
                if not (0 <= r < h and 0 <= q < w):
                    fail("%s: planted peak (%d, %d) outside the spectrum" % (name, r, q))
                val = mag[r, q]
                if abs(val - full) > tol * full:
                    fail("%s: bin-centred wave (%d, %d) magnitude %.6g at (%d, %d), planted %.6g"
                         % (name, kx, ky, val, r, q, full))
                win = mag[max(r - 1, 0):r + 2, max(q - 1, 0):q + 2]
                if win.max() > val:
                    fail("%s: bin-centred wave (%d, %d) is not a local maximum at (%d, %d)" % (name, kx, ky, r, q))
                if abs(ax[q] - sx_ / (w * d_x)) > 1e-12 * abs(ax).max() or abs(ay[r] - sy_ / (h * d_y)) > 1e-12 * abs(ay).max():
                    fail("%s: axes at the planted peak (%d, %d) are %.9g, %.9g, want %.9g, %.9g"
                         % (name, r, q, ax[q], ay[r], sx_ / (w * d_x), sy_ / (h * d_y)))
                peaks.append([r, q])
        else:
            r0, q0 = int(round(h // 2 + ky)), int(round(w // 2 + kx))
            if not (0 <= r0 < h and 0 <= q0 < w):
                fail("%s: off-bin wave outside the spectrum" % name)
            if mag[r0, q0] >= 0.9 * full:
                fail("%s: off-bin wave (%g, %g) puts %.6g (>= 0.9 of %.6g) in its nearest bin: the plant is bin-centred"
                     % (name, kx, ky, mag[r0, q0], full))
            win = mag[max(r0 - 2, 0):r0 + 3, max(q0 - 2, 0):q0 + 3]
            if win.max() >= 0.99 * full:
                fail("%s: off-bin wave (%g, %g) has a bin-centred peak %.6g near it: the plant is wrong"
                     % (name, kx, ky, win.max()))
    return peaks


def dqs(w, h, dx, dy):
    return 1.0 / (w * dx), 1.0 / (h * dy)


def profile(P, w, h, dx, dy, wb):
    """Mean power and pixel count per radial bin of a shifted w x h power spectrum (contract order of operations)."""
    dqx, dqy = dqs(w, h, dx, dy)
    ii = (np.arange(w) - w // 2)[None, :]
    jj = (np.arange(h) - h // 2)[:, None]
    qx = ii * dqx
    qy = jj * dqy
    q = np.sqrt(qx * qx + qy * qy)
    k = np.floor(q / wb).astype(np.int64)
    count = np.bincount(k.ravel())
    tot = np.bincount(k.ravel(), weights=P.ravel())
    mean = np.divide(tot, count, out=np.zeros_like(tot), where=count > 0)
    return mean, count.astype(np.int64)


def spot_mask(w, h, spots):
    ii = (np.arange(w) - w // 2)[None, :].astype(np.float64)
    jj = (np.arange(h) - h // 2)[:, None].astype(np.float64)
    M = np.zeros((h, w))
    for s in spots:
        for (kx, ky) in [(s["kx"], s["ky"]), (-s["kx"], -s["ky"])]:
            d = np.sqrt((ii - kx) ** 2 + (jj - ky) ** 2)
            m = np.zeros((h, w))
            m[d <= s["r"]] = 1.0
            if s["e"] > 0:
                edge = (d > s["r"]) & (d < s["r"] + s["e"])
                m[edge] = 0.5 * (1 + np.cos(np.pi * (d[edge] - s["r"]) / s["e"]))
            M = np.maximum(M, m)
    return M


def lattice_image(c, lat):
    w, h = c["width"], c["height"]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    img = np.zeros((h, w))
    for v in c["waves"]:
        if v["lattice"] == lat:
            img += v["amplitude"] * np.cos(2 * np.pi * (v["kx"] * xx / w + v["ky"] * yy / h) + v["phase"])
    return img


def corr(a, b):
    a, b = a - a.mean(), b - b.mean()
    return float((a * b).sum() / math.sqrt((a * a).sum() * (b * b).sum()))


def profile_case(c, px, pdir, out):
    name, w, h = c["name"], c["width"], c["height"]
    calibrated = bool(c["units"])
    dx = c["scale_x"] if calibrated else 1.0
    dy = c["scale_y"] if calibrated else 1.0
    dqx, dqy = dqs(w, h, dx, dy)
    given = c["bin_width"]
    wb = given if given is not None else max(dqx, dqy)
    P = np.abs(spectrum(px.astype(np.float64))) ** 2
    mean, count = profile(P, w, h, dx, dy, wb)
    if count.sum() != w * h or count[0] < 1:
        fail("%s: profile counts %d, want %d" % (name, count.sum(), w * h))
    q0 = c["ring"]["q0"]
    ring_bin = int(math.floor(q0 / wb))
    got = int(np.argmax(mean[1:])) + 1
    if got != ring_bin:
        fail("%s: the ring peaks in bin %d (bin 0 excluded), planted |q0| = %g is in bin %d (width %g)"
             % (name, got, q0, ring_bin, wb))
    srt = np.sort(mean[1:])
    if srt[-1] < 1.2 * srt[-2]:
        fail("%s: the ring peak %.6g is not 1.2x the next bin %.6g: a weak plant" % (name, srt[-1], srt[-2]))
    pm, pc = os.path.join(out, name + ".pmean.f64"), os.path.join(out, name + ".pcount.i64")
    np.ascontiguousarray(mean, dtype="<f8").tofile(pm)
    np.ascontiguousarray(count, dtype="<i8").tofile(pc)
    return {"name": name, "kind": "profile", "input": os.path.join(pdir, name + ".in.f32"), "width": w, "height": h,
            "scale_x": c["scale_x"], "scale_y": c["scale_y"], "units": c["units"], "crop": None,
            "out_width": w, "out_height": h, "pmean": pm, "pcount": pc, "bin_width": wb, "bin_width_given": given,
            "ring_bin": ring_bin, "nbins": int(count.size), "axis_units": "1/nm" if calibrated else "1/px",
            "peaks": [], "crop_of": None}


def ifft_case(c, px, pdir, out):
    name, w, h = c["name"], c["width"], c["height"]
    spots = c["spots"]
    # the plant: spots of different lattices must not touch each other's mask windows
    for a in c["waves"]:
        for b in c["waves"]:
            if a is b:
                continue
            sa = [s for s in spots if (s["kx"], s["ky"]) == (a["kx"], a["ky"])]
            for pt in [(b["kx"], b["ky"]), (-b["kx"], -b["ky"])]:
                if sa and pt != (a["kx"], a["ky"]):
                    d = math.hypot(a["kx"] - pt[0], a["ky"] - pt[1])
                    if d < sa[0]["r"] + sa[0]["e"] + 2:
                        fail("%s: wave (%g, %g) is %.3g from a masked spot (window %g): spots overlap"
                             % (name, pt[0], pt[1], d, sa[0]["r"] + sa[0]["e"]))
    x = px.astype(np.float64)
    M = spot_mask(w, h, spots)
    res = np.fft.ifft2(np.fft.ifftshift(spectrum(x) * M))
    real, imag_max, real_max = res.real, float(np.abs(res.imag).max()), float(np.abs(res.real).max())
    lat = c["mask_lattice"]
    other = "B" if lat == "A" else "A"
    ca, cb = corr(real, lattice_image(c, lat)), corr(real, lattice_image(c, other))
    if not ca > 0.99:
        fail("%s: the masked inverse correlates %.5f with the planted lattice %s (need > 0.99)" % (name, ca, lat))
    if not abs(cb) < 0.1:
        fail("%s: the masked inverse correlates %.5f with the other lattice %s (need |.| < 0.1)" % (name, cb, other))
    if not imag_max <= 1e-9 * real_max:
        fail("%s: imag max %.3g not tiny against real max %.3g: the mask is not Friedel-symmetric"
             % (name, imag_max, real_max))
    pf = os.path.join(out, name + ".ifft.f64")
    np.ascontiguousarray(real, dtype="<f8").tofile(pf)
    return {"name": name, "kind": "ifft", "input": os.path.join(pdir, name + ".in.f32"), "width": w, "height": h,
            "scale_x": c["scale_x"], "scale_y": c["scale_y"], "units": c["units"], "crop": None,
            "out_width": w, "out_height": h, "ifft": pf, "spots": spots, "mask_lattice": lat,
            "imag_max": imag_max, "real_max": real_max, "corr_masked": ca, "corr_other": cb,
            "peaks": [], "crop_of": None}


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(64)
    pdir, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    if np.__version__ != NUMPY:
        fail("numpy %s, pinned %s (tools/lib/references-lock.txt)" % (np.__version__, NUMPY))
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(pdir, "planted.json")) as f:
        planted = json.load(f)["cases"]
    cases = []
    for c in planted:
        name, w, h = c["name"], c["width"], c["height"]
        px = np.fromfile(os.path.join(pdir, name + ".in.f32"), dtype="<f4")
        if px.size != w * h:
            fail("%s: input has %d pixels, want %d" % (name, px.size, w * h))
        px = px.reshape(h, w)
        kind = c["kind"]
        if kind == "profile":
            cases.append(profile_case(c, px, pdir, out))
            continue
        if kind == "ifft":
            cases.append(ifft_case(c, px, pdir, out))
            continue
        if kind != "spectrum":
            fail("%s: unknown kind %r" % (name, kind))
        cr = c["crop"]
        if cr:
            if not (0 <= cr["row"] and cr["row"] + cr["height"] <= h and 0 <= cr["col"] and cr["col"] + cr["width"] <= w):
                fail("%s: crop outside the image" % name)
            px = np.ascontiguousarray(px[cr["row"]:cr["row"] + cr["height"], cr["col"]:cr["col"] + cr["width"]])
            px.astype("<f4").tofile(os.path.join(out, name + ".cropped.in.f32"))
        ow, oh = px.shape[1], px.shape[0]
        calibrated = bool(c["units"])
        dx = c["scale_x"] if calibrated else 1.0
        dy = c["scale_y"] if calibrated else 1.0
        F = spectrum(px.astype(np.float64))
        mag = np.abs(F)
        pw = mag ** 2
        ax = np.fft.fftshift(np.fft.fftfreq(ow, d=dx))
        ay = np.fft.fftshift(np.fft.fftfreq(oh, d=dy))
        peaks = [] if cr else check_plant(c, mag, ax, ay)
        files = {}
        for key, ext, arr in [("magnitude", "mag", mag), ("power", "pow", pw), ("axis_x", "ax", ax), ("axis_y", "ay", ay)]:
            p = os.path.join(out, "%s.%s.f64" % (name, ext))
            np.ascontiguousarray(arr, dtype="<f8").tofile(p)
            files[key] = p
        cases.append({"name": name, "kind": "spectrum", "input": os.path.join(pdir, name + ".in.f32"), "width": w, "height": h,
                      "scale_x": c["scale_x"], "scale_y": c["scale_y"], "units": c["units"], "crop": cr,
                      "out_width": ow, "out_height": oh, **files,
                      "axis_units": "1/nm" if calibrated else "1/px", "peaks": peaks, "crop_of": c["crop_of"]})
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump({"numpy": np.__version__, "cases": cases}, f, indent=1)
    print("reference.py: numpy %s, %d cases, plant checks passed" % (np.__version__, len(cases)))


if __name__ == "__main__":
    main()
