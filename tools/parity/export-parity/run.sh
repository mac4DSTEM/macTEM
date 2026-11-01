#!/bin/zsh
# tools/parity/export-parity — macTEM's Image room export (`ImageExport`, `ProfileCSV`, `ExportFile`) read back with Pillow 12.3.0,
# numpy 2.5.4 and Python's own `float` (pinned: tools/lib/references-lock.txt, reference.py). Classified `scientific` in
# tools/run-tests.sh. Checks P1, P3, P4, P5, P6; and P5-band, the angle's arms and P7, the label, added by a review.
# README.md says more.
#
#   run.sh   reference.py plants every input and its truth (pixels, look-up tables, calibrations, windows, marks, profile ends,
#            and the bar each case must draw, worked by hand); the harness (main.swift) writes the PNGs and CSVs with the
#            production code and dumps what it held in memory; reference.py reads it all back and checks it; then every
#            mutation of the app's export code (the CSV writers are ImagoKit's since 0.5.0; their mutants live in the kit) must fail the check it targets, or the gate fails for being blind. Each
#            mutation edits a COPY of one of the files (never the file in Sources/) and builds the harness against it.
#
# Pass: "export-parity: all passed", the extra controls line, then "negative controls: 16 of 16 caught by their checks", exit 0.
# The harness is Package.swift's ExportParity target over TEMCore (tools/lib/harness.sh builds it); the planted DM fixture and the
# real RosettaSciIO image enter through ImageOpening (the readers themselves are FormatoKit's).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
FIXTURE="$ROOT/macTEMTests/Fixtures/planted-2d.dm4"
PLANTED="$ROOT/macTEMTests/Fixtures/planted-2d.truth.json"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-export-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
"$ROOT/tools/lib/fetch-rsciio.sh"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/reference.py" plant "$FIXTURE" "$PLANTED" "$ROOT/References/rosettasciio" "$WORK/ref"

. "$ROOT/tools/lib/harness.sh"
mactem_harness_build ExportParity "$WORK/harness"

"$WORK/harness" "$WORK/ref" "$WORK/out"
"$PYTHON_BIN" -I -B "$HERE/reference.py" check "$WORK/ref" "$WORK/out"

# Negative controls. A mutant is caught only when reference.py exits exactly 1 (its own failure exit: a crash by signal, or the
# harness failing to render, is not a catch) AND its log holds a "  FAIL  " line of EVERY check the mutation targets (`|`
# separates them; a check is named by the text before ": " on its line, and a target also names every check below it:
# "P5-ring/p5-u1" is "P5-ring/p5-u1/0", "P5-ring/p5-u1/1", ...). Each edit applies to a COPY of the file in the scratch
# directory, must match its target text exactly once (a changed line makes the mutation fail LOUDLY, to be re-aimed), the
# harness must compile against it with no warning, and then the harness and reference.py run on the planted cases the
# mutation is aimed at (a case list and a variant list: a 4096-pixel render is not repeated for a CSV mutation), against the
# SAME planted inputs as the unmutated run. The mutants are independent, so they build and run in batches of JOBS at a time;
# their results are printed in order.
CORE="$ROOT/Sources/TEMCore/Data"
JOBS=${MACTEM_PARITY_JOBS:-6}   # mutants run at a time (their builds take turns: tools/lib/harness.sh)
failed_check() {   # failed_check <log> <target>: does <log> hold a "  FAIL  " line of that check (or of one below it)?
  awk -v want="$2" 'index($0, "  FAIL  ") == 1 { rest = substr($0, 9); if (index(rest, want ": ") == 1 || index(rest, want "/") == 1) hit = 1 } END { exit !hit }' "$1"
}
caught_by() {      # caught_by <log> <rc> <'|'-separated targets>
  local log=$1 rc=$2 spec=$3 target
  (( rc == 1 )) || return 1
  grep -qE '^export-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" || return 1
  for target in "${(@s:|:)spec}"; do failed_check "$log" "$target" || return 1; done
}

