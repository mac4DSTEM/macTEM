# tools/parity/sem-readers/make_hspy_4d_fixture.py — writes hyperspy-4d-unnamed.hspy for macTEMTests (real-file sweep, 12 Nov).
#
#   python -I -B make_hspy_4d_fixture.py <out dir>   (h5py 3.16.0, NumPy 2.5.4)
#
# HyperSpy names the experiment group of a signal without a title "__unnamed__"; a 4D-STEM .hspy holds a 4-dimensional "data" with
# four "axis-N" groups. This writes that layout (2 x 3 scan of 4 x 5 patterns, values 0..119) so the refusal can be checked not to
# show HyperSpy's internal group name.
import sys
from pathlib import Path
import h5py
import numpy as np

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
with h5py.File(out / "hyperspy-4d-unnamed.hspy", "w") as f:
    f.attrs["file_format"] = "HyperSpy"
    f.attrs["file_format_version"] = "3.3"
    experiment = f.create_group("Experiments/__unnamed__")
    experiment.create_dataset("data", data=np.arange(120, dtype=np.uint16).reshape(2, 3, 4, 5))
    for i, (name, size) in enumerate([("y", 2), ("x", 3), ("ky", 4), ("kx", 5)]):
        axis = experiment.create_group(f"axis-{i}")
        axis.attrs["name"] = name
        axis.attrs["size"] = size
        axis.attrs["scale"] = 1.0
        axis.attrs["offset"] = 0.0
        axis.attrs["units"] = "<undefined>"
        axis.attrs["navigate"] = i < 2
    experiment.create_group("metadata/General").attrs["title"] = ""
print(out / "hyperspy-4d-unnamed.hspy")
