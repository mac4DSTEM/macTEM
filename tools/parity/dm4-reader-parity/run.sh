#!/bin/zsh
# tools/parity/dm4-reader-parity — macTEM's DM3/DM4 reader against ncempy (pinned: tools/lib/references-lock.txt).
# Classified `scientific` in tools/run-tests.sh. Pre-registration: archive: roadmap-registrations-2026-10-15.md "DM image reader". README.md says more.
#
#   run.sh                 the gate: make_fixture.py writes one planted DM4 per pixel type into the scratch directory;
#                          reference.py checks ncempy against every planted truth and writes ncempy's reading of every
#                          case; the Swift reader must match it exactly (main.swift); then every mutation must fail
#                          the check it targets, or the gate fails for being blind.
#   run.sh --make-fixture  rewrite macTEMTests/Fixtures/planted-2d.dm4 and its truth (commit both; review the diff)
#
# Case 1 is the committed planted fixture and the per-type planted fixtures; case 2 is GMS-written files from
# RosettaSciIO at its pinned commit, fetched into References/ (tools/lib/fetch-rsciio.sh), and the files macTEM must
# refuse. Pass: "dm4-reader-parity: all passed", then "negative controls: 7 of 7 caught by their checks", exit 0.
# TEMCore sources come from tools/lib/sources.manifest.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
FIXTURE="$ROOT/macTEMTests/Fixtures/planted-2d.dm4"
PLANTED="$ROOT/macTEMTests/Fixtures/planted-2d.truth.json"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-dm4-reader-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"

if [[ "${1:-}" == "--make-fixture" ]]; then
  "$PYTHON_BIN" -I -B "$HERE/make_fixture.py" "$FIXTURE" "$PLANTED"
  exit 0
fi

"$ROOT/tools/lib/fetch-rsciio.sh"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/make_fixture.py" --types "$WORK/types"
"$PYTHON_BIN" -I -B "$HERE/reference.py" "$FIXTURE" "$PLANTED" "$WORK/types" "$ROOT/References/rosettasciio" "$WORK/ref"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" dm
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

"$WORK/harness" "$WORK/ref"

# Negative controls. A mutant is caught only when the harness exits exactly 1 (its own failure exit: an unknown
# mutation exits 64, a crash by signal) AND its log holds a failure of the check the mutation targets — anything
# else fails the gate with the mutant's log.
mutations=(transpose swap-calibration units pixel origin-sign accept-mixed-units ignore-format)
typeset -A targets=(
  transpose           ' shape'
  swap-calibration    ' scale'
  units               ' units'
  pixel               ' pixels'
  origin-sign         ' origin'
  accept-mixed-units  'digitalmicrograph_2D_test-MonoCL_spectrum-SI.dm4 refusal'
  ignore-format       'planted-si refusal'
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
     && grep -qE '^dm4-reader-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" \
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
  echo "dm4-reader-parity: negative controls: $caught of ${#mutations} caught by their checks"
  exit 1
fi
echo "dm4-reader-parity: negative controls: ${#mutations} of ${#mutations} caught by their checks"
