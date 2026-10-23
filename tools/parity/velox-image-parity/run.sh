#!/bin/zsh
# tools/parity/velox-image-parity — macTEM's Velox image reader (`ImageOpening.openNow` → `VeloxImageReader`, over FormatoKit's
# `VeloxEMDReader`) against the registered object rule written independently from the raw JSON, h5py 3.16.0 and RosettaSciIO
# 049e7d70 (`rsciio.emd.file_reader(select_type="images")`; pinned: tools/lib/references-lock.txt, tools/lib/fetch-rsciio.sh;
# the reader's own source: tools/lib/fetch-formatokit.sh). Classified `scientific` in tools/run-tests.sh.
# Pre-registration: archive: roadmap-registrations-2026-10-15.md "V1-3a Velox EMD images" (the 2026-10-13 amendment and the re-registration govern). README.md says more.
#
#   run.sh --make-fixture   rewrite macTEMTests/Fixtures/velox-*.emd and velox.truth.json (the unit tests' planted files; commit
#                           them and review the diff: they are written twice and must be byte-for-byte reproducible)
#   run.sh   make_fixture.py writes the planted Velox files and the memory plant; reference.py checks the rule, h5py and
#            RosettaSciIO against every planted truth and against each other, then writes the expected reading of every case
#            (manifest.json + .f32 frames); the Swift reader must match it (main.swift); then every mutation of the adapter,
#            each a scratch copy of VeloxImageReader.swift with one edit, must fail the check named for it, or the gate
#            fails for being blind.
#
# Pass: "velox-image-parity: all passed", then "negative controls: 14 of 14 caught by their checks" and ".emd metadata
# negative controls: 3 of 3 caught by their checks", exit 0.
# The owner's Ceta .emd (References/example_files/, gitignored) are a diagnostic: skipped with a printed line when absent.
# TEMCore sources come from tools/lib/sources.manifest, groups `velox` and `metadata` (the `.emd` metadata
# reader, V1-4a, is checked here against the same files), FormatoKit's modules are built from its pin; libhdf5 is FormatoKit's, re-signed
# in the scratch directory and named by FORMATO_HDF5_PATH (the kit's loader reads that variable first).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-velox-image-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"

if [[ "${1:-}" == "--make-fixture" ]]; then
  "$PYTHON_BIN" -I -B "$HERE/make_fixture.py" --unit "$ROOT/macTEMTests/Fixtures"
  exit 0
fi

"$ROOT/tools/lib/fetch-rsciio.sh"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

# libhdf5 finds libsz and libaec beside itself (@loader_path), so the three are copied together and signed ad hoc again.
# They are FormatoKit's, the vendored files its three framework binaries are built from (ADR 026; no copy is committed here): the pinned checkout's.
FORMATO_KIT="$("$ROOT/tools/lib/fetch-formatokit.sh")" || { echo "velox-image-parity: FormatoKit is not at its pin"; exit 65; }
mkdir -p "$WORK/hdf5"
for lib in libhdf5.dylib libaec.0.dylib libsz.2.dylib; do
  [[ -f "$FORMATO_KIT/tools/xcframework/vendored/$lib" ]] || { echo "velox-image-parity: $lib is not in FormatoKit's tools/xcframework/vendored"; exit 66; }
  cp "$FORMATO_KIT/tools/xcframework/vendored/$lib" "$WORK/hdf5/$lib"
  codesign -f -s - "$WORK/hdf5/$lib" > /dev/null 2>&1
  codesign --verify "$WORK/hdf5/$lib"
done
export FORMATO_HDF5_PATH="$WORK/hdf5/libhdf5.dylib"

STACK="$WORK/stack/planted-stack-1024x1024x64.emd"
"$PYTHON_BIN" -I -B "$HERE/make_fixture.py" "$WORK/planted"
"$PYTHON_BIN" -I -B "$HERE/make_fixture.py" --stack "$STACK"
"$PYTHON_BIN" -I -B "$HERE/reference.py" "$WORK/planted" "$ROOT/References/rosettasciio" \
  "$ROOT/References/example_files" "$WORK/ref"

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" velox metadata
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

"$WORK/harness" "$WORK/ref" "$STACK"

