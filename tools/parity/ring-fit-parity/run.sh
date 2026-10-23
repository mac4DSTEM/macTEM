#!/bin/zsh
# tools/parity/ring-fit-parity — macTEM's fit-driven ring calibration (`RingCalibration.fit`, archive: roadmap-registrations-2026-10-15.md "Diffraction S3, Camera
# length from one ring of known d", slice S3-b) on planted rings against their truth, with scipy's optimum of the same
# model printed beside it. Classified `diagnostic` in tools/run-tests.sh: S3-b's P1 and P2 FAILED on 2026-10-13 and this
# harness is that result's evidence (README.md); a new registration that passes on it makes it `scientific`.
#
#   run.sh   plants.py writes the plants, their truth and scipy's optimum; main.swift fits every plant, gates P1 (the clean
#            tier's accepted rings) and P2 (each refusal on its own plant), and prints every tier's distribution; then
#            every control runs on its own target case, which must pass unmutated first.
#
# Exit: the full run's checks and the controls both pass -> 0; otherwise 1. TEMCore sources come from
# tools/lib/sources.manifest, group `ring`. A full run takes about three minutes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-ring-fit-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/plants.py" "$WORK/ref"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" ring
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

set +e
"$WORK/harness" "$WORK/ref"
main_rc=$?
set -e

# The public Au pattern, a first look printed and never gated (au.swift), when tools/parity/au-ring-pattern/ has derived it here.
au_tif="$ROOT/References/ring-calibration/zenodo-8354219-au-thin-film-arina/derived_mean_pattern_data000001_192x192_float32.tif"
if [[ -f "$au_tif" ]]; then
  mactem_sources "$ROOT" tiff ring
  mactem_swiftc "$WORK/au" "$HERE/au.swift"
  "$WORK/au" "$au_tif" || echo "ring-fit-parity: the Au first look exited $? (printed only, not gated)"
else
  echo "ring-fit-parity: no Au pattern at $au_tif (tools/parity/au-ring-pattern/README.md derives it); first look skipped"
fi
mactem_sources "$ROOT" ring

# Controls. A mutant is caught only when the harness, run on the target case alone, exits exactly 1 with a FAIL of the
# targeted check — and the same case passes unmutated (exit 0) first, so a case that already fails cannot count.
# `accept-sparse` (the registered `acceptSparseCoverage: true`) is caught only because the check also requires that a
# coverage-refused ring comes back with no fit: its Δq is withheld either way, by `refusals`' own bin bound (README.md).
# The registered `refuse-bound` control is not run and its name is gone (DiffractoKit 0.1.0): its plant never reached the sigma
# bound and is an accepted plant now (`accept-bound`); tools/parity/ring-calibration-parity holds that refusal on both sides of its bound.
clean='clean-512x512-r140-e3-t90-g0-s0'
mutations=(recover radius-a centre refuse-conic refuse-gap accept-sparse refuse-noV)
typeset -A cases=(
  recover       "$clean"
  radius-a      "$clean"
  centre        "$clean"
  refuse-conic  'refuse-conic-512x512-r120-e1-t30-g0-s0'
  refuse-gap    'refuse-gap120-512x512-r120-e3-t45-g120-s0'
  accept-sparse 'refuse-gap120-512x512-r120-e3-t45-g120-s0'
  refuse-noV    'refuse-noV-512x512-r120-e1-t60-g0-s0'
)
typeset -A targets=(
  recover       "$clean dq"
  radius-a      "$clean dq"
  centre        "$clean centre"
  refuse-conic  'refuse-conic-512x512-r120-e1-t30-g0-s0 refuse'
  refuse-gap    'refuse-gap120-512x512-r120-e3-t45-g120-s0 refuse'
  accept-sparse 'refuse-gap120-512x512-r120-e3-t45-g120-s0 refuse'
  refuse-noV    'refuse-noV-512x512-r120-e1-t60-g0-s0 refuse'
)
caught=0
for mutation in $mutations; do
  only="${cases[$mutation]}"
  target="${targets[$mutation]}"
  set +e
  MACTEM_PARITY_ONLY="$only" "$WORK/harness" "$WORK/ref" > "$WORK/base-$mutation.log" 2>&1
  base_rc=$?
  MACTEM_PARITY_ONLY="$only" MACTEM_PARITY_MUTATE=$mutation "$WORK/harness" "$WORK/ref" > "$WORK/mutant-$mutation.log" 2>&1
  rc=$?
  set -e
  if (( base_rc == 0 && rc == 1 )) \
     && grep -qE '^ring-fit-parity: [0-9]+ FAILURES in [0-9]+ checks' "$WORK/mutant-$mutation.log" \
     && awk -v want="$target" 'index($0, "  FAIL  ") == 1 && index($0, want) { hit = 1 } END { exit !hit }' "$WORK/mutant-$mutation.log"; then
    caught=$(( caught + 1 ))
    echo "  ok    mutation '$mutation' is caught by its check '$target'"
  else
    echo "  FAIL  mutation '$mutation': unmutated exit $base_rc, mutated exit $rc, wanted 0 then 1 with a FAIL of '$target':"
    sed 's/^/        /' "$WORK/base-$mutation.log" "$WORK/mutant-$mutation.log"
  fi
done
echo "ring-fit-parity: negative controls: $caught of ${#mutations} caught by their checks"
if (( caught != ${#mutations} )); then
  exit 1
fi
exit $main_rc
