#!/bin/zsh
# tools/parity/histogram-parity — macTEM's IntensityHistogram (ImagoKit's, 96 bins; Sources/TEMCore/Compute holds the app extension) against numpy 2.5.4's
# np.histogram(f, bins=96, range=(f.min(), f.max())), f = a[np.isfinite(a)], a float32 (pinned:
# tools/lib/references-lock.txt). Classified `scientific` in tools/run-tests.sh. Pre-registration: archive: roadmap-registrations-2026-10-15.md V1-4
# ("Completed at pickup, 2026-10-13"). README.md says more.
#
#   run.sh   reference.py plants the float32 arrays (every bin edge numpy computes and one ulp either side, constants,
#            non-finite pixels, narrow ranges numpy refuses, signed zeros, 2048^2 images) and checks numpy against what
#            was planted; the harness opens every real image (RosettaSciIO's DM / TIFF / MRC files, the planted DM4, the
#            owner's Ceta TIFFs where present) through ImageOpening.openNow and dumps the pixels; reference.py histograms
#            the same float32 values; the Swift histogram must match numpy bin for bin (main.swift); then every
#            mutation must fail the check it targets, or the gate fails for being blind.
#
# Pass: "histogram-parity: all passed", then "negative controls: 7 of 7 caught by their checks", exit 0.
# The owner's Ceta TIFFs (References/example_files/, gitignored) are gated where present; the summary line says how many
# (machine-local: a clone without them gates none and says so).
# TEMCore sources come from tools/lib/sources.manifest, groups `histogram` and `dm` (the readers the real images open through).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-histogram-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
"$ROOT/tools/lib/fetch-rsciio.sh"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/reference.py" planted "$ROOT/References/rosettasciio" \
  "$ROOT/macTEMTests/Fixtures/planted-2d.dm4" "$ROOT/macTEMTests/Fixtures/planted-2d.truth.json" \
  "$ROOT/References/example_files" "$WORK/ref"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" histogram dm
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

"$WORK/harness" open "$WORK/ref"
"$PYTHON_BIN" -I -B "$HERE/reference.py" real "$WORK/ref"
"$WORK/harness" "$WORK/ref"

# Negative controls. A mutant is caught only when the harness exits exactly 1 (its own failure exit: an unknown
# mutation exits 64, a crash by signal) AND its log holds a failure of the check the mutation targets (a check is named
# by the text before ": " on a "  FAIL  " line) — anything else fails the gate with the mutant's log.
# The first six are SOURCE mutants: each compiles the harness against an edited COPY of ImagoKit's ImagoCore/IntensityHistogram.swift
# (MACTEM_KIT_OVERRIDE; the bin count's mutant edits a copy of the app's Compute/IntensityHistogram.swift) in the
# scratch directory (never a file in Sources/ or in the kit checkout). The edit must apply exactly once (a changed line makes the mutation
# fail LOUDLY, to be re-aimed), the build must succeed, and the mutant must then be caught. The seventh feeds the
# display canvas's normalised pixels to the unedited histogram (MACTEM_PARITY_MUTATE, in main.swift).
failed_check() {   # failed_check <log> <check>: does <log> hold a "  FAIL  " line of that check?
  awk -v want="$2: " 'index($0, "  FAIL  ") == 1 && index($0, want) { hit = 1 } END { exit !hit }' "$1"
}
caught_by() {      # caught_by <log> <rc> <check>
  (( $2 == 1 )) || return 1
  grep -qE '^histogram-parity: [0-9]+ FAILURES in [0-9]+ checks' "$1" || return 1
  failed_check "$1" "$3"
}