# Negative controls. The files below are macTEM's adapters and are never edited here: each mutant compiles the harness again
# against an edited COPY of one of them (VeloxImageReader.swift), or of FormatoKit's file that holds the rule since the kit
# switch (FormatoEMD/VeloxImageSelection.swift: the object rule and the axes; FormatoEMD/AcquisitionMetadataVelox.swift: the `.emd`
# metadata), in the scratch directory; a kit file's copy goes in MACTEM_KIT_OVERRIDE and the kit module is rebuilt from it. The edit must apply exactly once (a changed line
# makes the mutation fail LOUDLY, to be re-aimed), the build must succeed, and the mutant must then be caught: the harness
# exits exactly 1 (its own failure exit; a crash by signal is never a catch) AND its log holds a failure of EVERY check the
# mutation targets (`|` separates them; a check is named by the text before ": " on a "  FAIL  " line).
DATA="$ROOT/Sources/TEMCore/Data"
typeset -A caught total
caught=(image 0 metadata 0)
total=(image 0 metadata 0)

failed_check() {   # failed_check <log> <name>: does <log> hold a "  FAIL  " line of check <name>?
  awk -v want="$2: " 'index($0, "  FAIL  ") == 1 && index($0, want) { hit = 1 } END { exit !hit }' "$1"
}
caught_by() {      # caught_by <log> <rc> <'|'-separated targets>
  local log=$1 rc=$2 spec=$3 name
  (( rc == 1 )) || return 1
  grep -qE '^velox-image-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" || return 1
  for name in "${(@s:|:)spec}"; do failed_check "$log" "$name" || return 1; done
}

