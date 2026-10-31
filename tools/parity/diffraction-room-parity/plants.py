#!/usr/bin/env python3
"""Planted rings for tools/parity/diffraction-room-parity (archive: roadmap-registrations-2026-10-15.md "Diffraction room, slice 1a: the core and
tools/parity/diffraction-room-parity", clauses R1, R2, R4, R8). The numpy side of the harness; no Swift is read or measured.

    plants.py <out-dir> [--r8 full|half] [--no-rfp]

SEEDS, FIXED HERE BEFORE ANY RUN (2026-10-15, lane P of session 22da3599). They are the only randomness in the harness.
    SEED_R8_GEOM  = 2026101581   R8 geometry: the ring centre's sub-pixel offset, theta, the start-centre direction, the
                                 click's azimuth and the sign of its radial error
    SEED_R8_NOISE = 2026101582   R8 noise realisation, one per image
Every random draw is numpy's `default_rng` seeded from SHA-256("<seed>|<key>") (first 8 bytes), the key naming the image
or the cell by its parameters, so a draw never depends on how many cells exist or on their order: a subsampled grid
draws the same numbers for the cells it keeps. R1 and R4 have no random element (ring-fit-parity's centre(H, W, k), a
deterministic function of an index k: R1's new plants use k = 1000 + i, R4's k = 2000 + i). Nothing in this file may change
after R8's first print; a change is a new registration.

WHAT IT WRITES (all under <out-dir>, never committed; every image is raw little-endian float32, row-major, columns fastest,
`<name>.f32`; the manifest `manifest.json` carries every number the Swift side needs, floats as `%.17g`)
    rfp/        ring-fit-parity's own plants.py, called unchanged (its scipy optimum switched off: not used here): the 275
                plants R2 runs on, `rfp/planted.json` as it writes it.
    r1/         R1's new plants: theta {0, 30, 90, 135} deg x ellipticity {1, 3 %} x R 80-200 px x 512x384 and 640x512
                = 48. R1's clean tier is ring-fit-parity's 84 clean plants: the manifest lists them from rfp/ unchanged.
    r4/         R4's two-ring plants: ring 1 (Au {111}, {200} or {220} as the calibration ring) and ring 2 (the next
                family) at its physical radius R2 = L_px tan(2 asin(lambda g2 / 2)), L_px from ring 1: 48 plants.
    r8/         R8's images: 144, one per (R, ellipticity, noise, neighbour ratio); the 10368 cells (the full grid) reference
                them and add the cell's start centre, click and half-width. Nothing is fitted here.
Conventions. A case's (r0, c0) is (ROW, COLUMN) of the planted centre; `x_truth` = c0 and `y_truth` = r0 are the same
point as the app holds it (x = column, y = row). The ellipse is ring-fit-parity's: the major axis a along (cos t, sin t) in
(row, column), u = dr cos t + dc sin t, v = -dr sin t + dc cos t, u^2/a^2 + v^2/b^2 = 1, R = (a + b)/2 exactly. Rings are
exp(-((rho - 1) R)^2 / 2 s^2), s = 3 px, peak 1; a neighbour ring is the same shape scaled by the factor in the elliptical
radius, amplitude 0.5 (ring-fit-parity's `neighbour`); noise is Gaussian of the stated fraction of the peak (1).

R4's ratios. The registration names ratios 1.155, 1.41 and 1.17. Au's families are {200}/{111} = 1.1547, {220}/{200} = 1.4142
and {311}/{220} = 1.1726; the plants are those three physical pairs (the calibration ring and the next family), with ring 2
at the flat-detector radius of its own g, because the check is "the predicted ring lies within 0.5 px of the planted one" and
planting the rounded 1.41 would put the truth 0.9 px (R1 = 150) from the physical position by construction. R8's neighbours
are the registered ratios literally (1.06, 1.155, 1.17): there the neighbour is a trap, not a prediction.

R8's grid. R {40, 80, 150, 300} x ellipticity {0, 1, 3 %} x noise {0, 3, 10 %} x start-centre error {0, 5, 10, 20, 40, 60} px x
click error {0, 2, 5 % of R} x half-width factor f {0.03, 0.06, 0.10, 0.15} x neighbour {none, 1.06, 1.155, 1.17}
= 4*3*3*6*3*4*4 = 10368 cells over 144 images. Per cell: the start centre = true centre + error * (cos psi, sin psi) in (row,
column); the click = the ring point at azimuth phi pushed radially out (or in) from the true centre by click% * R; the click
radius = |click - start|; half-width = clamp(f * click radius, 10, 40) px; band = [click radius - hw, click radius + hw] about
the start centre (the design's seed rule, archive: diffraction-room-design-2026-10-15.md section 0; the Swift rule is
compared to this, not assumed equal). The band-rule subset (the rule's stated cells): start <= 20 px, click <= 5 %, noise <= 3 %,
neighbour none / 1.155 / 1.17, R 80-300 = 3*3*2*4*3*4*3 = 2592 cells. `--r8 half` keeps all of them and one in three of the
others (decided by the cell key's hash, so it is the same cells every run): 2592 + 2592 = about 5184. Controls (two, as
registered): the standard cell with the truth shifted 1 px must read accepted-wrong; the empty image must read thrown.
"""
import hashlib
import importlib.util
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))

