#!/bin/zsh
# tools/parity/metadata-parity — macTEM's acquisition-metadata readers (AcquisitionMetadata.tiff / .mrc / .dm, and slice S-b's
# .read(path:)) against ncempy 1.16, RosettaSciIO 049e7d70, tifffile 2026.9.20 and mrcfile 1.5.4 (pinned:
# tools/lib/references-lock.txt, tools/lib/fetch-rsciio.sh). Classified `scientific` in tools/run-tests.sh.
# Pre-registration: archive: roadmap-registrations-2026-10-15.md "V1-4a Metadata panel" (the compute core; "S-b, the DM wiring and tag 65027"). README.md
# says more.
#
#   run.sh   make_fixture.py writes the planted files and tag maps with their hand-written truth; reference.py checks the
#            references against every planted truth and writes the expected readings of every case (manifest.json); the
#            Swift readers must match them (main.swift); then every mutation must fail the check it targets, or the
#            gate fails for being blind. Fifteen mutations rewrite the harness's inputs or the readings it takes
#            (MACTEM_PARITY_MUTATE); six edit a COPY of one of the app's sources (the open, read(path:); never the file in
#            Sources/) and build the harness against it.
#
# Pass: "metadata-parity: all passed", then "negative controls: 21 of 21 caught by their checks", exit 0.
# The owner's Ceta TIFFs (References/example_files/, gitignored) are gated where present; the summary line says how many
# of the 6 were (machine-local: a clone without them gates 0 of 6 and says so).
# The harness is Package.swift's MetadataParity target over TEMCore (tools/lib/harness.sh builds it).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-metadata-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
"$ROOT/tools/lib/fetch-rsciio.sh"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

"$PYTHON_BIN" -I -B "$HERE/make_fixture.py" "$WORK/planted"
"$PYTHON_BIN" -I -B "$HERE/reference.py" "$WORK/planted" "$ROOT/References/rosettasciio" \
  "$ROOT/References/example_files" "$WORK/ref"

. "$ROOT/tools/lib/harness.sh"
mactem_harness_build MetadataParity "$WORK/harness"

"$WORK/harness" "$WORK/ref"

# Negative controls. A mutant is caught only when the harness exits exactly 1 (its own failure exit: an unknown
# mutation exits 64, a crash by signal) AND its log holds a failure of EVERY check the mutation targets (`|` separates
# them; a check is named by the text before ": " on a "  FAIL  " line) — anything else fails the gate with the mutant's log.
# A CRASH of the harness is therefore never a catch. A mutant that makes the reader TRAP (a slice out of range exits by
# signal, 133 on arm64) is caught only through a case the harness runs in a child process (main.swift, `isolate`): the
# trap kills the child, and the harness itself fails the check `read:<case> survives` and exits 1.
mutations=(kv-unscaled mm-unscaled nil-as-zero stem-cl-in-tem dm-date-swapped mrc-bitmask-ignored mrc-big-endian
           actual-for-indicated frametime-as-dwell
           dm-wrong-object dm-prefix-kept dm-strings-lost dm-creation-dropped tiff-65027-skipped tiff-dm-before-velox)
typeset -A targets=(
  kv-unscaled           'planted-velox-diffraction highTensionKV'
  mm-unscaled           'planted-velox-diffraction cameraLengthMM'
  nil-as-zero           'planted-fei-sem-hv-empty highTensionKV'
  stem-cl-in-tem        'dm-test_dm_image_um_unit-dm3-IL2 cameraLengthMM'
  dm-date-swapped       'planted-dm-tem-diffraction acquired'
  mrc-bitmask-ignored   'planted-fei2-unset-bits highTensionKV'
  mrc-big-endian        'planted-fei2-stem highTensionKV'
  actual-for-indicated  'planted-dm-actual-ne-indicated magnification'
  frametime-as-dwell    'planted-velox-stem dwellUS'
  dm-wrong-object       'read:planted-dm4-two-objects C1 primary object|read:planted-dm4-two-objects highTensionKV'
  dm-prefix-kept        'read:dm-test_STEM_image-dm3-IL2 highTensionKV|read:dm-test_STEM_image-dm3-IL2 C2 numbers'
  dm-strings-lost       'read:dm-test_STEM_image-dm3-IL2 mode|read:dm-test_STEM_image-dm3-IL2 acquired|read:dm-test_STEM_image-dm3-IL2 C2 strings'
  dm-creation-dropped   'read:dm-test_stackbuilder_imagestack-dm3-IL2 highTensionKV|read:dm-test_stackbuilder_imagestack-dm3-IL2 C2 numbers'
  tiff-65027-skipped    'read:rsciio-dm-tiff-65027 highTensionKV'
  tiff-dm-before-velox  'read:planted-tiff-velox-and-dm highTensionKV'
)

# Does <log> hold a "  FAIL  " line of check <name> (the text up to ": ")?
failed_check() {
  awk -v want="$2: " 'index($0, "  FAIL  ") == 1 && index($0, want) { hit = 1 } END { exit !hit }' "$1"
}
# Is the mutant of <log>, which exited <rc>, caught by all of <targets> ('|'-separated)?
caught_by() {
  local log=$1 rc=$2 spec=$3 name
  (( rc == 1 )) || return 1
  grep -qE '^metadata-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" || return 1
  for name in "${(@s:|:)spec}"; do failed_check "$log" "$name" || return 1; done
}

