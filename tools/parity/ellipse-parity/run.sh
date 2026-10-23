#!/bin/zsh
# tools/parity/ellipse-parity — macTEM's ring/ellipse fit (`EllipseCalibration.fit1D`, archive: roadmap-registrations-2026-10-15.md V1-7 "S2") against the
# planted ellipse and a numpy/scipy optimum of the same objective (pinned: tools/lib/references-lock.txt). Classified
# `scientific` in tools/run-tests.sh (the classification is the owner's session's to add). README.md says more.
#
#   run.sh   make_fixture.py writes the planted rings; reference.py checks numpy against the plant and writes
#            manifest.json; the Swift side (main.swift) must match the plant; then every mutation must fail the check
#            it targets, or the gate fails for being blind.
#
# Pass: "ellipse-parity: all passed", then "ellipse-parity: negative controls: 5 of 5 caught by their checks", exit 0.
# TEMCore sources come from tools/lib/sources.manifest, group `ellipse`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-ellipse-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/make_fixture.py" "$WORK/planted"
"$PYTHON_BIN" -I -B "$HERE/reference.py" "$WORK/planted" "$WORK/ref"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" ellipse
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

"$WORK/harness" "$WORK/ref"

# Negative controls. A mutant is caught only when the harness exits exactly 1 (its own failure exit: an unknown
# mutation exits 64, a crash by signal) AND its log holds a failure of the check the mutation targets, on a case where
# the mutation moves that quantity beyond its band (an ε 3 % ring at θ 45° or 135°, R 200 / 160, where the clean fit
# itself passes, so the failure is the mutation's):
#   xy-swap           the centre's row and column exchanged (the plant's centre has row != column).
#   ab-swap           a and b exchanged: 2·ε beyond the 0.05 % axes band.
#   theta-sign        θ -> π − θ: 90° at θ = 45°.
#   mean-radius-major the "mean radius" taken as a: ε/2 = 1.5 % beyond the radius band.
#   no-weight         EMULATED on the output (the weight is inside the verbatim copy): the unweighted objective's
#                     minimum is the start centre and the annulus circle, so the centre moves by the start centre's error (1.3 px in row).
mutations=(xy-swap ab-swap theta-sign mean-radius-major no-weight)
typeset -A targets=(
  xy-swap            'clean-512x512-r200-e3-t135-g60-s0 centre'
  ab-swap            'clean-512x512-r200-e3-t135-g60-s0 axes'
  theta-sign         'clean-512x512-r200-e3-t135-g60-s0 theta'
  mean-radius-major  'clean-512x512-r200-e3-t135-g60-s0 radius'
  no-weight          'clean-512x512-r200-e3-t135-g60-s0 centre'
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
     && grep -qE '^ellipse-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" \
     && awk -v want="$target" 'index($0, "  FAIL  ") == 1 && index($0, want) { hit = 1 } END { exit !hit }' "$log"; then
    caught=$(( caught + 1 ))
    echo "  ok    mutation '$mutation' is caught by its check '$target'"
  elif [[ -z "$target" ]]; then
    echo "  FAIL  mutation '$mutation' has no target check in run.sh (exit $rc):"
    sed 's/^/        /' "$log"
  else
    echo "  FAIL  mutation '$mutation' exited $rc without failing its check '$target':"
    sed 's/^/        /' "$log"
  fi
done
if (( caught != ${#mutations} )); then
  echo "ellipse-parity: negative controls: $caught of ${#mutations} caught by their checks"
  exit 1
fi
echo "ellipse-parity: negative controls: ${#mutations} of ${#mutations} caught by their checks"
