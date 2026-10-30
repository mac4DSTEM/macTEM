#!/bin/zsh
# tools/parity/diffraction-room-parity — the Diffraction room's core, slice 1a (TEMCore/Diffraction: StandardCrystals; RingOverlay, IndexingDisplay and CrystalLoading are DiffractoKit's since the 2026-10-20 switch,
# calling DiffractoKit directly; archive: roadmap-registrations-2026-10-15.md "Diffraction room, slice 1a"
# and its addendum) against reference.py's numpy and 60-digit decimal tables and plants.py's planted rings. R8 (the seed-rule grid) is not
# part of this run. Classified `scientific` in tools/run-tests.sh. README.md says more.
#
#   run.sh   plants.py writes the planted rings (R8's grid in its half form, unused here); reference.py writes the tables and checks them
#            against themselves; the Swift side (main.swift) fits the planted rings on 4 workers (R1, R2, R4) and compares every table
#            (R3, R5, R6, R7, R9); then every control runs on its own target and must turn the NAMED check red.
#
# Pass: "diffraction-room-parity: all passed", then "diffraction-room-parity: negative controls: 34 of 34 caught by their checks", exit 0.
# A full run takes about five minutes (the fits dominate: R2 fits each of 275 plants three times).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-diffraction-room-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$ROOT/tools/lib/fetch-py4dstem-scattering.sh" > /dev/null
"$PYTHON_BIN" -I -B "$HERE/plants.py" "$WORK/plants" --r8 half
"$PYTHON_BIN" -I -B "$HERE/reference.py" "$ROOT/References/py4dstem-scattering/scattering_factors.txt" "$WORK/ref" \
  --plants "$WORK/plants" --cif-dir "$ROOT/References/crystal-structures"

. "$ROOT/tools/lib/harness.sh"
mactem_harness_build DiffractionRoomParity "$WORK/harness"

set +e
"$WORK/harness" "$WORK/plants" "$WORK/ref" "$ROOT/References/crystal-structures"
main_rc=$?
set -e

