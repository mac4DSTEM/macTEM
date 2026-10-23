#!/bin/zsh
# tools/parity/hrtem-filter-parity — ImagoKit's HRTEM filters (`HRTEMFilter`, ADR 027; archive: roadmap-registrations-2026-10-15.md "V1-6d HRTEM filters, third registration")
# against reference.py's float64 reading of the same steps A1–A6 and the plants' truth. Classified in tools/run-tests.sh by
# the latest registration's result (README.md).
#
#   run.sh   plants.py writes the planted images; reference.py reads them (with its own self-checks, exit 1 on any) and
#            writes every stage; main.swift runs the Swift filter on the same inputs and gates the registration's P1
#            and P2; then each control runs on its own target case, which must pass unmutated first.
#
# Exit: the run's checks and the controls both pass -> 0; otherwise 1. TEMCore sources come from
# tools/lib/sources.manifest, group `hrtem`. A full run takes a few seconds.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-hrtem-filter-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/plants.py" "$WORK/planted"
"$PYTHON_BIN" -I -B "$HERE/reference.py" "$WORK/planted" "$WORK/ref"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" hrtem
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

set +e
"$WORK/harness" "$WORK/ref"
main_rc=$?
set -e

# Controls, emulated on the Swift output (main.swift's header), on bin-128: a control counts when its targeted check does
# NOT fail unmutated and DOES fail mutated (exit 1).
case_name='bin-128'
mutations=(absf-sign dc-removed flag-moved a-scaled)
typeset -A targets=(
  absf-sign   "$case_name absf"
  dc-removed  "$case_name dc"
  flag-moved  "$case_name flags"
  a-scaled    "$case_name a"
)
set +e
MACTEM_PARITY_ONLY="$case_name" "$WORK/harness" "$WORK/ref" > "$WORK/base.log" 2>&1
base_rc=$?
set -e
caught=0
for mutation in $mutations; do
  target="${targets[$mutation]}"
  set +e
  MACTEM_PARITY_ONLY="$case_name" MACTEM_PARITY_MUTATE=$mutation "$WORK/harness" "$WORK/ref" > "$WORK/mutant-$mutation.log" 2>&1
  rc=$?
  set -e
  if (( rc == 1 )) && ! awk -v want="$target" 'index($0, "  FAIL  ") == 1 && index($0, want) { hit = 1 } END { exit !hit }' "$WORK/base.log" \
     && grep -qE '^hrtem-filter-parity: [0-9]+ FAILURES in [0-9]+ checks' "$WORK/mutant-$mutation.log" \
     && awk -v want="$target" 'index($0, "  FAIL  ") == 1 && index($0, want) { hit = 1 } END { exit !hit }' "$WORK/mutant-$mutation.log"; then
    caught=$(( caught + 1 ))
    echo "  ok    mutation '$mutation' is caught by its check '$target'"
  else
    echo "  FAIL  mutation '$mutation': unmutated exit $base_rc, mutated exit $rc; wanted '$target' passing unmutated and failing mutated:"
    sed 's/^/        /' "$WORK/base.log" "$WORK/mutant-$mutation.log"
  fi
done
echo "hrtem-filter-parity: negative controls: $caught of ${#mutations} caught by their checks"
if (( caught != ${#mutations} )); then
  exit 1
fi
exit $main_rc
