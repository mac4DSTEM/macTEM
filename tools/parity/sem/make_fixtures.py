#!/usr/bin/env python
"""tools/parity/sem/make_fixtures.py — write the planted fixtures that no public file covers.

    make_fixtures.py [--data References/sem-data]

Planted, deterministic, small, committed under fixtures/ with the hand-written truth beside them:

* `planted_oxford.ctf`: an Oxford Channel 5 text file with 4 x 5 points of two phases (fcc and bcc iron, the duplex
  steel of the public .ang map), hand-written values in the table below, one not-indexed point (phase 0, error 3)
  and the MAD, BC and BS columns.
  orix has no .ctf writer (0.15.0 saves .ang and .h5 only) and no public .ctf of a known licence was found on the
  day, so the planted file is the ctf reader's fixture; its truth is `planted_oxford.truth.json`.
* `oxford_h5oina_patterns.h5oina` and `bruker_h5ebsd_patterns.h5`: kikuchipy's own dummy writers
  (`kikuchipy.data._dummy_files`), which build a 3 x 3 file around the Ni small dataset. Regenerated here so a
  kikuchipy change in the writers is a visible diff, never a silent one.

Run with `python -I -B`.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"

# phase, x, y, bands, error, euler1, euler2, euler3, MAD, BC, BS. Point (row 1, col 2) is not indexed (phase 0).
CTF_ROWS = [
    (1, 0.0, 0.0, 9, 0, 97.5831, 44.5012, 210.5470, 0.3271, 150, 180),
    (1, 0.5, 0.0, 9, 0, 97.6060, 44.5600, 210.6700, 0.3122, 152, 181),
    (2, 1.0, 0.0, 10, 0, 203.2510, 35.1250, 77.0780, 0.4410, 131, 160),
    (2, 1.5, 0.0, 10, 0, 203.2700, 35.1500, 77.0100, 0.4512, 128, 158),
    (2, 2.0, 0.0, 10, 0, 203.3100, 35.2000, 76.9900, 0.4388, 130, 161),
    (1, 0.0, 0.5, 9, 0, 97.5900, 44.5100, 210.5300, 0.3300, 149, 179),
    (1, 0.5, 0.5, 8, 0, 97.6100, 44.5500, 210.6000, 0.3190, 151, 182),
    (0, 1.0, 0.5, 0, 3, 0.0000, 0.0000, 0.0000, 0.0000, 60, 20),
    (2, 1.5, 0.5, 10, 0, 203.2600, 35.1400, 77.0300, 0.4499, 127, 157),
    (2, 2.0, 0.5, 10, 0, 203.3000, 35.1900, 77.0000, 0.4400, 129, 160),
    (1, 0.0, 1.0, 9, 0, 97.5700, 44.4900, 210.5600, 0.3250, 150, 180),
    (1, 0.5, 1.0, 9, 0, 97.6000, 44.5400, 210.6500, 0.3100, 153, 183),
    (1, 1.0, 1.0, 9, 0, 97.6200, 44.5700, 210.6900, 0.3150, 152, 182),
    (2, 1.5, 1.0, 10, 0, 203.2800, 35.1600, 77.0200, 0.4520, 126, 156),
    (2, 2.0, 1.0, 10, 0, 203.2900, 35.1800, 77.0100, 0.4450, 128, 159),
    (1, 0.0, 1.5, 9, 0, 97.5800, 44.5000, 210.5500, 0.3280, 151, 181),
    (1, 0.5, 1.5, 9, 0, 97.6050, 44.5450, 210.6600, 0.3110, 152, 182),
    (1, 1.0, 1.5, 9, 0, 97.6150, 44.5650, 210.6800, 0.3160, 151, 181),
    (2, 1.5, 1.5, 10, 0, 203.2750, 35.1550, 77.0250, 0.4515, 127, 157),
    (2, 2.0, 1.5, 10, 0, 203.2950, 35.1850, 77.0050, 0.4440, 129, 160),
]

CTF_HEADER = """Channel Text File
Prj	planted_oxford
Author	[Unknown]
JobMode	Grid
XCells	5
YCells	4
XStep	0.5000
YStep	0.5000
AcqE1	0.0000
AcqE2	0.0000
AcqE3	0.0000
Euler angles refer to Sample Coordinate system (CS0)!	Mag	2000	Coverage	100	Device	0	KV	20	TiltAngle	70	TiltAxis	0
Phases	2
3.5900;3.5900;3.5900	90.000;90.000;90.000	Iron fcc	11	225			Generic superlattice
2.8660;2.8660;2.8660	90.000;90.000;90.000	Iron bcc (old)	11	229
Phase	X	Y	Bands	Error	Euler1	Euler2	Euler3	MAD	BC	BS
"""


def write_ctf() -> None:
    lines = [CTF_HEADER]
    for r in CTF_ROWS:
        lines.append("\t".join(["%d" % r[0], "%.4f" % r[1], "%.4f" % r[2], "%d" % r[3], "%d" % r[4],
                                "%.4f" % r[5], "%.4f" % r[6], "%.4f" % r[7], "%.4f" % r[8], "%d" % r[9], "%d" % r[10]]) + "\n")
    (FIXTURES / "planted_oxford.ctf").write_text("".join(lines), encoding="utf-8")
    truth = {
        "shape_rc": [4, 5], "x_step": 0.5, "y_step": 0.5,
        "phases": {"1": {"name": "Iron fcc", "space_group": 225, "a": 3.59}, "2": {"name": "Iron bcc (old)", "space_group": 229, "a": 2.866}},
        "not_indexed_points": [[1, 2]],
        "rows": [list(r) for r in CTF_ROWS],
        "columns": ["phase", "x", "y", "bands", "error", "euler1_deg", "euler2_deg", "euler3_deg", "MAD", "BC", "BS"],
    }
    (FIXTURES / "planted_oxford.truth.json").write_text(json.dumps(truth, indent=2) + "\n", encoding="utf-8")


def write_kikuchipy_dummies() -> None:
    import kikuchipy.data._dummy_files.bruker_h5ebsd as bruker
    import kikuchipy.data._dummy_files.oxford_h5ebsd as oxford

    oxford.create_dummy_oxford_h5ebsd_file(FIXTURES / "oxford_h5oina_patterns.h5oina")
    bruker.create_dummy_bruker_h5ebsd_file(FIXTURES / "bruker_h5ebsd_patterns.h5")


def main() -> int:
    argparse.ArgumentParser(description=__doc__.split("\n")[0]).parse_args()
    FIXTURES.mkdir(exist_ok=True)
    write_ctf()
    write_kikuchipy_dummies()
    print("make_fixtures.py: planted_oxford.ctf, oxford_h5oina_patterns.h5oina, bruker_h5ebsd_patterns.h5 written")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
