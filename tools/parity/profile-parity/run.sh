#!/bin/zsh
# tools/parity/profile-parity — macTEM's distance, angle and line profile (`ImageMeasurement`, `LineProfile`) against the closed
# forms and scikit-image 0.26.0's `measure.profile_line` with scipy 1.18.1 (pinned: tools/lib/references-lock.txt,
# reference.py). Classified `scientific` in tools/run-tests.sh.
# README.md says more.
#
#   run.sh   reference.py checks scikit-image against an independent interpolation and the analytic ramps, then writes its
#            profiles and the closed forms (manifest.json); the Swift code must match them (main.swift); then every source
#            mutation must fail the check it targets, or the gate fails for being blind. Each mutation edits a COPY of the seam file
#            (never the file in Sources/) and builds the harness against it.
#
# Pass: "profile-parity: all passed", the extra controls line, then "negative controls: 5 of 5 caught by their checks", exit 0.
# The harness is Package.swift's ProfileParity target over TEMCore (tools/lib/harness.sh builds it); the planted DM fixture and the
# real RosettaSciIO images enter as the pixels and calibration ncempy reads from them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
FIXTURE="$ROOT/macTEMTests/Fixtures/planted-2d.dm4"
PLANTED="$ROOT/macTEMTests/Fixtures/planted-2d.truth.json"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-profile-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
"$ROOT/tools/lib/fetch-rsciio.sh"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/reference.py" "$FIXTURE" "$PLANTED" "$ROOT/References/rosettasciio" "$WORK/ref"

. "$ROOT/tools/lib/harness.sh"
mactem_harness_build ProfileParity "$WORK/harness"

"$WORK/harness" "$WORK/ref"

# Negative controls. A mutant is caught only when the harness exits exactly 1 (its own failure exit: a crash by signal is
# not a catch) AND its log holds a "  FAIL  " line of the check the mutation targets (a check is named by the text before
# ": ") — anything else fails the gate with the mutant's log. Each edit applies to a COPY of the file in the scratch
# directory, must match its target text exactly once (a changed line makes the mutation fail LOUDLY, to be re-aimed), the
# harness must compile against it, and then the harness must go red.
CORE="$ROOT/Sources/TEMCore"
failed_check() {   # failed_check <log> <check>: does <log> hold a "  FAIL  " line of that check?
  awk -v want="$2: " 'index($0, "  FAIL  ") == 1 && index($0, want) { hit = 1 } END { exit !hit }' "$1"
}
source_mutant() {  # source_mutant <name> <file under Sources/TEMCore> <target check> <old> <new> [<old> <new>]...
  local name=$1 file=$2 target=$3; shift 3
  local dir="$WORK/mutant-$name" copy
  mkdir -p "$dir"
  copy="$dir/${file:t}"
  cp "$CORE/$file" "$copy"
  while (( $# >= 2 )); do
    "$PYTHON_BIN" -I -B -c '
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("source mutation: expected exactly one occurrence of the edit target, found %d: %s" % (text.count(old), old))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
' "$copy" "$1" "$2" || { echo "  FAIL  mutation '$name' does not apply to $file"; return; }
    shift 2
  done
  if ! mactem_harness_mutant ProfileParity "$dir/harness" "Sources/TEMCore/$file" "$copy" > "$dir/build.log" 2>&1; then
    echo "  FAIL  mutation '$name' does not compile:"
    sed 's/^/        /' "$dir/build.log"
    return
  fi
  local log="$dir/mutant.log" rc
  set +e
  "$dir/harness" "$WORK/ref" > "$log" 2>&1
  rc=$?
  set -e
  if (( rc == 1 )) && grep -qE '^profile-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" && failed_check "$log" "$target"; then
    caught=$(( caught + 1 ))
    echo "  ok    mutation '$name' ($file) is caught by its check '$target'"
  else
    echo "  FAIL  mutation '$name' ($file) exited $rc without failing its check '$target':"
    sed 's/^/        /' "$log" | head -40
  fi
}

# --- The registered five (the other three moved to the kit with distance and angle).
caught=0
LP="Compute/LineProfile.swift"
# (Distance and angle are ImagoKit's `ImageMeasurement` since 0.5.0: the kit's own tests hold their closed forms and mutants; this harness still
# checks them through the seam, above.)
# (4) the width ignored (the seam's own rule: a width below 1 is 1, otherwise the caller's).
source_mutant width-ignored $LP 'profile wave horizontal w3 samples' \
  'let w = max(1, width)' 'let w = 1'
# The line profile's numbers are ImagoKit's (0.4.0); its own tests hold the fold against scikit-image. What this harness holds is
# the seam's choice of options: bilinear, "reflect", the mean, float64 arithmetic.
# (5) "nearest" (the coordinate clamped to the image) for "reflect".
source_mutant nearest-for-reflect $LP 'profile wave border-crossing w1 samples' \
  'mode: .reflect' 'mode: .nearest'
# (6) the sum across the width for the mean.
source_mutant sum-for-mean $LP 'profile wave horizontal w3 samples' \
  'reduce: .mean' 'reduce: .sum'
# (7) nearest-neighbour interpolation for bilinear.
source_mutant order-nearest-for-linear $LP 'profile wave diagonal w3 samples' \
  'order: .linear' 'order: .nearest'
# (8) float32 arithmetic for float64 (the f64 checks, gated at 1e-12 of the image maximum, see the rounding).
source_mutant float32-for-float64 $LP 'profile wave 3-4-5 w1 samples f64' \
  'arithmetic: .float64' 'arithmetic: .float32'
registered=$caught

# --- Extra controls (not registered; each failing one fails the gate as well).
# (10) scipy's "mirror" (about the pixel CENTRES) for "reflect" (about the outer edges): the two names are swapped between
# numpy.pad and scipy.ndimage.
source_mutant mirror-for-reflect $LP 'profile wave border-crossing w1 samples' \
  'mode: .reflect' 'mode: .mirror'
# (11) wrap for reflect.
source_mutant wrap-for-reflect $LP 'profile wave border-crossing w1 samples' \
  'mode: .reflect' 'mode: .wrap'
# (12) constant (zeros beyond the edge) for reflect.
source_mutant constant-for-reflect $LP 'profile wave border-crossing w1 samples' \
  'mode: .reflect' 'mode: .constant'
extras=$(( caught - registered ))
total_extras=3

if (( registered != 5 || extras != total_extras )); then
  echo "profile-parity: negative controls: $registered of 5 registered, $extras of $total_extras extra, caught by their checks"
  exit 1
fi
echo "extra controls (not registered): $extras of $total_extras caught by their checks"
echo "negative controls: $registered of 5 caught by their checks"