# mutant_job <id> <kind> <name> <file under Sources/TEMCore/Data> <targets> <cases> <variants> <old> <new> [<old> <new>]...
# Runs in a background subshell; writes $WORK/result-<id> (first line: caught | missed) for `report_mutants`.
mutant_job() {
  local id=$1 kind=$2 name=$3 file=$4 spec=$5 cases=$6 variants=$7; shift 7
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
  if ! mactem_harness_mutant ExportParity "$dir/harness" "Sources/TEMCore/Data/$file" "$copy" > "$dir/build.log" 2>&1; then
    { echo missed; echo "  FAIL  mutation '$name' does not compile:"; sed 's/^/        /' "$dir/build.log"; } > "$res"
    return
  fi
  local log="$dir/mutant.log" hrc rc
  set +e
  "$dir/harness" "$WORK/ref" "$dir/out" "$cases" "$variants" > "$dir/harness.log" 2>&1
  hrc=$?
  if (( hrc != 0 )); then
    { echo missed; echo "  FAIL  mutation '$name' ($file): the harness exited $hrc before reference.py could see its output:"
      sed 's/^/        /' "$dir/harness.log" | head -20; } > "$res"
    return
  fi
  "$PYTHON_BIN" -I -B "$HERE/reference.py" check "$WORK/ref" "$dir/out" "$cases" "$variants" > "$log" 2>&1
  rc=$?
  if caught_by "$log" $rc "$spec"; then
    { echo caught; echo "  ok    mutation '$name' ($file) is caught by its check '${spec//|/' and '}'"; } > "$res"
  else
    { echo missed; echo "  FAIL  mutation '$name' ($file) exited $rc without failing its check '${spec//|/' and '}':"
      sed 's/^/        /' "$log" | head -40; } > "$res"
  fi
}

typeset -i seq=0 running=0
typeset -a kinds=()
source_mutant() {  # source_mutant <registered|extra> <name> <file> <targets> <cases> <variants> <old> <new> [<old> <new>]...
  seq=$(( seq + 1 ))
  kinds+=("$1")
  ( mutant_job "$seq" "$@" ) &
  running=$(( running + 1 ))
  if (( running >= JOBS )); then wait; running=0; fi
}

PC=ProfileCSV.swift
IE=ImageExport.swift
IO='ImageExport+Overlays.swift'

# --- The first twenty-four mutations, each red on its own check; seven more join them below (from a review, R1), five more (Results).
# P1, the CSV. (1) %.15g: a double no longer re-reads bit-equal.
# (2) positions in pixels although the axes are calibrated (the pixel length scaled back from the position).
# (3) positions in the unit the app shows (nm), though the file states metres: the Velox case.
# (4) the profile reversed.
# (5) NaN written as 0.
# (6) x and y swapped in the header's start point.
# P3, the bar. (7) the bar on y's scale (the anisotropic plant: x 0.5 nm, y 0.8 nm).
# (8) the bar's length taken from the label's number after `ladder` rescaled it (the 2 um case): a MISSING bar (0.4 px, which the plate-fit
# rule drops), not a wrong length; (7) is the wrong-length demonstration.
# (9) the length floored (the plant whose length is 75.76 px).
# (10) the bar not snapped to the pixel grid: a half-pixel offset, antialiased edges.
source_mutant registered bar-not-snapped $IO 'P3-drawn/aniso512' aniso512 bar \
  'context.setShouldAntialias(false)' 'context.setShouldAntialias(true)' \
  'context.fill(CGRect(x: layout.barX, y: layout.barTop, width: layout.barWidth, height: layout.barHeight))' \
  'context.fill(CGRect(x: Double(layout.barX) + 0.5, y: Double(layout.barTop), width: Double(layout.barWidth), height: Double(layout.barHeight)))'
# P4, the pixels. (11) the image flipped vertically, (12) flipped horizontally, (13) transposed (up512 is square and asymmetric).
source_mutant registered flipped-vertically $IE 'P4-pixels/up512' up512 plain \
  'let source = shared.source + row * width' 'let source = shared.source + (height - 1 - row) * width'
source_mutant registered flipped-horizontally $IE 'P4-pixels/up512' up512 plain \
  'let (r, g, b) = mapping.rgb(source[column])' 'let (r, g, b) = mapping.rgb(source[width - 1 - column])'
source_mutant registered transposed $IE 'P4-pixels/up512' up512 plain \
  'let (r, g, b) = mapping.rgb(source[column])' 'let (r, g, b) = mapping.rgb(source[column * width + row * (1 - width)])'