# Controls. A mutant is caught only when the harness exits exactly 1 (an unknown mutation exits 64, a crash by signal) AND its log holds a
# FAIL line of the check KIND the mutation targets ("  FAIL  <kind> <case>: ..."), on a run restricted to the section (and, for the fitted
# ones, the one plant) that holds the target, which passes unmutated first (exit 0). The mutations are EMULATED on the outputs of the core's
# functions or on what is passed to them (the core has no option to break); main.swift's header lists them.
#   R1 (plant r1-384x512-r120-e3-t30: 384 x 512, so a row/column swap moves the centre by 57 px; 3 % ellipticity at 30 degrees)
#      xy-swap ab-swap theta-sign theta-deg corner-offset                                  -> R1 on-truth
#   R2 (clean-512x512-r140-e3-t90-g0-s0; the sparse one on refuse-gap120-512x512-r120-e3-t45-g120-s0)
#      v-default refusals-noV annulus-sum radius-a accept-sparse sigma-swap                -> R2 pin
#   R3 small-angle no-half kv-as-v two-pi linear-with-V                                    -> R3 q
#   R4 g-over-dq -> R4 radius; offsets-kept image-centre -> R4 on-truth
#   R5 x10 x2pi mrad-no-lambda -> R5 spelling; ratio-inverted -> R5 fit-vs-file
#   R6 delta-over-measured -> R6 delta; pct-x10 -> R6 delta-pct; tol-fraction sigma-pct -> R6 sigma-q; odds-margin -> R6 odds; z-no-tol -> R6 z
#   R7 au-4.0872 -> R7 family; no-diamond occupancy-ignored -> R7 count (the kit refuses Cu3Au's two sites on one position at occupancy 1)
#   R9 fp-reencoded -> R9 hash; cap-off-by-one -> R9 cap
clean='clean-512x512-r140-e3-t90-g0-s0'
gap='refuse-gap120-512x512-r120-e3-t45-g120-s0'
r1p='r1-384x512-r120-e3-t30'
r4p='r4-p1.155-384x512-r80-e3-t30'
r4q='r4-p1.41-512x640-r150-e3-t30'   # ratio 1.41, R 150, 3 %: offsets kept instead of scaled are 0.9 px off here (0.3 px at ratio 1.155, R 80)
typeset -a controls=(
  "xy-swap|R1|$r1p|R1 on-truth"        "ab-swap|R1|$r1p|R1 on-truth"       "theta-sign|R1|$r1p|R1 on-truth"
  "theta-deg|R1|$r1p|R1 on-truth"      "corner-offset|R1|$r1p|R1 on-truth"
  "v-default|R2|$clean|R2 pin"         "refusals-noV|R2|$clean|R2 pin"     "annulus-sum|R2|$clean|R2 pin"
  "radius-a|R2|$clean|R2 pin"          "accept-sparse|R2|$gap|R2 pin"      "sigma-swap|R2|$clean|R2 pin"
  "small-angle|R3||R3 q"               "no-half|R3||R3 q"                  "kv-as-v|R3||R3 q"
  "two-pi|R3||R3 q"                    "linear-with-V|R3||R3 q"
  "g-over-dq|R4|$r4p|R4 radius"        "offsets-kept|R4|$r4q|R4 on-truth"  "image-centre|R4|$r4p|R4 on-truth"
  "x10|R5||R5 spelling"                "x2pi|R5||R5 spelling"              "mrad-no-lambda|R5||R5 spelling"
  "ratio-inverted|R5||R5 fit-vs-file"
  "delta-over-measured|R6||R6 delta"   "pct-x10|R6||R6 delta-pct"          "tol-fraction|R6||R6 sigma-q"
  "odds-margin|R6||R6 odds"            "z-no-tol|R6||R6 z"                 "sigma-pct|R6||R6 sigma-q"
  "au-4.0872|R7||R7 family"            "no-diamond|R7||R7 count"           "occupancy-ignored|R7||R7 count"
  "fp-reencoded|R9||R9 hash"           "cap-off-by-one|R9||R9 cap"
)
caught=0
for control in $controls; do
  mutation="${control%%|*}"; rest="${control#*|}"
  section="${rest%%|*}"; rest="${rest#*|}"
  plant="${rest%%|*}"; target="${rest#*|}"
  penv=(MACTEM_PARITY_SECTIONS="$section")
  [[ -n "$plant" ]] && penv+=(MACTEM_PARITY_ONLY="$plant")
  set +e
  env "${penv[@]}" "$WORK/harness" "$WORK/plants" "$WORK/ref" "$ROOT/References/crystal-structures" > "$WORK/base-$mutation.log" 2>&1
  base_rc=$?
  env "${penv[@]}" MACTEM_PARITY_MUTATE="$mutation" "$WORK/harness" "$WORK/plants" "$WORK/ref" "$ROOT/References/crystal-structures" > "$WORK/mutant-$mutation.log" 2>&1
  rc=$?
  set -e
  if (( base_rc == 0 && rc == 1 )) \
     && grep -qE '^diffraction-room-parity: [0-9]+ FAILURES in [0-9]+ checks' "$WORK/mutant-$mutation.log" \
     && awk -v want="$target" 'index($0, "  FAIL  " want " ") == 1 { hit = 1 } END { exit !hit }' "$WORK/mutant-$mutation.log"; then
    caught=$(( caught + 1 ))
    echo "  ok    mutation '$mutation' is caught by its check '$target'"
  else
    echo "  FAIL  mutation '$mutation': unmutated exit $base_rc, mutated exit $rc, wanted 0 then 1 with a FAIL of '$target':"
    sed 's/^/        /' "$WORK/base-$mutation.log" "$WORK/mutant-$mutation.log" | head -60
  fi
done
echo "diffraction-room-parity: negative controls: $caught of ${#controls} caught by their checks"
if (( caught != ${#controls} )); then
  exit 1
fi
exit $main_rc
