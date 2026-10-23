#!/bin/zsh
# tools/parity/tiff-reader-parity — macTEM's TIFF reader against RosettaSciIO 049e7d70 + tifffile 2026.9.20 (pinned:
# tools/lib/references-lock.txt, tools/lib/fetch-rsciio.sh) and, for the Velox/Ceta convention, the registration's
# own rule. Classified `scientific` in tools/run-tests.sh. Pre-registration: archive: roadmap-registrations-2026-10-15.md "V1-3b TIFF" (the
# re-registration block governs). README.md says more.
#
#   run.sh   make_fixture.py writes the planted TIFFs; reference.py checks the reference against every planted truth
#            and writes its reading of every case (manifest.json + .f32); the Swift reader must match it exactly
#            (main.swift); then every mutation must fail the check it targets, or the gate fails for being blind.
#
# Pass: "tiff-reader-parity: all passed", then "negative controls: 7 of 7 caught by their checks", exit 0.
# The owner's Ceta TIFFs (References/example_files/, gitignored) are a diagnostic: skipped with a printed line when absent.
# TEMCore sources come from tools/lib/sources.manifest, group `tiff`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-tiff-reader-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
"$ROOT/tools/lib/fetch-rsciio.sh"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/make_fixture.py" "$WORK/planted"
"$PYTHON_BIN" -I -B "$HERE/reference.py" "$WORK/planted" "$ROOT/References/rosettasciio" \
  "$ROOT/References/example_files" "$WORK/ref"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" tiff
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

"$WORK/harness" "$WORK/ref"

# Negative controls. A mutant is caught only when the harness exits exactly 1 (its own failure exit: an unknown
# mutation exits 64, a crash by signal) AND its log holds a failure of the check the mutation targets — anything
# else fails the gate with the mutant's log.
mutations=(transpose swap-calibration units pixel origin-sign accept-unequal-rgb drop-notes)
typeset -A targets=(
  transpose           ' shape'
  swap-calibration    ' scale'
  units               ' units'
  pixel               ' pixels'
  origin-sign         ' origin'
  accept-unequal-rgb  'rgb-unequal-plain refusal'
  drop-notes          ' notes'
)
caught=0
for mutation in $mutations; do
  log="$WORK/mutant-$mutation.log"
  target="${targets[$mutation]:-}"
  set +e
  MACTEM_PARITY_MUTATE=$mutation "$WORK/harness" "$WORK/ref" > "$log" 2>&1
  rc=$?
  set -e
  if [[ -n "$target" ]] && (( rc == 1 )) \
     && grep -qE '^tiff-reader-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" \
     && awk -v want="$target: " 'index($0, "  FAIL  ") == 1 && index($0, want) { hit = 1 } END { exit !hit }' "$log"; then
    caught=$(( caught + 1 ))
    echo "  ok    mutation '$mutation' is caught by its check '${target# }'"
  elif [[ -z "$target" ]]; then
    echo "  FAIL  mutation '$mutation' has no target check in run.sh (exit $rc):"
    sed 's/^/        /' "$log"
  else
    echo "  FAIL  mutation '$mutation' exited $rc without failing its check '${target# }':"
    sed 's/^/        /' "$log"
  fi
done
if (( caught != ${#mutations} )); then
  echo "tiff-reader-parity: negative controls: $caught of ${#mutations} caught by their checks"
  exit 1
fi
echo "tiff-reader-parity: negative controls: ${#mutations} of ${#mutations} caught by their checks"