SEED_R8_GEOM = 2026101581
SEED_R8_NOISE = 2026101582

R1_K0 = 1000
R4_K0 = 2000
SIGMA = 3.0
NEIGHBOUR_AMP = 0.5
GUESS = (1.3, -0.9)
MARGIN = 20.0

R1_THETAS = (0.0, 30.0, 90.0, 135.0)
R1_ELLIPTICITIES = (0.01, 0.03)
R1_SIZES = (((384, 512), (80, 120, 160)), ((512, 640), (80, 140, 200)))      # (rows, cols), radii

AU_A = 4.0782
R4_PAIRS = (("1.155", (1, 1, 1), (2, 0, 0)), ("1.41", (2, 0, 0), (2, 2, 0)), ("1.17", (2, 2, 0), (3, 1, 1)))
R4_VOLTS = (80000.0, 200000.0, 300000.0)
R4_THETAS = (0.0, 30.0, 90.0, 135.0)
R4_ELLIPTICITIES = (0.01, 0.03)
R4_RADII = ((80, (384, 512)), (150, (512, 640)))

R8_R = (40, 80, 150, 300)
R8_ELL = (0.0, 0.01, 0.03)
R8_NOISE = (0.0, 0.03, 0.10)
R8_START = (0, 5, 10, 20, 40, 60)
R8_CLICK = (0.0, 0.02, 0.05)
R8_F = (0.03, 0.06, 0.10, 0.15)
R8_NEIGH = (None, 1.06, 1.155, 1.17)
HW_MIN, HW_MAX = 10.0, 40.0