# (14) gamma as v^gamma (the exponent not inverted), (15) the window ignored, (16) window and gamma in the wrong order
# (up512: window 0.25-0.63 of the range, gamma 0.5), (17) the LUT sampled nearest (aniso512: a random LUT), (18) a masked
# pixel through the LUT (nan400).
# (19) the colour tag dropped: the bitmap in another colour space, so the PNG carries that profile and no sRGB chunk. (A DEVICE
# RGB context is not a mutation: ImageIO writes an sRGB chunk for it as well, measured 2026-10-13 on macOS 27.0.1.) (20) RGBA written.
source_mutant registered srgb-tag-dropped $IO 'P4-format/aniso512/plain/srgb' aniso512 plain \
  'let space = CGColorSpace(name: CGColorSpace.sRGB),' 'let space = CGColorSpace(name: CGColorSpace.genericRGBLinear),'
source_mutant registered rgba-written $IO 'P4-format/aniso512/plain/ihdr|P4-format/aniso512/plain/pillow' aniso512 plain \
  'bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)' 'bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)'
# P5, the marks (the black plants p5-u1: a horizontal, a vertical and two 30 degree strokes, and four rings). (21) a mark at the
# pixel's corner (no +0.5), (22) a mark's x and y swapped (the 30 degree stroke is not symmetric about the diagonal).
source_mutant registered mark-without-half-pixel $IO 'P5-stroke/p5-u1/horizontal|P5-ring/p5-u1' p5-u1 marks \
  'CGPoint(x: $0.x + 0.5, y: $0.y + 0.5)' 'CGPoint(x: $0.x, y: $0.y)'
source_mutant registered mark-xy-swapped $IO 'P5-stroke/p5-u1/30deg|P5-ring/p5-u1' p5-u1 marks \
  'CGPoint(x: $0.x + 0.5, y: $0.y + 0.5)' 'CGPoint(x: $0.y + 0.5, y: $0.x + 0.5)'
# P6, the footprint. (23) a plate over the whole image, (24) the marks option ignored.
source_mutant registered full-image-plate $IO 'P6-footprint/aniso512/outside' aniso512 full \
  'BarLayout(plate: CGRect(x: margin, y: height - margin - plateHeight, width: plateWidth, height: plateHeight),' \
  'BarLayout(plate: CGRect(x: 0, y: 0, width: width, height: height),'
source_mutant registered marks-option-ignored $IE 'P6-footprint/aniso512/bar-only-marks-untouched' aniso512 bar \
  'if options.marks { drawMarks(marks, in: context, width: width, height: height, overlayScale: u) }' \
  'drawMarks(marks, in: context, width: width, height: height, overlayScale: u)'

# A review (round 1, R1) found that these seven mutants of registered claims stayed green against the first twenty-four, and added the
# plants and checks that catch them; they are REGISTERED controls now (thirty-one in all), because each answers a registered claim.
# (25) the drawn length biased by +0.2 px (P3-drawn is "round half up"; frac40's 74.40 gives 74, and 75 with the bias) and (26) rounded half
# to even (tie512's 62.5 gives 63, and 62 here).
# P5 (marks sit where they were measured), the profile's band and the angle's arms (the black plants p5x-u1 and -u2). (27) a band
# twice as wide as the width the profile averages over, (28) a band never drawn, (29) an angle drawn through the wrong vertex.
source_mutant registered band-twice-as-wide $IO 'P5-band/p5x-u1' p5x-u1 marks \
  'let half = Double(mark.width) / 2' 'let half = Double(mark.width)'
source_mutant registered band-never-drawn $IO 'P5-band/p5x-u1' p5x-u1 marks \
  'if mark.kind == .profile, mark.width > 1, points.count == 2 {' 'if mark.kind == .profile, mark.width > 1_000_000, points.count == 2 {'
source_mutant registered angle-drawn-through-the-wrong-vertex $IO 'P5-stroke/p5x-u1/angle-arm-1' p5x-u1 marks \
  $'                context.addLines(between: points)\n                context.strokePath()' \
  $'                context.addLines(between: (mark.kind == .angle && points.count == 3) ? [points[0], points[2], points[1]] : points)\n                context.strokePath()'
# P7 (the label a mark carries is drawn, upright, where it is anchored; the plants p7-u1 and -u2, the labels drawn alone and upright
# by main.swift's own CoreGraphics context). (30) a mark's label never drawn, (31) every label upside down.
source_mutant registered mark-label-not-drawn $IO 'P7-label/p7-u1/mark-0' p7-u1 marks,bar \
  'guard let anchor, !mark.label.isEmpty, let text = textLine(mark.label, font: font) else { continue }' \
  'guard let anchor, !mark.label.isEmpty, mark.label.count < 0, let text = textLine(mark.label, font: font) else { continue }'