source_mutant() {  # source_mutant <image|metadata> <file in Sources/TEMCore/Data, or FormatoKit's <Module>/<File>.swift> <name> <targets> <old> <new> [<old> <new>]...
  local group=$1 FILE=$2 name=$3 spec=$4; shift 4
  total[$group]=$(( total[$group] + 1 ))
  local dir="$WORK/source-$name" copy kitrel="" kit
  mkdir -p "$dir"
  copy="$dir/${FILE:t}"
  if [[ "$FILE" == */* ]]; then
    kitrel="Sources/$FILE"
    kit="$("$ROOT/tools/lib/fetch-formatokit.sh")" || { echo "  FAIL  source mutation '$name': FormatoKit is not at its pin"; return; }
    [[ -f "$kit/$kitrel" ]] || { echo "  FAIL  source mutation '$name': FormatoKit has no $kitrel"; return; }
    cp "$kit/$kitrel" "$copy"
  else
    cp "$DATA/$FILE" "$copy"
  fi
  while (( $# >= 2 )); do
    "$PYTHON_BIN" -I -B -c '
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("source mutation: expected exactly one occurrence of the edit target, found %d: %s" % (text.count(old), old))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
' "$copy" "$1" "$2" || { echo "  FAIL  source mutation '$name' does not apply to $FILE"; return; }
    shift 2
  done
  local -a saved=("${MACTEM_SOURCES[@]}") edited=()
  local src
  if [[ -n "$kitrel" ]]; then
    MACTEM_KIT_OVERRIDE=([$kitrel]="$copy")
    if ! mactem_swiftc "$dir/harness" "$HERE/main.swift" > "$dir/build.log" 2>&1; then
      MACTEM_KIT_OVERRIDE=()
      echo "  FAIL  source mutation '$name' does not compile:"
      sed 's/^/        /' "$dir/build.log"
      return
    fi
    MACTEM_KIT_OVERRIDE=()
  else
    for src in "${saved[@]}"; do
      if [[ "${src:t}" == "$FILE" ]]; then edited+=("$copy"); else edited+=("$src"); fi
    done
    if [[ "${edited[(r)$copy]}" != "$copy" ]]; then
      echo "  FAIL  source mutation '$name': $FILE is not among the harness's sources (tools/lib/sources.manifest, groups velox, metadata)"
      return
    fi
    MACTEM_SOURCES=("${edited[@]}")
    if ! mactem_swiftc "$dir/harness" "$HERE/main.swift" > "$dir/build.log" 2>&1; then
      MACTEM_SOURCES=("${saved[@]}")
      echo "  FAIL  source mutation '$name' does not compile:"
      sed 's/^/        /' "$dir/build.log"
      return
    fi
    MACTEM_SOURCES=("${saved[@]}")
  fi
  local log="$dir/mutant.log" rc
  set +e
  "$dir/harness" "$WORK/ref" "$STACK" > "$log" 2>&1
  rc=$?
  set -e
  if caught_by "$log" $rc "$spec"; then
    caught[$group]=$(( caught[$group] + 1 ))
    echo "  ok    mutation '$name' is caught by its check '${spec//|/' and '}'"
  else
    echo "  FAIL  mutation '$name' exited $rc without failing its check '${spec//|/' and '}':"
    sed 's/^/        /' "$log" | head -40
  fi
}

# 1. the image transposed: width and height swapped and the pixels laid out the other way.
source_mutant image VeloxImageReader.swift transpose 'planted-aniso-m shape' \
  'return CalibratedImage(width: entry.width, height: entry.height, pixels: pixels, x: x, y: y,' \
  'return CalibratedImage(width: entry.height, height: entry.width, pixels: (0..<pixels.count).map { pixels[($0 % entry.height) * entry.width + $0 / entry.height] }, x: x, y: y,'
# 2. the frame index ignored: frame 0 is read whatever frame was asked (the label still names the frame asked).
source_mutant image VeloxImageReader.swift frame-index-ignored 'planted-frames frame 2 pixels' \
  'pixels = try reader.readImageFrame(id: entry.id, frame: frame)' \
  'pixels = try reader.readImageFrame(id: entry.id, frame: 0)'
# 3 to 7, 9 and 10 edit FormatoKit's VeloxImageSelection.swift (the object rule and the axes left the app at the kit switch).
# 3. PixelSize width and height swapped: x takes the height, y the width.
source_mutant image FormatoEMD/VeloxImageSelection.swift pixel-size-swapped 'planted-aniso-m x scale|planted-aniso-m y scale' \
  'axis(size: size?.width, unit: m.pixelUnit, offset: m.offset?.x)' \
  'axis(size: size?.height, unit: m.pixelUnit, offset: m.offset?.x)' \
  'axis(size: size?.height, unit: m.pixelUnitY, offset: m.offset?.y)' \
  'axis(size: size?.width, unit: m.pixelUnitY, offset: m.offset?.y)'
# 4. Offset x and y swapped: x takes Offset.y and y takes Offset.x.
source_mutant image FormatoEMD/VeloxImageSelection.swift offset-xy-swapped 'planted-aniso-m x origin|planted-aniso-m y origin' \
  'unit: m.pixelUnit, offset: m.offset?.x)' 'unit: m.pixelUnit, offset: m.offset?.y)' \
  'unit: m.pixelUnitY, offset: m.offset?.y)' 'unit: m.pixelUnitY, offset: m.offset?.x)'
# 5. the offset's sign: origin = +Offset / PixelSize.
source_mutant image FormatoEMD/VeloxImageSelection.swift offset-sign 'planted-aniso-m x origin sign|planted-aniso-m y origin sign' \
  'origin: -(offset ?? 0) / size' 'origin: (offset ?? 0) / size'
# 6. origin = -Offset: the pixel size forgotten, so the origin is in metres, not pixels.
source_mutant image FormatoEMD/VeloxImageSelection.swift origin-is-minus-offset 'planted-aniso-m x origin|planted-aniso-m y origin' \
  'origin: -(offset ?? 0) / size' 'origin: -(offset ?? 0)'
# 7. the y unit read from PixelUnitX (RosettaSciIO's way).
source_mutant image FormatoEMD/VeloxImageSelection.swift y-unit-from-x 'planted-aniso-mixed y units' \
  'unit: m.pixelUnitY, offset: m.offset?.y)' 'unit: m.pixelUnit, offset: m.offset?.y)'
# 8. an int16 entry's values reinterpreted as UInt16 bit patterns.
source_mutant image VeloxImageReader.swift int16-read-unsigned 'planted-int16-negative pixels' \
  'return image(entry, pixels: pixels, frame: frame, fileName: formatoDisplayFileName(path))' \
  'return image(entry, pixels: entry.elementType == .int16 ? pixels.map { Float(UInt16(bitPattern: Int16($0))) } : pixels, frame: frame, fileName: formatoDisplayFileName(path))'
# 9. the first candidate opens, whatever its detector: the HAADF no longer wins.
source_mutant image FormatoEMD/VeloxImageSelection.swift first-candidate-over-haadf 'planted-haadf-last object' \
  'return candidates.first { $0.detectorName == "HAADF" } ?? candidates.first' \
  'return candidates.first'
# 10. an entry whose DetectorIndex names an Analytical detector is a candidate like any other.
source_mutant image FormatoEMD/VeloxImageSelection.swift analytical-not-excluded 'planted-no-haadf object' \
  'return detector.type != analyticalDetectorType' \
  '_ = detector.type; return true'
# 11. a file that is not Velox lists as holding no images, so it is refused as empty, not as not Velox.
source_mutant image VeloxImageReader.swift non-velox-as-empty 'planted-berkeley refusal' \
  'return try reader.images()' 'do { return try reader.images() } catch VeloxEMDError.notVeloxFile { return [] }'
# 12. the whole stack read, and the frame asked taken from it, clamped into the stack (peak memory the size of the stack as
#     Float32; the clamp keeps a frame outside it from trapping, which would be a crash, never a catch).
source_mutant image VeloxImageReader.swift whole-stack-read 'memory stack growth' \
  'pixels = try reader.readImageFrame(id: entry.id, frame: frame)' \
  'pixels = try (0..<entry.frameCount).map { try reader.readImageFrame(id: entry.id, frame: $0) }[min(max(frame, 0), entry.frameCount - 1)]'
# 13. the frame label dropped.
source_mutant image VeloxImageReader.swift frame-label-dropped 'planted-frames frame label' \
  'notes.append("frame \(frame + 1) of \(entry.frameCount)")' '_ = frame'
# 14. the voltage in kV, not volts.
source_mutant image VeloxImageReader.swift voltage-over-1e3 'planted-aniso-m voltage' \
  'voltage: m.accelerationVoltageVolts, notes: notes)' 'voltage: m.accelerationVoltageVolts.map { $0 / 1e3 }, notes: notes)'

# The `.emd` metadata (V1-4a, "the panel", the `.emd` sentence): FormatoKit's AcquisitionMetadataVelox.swift (`.app`), the registered three.
# 15. the high tension left in volts, not kV.
source_mutant metadata FormatoEMD/AcquisitionMetadataVelox.swift voltage-not-over-1e3 'planted-aniso-m metadata highTension' \
  'if let kv = positive(m.accelerationVoltageVolts.map { $0 / 1e3 }) {' 'if let kv = positive(m.accelerationVoltageVolts) {'
# 16. the dwell of a camera image: Scan.DwellTime read whatever the entry's detector is.
source_mutant metadata FormatoEMD/AcquisitionMetadataVelox.swift dwell-on-a-camera-image 'planted-int16-negative metadata dwell' \
  $'if entry.detectorType == "ScanningDetector",\n           let us = positive(m.dwellTimeSeconds.map { $0 * 1e6 }) {' \
  'if let us = positive(m.dwellTimeSeconds.map { $0 * 1e6 }) {'
# 17. the date's zone conversion dropped: the instant shown in UTC, whatever zone is asked for.
source_mutant metadata FormatoEMD/AcquisitionMetadataVelox.swift date-zone-dropped 'planted-aniso-m metadata zone' \
  'calendar.timeZone = timeZone' 'calendar.timeZone = TimeZone(identifier: "UTC") ?? timeZone'

failed=0
if (( caught[image] != total[image] )); then
  echo "velox-image-parity: negative controls: ${caught[image]} of ${total[image]} caught by their checks"
  failed=1
else
  echo "velox-image-parity: negative controls: ${total[image]} of ${total[image]} caught by their checks"
fi
if (( caught[metadata] != total[metadata] )); then
  echo "velox-image-parity: .emd metadata negative controls: ${caught[metadata]} of ${total[metadata]} caught by their checks"
  failed=1
else
  echo "velox-image-parity: .emd metadata negative controls: ${total[metadata]} of ${total[metadata]} caught by their checks"
fi
exit $failed
