# tools/parity/sem-readers/make_h5ebsd_fixtures.py — writes the h5ebsd fixtures of macTEMTests and the truth they are read against.
#
#   python -I -B make_h5ebsd_fixtures.py <out dir>
#
# Fixtures (each under 1 MiB, copied flat into the test bundle, so the names are unique):
#   ebsd-kikuchipy-h5ebsd.h5   kikuchipy's in-package kikuchipy_h5ebsd/patterns.h5 (two scans of 3 x 3 Ni patterns, 60 x 60, CC BY 4.0)
#   ebsd-edax-h5ebsd.h5        kikuchipy's in-package edax_h5ebsd/patterns.h5 (OIM Analysis 7.2.1 layout, one scan)
#   ebsd-bruker-h5ebsd.h5      kikuchipy's dummy Bruker file (no region of interest)
#   ebsd-bruker-roi-h5ebsd.h5  kikuchipy's dummy Bruker file with a rectangular region of interest (patterns in file order, IX/IY in EBSD/SEM)
#   ebsd-oxford.h5oina      kikuchipy's dummy H5OINA 7.0 file (processed and unprocessed patterns)
#   ebsd-oxford-6.h5oina    the same at H5OINA 6.0 (Camera Binning Mode)
# Truth: ebsd-h5ebsd.truth.json, what kikuchipy 0.13.1's readers return for each file: shapes, steps, the detector (PC in the Bruker
# convention as `EBSDDetector.pc`), the static background, the first and last pattern, the sha256 of the whole pattern array in
# (ny, nx, sy, sx) C order, and the sha256 of each fixture. Floats are repr() (round-trip exact).
import hashlib, json, shutil, sys
from pathlib import Path
import numpy as np
import kikuchipy as kp
from kikuchipy.data._dummy_files.bruker_h5ebsd import create_dummy_bruker_h5ebsd_file, create_dummy_bruker_h5ebsd_roi_file
from kikuchipy.data._dummy_files.oxford_h5ebsd import create_dummy_oxford_h5ebsd_file

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
pkg = Path(kp.__file__).parent / "data"
shutil.copy(pkg / "kikuchipy_h5ebsd" / "patterns.h5", out / "ebsd-kikuchipy-h5ebsd.h5")
shutil.copy(pkg / "edax_h5ebsd" / "patterns.h5", out / "ebsd-edax-h5ebsd.h5")
create_dummy_bruker_h5ebsd_file(out / "ebsd-bruker-h5ebsd.h5")
create_dummy_bruker_h5ebsd_roi_file(out / "ebsd-bruker-roi-h5ebsd.h5")
create_dummy_oxford_h5ebsd_file(out / "ebsd-oxford.h5oina", version="7.0")
create_dummy_oxford_h5ebsd_file(out / "ebsd-oxford-6.h5oina", version="6.0")

def sha(b): return hashlib.sha256(b).hexdigest()
def flt(a): return [repr(float(v)) for v in np.asarray(a, dtype=np.float64).ravel()]

truth = {"kikuchipy": kp.__version__, "files": {}}
for name, kw in [("ebsd-kikuchipy-h5ebsd.h5", {}), ("ebsd-edax-h5ebsd.h5", {}), ("ebsd-bruker-h5ebsd.h5", {}),
                 ("ebsd-bruker-roi-h5ebsd.h5", {}), ("ebsd-oxford.h5oina", {}), ("ebsd-oxford-6.h5oina", {})]:
    path = out / name
    s = kp.load(path, **kw)
    d = s.detector
    om = s.original_metadata.as_dictionary()
    sem = s.metadata.Acquisition_instrument.SEM.as_dictionary() if "SEM" in s.metadata.Acquisition_instrument else {}
    data = np.ascontiguousarray(s.data)
    nav = list(s._navigation_shape_rc); sig = list(s._signal_shape_rc)
    bg = s.static_background
    entry = {
        "file_sha256": sha(path.read_bytes()),
        "manufacturer": om["manufacturer"], "version": om["version"],
        "nav_shape": nav, "sig_shape": sig, "dtype": str(data.dtype),
        "step": [repr(float(s.axes_manager["y"].scale)), repr(float(s.axes_manager["x"].scale))],
        "scan_unit": s.axes_manager["x"].units,
        "px_size": repr(float(d.px_size)), "binning": int(d.binning),
        "tilt": repr(float(d.tilt)), "azimuthal": repr(float(d.azimuthal)), "twist": repr(float(d.twist)),
        "sample_tilt": repr(float(d.sample_tilt)),
        "pc_shape": list(d.pc.shape), "pc_bruker": flt(d.pc),
        "static_background": None if bg is None else {"dtype": str(bg.dtype), "shape": list(bg.shape), "values": [int(v) for v in bg.ravel()]},
        "patterns_sha256": sha(data.tobytes()),
        "first_pattern": [int(v) for v in data.reshape(-1, sig[0], sig[1])[0].ravel()],
        "last_pattern": [int(v) for v in data.reshape(-1, sig[0], sig[1])[-1].ravel()],
        "sem": {k: (repr(float(v)) if isinstance(v, (int, float, np.number)) else v) for k, v in sem.items() if v is not None},
        "xmap_phase_names": [str(p.name) for _, p in s.xmap.phases] if s.xmap.phases.size else [],
        "xmap_has_rotations": bool(s.xmap.rotations.size > 0 and not np.allclose(s.xmap.rotations.data, [1, 0, 0, 0])),
    }
    if entry["xmap_has_rotations"]:
        # The stored Bunge angles (radians) of the first and last point, read back from the file: what the reader returns.
        import h5py
        with h5py.File(path) as h:
            g = h[s.xmap_group_path] if hasattr(s, "xmap_group_path") else h[list(k for k in h if isinstance(h[k], h5py.Group))[0] + "/EBSD/CrystalMap/crystal_map/data"]
            e = np.column_stack((g["phi1"][()], g["Phi"][()], g["phi2"][()]))
        entry["xmap_euler_first"] = flt(e[0]); entry["xmap_euler_last"] = flt(e[-1])
        entry["xmap_phase_ids_first_last"] = [int(g_id) for g_id in (e.shape[0] and [s.xmap.phase_id[0], s.xmap.phase_id[-1]])]
    truth["files"][name] = entry
(out / "ebsd-h5ebsd.truth.json").write_text(json.dumps(truth, indent=1) + "\n")
print("wrote", len(truth["files"]), "fixtures to", out)
