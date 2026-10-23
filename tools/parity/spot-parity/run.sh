#!/bin/zsh
# tools/parity/spot-parity — macTEM's spot d-spacing (Hann-windowed power centroid, archive: roadmap-registrations-2026-10-15.md V1-6 "Slice C") against a numpy
# 2.5.4 script of the same estimator (pinned: tools/lib/references-lock.txt) and the planted spacing d0. Classified
# `scientific` in tools/run-tests.sh. README.md says more.
#
#   run.sh   make_fixture.py writes the planted lattices; reference.py checks numpy against the plant (P1 0.2 % clean,
#            P3 0.5 % noisy, snap = planted maximum, flags, and that every mutation moves its target) and writes
#            manifest.json; the Swift side (main.swift) must match it; then every mutation must fail the check it
#            targets, or the gate fails for being blind.
#
# Pass: "spot-parity: all passed", then "negative controls: 7 of 7 caught by their checks", exit 0.
# macTEM's seam to the kit comes from tools/lib/sources.manifest, group `spot`; the estimator is ImagoKit's (ADR 027).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-spot-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/make_fixture.py" "$WORK/planted"
"$PYTHON_BIN" -I -B "$HERE/reference.py" "$WORK/planted" "$WORK/ref"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" spot
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

# The five estimator mutants edit the kit's SpotMeasurement.swift (the old SpotMeasure.Options controls, which the kit does not
# carry): an edited copy is named in MACTEM_KIT_OVERRIDE, the kit's modules are rebuilt from it (a distinct key under
# build/imagokit) and the harness is compiled against them. Each edit must change the file, or the control is blind.
KIT="$("$ROOT/tools/lib/fetch-imagokit.sh" 2> /dev/null | tail -1)"
kit_mutant() {   # <name> -> prints the path of the edited SpotMeasurement.swift
  "$PYTHON_BIN" -I -B - "$KIT/Sources/ImagoFFT/SpotMeasurement.swift" "$1" "$WORK/kit-$1.swift" <<'PY'
import sys
src, name, dst = sys.argv[1:4]
s = open(src).read()
edits = {
  "no-mean": ("let mean = source.pixels.reduce(0.0) { $0 + Double($1) } / Double(w * h)", "let mean = 0.0"),
  "no-hann": ("let hx = hanning(w), hy = hanning(h)", "let hx = [Double](repeating: 1, count: w), hy = [Double](repeating: 1, count: h)"),
  "window-3x3": ("let half = 2\n", "let half = 1\n"),
  "magnitude-weights": ("            let v = p(r, c)\n            sum += v;", "            let v = p(r, c).squareRoot()\n            sum += v;"),
  "no-snap": ("if let first = window.first(where: { p($0.0, $0.1) >= best * (1 - 1e-6) }) { (sr, sc) = first }", "if best < 0, let first = window.first(where: { p($0.0, $0.1) >= best * (1 - 1e-6) }) { (sr, sc) = first }"),
}
old, new = edits[name]
assert s.count(old) == 1, (name, s.count(old))
open(dst, "w").write(s.replace(old, new))
PY
  print -r -- "$WORK/kit-$1.swift"
}

"$WORK/harness" "$WORK/ref"

# Negative controls. A mutant is caught only when the harness exits exactly 1 (its own failure exit: an unknown
# mutation exits 64, a crash by signal) AND its log holds a failure of the check the mutation targets. Targets are
# cases where reference.py (which asserts this before the Swift side runs) shows the mutation moves the target:
#   dc1000-128x128-k5 (DC 1000, spot at 5 bins): without the mean the DC skirt wins the snap and the spot is refused near DC (its d check).
#   s128x128-k5-a70-o0.25_0.5 (anisotropic, ky 5.5 > kx 2.25, sub-bin offset): no-hann 0.18 px, window-3x3 0.030 px,
#     magnitude-weights 0.032 px (centroid check, band 1e-6 px); one-spacing 40 % and qx-only 58 % (d check, band 0.2 %).
#   x128-k5-o0.25_0.25-c0_2 (click 2 columns off the maximum): no-snap moves the centroid by 0.096 px.
mutations=(no-mean no-hann window-3x3 magnitude-weights no-snap one-spacing qx-only)
typeset -A targets=(
  no-mean            'dc1000-128x128-k5 d'
  no-hann            's128x128-k5-a70-o0.25_0.5 centroid'
  window-3x3         's128x128-k5-a70-o0.25_0.5 centroid'
  magnitude-weights  's128x128-k5-a70-o0.25_0.5 centroid'
  no-snap            'x128-k5-o0.25_0.25-c0_2 centroid'
  one-spacing        's128x128-k5-a70-o0.25_0.5 d'
  qx-only            's128x128-k5-a70-o0.25_0.5 d'
)
caught=0
for mutation in $mutations; do
  log="$WORK/mutant-$mutation.log"
  target="${targets[$mutation]:-}"
  set +e
  exe="$WORK/harness"
  case "$mutation" in
    no-mean|no-hann|window-3x3|magnitude-weights|no-snap)
      MACTEM_KIT_OVERRIDE=( [Sources/ImagoFFT/SpotMeasurement.swift]="$(kit_mutant "$mutation")" )
      mactem_sources "$ROOT" spot
      exe="$WORK/harness-$mutation"
      mactem_swiftc "$exe" "$HERE/main.swift"
      MACTEM_KIT_OVERRIDE=() ;;
  esac
  MACTEM_PARITY_MUTATE=$mutation "$exe" "$WORK/ref" > "$log" 2>&1
  rc=$?
  set -e
  if [[ -n "$target" ]] && (( rc == 1 )) \
     && grep -qE '^spot-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" \
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
  echo "spot-parity: negative controls: $caught of ${#mutations} caught by their checks"
  exit 1
fi
echo "spot-parity: negative controls: ${#mutations} of ${#mutations} caught by their checks"
