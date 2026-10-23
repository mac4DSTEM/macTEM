#!/bin/zsh
# tools/parity/mrc-reader-parity — macTEM's MRC reader against mrcfile 1.5.4 (pinned: tools/lib/references-lock.txt) and
# RosettaSciIO 049e7d70's tests/data/mrc files (tools/lib/fetch-rsciio.sh). Classified `scientific` in
# tools/run-tests.sh. Pre-registration: archive: roadmap-registrations-2026-10-15.md "V1-3c-i One MRC image". README.md says more.
#
#   run.sh   make_fixture.py writes the planted MRC files with its own writer; reference.py checks mrcfile against every
#            planted truth and writes its reading of every case (manifest.json + .f32); the Swift reader must match it
#            exactly (main.swift); then every mutation must fail the check it targets, or the gate fails for being blind.
#
# Pass: "mrc-reader-parity: all passed", then "negative controls: 7 of 7 caught by their checks", exit 0.
# TEMCore sources come from tools/lib/sources.manifest, group `mrc`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-mrc-reader-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
"$ROOT/tools/lib/fetch-rsciio.sh"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/make_fixture.py" "$WORK/planted"
"$PYTHON_BIN" -I -B "$HERE/reference.py" "$WORK/planted" "$ROOT/References/rosettasciio" "$WORK/ref"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" mrc
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

"$WORK/harness" "$WORK/ref"

# Negative controls. A mutant is caught only when the harness exits exactly 1 (its own failure exit: an unknown
# mutation exits 64, a crash by signal) AND its log holds a failure of the check the mutation targets — anything
# else fails the gate with the mutant's log.
mutations=(transpose mode0-unsigned ignore-stamp ignore-nsymbt scale-from-my drop-nonpositive accept-stack)
typeset -A targets=(
  transpose          ' shape'
  mode0-unsigned     ' pixels'
  ignore-stamp       'mode1-bigendian read'
  ignore-nsymbt      ' pixels'
  scale-from-my      ' scale'
  drop-nonpositive   ' notes'
  accept-stack       'stack-nz3 refusal'
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
     && grep -qE '^mrc-reader-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" \
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
  echo "mrc-reader-parity: negative controls: $caught of ${#mutations} caught by their checks"
  exit 1
fi
echo "mrc-reader-parity: negative controls: ${#mutations} of ${#mutations} caught by their checks"
