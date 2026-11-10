#!/usr/bin/env python
"""tools/parity/sem/check.py — the drift gate: emit every bundle into a scratch folder with the pinned stack and compare
against the committed references/ within each array's committed tolerance (an array of rotations whose entry names a
point group by its misorientation angle per point, lib/refbundle.py).

    check.py [--data References/sem-data] [--require-data]

Exit 0 when every committed bundle is reproduced; 1 with one line per drift (a moved number, a changed shape, dtype,
input checksum, value, or stack version), or per bundle that is committed but not emitted (missing dataset: fetch it
or pass without --require-data to see the skip) or emitted but not committed. Run with `python -I -B`.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
from refbundle import main_check  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data", type=Path, default=HERE.parent.parent.parent / "References" / "sem-data")
    ap.add_argument("--require-data", action="store_true")
    args = ap.parse_args()
    with tempfile.TemporaryDirectory(prefix="mactem-sem-parity-") as tmp:
        cmd = [sys.executable, "-I", "-B", str(HERE / "emit.py"), "--out", tmp, "--data", str(args.data)]
        if args.require_data:
            cmd.append("--require-data")
        r = subprocess.run(cmd, check=False)
        if r.returncode != 0:
            print("sem-parity: emit.py failed", file=sys.stderr)
            return r.returncode
        return main_check(HERE / "references", Path(tmp))


if __name__ == "__main__":
    sys.exit(main())
