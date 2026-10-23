#!/bin/zsh
# tools/parity/ring-calibration-parity — macTEM's camera-length closed forms and refusal decision (`RingCalibration`,
# archive: roadmap-registrations-2026-10-15.md "Diffraction S3, Camera length from one ring of known d", slice S3-a) against a numpy script of the closed
# forms with CODATA 2018 constants (numpy pinned: tools/lib/references-lock.txt), evaluated in 60-digit decimal arithmetic.
# Classified `scientific` in tools/run-tests.sh (the integrator's to add, with the `ring` group in tools/lib/sources.manifest).
# README.md says more.
#
#   run.sh   reference.py writes the closed-form table (320 cases, 5 wavelengths, the refusal plants on their boundaries, the
#            radius plants) and
#            checks it against itself (two numerical routes, the textbook wavelengths, every mutation moves its target);
#            the Swift side (main.swift) must match it to 1e-12 relative; then every mutation must fail the check it
#            targets, or the gate fails for being blind.
#
# Pass: "ring-calibration-parity: all passed", then "ring-calibration-parity: negative controls: 8 of 8 caught by their
# checks", exit 0. TEMCore sources come from tools/lib/sources.manifest, group `ring`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-ring-calibration-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/reference.py" "$WORK/ref"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" ring
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

"$WORK/harness" "$WORK/ref"

# Negative controls. A mutant is caught only when the harness exits exactly 1 (its own failure exit: an unknown
# mutation exits 64, a crash by signal) AND its log holds a failure of the check the mutation targets, on a case where
# reference.py (which asserts this before the Swift side runs) shows the mutation moves the target quantity far outside
# the 1e-12 band:
#   q-two-over-d      dq = 2/d/R instead of 1/d/R (x2).                         Au422-80kV-R200-p0.014 formula
#   a-for-nm          d in A read as nm: dq x10.                                 Au422-80kV-R200-p0.014 formula
#   small-angle       L_px = R d / lambda: 9.45e-4 off at 80 kV Au {422}.        Au422-80kV-R200-p0.014 formula
#   pitch-um          the pitch in um used as mm: L_mm x1000.                    Au422-80kV-R200-p0.014 formula
#   non-relativistic  lambda = h / sqrt(2 m0 e V): 3.8 % off at 80 kV.           lambda-80kV wavelength
#   kv-as-v           the kV number passed as volts: lambda x32.8 at 80 kV.      lambda-80kV wavelength
#   v-default         a missing V taken as 200 kV: the refusal does not fire.    noV-missing refuse-noV
#   radius-a          FitReport.radius taken as the first axis, not (a+b)/2: 1.5 % off at 3 % ellipticity.
#                                                                                ellipse-3pct-minor100-a-major radius
# The mutations other than v-default are emulated on the closed forms' outputs (the Core functions take plain numbers
# and have no option to break); v-default and kv-as-v change what is passed to them.
mutations=(q-two-over-d a-for-nm small-angle pitch-um non-relativistic kv-as-v v-default radius-a)
typeset -A targets=(
  q-two-over-d      'Au422-80kV-R200-p0.014 formula'
  a-for-nm          'Au422-80kV-R200-p0.014 formula'
  small-angle       'Au422-80kV-R200-p0.014 formula'
  pitch-um          'Au422-80kV-R200-p0.014 formula'
  non-relativistic  'lambda-80kV wavelength'
  kv-as-v           'lambda-80kV wavelength'
  v-default         'noV-missing refuse-noV'
  radius-a          'ellipse-3pct-minor100-a-major radius'
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
     && grep -qE '^ring-calibration-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" \
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
  echo "ring-calibration-parity: negative controls: $caught of ${#mutations} caught by their checks"
  exit 1
fi
echo "ring-calibration-parity: negative controls: ${#mutations} of ${#mutations} caught by their checks"
