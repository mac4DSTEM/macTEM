#!/bin/zsh
# tools/parity/fft-export-parity — macTEM's FFT-room export (V1-10 slice 2: `FFTExport`, ImagoKit's `RadialProfileCSV` and `SpotsCSV`, `ImageExport`'s
# provenance and spot marks) read back with Pillow 12.3.0, numpy 2.5.4 and Python's own `float` (pinned: tools/lib/references-lock.txt,
# reference.py). Classified `scientific` in tools/run-tests.sh. Tier 2 (no pre-registration); the design is
# archive: fft-export-design-2026-10-14.md. README.md says more.
#
#   run.sh   reference.py plants two images with lattices on whole bins, their calibrations, regions, windows and clicks; the harness
#            (main.swift) transforms, measures and writes with the production code and dumps what it held in memory; reference.py
#            reads it all back and checks it (F-1 to F-6); then every mutation of the transform export must turn its check red, or the gate
#            fails for being blind. A mutation edits a COPY of one file (never the file in Sources/) and compiles the harness against it.
#
# Pass: "fft-export-parity: all passed", then "negative controls: N of N caught by their checks", exit 0.
# TEMCore sources come from tools/lib/sources.manifest, group `export` (which holds the FFT cores).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-fft-export-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/reference.py" plant "$WORK/ref"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" export
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

"$WORK/harness" "$WORK/ref" "$WORK/out"
"$PYTHON_BIN" -I -B "$HERE/reference.py" check "$WORK/ref" "$WORK/out"

# Negative controls. A mutant is caught only when reference.py exits exactly 1 AND its log holds a "  FAIL  " line of EVERY check the
# mutation targets (`|` separates them; a target also names every check below it: "F-1-values" is "F-1-values/whole", ...). Each edit
# applies to a COPY of the file, must match its target text exactly once, and the harness must compile against it with no warning.
CORE="$ROOT/Sources/TEMCore/Data"
JOBS=6
failed_check() {
  awk -v want="$2" 'index($0, "  FAIL  ") == 1 { rest = substr($0, 9); if (index(rest, want ": ") == 1 || index(rest, want "/") == 1) hit = 1 } END { exit !hit }' "$1"
}
caught_by() {
  local log=$1 rc=$2 spec=$3 target
  (( rc == 1 )) || return 1
  grep -qE '^fft-export-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" || return 1
  for target in "${(@s:|:)spec}"; do failed_check "$log" "$target" || return 1; done
}

mutant_job() {   # <id> <name> <file> <targets> <old> <new> [<old> <new>]...
  local id=$1 name=$2 file=$3 spec=$4; shift 4
  local dir="$WORK/mutant-$name" res="$WORK/result-$id" copy
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
' "$copy" "$1" "$2" || { { echo missed; echo "  FAIL  mutation '$name' does not apply to $file"; } > "$res"; return; }
    shift 2
  done
  local -a edited=()
  local src
  for src in "${MACTEM_SOURCES[@]}"; do
    if [[ "${src:t}" == "${file:t}" ]]; then edited+=("$copy"); else edited+=("$src"); fi
  done
  MACTEM_SOURCES=("${edited[@]}")
  if ! mactem_swiftc "$dir/harness" "$HERE/main.swift" > "$dir/build.log" 2>&1; then
    { echo missed; echo "  FAIL  mutation '$name' does not compile:"; sed 's/^/        /' "$dir/build.log" | head -20; } > "$res"
    return
  fi
  local log="$dir/mutant.log" hrc rc
  set +e
  "$dir/harness" "$WORK/ref" "$dir/out" > "$dir/harness.log" 2>&1
  hrc=$?
  if (( hrc != 0 )); then
    { echo missed; echo "  FAIL  mutation '$name' ($file): the harness exited $hrc before reference.py could see its output:"
      sed 's/^/        /' "$dir/harness.log" | head -20; } > "$res"
    return
  fi
  "$PYTHON_BIN" -I -B "$HERE/reference.py" check "$WORK/ref" "$dir/out" > "$log" 2>&1
  rc=$?
  if caught_by "$log" $rc "$spec"; then
    { echo caught; echo "  ok    mutation '$name' ($file) is caught by its check '${spec//|/' and '}'"; } > "$res"
  else
    { echo missed; echo "  FAIL  mutation '$name' ($file) exited $rc without failing its check '${spec//|/' and '}':"
      sed 's/^/        /' "$log" | head -30; } > "$res"
  fi
}

typeset -i seq=0 running=0
mutant() {   # <name> <file> <targets> <old> <new> [<old> <new>]...
  seq=$(( seq + 1 ))
  ( mutant_job "$seq" "$@" ) &
  running=$(( running + 1 ))
  if (( running >= JOBS )); then wait; running=0; fi
}

FE=FFTExport.swift
IE=ImageExport.swift
IO='ImageExport+Overlays.swift'

# (F-1 and F-2, the profile and spots writers, are ImagoKit's `RadialProfileCSV` and `SpotsCSV` since 0.5.0: their mutants live in the kit; this harness still reads
# the files back through the app's titles and sentences.)
# F-3 and F-4, the transform and its bar.
mutant space-real $FE 'F-3-meta' \
  '"space": "reciprocal",' '"space": "real",'
mutant bar-on-dq-y $FE 'F-4-plan' \
  'x: AxisCalibration(scale: h.spacingX * ux.factor, unit: ux.label, origin: 0),' 'x: AxisCalibration(scale: h.spacingY * uy.factor, unit: ux.label, origin: 0),'
mutant provenance-validation-kept $IE 'F-3-meta' \
  'object["validation"] = .string(provenance.validation)' 'object["validation"] = object["validation"]'
# F-5, the rings.
mutant ring-without-half-pixel $IO 'F-5-rings' \
  'CGPoint(x: $0.x + 0.5, y: $0.y + 0.5)' 'CGPoint(x: $0.x, y: $0.y)'
mutant ring-radius-3 $IO 'F-5-rings' \
  'let ringRadius = (mark.kind == .spot ? 7.0 : 3.0) * scale' 'let ringRadius = (mark.kind == .spot ? 3.0 : 3.0) * scale'
mutant spot-not-drawn $IO 'F-5-rings' \
  '(mark.kind == .spot ? mark.points.count == 1 : mark.points.count >= 2)' '(mark.kind == .spot ? mark.points.count == 2 : mark.points.count >= 2)'
wait

caught=0
for (( i = 1; i <= seq; i++ )); do
  [[ -f "$WORK/result-$i" ]] || { echo "  FAIL  mutation #$i left no result"; continue; }
  sed 1d "$WORK/result-$i"
  [[ "$(head -1 "$WORK/result-$i")" == caught ]] && caught=$(( caught + 1 ))
done
if (( caught != seq )); then
  echo "fft-export-parity: negative controls: $caught of $seq caught by their checks"
  exit 1
fi
echo "negative controls: $caught of $seq caught by their checks"
