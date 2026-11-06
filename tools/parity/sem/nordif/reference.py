# SPDX-License-Identifier: GPL-3.0-only
"""Reference for macTEM's NORDIF reader (Sources/TEMCore/SEM/NORDIF), from kikuchipy 0.13.1.

Reads the in-package NORDIF folder of kikuchipy (`kikuchipy/data/nordif`: Pattern.dat, Setting.txt, the three bad
settings files, the background and calibration .bmp patterns) with `kikuchipy.load` exactly as a user would, and writes
`reference.json` beside the copied files in macTEMTests/Fixtures/sem/nordif/. NORDIFReaderTests compares the Swift
reader with it: settings exact, patterns bit-exact (SHA-256 of the uint8 block in map order plus corner samples),
calibration positions exact, the refused files with the sentence stated here.

    python -I tools/parity/sem/nordif/reference.py [--copy]

`--copy` also copies the fixture files from the installed kikuchipy package (done once; they are tracked). Needs the
`tools/parity/sem` environment (kikuchipy 0.13.1 on CPython 3.13).
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import warnings
from pathlib import Path

import kikuchipy as kp
import numpy as np

ROOT = Path(__file__).resolve().parents[4]
FIXTURES = ROOT / "macTEMTests" / "Fixtures" / "sem" / "nordif"
SOURCE = Path(kp.__file__).resolve().parent / "data" / "nordif"
FILES = [
    "Pattern.dat",
    "Setting.txt",
    "Setting_bad1.txt",
    "Setting_bad2.txt",
    "Setting_bad3.txt",
    "Background acquisition pattern.bmp",
    "Background calibration pattern.bmp",
    "Calibration (294,532).bmp",
    "Calibration (425,447).bmp",
]

# The app's refusal sentences, pinned here so the Swift test and this file cannot drift apart. The reference's own
# message is kept beside each one.
NO_CALIBRATION_PATTERNS = (
    "it lists no calibration patterns (no 'Calibration (x,y)' line under [Calibration patterns])."
)


def sha256(a: np.ndarray) -> str:
    return hashlib.sha256(np.ascontiguousarray(a).tobytes()).hexdigest()


def array_block(a: np.ndarray) -> dict:
    """Shape, dtype, SHA-256 of the C-ordered bytes, and the first and last rows of the first and last pattern."""
    first = a.reshape(-1, *a.shape[-2:])[0]
    last = a.reshape(-1, *a.shape[-2:])[-1]
    return {
        "shape": list(a.shape),
        "dtype": str(a.dtype),
        "sha256": sha256(a),
        "first_pattern_first_row": first[0].tolist(),
        "first_pattern_last_row": first[-1].tolist(),
        "last_pattern_first_row": last[0].tolist(),
        "last_pattern_last_row": last[-1].tolist(),
    }


def detector_block(d: kp.detectors.EBSDDetector) -> dict:
    return {
        "shape": list(d.shape),
        "pc": [float(v) for v in d.pc[0]],
        "sample_tilt": float(d.sample_tilt),
        "tilt": float(d.tilt),
        "azimuthal": float(d.azimuthal),
        "binning": int(d.binning),
        "px_size": float(d.px_size),
    }


def acquisition(setting_file: str) -> dict:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        s = kp.load(FIXTURES / "Pattern.dat", setting_file=str(FIXTURES / setting_file))
    sem = s.metadata.Acquisition_instrument.SEM
    am = s.axes_manager
    out = {
        "settings_file": setting_file,
        "microscope": sem.microscope,
        "beam_energy_kv": float(sem.beam_energy),
        "magnification": int(sem.magnification),
        "working_distance_mm": float(sem.working_distance),
        "navigation_shape_yx": [am["y"].size, am["x"].size],
        "step_um": [float(am["y"].scale), float(am["x"].scale)],
        "pattern_shape_yx": [am["dy"].size, am["dx"].size],
        "detector": detector_block(s.detector),
        "data": array_block(s.data),
    }
    if s.static_background is not None:
        out["static_background"] = array_block(s.static_background)
    return out


def calibration(setting_file: str) -> dict:
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            s = kp.load(FIXTURES / setting_file)
    except ValueError as e:
        return {"settings_file": setting_file, "reference_error": str(e), "refusal": NO_CALIBRATION_PATTERNS}
    omd = s.original_metadata.as_dictionary()
    cal = omd["calibration_patterns"]
    roi = omd["roi"]
    area = omd["area"]

    def ints(x):
        return None if x is None else [int(v) for v in np.asarray(x).ravel()]

    out = {
        "settings_file": setting_file,
        "detector": detector_block(s.detector),
        "indices_yx": [[int(v) for v in row] for row in cal["indices"]],
        "indices_scaled_yx": [[int(v) for v in row] for row in cal["indices_scaled"]],
        "area_shape_yx": ints(area["shape"]),
        "area_shape_scaled_yx": ints(area.get("shape_scaled")),
        "roi_origin_yx": ints(roi["origin"]),
        "roi_shape_yx": ints(roi["shape"]),
        "roi_origin_scaled_yx": ints(roi["origin_scaled"]),
        "roi_shape_scaled_yx": ints(roi["shape_scaled"]),
        "data": array_block(s.data),
        "patterns": [{"file": f"Calibration ({x},{y}).bmp", "sha256": sha256(p)} for (y, x), p in zip(cal["indices"], s.data)],
    }
    if s.static_background is not None:
        out["static_background"] = array_block(s.static_background)
    return out


def main(argv: list[str]) -> int:
    if "--copy" in argv:
        FIXTURES.mkdir(parents=True, exist_ok=True)
        for name in FILES:
            shutil.copyfile(SOURCE / name, FIXTURES / name)
    missing = [name for name in FILES if not (FIXTURES / name).is_file()]
    if missing:
        print(f"missing fixtures {missing}; run with --copy", file=sys.stderr)
        return 1
    reference = {
        "reference": {"package": "kikuchipy", "version": kp.__version__, "source": "kikuchipy/data/nordif"},
        "files": {name: hashlib.sha256((FIXTURES / name).read_bytes()).hexdigest() for name in FILES},
        "acquisition": {f: acquisition(f) for f in ["Setting.txt", "Setting_bad1.txt", "Setting_bad2.txt", "Setting_bad3.txt"]},
        "calibration": {f: calibration(f) for f in ["Setting.txt", "Setting_bad1.txt", "Setting_bad2.txt", "Setting_bad3.txt"]},
    }
    (FIXTURES / "reference.json").write_text(json.dumps(reference, indent=1) + "\n")
    print(f"wrote {FIXTURES / 'reference.json'} from kikuchipy {kp.__version__}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
