# tools/parity/sem-readers/make_h5oina_lzf_fixture.py — writes ebsd-oxford-lzf.h5oina for macTEMTests (#524).
#
#   python -I -B make_h5oina_lzf_fixture.py <macTEMTests/Fixtures/ebsd-oxford.h5oina> <out dir>   (h5py 3.16.0, NumPy 2.5.4)
#
# AZtec (H5OINA 5.0 to 7.0) stores its pattern datasets compressed with h5py's LZF filter (HDF5 filter 32000), which libhdf5 does
# not carry; FormatoKit 0.14.0 decodes it. This copies ebsd-oxford.h5oina object by object, attributes included, and writes every
# dataset of more than 16 values chunked one pattern (or one image) per chunk and LZF-compressed with h5py's own encoder. The values
# are the source file's, so the test reads this file and asserts it reads exactly as ebsd-oxford.h5oina does.
import sys
from pathlib import Path
import h5py

source, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
target = out / "ebsd-oxford-lzf.h5oina"


def copy_attrs(src, dst):
    for key, value in src.attrs.items():
        dst.attrs[key] = value


def copy_group(src, dst):
    copy_attrs(src, dst)
    for name, item in src.items():
        if isinstance(item, h5py.Group):
            copy_group(item, dst.create_group(name))
        elif item.size > 16:
            chunks = (1,) + item.shape[1:] if item.ndim == 3 else item.shape
            data = dst.create_dataset(name, data=item[()], chunks=chunks, compression="lzf")
            copy_attrs(item, data)
        else:
            data = dst.create_dataset(name, data=item[()])
            copy_attrs(item, data)


with h5py.File(source, "r") as src, h5py.File(target, "w", libver="earliest") as dst:
    copy_attrs(src, dst)
    copy_group(src, dst)

with h5py.File(target, "r") as check:
    compressed = []
    check.visititems(lambda n, o: compressed.append(n) if isinstance(o, h5py.Dataset) and o.compression == "lzf" else None)
    print(target, "LZF datasets:", compressed)