# ---------------------------------------------------------------------------------------------------------- helpers
def load_rfp():
    path = os.path.join(HERE, "ring_fit_plants.py")
    spec = importlib.util.spec_from_file_location("ring_fit_plants", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.scipy_optimum = lambda img, case: None          # the scipy optimum is printed by ring-fit-parity, unused here
    return mod


def jfloat(x):
    x = float(x)
    if math.isnan(x):
        return '"NaN"'
    if math.isinf(x):
        return '"Infinity"' if x > 0 else '"-Infinity"'
    return "%.17g" % x


def dumps(o, indent=0):
    """JSON with every float as %.17g (the round-trip-exact decimal), NaN/Inf as strings; numpy scalars accepted."""
    pad = "  " * indent
    if isinstance(o, dict):
        if not o:
            return "{}"
        return "{\n" + ",\n".join("%s  %s: %s" % (pad, json.dumps(str(k)), dumps(v, indent + 1)) for k, v in o.items()) + "\n" + pad + "}"
    if isinstance(o, (list, tuple)):
        if not o:
            return "[]"
        if all(isinstance(v, (int, float, np.floating, np.integer)) and not isinstance(v, bool) for v in o):
            return "[" + ", ".join(dumps(v) for v in o) + "]"
        return "[\n" + ",\n".join(pad + "  " + dumps(v, indent + 1) for v in o) + "\n" + pad + "]"
    if isinstance(o, (bool, np.bool_)):
        return "true" if o else "false"
    if isinstance(o, (np.integer,)) or (isinstance(o, int) and not isinstance(o, bool)):
        return str(int(o))
    if isinstance(o, (float, np.floating)):
        return jfloat(o)
    if o is None:
        return "null"
    return json.dumps(o)


def rng_for(seed, key):
    h = hashlib.sha256(("%d|%s" % (seed, key)).encode()).digest()
    return np.random.default_rng(int.from_bytes(h[:8], "big"))


def write_f32(path, img):
    np.asarray(img).astype("<f4").tofile(path)


def case_fields(rfp, name, Hh, W, k, R, eps, theta_deg, extra=None):
    """The record of one planted ring in ring-fit-parity's conventions (centre by its deterministic centre(H, W, k))."""
    a, b = rfp.axes(R, eps)
    theta = None if eps == 0 else math.radians(theta_deg)
    r0, c0 = rfp.centre(Hh, W, k)
    rec = dict(name=name, file=None, rows=Hh, cols=W, r0=r0, c0=c0, x_truth=c0, y_truth=r0, R=float(R), a=a, b=b,
               theta=theta, theta_deg=float(theta_deg) if eps != 0 else None, eps=eps, sigma=SIGMA,
               inner=b - MARGIN, outer=a + MARGIN, guess_row=r0 + GUESS[0], guess_col=c0 + GUESS[1])
    if extra:
        rec.update(extra)
    return rec, a, b, (theta or 0.0), r0, c0


# -------------------------------------------------------------------------------------------------------------- R1
def make_r1(rfp, out, rfp_planted):
    os.makedirs(os.path.join(out, "r1"), exist_ok=True)
    cases = []
    for c in rfp_planted["cases"]:
        if c["tier"] == "clean":
            cases.append(dict(c, group="rfp-clean", file="rfp/" + c["file"], x_truth=c["c0"], y_truth=c["r0"]))
    n_clean = len(cases)
    i = 0
    for (Hh, W), radii in R1_SIZES:
        for R in radii:
            for eps in R1_ELLIPTICITIES:
                for t in R1_THETAS:
                    name = "r1-%dx%d-r%g-e%g-t%g" % (Hh, W, R, eps * 100, t)
                    rec, a, b, theta, r0, c0 = case_fields(rfp, name, Hh, W, R1_K0 + i, R, eps, t)
                    img = rfp.render(Hh, W, r0, c0, a, b, theta, 0.0, 0.0, s=SIGMA)
                    rec["file"] = "r1/" + name + ".f32"
                    rec["group"] = "r1-theta"
                    write_f32(os.path.join(out, rec["file"]), img)
                    cases.append(rec)
                    i += 1
    return cases, n_clean, i


# -------------------------------------------------------------------------------------------------------------- R4
def make_r4(rfp, out):
    os.makedirs(os.path.join(out, "r4"), exist_ok=True)
    cases = []
    i = 0
    for label, hkl1, hkl2 in R4_PAIRS:
        d1 = AU_A / math.sqrt(sum(v * v for v in hkl1))
        d2 = AU_A / math.sqrt(sum(v * v for v in hkl2))
        for R1, (Hh, W) in R4_RADII:
            for eps in R4_ELLIPTICITIES:
                for t in R4_THETAS:
                    volts = R4_VOLTS[i % len(R4_VOLTS)]
                    lam = rfp.wavelength(volts)
                    tt1 = 2.0 * math.asin(lam / (2.0 * d1))
                    tt2 = 2.0 * math.asin(lam / (2.0 * d2))
                    L = R1 / math.tan(tt1)
                    R2 = L * math.tan(tt2)
                    f = R2 / R1
                    name = "r4-p%s-%dx%d-r%g-e%g-t%g" % (label, Hh, W, R1, eps * 100, t)
                    rec, a, b, theta, r0, c0 = case_fields(rfp, name, Hh, W, R4_K0 + i, R1, eps, t)
                    img = rfp.render(Hh, W, r0, c0, a, b, theta, 0.0, 0.0, s=SIGMA, neighbour=(f, NEIGHBOUR_AMP))
                    hw = min(max(0.06 * R1, HW_MIN), HW_MAX)
                    rec.update(file="r4/" + name + ".f32", group="r4", pair=label, hkl1="%d%d%d" % hkl1,
                               hkl2="%d%d%d" % hkl2, a_lattice=AU_A, d1=d1, d2=d2, volts=volts, pitch_mm=0.014,
                               lambda_A=lam, length_px=L, ring2_R=R2, ring2_factor=f, ring2_a=a * f, ring2_b=b * f,
                               ring2_theta=rec["theta"], ring2_r0=r0, ring2_c0=c0, neighbour_amp=NEIGHBOUR_AMP,
                               rule_half_width=hw, rule_inner=R1 - hw, rule_outer=R1 + hw)
                    write_f32(os.path.join(out, rec["file"]), img)
                    cases.append(rec)
                    i += 1
    return cases


# -------------------------------------------------------------------------------------------------------------- R8
def r8_size(R):
    return int(math.ceil(2.0 * (1.2 * 1.03 * R + 80.0) / 32.0)) * 32


def img_key(R, eps, noise, neigh):
    return "R%g-e%g-n%g-nb%s" % (R, eps * 100, noise * 100, "none" if neigh is None else "%g" % neigh)


def cell_key(ik, start, click, f):
    return "%s-s%g-c%g-f%g" % (ik, start, click * 100, f)


def in_band_subset(R, noise, start, click, neigh):
    return start <= 20 and click <= 0.05 and noise <= 0.03 and neigh in (None, 1.155, 1.17) and 80 <= R <= 300


def keeps_in_half(key):
    return int.from_bytes(hashlib.sha256(("keep|" + key).encode()).digest()[:4], "big") % 3 == 0


def ring_radius_at(a, b, theta, phi):
    """The ellipse's radius from its centre at azimuth phi (row = r cos phi, column = r sin phi)."""
    d = phi - theta
    return 1.0 / math.sqrt(math.cos(d) ** 2 / (a * a) + math.sin(d) ** 2 / (b * b))


def make_r8(rfp, out, mode):
    os.makedirs(os.path.join(out, "r8"), exist_ok=True)
    images, cells = {}, []
    n_full = 0
    for R in R8_R:
        n = r8_size(R)
        for eps in R8_ELL:
            for noise in R8_NOISE:
                for neigh in R8_NEIGH:
                    ik = img_key(R, eps, noise, neigh)
                    g = rng_for(SEED_R8_GEOM, "img|" + ik)
                    ur, uc = g.uniform(-3.0, 3.0, 2)
                    theta_deg = float(g.uniform(0.0, 180.0)) if eps != 0 else 0.0
                    r0, c0 = n / 2.0 + float(ur), n / 2.0 + float(uc)
                    a, b = rfp.axes(R, eps)
                    theta = math.radians(theta_deg) if eps != 0 else 0.0
                    images[ik] = dict(key=ik, file="r8/img-%s.f32" % ik, rows=n, cols=n, r0=r0, c0=c0, a=a, b=b,
                                      theta=(theta if eps != 0 else None), theta_deg=(theta_deg if eps != 0 else None), R=float(R), eps=eps,
                                      noise=noise, neighbour=neigh, neighbour_amp=(NEIGHBOUR_AMP if neigh else None),
                                      sigma=SIGMA, x_truth=c0, y_truth=r0)
                    for start in R8_START:
                        for click in R8_CLICK:
                            for f in R8_F:
                                n_full += 1
                                key = cell_key(ik, start, click, f)
                                subset = in_band_subset(R, noise, start, click, neigh)
                                if mode == "half" and not subset and not keeps_in_half(key):
                                    continue
                                cg = rng_for(SEED_R8_GEOM, "cell|" + key)
                                psi, phi = cg.uniform(0.0, 2 * math.pi, 2)
                                sign = 1.0 if cg.integers(0, 2) == 1 else -1.0
                                srow, scol = r0 + start * math.cos(psi), c0 + start * math.sin(psi)
                                rc = ring_radius_at(a, b, theta, phi) + sign * click * R
                                krow, kcol = r0 + rc * math.cos(phi), c0 + rc * math.sin(phi)
                                crad = math.hypot(krow - srow, kcol - scol)
                                hw = min(max(f * crad, HW_MIN), HW_MAX)
                                cells.append(dict(key=key, image=ik, R=float(R), eps=eps, noise=noise, neighbour=neigh,
                                                  start_px=float(start), click_pct=click * 100.0, f=f,
                                                  start_row=srow, start_col=scol, start_dir_rad=float(psi),
                                                  click_row=krow, click_col=kcol, click_azimuth_rad=float(phi),
                                                  click_sign=sign, click_radius=crad, half_width=hw,
                                                  inner=max(crad - hw, 0.0), inner_raw=crad - hw, outer=crad + hw,
                                                  band_pixels=4.0 * math.pi * crad * hw, in_band_subset=subset))
    # images (every image a kept cell uses)
    used = sorted({c["image"] for c in cells})
    for ik in used:
        im = images[ik]
        n = im["rows"]
        img = rfp.render(n, n, im["r0"], im["c0"], im["a"], im["b"], im["theta"] or 0.0, 0.0, 0.0, s=SIGMA,
                         neighbour=(im["neighbour"], NEIGHBOUR_AMP) if im["neighbour"] else None)
        if im["noise"] > 0:
            img = img + rng_for(SEED_R8_NOISE, "noise|" + ik).normal(0.0, im["noise"], img.shape)
        write_f32(os.path.join(out, im["file"]), img)
    # the controls
    std_img = img_key(150, 0.01, 0.0, None)
    std = next(c for c in cells if c["key"] == cell_key(std_img, 0, 0.0, 0.06))      # in the band-rule subset: kept in both modes
    controls = [dict(name="truth-shifted-1px", cell=std["key"], truth_radius_shift_px=1.0, expect="acceptedWrong",
                     note="the standard cell must be accepted and right unshifted; with the truth radius +1 px it must read accepted-wrong"),
                dict(name="empty-image", file="r8/control-empty.f32", rows=images[std_img]["rows"], cols=images[std_img]["cols"],
                     start_row=images[std_img]["r0"], start_col=images[std_img]["c0"], click_row=images[std_img]["r0"],
                     click_col=images[std_img]["c0"] + 150.0, half_width=10.0, expect="thrown",
                     note="an all-zero image: the fit throws (ring-fit-parity's insufficientSignal)")]
    write_f32(os.path.join(out, "r8", "control-empty.f32"), np.zeros((images[std_img]["rows"], images[std_img]["cols"])))
    return images, cells, controls, n_full, len(used)


def estimate(cells, n_full):
    """The fit-time estimate, never a measurement: the band's pixels (4 pi r hw) x a per-pixel cost of 10, 30 or 100 us (the
    design's probes on a loaded Mac: 66 s for 0.68 M band pixels, 11.6 s for 0.30 M = 97 and 38 us; the kit's note, a few
    hundred ms at R 100, is about 20 us), and the registration's own 0.04-2 s per fit."""
    areas = np.array([c["band_pixels"] for c in cells])
    est = dict(cells=len(cells), full_grid_cells=n_full, band_pixels_total=float(areas.sum()),
               band_pixels_median=float(np.median(areas)), band_pixels_max=float(areas.max()),
               registered_per_fit_s=(0.04, 2.0))
    est["serial_hours_at_registered_bounds"] = (len(cells) * 0.04 / 3600.0, len(cells) * 2.0 / 3600.0)
    est["wall_minutes_8_jobs_at_registered_bounds"] = (len(cells) * 0.04 / 8 / 60.0, len(cells) * 2.0 / 8 / 60.0)
    for us in (10, 30, 100):
        est["wall_minutes_8_jobs_at_%d_us_per_band_pixel" % us] = float(areas.sum() * us * 1e-6 / 8 / 60.0)
    return est


def main(out, mode="full", with_rfp=True):
    os.makedirs(out, exist_ok=True)
    rfp = load_rfp()
    rfp_dir = os.path.join(out, "rfp")
    if with_rfp:
        rfp.main(rfp_dir)
    with open(os.path.join(rfp_dir, "planted.json")) as fh:
        rfp_planted = json.load(fh)
    r1, n_clean, n_new = make_r1(rfp, out, rfp_planted)
    r4 = make_r4(rfp, out)
    images, cells, controls, n_full, n_img = make_r8(rfp, out, mode)
    summary = dict(r1_clean=n_clean, r1_new=n_new, r4=len(r4), r8_images=n_img, r8_cells_full=n_full, r8_cells_written=len(cells),
                   r8_band_subset=sum(1 for c in cells if c["in_band_subset"]))
    manifest = dict(numpy=np.__version__, seeds=dict(SEED_R8_GEOM=SEED_R8_GEOM, SEED_R8_NOISE=SEED_R8_NOISE,
                                                     R1_K0=R1_K0, R4_K0=R4_K0),
                    sigma=SIGMA, margin=MARGIN, guess=list(GUESS), r8_mode=mode, summary=summary,
                    r1=r1, r4=r4,
                    r8=dict(images=list(images.values()), cells=cells, controls=controls,
                            grid=dict(R=R8_R, ellipticity=R8_ELL, noise=R8_NOISE, start_px=R8_START, click_pct=[c * 100 for c in R8_CLICK],
                                      f=R8_F, neighbour=[n for n in R8_NEIGH if n is not None] + ["none"],
                                      half_width_clamp=[HW_MIN, HW_MAX], neighbour_amp=NEIGHBOUR_AMP),
                            band_rule=dict(start_px_max=20, click_pct_max=5, noise_max=0.03, neighbours=["none", 1.155, 1.17],
                                           R_range=[80, 300], right_if="accepted and |dR|/R < 0.001"),
                            estimate=estimate(cells, n_full)))
    with open(os.path.join(out, "manifest.json"), "w") as fh:
        fh.write(dumps(manifest) + "\n")
    print("plants: R1 %d (%d ring-fit-parity clean + %d new), R4 %d, R8 %d cells written of %d (%d images, %d in the band-rule subset) in %s"
          % (len(r1), n_clean, n_new, len(r4), len(cells), n_full, n_img, summary["r8_band_subset"], out))


if __name__ == "__main__":
    args = sys.argv[1:]
    mode, with_rfp = "full", True
    if "--r8" in args:
        i = args.index("--r8")
        mode = args[i + 1]
        del args[i:i + 2]
        if mode not in ("full", "half"):
            sys.exit(__doc__)
    if "--no-rfp" in args:
        args.remove("--no-rfp")
        with_rfp = False
    if len(args) != 1:
        print(__doc__)
        sys.exit(64)
    main(args[0], mode, with_rfp)
