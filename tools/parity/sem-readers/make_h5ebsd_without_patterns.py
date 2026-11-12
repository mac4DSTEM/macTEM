# tools/parity/sem-readers/make_h5ebsd_without_patterns.py — writes the Bruker and EDAX h5ebsd fixtures saved without patterns (#514).
#
#   python -I -B make_h5ebsd_without_patterns.py <fixtures dir>        (h5py 3.16.0, NumPy 2.5.4, as pinned in tools/parity/sem)
#
# Esprit and OIM Analysis can save an EBSD scan's map without its patterns. Each fixture is the committed kikuchipy-made file
# (make_h5ebsd_fixtures.py) with every object copied except the pattern dataset, so the map, header and SEM groups stay as they were:
#   ebsd-bruker-nopatterns-h5ebsd.h5   ebsd-bruker-h5ebsd.h5 without Scan 0/EBSD/Data/RawPatterns
#   ebsd-edax-nopatterns-h5ebsd.h5     ebsd-edax-h5ebsd.h5 without Scan 1/EBSD/Data/Pattern, and without the five schematic pictures of
#                                      its Header/Coordinate System (850 KiB of RGB images no reader looks at)
# macTEM refuses both in words until it reads their maps (EBSDH5ContentTests).
import sys
from pathlib import Path
import h5py

folder = Path(sys.argv[1])


def without(source, target, *dropped):
    with h5py.File(folder / source, "r") as src, h5py.File(folder / target, "w") as dst:
        def copy(group_in, group_out):
            for key, value in group_in.attrs.items():
                group_out.attrs[key] = value
            for name in group_in:
                path = group_in[name].name
                if path in dropped:
                    continue
                item = group_in[name]
                if isinstance(item, h5py.Group):
                    copy(item, group_out.create_group(name))
                else:
                    group_in.copy(item, group_out, name=name)
        copy(src, dst)


without("ebsd-bruker-h5ebsd.h5", "ebsd-bruker-nopatterns-h5ebsd.h5", "/Scan 0/EBSD/Data/RawPatterns")
without("ebsd-edax-h5ebsd.h5", "ebsd-edax-nopatterns-h5ebsd.h5", "/Scan 1/EBSD/Data/Pattern", "/Scan 1/EBSD/Header/Coordinate System")
