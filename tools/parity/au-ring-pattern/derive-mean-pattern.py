"""Mean of the 100000 frames of Au_000_data_000001.h5 -> a 192x192 float32 TIFF.

  References/python-venv/bin/python -I derive-mean-pattern.py <data.h5> <out.tif> [<existing.tif>]

The frames are bitshuffle-LZ4 (HDF5 filter 32008); hdf5plugin (locked) registers the decoder, so no new package is
needed. Counts are summed exactly in uint64/float64 (integers below 2^53), divided once by the frame count in float64,
and only then rounded to float32. With a third argument the result is compared with that TIFF.
The input is untrusted data: it is only read, as arrays.
"""
import hashlib, sys
import h5py, hdf5plugin  # noqa: F401  (registers the bitshuffle filter)
import numpy as np, tifffile

src, out = sys.argv[1], sys.argv[2]
with h5py.File(src, "r") as f:
    d = f["entry/data/data"]
    n, h, w = d.shape
    assert (h, w) == (192, 192) and d.dtype == np.uint16, (d.shape, d.dtype)
    total = np.zeros((h, w), np.float64)
    for a in range(0, n, 1000):                       # chunks are one frame each; read 1000 at a time
        total += d[a:a + 1000].sum(axis=0, dtype=np.float64)
mean = (total / n).astype(np.float32)
tifffile.imwrite(out, mean, photometric="minisblack")
print(f"frames {n}  shape {mean.shape}  dtype {mean.dtype}")
print(f"min {mean.min():.6f}  max {mean.max():.6f}  mean {mean.mean(dtype=np.float64):.6f}  sum(counts) {total.sum():.0f}")
print("sha256", hashlib.sha256(open(out, "rb").read()).hexdigest())
if len(sys.argv) > 3:
    ref = tifffile.imread(sys.argv[3])
    print(f"vs {sys.argv[3]}: shape {ref.shape} dtype {ref.dtype}  max|diff| {np.abs(mean.astype(np.float64) - ref).max():.3e}"
          f"  array bit-identical {np.array_equal(mean.view(np.uint32), ref.astype(np.float32).view(np.uint32))}"
          f"  file bit-identical {open(out,'rb').read() == open(sys.argv[3],'rb').read()}")