caught=0
for mutation in $mutations; do
  log="$WORK/mutant-$mutation.log"
  target="${targets[$mutation]:-}"
  set +e
  MACTEM_PARITY_MUTATE=$mutation "$WORK/harness" "$WORK/ref" > "$log" 2>&1
  rc=$?
  set -e
  if [[ -n "$target" ]] && caught_by "$log" $rc "$target"; then
    caught=$(( caught + 1 ))
    echo "  ok    mutation '$mutation' is caught by its check '${target//|/' and '}'"
  elif [[ -z "$target" ]]; then
    echo "  FAIL  mutation '$mutation' has no target check in run.sh (exit $rc):"
    sed 's/^/        /' "$log"
  else
    echo "  FAIL  mutation '$mutation' exited $rc without failing its check '${target//|/' and '}':"
    sed 's/^/        /' "$log"
  fi
done

# Source mutations. The files below are never edited here: each mutant builds the harness again (tools/lib/harness.sh, in a mirror
# of the package) with an edited COPY of one TEMCore file. The edit must apply exactly once (a changed line makes the mutation fail
# LOUDLY, to be re-aimed), the build must succeed, and the mutant must then be caught as above. Only the app's own files are
# mutated: the tag walker and the TIFF reader are FormatoKit's, and FormatoKit's tests hold them.
source_mutant() {   # source_mutant <name> <file in Sources/TEMCore/Data> <targets> <old> <new> [<old> <new>]...
  local name=$1 file=$2 spec=$3; shift 3
  local dir="$WORK/source-$name" copy
  mkdir -p "$dir"
  copy="$dir/$file"
  local rel="Sources/TEMCore/Data/$file"
  [[ -f "$ROOT/$rel" ]] || { echo "  FAIL  source mutation '$name': there is no $rel"; return; }
  cp "$ROOT/$rel" "$copy"
  while (( $# >= 2 )); do
    "$PYTHON_BIN" -I -B -c '
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("source mutation: expected exactly one occurrence of the edit target, found %d: %s" % (text.count(old), old))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
' "$copy" "$1" "$2" || { echo "  FAIL  source mutation '$name' does not apply to $file"; return; }
    shift 2
  done
  if ! mactem_harness_mutant MetadataParity "$dir/harness" "$rel" "$copy" > "$dir/build.log" 2>&1; then
    echo "  FAIL  source mutation '$name' does not compile:"
    sed 's/^/        /' "$dir/build.log"
    return
  fi
  local log="$dir/mutant.log" rc
  set +e
  "$dir/harness" "$WORK/ref" > "$log" 2>&1
  rc=$?
  set -e
  if caught_by "$log" $rc "$spec"; then
    caught=$(( caught + 1 ))
    echo "  ok    source mutation '$name' ($file) is caught by its check '${spec//|/' and '}'"
  else
    echo "  FAIL  source mutation '$name' ($file) exited $rc without failing its check '${spec//|/' and '}':"
    sed 's/^/        /' "$log" | head -40
  fi
}
source_mutations=0
source_mutant_run() { source_mutations=$(( source_mutations + 1 )); source_mutant "$@"; }

# The open and the wiring of read(path:).
# (7) the open shows the first object that is not the thumbnail, while read(path:) still describes the object rule's.
source_mutant_run open-first-object ImageOpening.swift \
  'read:planted-dm4-two-objects C1 openNow' \
  'guard let object = primaryImageObject(in: objects) else {' \
  'guard let object = objects.first(where: { $0.role != .thumbnail }) else {'
# (8) the registered wrong-object mutation itself: read(path:) describes the first object that is not the thumbnail.
source_mutant_run read-first-object AcquisitionMetadata+Read.swift \
  'read:planted-dm4-two-objects highTensionKV|read:planted-dm4-no-primary-object highTensionKV' \
  'let shown = ImageOpening.primaryImageObject(in: objects) else' \
  'let shown = objects.first(where: { $0.role != .thumbnail }) else'
# (9) the strings of the object not handed to the DM rules.
source_mutant_run read-strings-dropped AcquisitionMetadata+Read.swift \
  'read:dm-test_STEM_image-dm3-IL2 mode|read:dm-test_STEM_image-dm3-IL2 acquired' \
  'strings: shown.imageTagStrings' 'strings: [:]'
# (10) the .mrc extension not dispatched (C6).
source_mutant_run read-mrc-not-dispatched AcquisitionMetadata+Read.swift \
  'read:rsciio-4dstemscan highTensionKV|read:planted-fei2-stem highTensionKV' \
  'case "mrc":' 'case "mrcx":'

# (11) the extension compared as written, not lower-cased (C6: .TIF, .MRC, .DM4).
source_mutant_run read-extension-case AcquisitionMetadata+Read.swift \
  'read:planted-ext-upper-TIF highTensionKV|read:planted-ext-upper-MRC highTensionKV|read:planted-ext-upper-DM4 highTensionKV' \
  'pathExtension.lowercased()' 'pathExtension'
# (12) .tiff not dispatched, only .tif (C6).
source_mutant_run read-tiff-extension AcquisitionMetadata+Read.swift \
  'read:planted-ext-tiff highTensionKV' \
  'case "tif", "tiff":' 'case "tif":'


total=$(( ${#mutations} + source_mutations ))
if (( caught != total )); then
  echo "metadata-parity: negative controls: $caught of $total caught by their checks"
  exit 1
fi
echo "metadata-parity: negative controls: $total of $total caught by their checks"
