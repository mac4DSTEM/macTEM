#!/usr/bin/env python3
"""Reference arrays for TEMCore's `PatternProcessing` (static and dynamic background removal of EBSD patterns) from
kikuchipy 0.13.1, the pinned Python reference of the SEM program (docs/sem/plan.md, docs/parity.md).

    python3 -I background_reference.py --data patterns_v2.h5 --out ../../../macTEMTests/Fixtures/sem/background
    python3 -I background_reference.py --data patterns_v2.h5 --whole-set "$MACEM_DATA/sem/nickel_ebsd_large"

`--out` writes the per-pattern fixtures the unit tests (macTEMTests/SEMBackgroundParityTests.swift) read: pattern (0, 0) and
pattern (27, 37) of kikuchipy's nickel_ebsd_large (Aanes et al. 2020, CC BY 4.0; docs/data-sources.md) and the file's static
background, raw little-endian arrays named `<case>.u8` / `<case>.f32` beside `manifest.json` (shapes, parameters, pins, and the
sha256 of every array). `--whole-set` writes the opt-in whole-set references (all 4125 patterns, 15 MB each) the same test
reads from `$MACEM_DATA` when they are there. Every case is kikuchipy's own function on kikuchipy's own float32 path, so the
fixtures carry its float32 rounding; the Swift side is float64 and matches within the tolerance stated in docs/parity.md.
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path

import h5py
import numpy as np
import scipy
from scipy.ndimage import gaussian_filter

import kikuchipy as kp
from kikuchipy.filters.fft_barnes import _fft_filter
from kikuchipy.pattern._pattern import (
    _dynamic_background_frequency_space_setup,
    _remove_background_divide,
    _remove_background_subtract,
    _remove_dynamic_background,
    _remove_static_background_divide,
    _remove_static_background_subtract,
    get_dynamic_background,
)

PINS = {"kikuchipy": "0.13.1", "numpy": "2.5.4", "scipy": "1.18.1"}
DATASET = "nickel_ebsd_large/patterns_v2.h5"
PATTERNS = [(0, 0), (27, 37)]  # (row, column) in the 55 x 75 map: the north-star pattern of figure F2, and one from the middle


def check_pins():
    have = {"kikuchipy": kp.__version__, "numpy": np.__version__, "scipy": scipy.__version__}
    bad = {k: (v, have[k]) for k, v in PINS.items() if have[k] != v}
    if bad:
        sys.exit(f"background_reference.py: pinned versions differ (want, have): {bad}")


def load(path):
    with h5py.File(path, "r") as f:
        patterns = f["Scan 1/EBSD/Data/patterns"][()]
        background = f["Scan 1/EBSD/Header/static_background"][()]
        rows, columns = int(f["Scan 1/EBSD/Header/n_rows"][0]), int(f["Scan 1/EBSD/Header/n_columns"][0])
    assert patterns.dtype == np.uint8 and background.dtype == np.uint8
    return patterns.reshape(rows, columns, *patterns.shape[1:]), background


def frequency_setup(shape, std, truncate):
    fft_shape, window_shape, transfer, before, after = _dynamic_background_frequency_space_setup(shape, std, truncate)
    return dict(fft_shape=fft_shape, window_shape=window_shape, transfer_function=transfer,
                offset_before_fft=before, offset_after_ifft=after)


def cases(pattern, background, mean_background):
    """Every reference array for one uint8 pattern, in the order the manifest lists them."""
    bg32 = background.astype(np.float32)
    p32 = pattern.astype(np.float32)
    out = {}
    out["raw"] = pattern
    out["static_subtract"] = _remove_static_background_subtract(pattern, bg32, np.uint8, 0, 255, False)
    out["static_subtract_values"] = _remove_background_subtract(p32.copy(), bg32, 0, 255)
    out["static_divide"] = _remove_static_background_divide(pattern, bg32, np.uint8, 0, 255, False)
    out["static_subtract_scaled"] = _remove_static_background_subtract(pattern, bg32, np.uint8, 0, 255, True)
    out["static_divide_scaled"] = _remove_static_background_divide(pattern, bg32, np.uint8, 0, 255, True)
    out["mean_static_subtract"] = _remove_static_background_subtract(pattern, mean_background.astype(np.float32), np.uint8, 0, 255, False)
    # The dynamic cases run on the static-subtracted pattern, as the F2 chain does.
    s = out["static_subtract"]
    std, truncate = s.shape[1] / 8, 4.0
    setup = frequency_setup(s.shape, std, truncate)
    out["dynamic_background_frequency"] = get_dynamic_background(s.astype(np.float32), "frequency", std, truncate)
    out["dynamic_background_spatial"] = get_dynamic_background(s.astype(np.float32), "spatial", std, truncate)
    out["dynamic_frequency_subtract"] = _remove_dynamic_background(s, _fft_filter, "subtract", np.uint8, 0, 255, **setup)
    out["dynamic_frequency_subtract_values"] = _remove_background_subtract(
        s.astype(np.float32), _fft_filter(s.astype(np.float32), **setup), 0, 255)
    out["dynamic_frequency_divide"] = _remove_dynamic_background(s, _fft_filter, "divide", np.uint8, 0, 255, **setup)
    out["dynamic_spatial_subtract"] = _remove_dynamic_background(s, gaussian_filter, "subtract", np.uint8, 0, 255, sigma=std, truncate=truncate)
    out["dynamic_spatial_divide"] = _remove_dynamic_background(s, gaussian_filter, "divide", np.uint8, 0, 255, sigma=std, truncate=truncate)
    # An odd window (int(3 * 5) = 15 px): the other offset rule of the padded FFT route.
    setup_odd = frequency_setup(s.shape, 5.0, 3.0)
    out["dynamic_frequency_subtract_std5_truncate3"] = _remove_dynamic_background(s, _fft_filter, "subtract", np.uint8, 0, 255, **setup_odd)
    out["dynamic_background_frequency_std5_truncate3"] = get_dynamic_background(s.astype(np.float32), "frequency", 5.0, 3.0)
    out["dynamic_spatial_subtract_std5_truncate3"] = _remove_dynamic_background(s, gaussian_filter, "subtract", np.uint8, 0, 255, sigma=5.0, truncate=3.0)
    return out


def write_array(folder, name, array):
    suffix = {np.dtype(np.uint8): "u8", np.dtype(np.float32): "f32"}[array.dtype]
    data = np.ascontiguousarray(array).astype(array.dtype.newbyteorder("<")).tobytes()
    (folder / f"{name}.{suffix}").write_bytes(data)
    return {"file": f"{name}.{suffix}", "dtype": suffix, "shape": list(array.shape), "sha256": hashlib.sha256(data).hexdigest()}


def write_fixtures(patterns, background, out):
    out.mkdir(parents=True, exist_ok=True)
    mean_background = patterns.reshape(-1, *patterns.shape[2:]).mean(axis=0).astype(np.uint8)  # numpy's astype truncates
    manifest = {
        "reference": "kikuchipy 0.13.1 (pattern._pattern, filters.fft_barnes), scipy.ndimage.gaussian_filter", "pins": PINS,
        "dataset": DATASET, "pattern_shape": list(patterns.shape[2:]), "map_shape": list(patterns.shape[:2]),
        "std_default": patterns.shape[3] / 8, "truncate_default": 4.0, "odd_window": {"std": 5.0, "truncate": 3.0},
        "arrays": {},
    }
    manifest["arrays"]["static_background"] = write_array(out, "static_background", background)
    manifest["arrays"]["mean_background"] = write_array(out, "mean_background", mean_background)
    for row, column in PATTERNS:
        prefix = f"p{row}_{column}"
        for name, array in cases(patterns[row, column], background, mean_background).items():
            manifest["arrays"][f"{prefix}_{name}"] = write_array(out, f"{prefix}_{name}", array)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {len(manifest['arrays'])} arrays to {out}")


def write_whole_set(patterns, background, out):
    """patterns.u8 (every pattern, map order), static_background.u8 and f2_reference.u8 (static subtract, then dynamic
    frequency subtract at the defaults), with manifest-whole.json."""
    out.mkdir(parents=True, exist_ok=True)
    flat = patterns.reshape(-1, *patterns.shape[2:])
    bg32 = background.astype(np.float32)
    std, truncate = flat.shape[2] / 8, 4.0
    setup = frequency_setup(flat.shape[1:], std, truncate)
    f2 = np.empty_like(flat)
    for i, p in enumerate(flat):
        s = _remove_static_background_subtract(p, bg32, np.uint8, 0, 255, False)
        f2[i] = _remove_dynamic_background(s, _fft_filter, "subtract", np.uint8, 0, 255, **setup)
    manifest = {"pins": PINS, "dataset": DATASET, "map_shape": list(patterns.shape[:2]), "pattern_shape": list(patterns.shape[2:]),
                "std": std, "truncate": truncate, "arrays": {}}
    manifest["arrays"]["patterns"] = write_array(out, "patterns", flat)
    manifest["arrays"]["static_background"] = write_array(out, "static_background", background)
    manifest["arrays"]["f2_reference"] = write_array(out, "f2_reference", f2)
    (out / "manifest-whole.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote the whole-set references ({flat.shape[0]} patterns) to {out}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True, type=Path, help="nickel_ebsd_large/patterns_v2.h5")
    ap.add_argument("--out", type=Path, help="fixture folder for the per-pattern references")
    ap.add_argument("--whole-set", type=Path, help="folder for the whole-set references (opt-in test)")
    args = ap.parse_args()
    if not (args.out or args.whole_set):
        ap.error("give --out and/or --whole-set")
    check_pins()
    patterns, background = load(args.data)
    if args.out:
        write_fixtures(patterns, background, args.out)
    if args.whole_set:
        write_whole_set(patterns, background, args.whole_set)


if __name__ == "__main__":
    main()