source_mutant registered label-upside-down $IO 'P7-label/p7-u1/mark-0|P7-label/p7-u1/bar' p7-u1 marks,bar \
  'context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)' 'context.textMatrix = CGAffineTransform(scaleX: 1, y: 1)'

# R-P1, the Results room's CSV (its mutations): the case `results`,
# five more registered controls, each red on the check it targets. (37) %.15g: the planted 0.1, 1/3 and the lattice's spot no longer
# re-read bit-equal. (38) a dropped quote: the planted label with a comma, a quote and a newline splits its line. (39) the NaN case written
# as 0. (40) the validation line of one product (the angle's) omitted from the header. (41) a spot's |q| in place of its d.
RC=ResultsCSV.swift
RR=ResultRow.swift
source_mutant registered results-spot-q-for-d $RR 'R-P1/spot-values' results all \
  'Entry("d", m.d, unit: m.units, text: neighbour),' 'Entry("d", m.q, unit: m.units, text: neighbour),'

# --- Extra controls (not registered; each failing one fails the gate as well).
# (42) the Results CSV drops the "unvalidated (reader note)" qualifier from its header lines and its validation column (the case
# `results-unvalidated`: a file whose reader notes say so; unvalidated stays labelled).
# (32) the scale bar option ignored.
source_mutant extra scale-bar-option-ignored $IE 'P6-footprint/aniso512/marks-only-plate-untouched' aniso512 marks \
  'if options.scaleBar {' 'if true {'
# (33) round half to even in the colour's last step (uncal640's canvas sits at t = 1/2 between two gray texels everywhere).
# (34) the overlay scale from min(W, H) / 256.
# (35) header values not sanitised (a file name with CR, LF, U+2028 starts a line of its own).
# (36) the RFC 4180 quoting inverted: the column header's unit with a comma and a quote is written bare.
# --- Review round 1 additions beyond the first set: the other mutants that stayed green, each red on a check the first harness
# did not have (P5-band, P7-label, P4-format/<case>/meta on unitsmix512 and yonly512).
source_mutant extra band-along-the-line $IO 'P5-band/p5x-u1' p5x-u1 marks \
  'let nx = -dy / length * half, ny = dx / length * half' 'let nx = dx / length * half, ny = dy / length * half'
source_mutant extra band-scaled-by-u $IO 'P5-band/p5x-u2' p5x-u2 marks \
  'let half = Double(mark.width) / 2' 'let half = Double(mark.width) / 2 * scale'
source_mutant extra mark-label-unit-dropped $IO 'P7-label/p7-u1/mark-0' p7-u1 marks,bar \
  'let text = textLine(mark.label, font: font) else { continue }' \
  'let text = textLine(String(mark.label.split(separator: " ").first ?? ""), font: font) else { continue }'
source_mutant extra mark-label-one-point-further-right $IO 'P7-label/p7-u1/mark-0' p7-u1 marks,bar \
  'let x = min(max(anchor.x + 6 * scale, 2 * scale)' 'let x = min(max(anchor.x + 7 * scale, 2 * scale)'
source_mutant extra mark-bias-0.04-px $IO 'P7-label/p7-u1/mark-0' p7-u1 marks,bar \
  'CGPoint(x: $0.x + 0.5, y: $0.y + 0.5)' 'CGPoint(x: $0.x + 0.54, y: $0.y + 0.54)'
source_mutant extra y-scale-hidden-without-x $IE 'P4-format/yonly512' yonly512 plain \
  '"x_scale": axis(source.x), "y_scale": axis(source.y),' '"x_scale": axis(source.x), "y_scale": source.x == nil ? .null : axis(source.y),'
wait

# Report, in order.
caught=0 registered=0 extras=0 total_registered=16 total_extras=7
for (( i = 1; i <= seq; i++ )); do
  [[ -f "$WORK/result-$i" ]] || { echo "  FAIL  mutation #$i left no result"; continue; }
  sed 1d "$WORK/result-$i"
  if [[ "$(head -1 "$WORK/result-$i")" == caught ]]; then
    caught=$(( caught + 1 ))
    if [[ "${kinds[$i]}" == registered ]]; then registered=$(( registered + 1 )); else extras=$(( extras + 1 )); fi
  fi
done

if (( registered != total_registered || extras != total_extras )); then
  echo "export-parity: negative controls: $registered of $total_registered registered, $extras of $total_extras extra, caught by their checks"
  exit 1
fi
echo "extra controls (not registered): $extras of $total_extras caught by their checks"
echo "negative controls: $registered of $total_registered caught by their checks"
