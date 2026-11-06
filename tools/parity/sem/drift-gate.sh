#!/usr/bin/env bash
# tools/parity/sem/run.sh — provision the stack, fetch the data, run the drift gate. Exit 0 when references/ is what the
# pinned stack emits today. Redirect to a log and read the exit code on its own line.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$("$HERE/setup.sh")"
"$HERE/fetch-data.sh"
"$PY" -I -B "$HERE/check.py" --require-data "$@"
