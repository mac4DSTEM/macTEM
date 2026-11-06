#!/usr/bin/env bash
# tools/parity/sem/setup.sh — the SEM program's reference stack: a venv at References/sem-venv (gitignored) built from
# requirements.lock on CPython 3.14, every package pinned (the lock is pip's freeze of the resolved closure).
#   setup.sh            provision or reuse; prints the interpreter path on its last line
#   PYTHON_BASE=...     the CPython 3.14 to build from (default: python3.14 on PATH, then python3 if it is 3.14)
# A venv whose freeze is not the lock is rebuilt. This is the SEM twin of tools/lib/python.sh (the TEM harnesses'
# ncempy stack, 3.14 too): one stack per program, so a kikuchipy pin never moves an EELS number.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
VENV="${MACTEM_SEM_VENV:-$ROOT/References/sem-venv}"
LOCK="$HERE/requirements.lock"
MINOR=3.14

pins() { sed -E 's/#.*$//; s/[[:space:]]+$//; /^$/d' "$LOCK" | LC_ALL=C sort; }
frozen() { "$VENV/bin/python" -I -m pip freeze --disable-pip-version-check 2>/dev/null | LC_ALL=C sort; }

if [[ -x "$VENV/bin/python" ]] && diff -q <(pins) <(frozen) >/dev/null 2>&1; then
  echo "setup.sh: References/sem-venv is requirements.lock" >&2; echo "$VENV/bin/python"; exit 0
fi

base="${PYTHON_BASE:-}"
if [[ -z "$base" ]]; then
  for c in "python$MINOR" python3; do
    if command -v "$c" >/dev/null && [[ "$("$c" -I -c 'import sys; print("%d.%d" % sys.version_info[:2])')" == "$MINOR" ]]; then base="$(command -v "$c")"; break; fi
  done
fi
[[ -n "$base" ]] || { echo "setup.sh: no CPython $MINOR found; set PYTHON_BASE=/path/to/python$MINOR" >&2; exit 69; }

rm -rf "$VENV"
"$base" -m venv "$VENV"
"$VENV/bin/python" -I -m pip install --disable-pip-version-check -q --upgrade pip >/dev/null
"$VENV/bin/python" -I -m pip install --disable-pip-version-check -q --no-deps -r "$LOCK"
"$VENV/bin/python" -I -m pip check >/dev/null
if ! diff -q <(pins) <(frozen) >/dev/null; then
  echo "setup.sh: the venv's freeze is not the lock after install (< pinned, > installed):" >&2
  diff <(pins) <(frozen) | grep -E '^[<>]' >&2 || true
  exit 1
fi
echo "setup.sh: References/sem-venv built from requirements.lock" >&2
echo "$VENV/bin/python"
