#!/bin/zsh
# tools/parity/crystal-parity — macTEM's kinematic reflection list (Crystal.reflections, ScatteringFactors) against a numpy
# reference written from the definitions, with py4DSTEM's scattering_factors.txt (commit f050d207, sha256 asserted) as the
# INDEPENDENT source of the Lobato-Van Dyck table. Classified `scientific` in tools/run-tests.sh (done). Pre-registration: archive: roadmap-registrations-2026-10-15.md V1-8 "S1, the kinematic d list". README.md says more.
#
#   run.sh   fetch-py4dstem-scattering.sh provisions the table (network once, then sha256-checked); reference.py writes
#            the reference reflections of Au, Al, Si, Mg and a disordered Cu3Au-like cell, and confirms every mutation
#            moves its target in numpy; the Swift side must match them (main.swift); then every mutation must fail the
#            check it targets, or the gate fails for being blind.
#
# Pass: "crystal-parity: all passed", then "negative controls: 11 of 11 caught by their checks", exit 0.
# TEMCore sources come from tools/lib/sources.manifest, group `crystal`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-crystal-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$ROOT/tools/lib/fetch-py4dstem-scattering.sh"
"$PYTHON_BIN" -I -B "$HERE/reference.py" "$ROOT/References/py4dstem-scattering/scattering_factors.txt" "$WORK/ref"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" crystal
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

"$WORK/harness" "$WORK/ref"

# Negative controls. A mutant is caught only when the harness exits exactly 1 (its own failure exit: an unknown mutation
# exits 64, a crash by signal) AND its log holds a failure of the check the mutation targets. Targets: a wrong table row
# (Au's Z shifted to Pt: |F| moves 1.2 % in numpy) -> Au F; f_e of |g| instead of |g|^2 (Al, 43 %) -> Al F; 1/V dropped (Mg,
# F x 46) -> Mg F; the diamond basis missing (Si: the 4n+2 reflections appear) -> Si absences; occupancy ignored (the
# disordered Cu3Au-like cell) -> Cu3Au-occ F; d scaled by 1 + 1e-10 (inside nothing but the P1 band) -> Au d; one
# reflection dropped -> Al set; the cut-off at 1e-3 -> Weak-cut set; one table row perturbed by 1e-6 -> table; F conjugated
# (exp(-2 pi i h.x); |F| is unchanged, so only the complex check sees it, on non-centrosymmetric hcp Mg) -> Mg Fphase; the list
# reversed -> Al order.
mutations=(table-row fe-of-g no-inverse-volume no-diamond-basis occupancy-ignored d-offset drop-reflection
           tolerance-1e-3 table-perturb phase-conjugate sort-order)
typeset -A targets=(
  table-row          'Au F'
  fe-of-g            'Al F'
  no-inverse-volume  'Mg F'
  no-diamond-basis   'Si absences'
  occupancy-ignored  'Cu3Au-occ F'
  d-offset           'Au d'
  drop-reflection    'Al set'
  tolerance-1e-3     'Weak-cut set'
  table-perturb      'table'
  phase-conjugate    'Mg Fphase'
  sort-order         'Al order'
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
     && grep -qE '^crystal-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" \
     && awk -v want="$target: " 'index($0, "  FAIL  ") == 1 && index($0, want) { hit = 1 } END { exit !hit }' "$log"; then
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
  echo "crystal-parity: negative controls: $caught of ${#mutations} caught by their checks"
  exit 1
fi
echo "crystal-parity: negative controls: ${#mutations} of ${#mutations} caught by their checks"