CORE="$ROOT/Sources/TEMCore/Compute"
KIT_DIR="$("$ROOT/tools/lib/fetch-imagokit.sh")"
KIT_FILE="Sources/ImagoCore/IntensityHistogram.swift"
caught=0
total=0
source_mutant() {   # source_mutant [--app] <name> <target check> <old> <new> [<old> <new>]...  (--app: the app's file, else the kit's)
  local in_app=0
  if [[ "$1" == --app ]]; then in_app=1; shift; fi
  local name=$1 target=$2; shift 2
  total=$(( total + 1 ))
  local dir="$WORK/source-$name" copy
  mkdir -p "$dir"
  copy="$dir/IntensityHistogram.swift"
  if (( in_app )); then cp "$CORE/IntensityHistogram.swift" "$copy"; else cp "$KIT_DIR/$KIT_FILE" "$copy"; fi
  while (( $# >= 2 )); do
    "$PYTHON_BIN" -I -B -c '
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("source mutation: expected exactly one occurrence of the edit target, found %d: %s" % (text.count(old), old))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
' "$copy" "$1" "$2" || { echo "  FAIL  source mutation '$name' does not apply to IntensityHistogram.swift"; return; }
    shift 2
  done
  local -a saved=("${MACTEM_SOURCES[@]}") edited=()
  local src
  if (( in_app )); then
    for src in "${saved[@]}"; do
      if [[ "${src:t}" == "IntensityHistogram.swift" ]]; then edited+=("$copy"); else edited+=("$src"); fi
    done
    if [[ "${edited[(r)$copy]}" != "$copy" ]]; then
      echo "  FAIL  source mutation '$name': IntensityHistogram.swift is not among the harness's sources (tools/lib/sources.manifest, group histogram)"
      return
    fi
    MACTEM_SOURCES=("${edited[@]}")
  else
    MACTEM_KIT_OVERRIDE[$KIT_FILE]="$copy"
  fi
  if ! mactem_swiftc "$dir/harness" "$HERE/main.swift" > "$dir/build.log" 2>&1; then
    MACTEM_SOURCES=("${saved[@]}"); unset "MACTEM_KIT_OVERRIDE[$KIT_FILE]"
    echo "  FAIL  source mutation '$name' does not compile:"
    sed 's/^/        /' "$dir/build.log"
    return
  fi
  MACTEM_SOURCES=("${saved[@]}"); unset "MACTEM_KIT_OVERRIDE[$KIT_FILE]"
  local log="$dir/mutant.log" rc
  set +e
  "$dir/harness" "$WORK/ref" > "$log" 2>&1
  rc=$?
  set -e
  if caught_by "$log" $rc "$target"; then
    caught=$(( caught + 1 ))
    echo "  ok    source mutation '$name' is caught by its check '$target'"
  else
    echo "  FAIL  source mutation '$name' exited $rc without failing its check '$target':"
    sed 's/^/        /' "$log" | head -40
  fi
}

# (1) the corrections against the edges dropped: the uncorrected index stands (reference.py asserts it is wrong in both
# directions on edges-tenth and edges-sub-unit-neg).
source_mutant edge-corrections-dropped 'edges-tenth counts' \
  'if p < edges[i] { i -= 1 }' 'if p < edges[i] { i -= 0 }' \
  '&& i != bins - 1 { i += 1 }' '&& i != bins - 1 { i += 0 }'
# (2) the last bin half-open: a value on the last edge is not counted.
source_mutant last-bin-half-open 'two-valued counts' \
  'if i == bins { i -= 1 }' 'if i == bins { continue }'
# (3) non-finite pixels counted: only NaN is left out of the statistics, so ±inf is a finite pixel, a minimum and a maximum.
source_mutant non-finite-counted 'mixed-nonfinite finite count' \
  $'for p in pixels where p.isFinite {\n            if p < lowest' $'for p in pixels where !p.isNaN {\n            if p < lowest'
# (4) 95 bins.
source_mutant --app bins-95 'bin count' \
  'package nonisolated static let binCount = 96' 'package nonisolated static let binCount = 95'
# (5) a constant image not widened to ±0.5.
source_mutant constant-not-widened 'constant-7.25 refusal' \
  'if first == last {' 'if first > last {'
# (6) the mean accumulated in Float32.
source_mutant mean-in-float32 'noisy-2048 mean' \
  'block += Double(p)' 'block = Double(Float(block) + p)'

# (7) the histogram of the display canvas (normalised pixels) instead of the raw ones.
total=$(( total + 1 ))
log="$WORK/mutant-display-canvas.log"
set +e
MACTEM_PARITY_MUTATE=display-canvas "$WORK/harness" "$WORK/ref" > "$log" 2>&1
rc=$?
set -e
if caught_by "$log" $rc 'real-planted-2d.dm4 minimum'; then
  caught=$(( caught + 1 ))
  echo "  ok    mutation 'display-canvas' is caught by its check 'real-planted-2d.dm4 minimum'"
else
  echo "  FAIL  mutation 'display-canvas' exited $rc without failing its check 'real-planted-2d.dm4 minimum':"
  sed 's/^/        /' "$log" | head -40
fi

if (( caught != total )); then
  echo "histogram-parity: negative controls: $caught of $total caught by their checks"
  exit 1
fi
echo "histogram-parity: negative controls: $total of $total caught by their checks"
