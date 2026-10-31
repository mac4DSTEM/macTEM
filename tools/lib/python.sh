#!/bin/zsh
# tools/lib/python.sh — the pinned reference-Python environment for the scientific harnesses.
#
# mac4DSTEM's python.sh only RESOLVES an interpreter and pins the direct dependencies in a CI-only file. macTEM
# PROVISIONS instead: a venv under the gitignored References/ built from tools/lib/references-lock.txt, which
# pins the FULL closure as wheels, so a parity result is a claim about one known stack on every machine. The venv
# is used only while `pip freeze` in it equals the lock's package lines; anything else reprovisions it. The harness
# then asserts the reference's version, the sha256 of the reference source, numpy's version and the Python minor
# (tools/parity/metadata-parity/reference.py, for one), so an override (PYTHON=) cannot swap the reader or numpy silently; the rest
# of an override's stack is not checked.
#
#   resolve_mactem_python <repo-root>   -> exports PYTHON_BIN, provisioning on first use or when the venv is not the lock
#
# Overrides: PYTHON=/path/to/python uses that interpreter as-is; only what the harness asserts is checked.
#            MACTEM_PYTHON_BASE=/path/to/python3.14 picks the venv's base interpreter.
# The first provision downloads the lock's wheels from PyPI (network once).
MACTEM_PYTHON_MINOR="3.14"   # the lock was resolved and verified on CPython 3.14.7 (2026-10-12)

# What the venv holds against what the lock pins, as diff lines ("< " pinned, not installed as pinned; "> " installed,
# not pinned); empty when they are equal. A dead interpreter freezes nothing, so every pin shows as missing.
mactem_python_venv_drift() {  # <venv> <lock>
  diff <(sed -E 's/#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d' "$2" | LC_ALL=C sort) \
       <("$1/bin/python" -I -m pip freeze --disable-pip-version-check 2>/dev/null | LC_ALL=C sort) \
    | grep -E '^[<>] ' || true
}

resolve_mactem_python() {
  local root=$1
  local venv="$root/References/python-venv" lock="$root/tools/lib/references-lock.txt"
  local want have base candidate drift
  if [[ -n "${PYTHON:-}" ]]; then
    PYTHON_BIN=$PYTHON; export PYTHON_BIN; return 0
  fi
  want="$(shasum -a 256 "$lock" | cut -d' ' -f1)"
  have="$(cat "$venv/.lock-sha256" 2>/dev/null || true)"
  # Ready only when what is installed IS the lock. The stamp alone kept a venv into which numpy was upgraded, or
  # whose base interpreter was deleted (review, 2026-10-12).
  if [[ -x "$venv/bin/python" ]]; then
    drift="$(mactem_python_venv_drift "$venv" "$lock")"
    if [[ "$have" == "$want" && -z "$drift" ]] \
       && "$venv/bin/python" -I -B -c 'import ncempy.io.dm' >/dev/null 2>&1; then
      PYTHON_BIN="$venv/bin/python"; export PYTHON_BIN; return 0
    fi
    if [[ -n "$drift" ]]; then
      echo "python.sh: References/python-venv is not tools/lib/references-lock.txt (< pinned, > installed):" >&2
      print -r -- "$drift" | sed 's/^/  /' >&2
    fi
  fi

  base=""
  for candidate in "${MACTEM_PYTHON_BASE:-}" "$(command -v "python$MACTEM_PYTHON_MINOR" 2>/dev/null || true)" \
                   "$(command -v python3 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if [[ "$("$candidate" -I -c 'import sys; print("%d.%d" % sys.version_info[:2])')" == "$MACTEM_PYTHON_MINOR" ]]; then
      base=$candidate; break
    fi
  done
  if [[ -z "$base" ]]; then
    echo "python.sh: no Python $MACTEM_PYTHON_MINOR found to build References/python-venv." >&2
    echo "  Set MACTEM_PYTHON_BASE=/path/to/python$MACTEM_PYTHON_MINOR." >&2
    return 1
  fi
  echo "python.sh: provisioning References/python-venv from $base and tools/lib/references-lock.txt" >&2
  mkdir -p "$root/References"
  "$base" -I -m venv --clear "$venv" || return 1
  "$venv/bin/python" -I -m pip install --disable-pip-version-check -q --only-binary=:all: --no-deps -r "$lock" || return 1
  "$venv/bin/python" -I -m pip check || return 1      # the lock is a closed set: nothing missing
  drift="$(mactem_python_venv_drift "$venv" "$lock")"
  if [[ -n "$drift" ]]; then
    echo "python.sh: the provisioned venv still differs from the lock (< pinned, > installed):" >&2
    print -r -- "$drift" | sed 's/^/  /' >&2
    return 1
  fi
  print -r -- "$want" > "$venv/.lock-sha256"
  PYTHON_BIN="$venv/bin/python"; export PYTHON_BIN
}
