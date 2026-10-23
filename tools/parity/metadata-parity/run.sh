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
#            (MACTEM_PARITY_MUTATE); eighteen edit a COPY of one source (the kit's tag walker, tiff(data:) and slice guard, the open, read(path:); never
#            the file in Sources/) and compile the harness against it.
#
# Pass: "metadata-parity: all passed", then "negative controls: 33 of 33 caught by their checks", exit 0.
# The owner's Ceta TIFFs (References/example_files/, gitignored) are gated where present; the summary line says how many
# of the 6 were (machine-local: a clone without them gates 0 of 6 and says so).
# TEMCore sources come from tools/lib/sources.manifest, group `metadata` (which names AcquisitionMetadata+Read.swift).
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

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" metadata
mactem_swiftc "$WORK/harness" "$HERE/main.swift"

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

# Source mutations (slice S-b). The files below are copies or other lanes' code and are never edited here: each mutant
# compiles the harness again against an edited COPY of one source file in the scratch directory. The edit must apply
# exactly once (a changed line makes the mutation fail LOUDLY, to be re-aimed), the build must succeed, and the mutant must
# then be caught as above. The walker (FormatoDM/DM4Experiment.swift) is FormatoKit's file since 0.4.0 (SpectroKit's before it, a verbatim copy of
# mac4DSTEM's); each file is found among the harness's own sources, so the copy is of the file the harness compiles.
# A mutant of a FormatoKit file (the walker, FormatoDM/DM4Experiment.swift): the edited copy goes in MACTEM_KIT_OVERRIDE and
# the harness is compiled against the kit rebuilt from it (tools/lib/sources.manifest rebuilds the module and no other).
kit_source_mutant() {   # kit_source_mutant <name> <Module/File.swift> <targets> <old> <new> [<old> <new>]...
  local name=$1 file=$2 spec=$3; shift 3
  local dir="$WORK/source-$name" copy rel="Sources/$file" kit
  mkdir -p "$dir"
  kit="$("$ROOT/tools/lib/fetch-formatokit.sh")" || { echo "  FAIL  source mutation '$name': FormatoKit is not at its pin"; return; }
  [[ -f "$kit/$rel" ]] || { echo "  FAIL  source mutation '$name': FormatoKit has no $rel"; return; }
  copy="$dir/${file:t}"
  cp "$kit/$rel" "$copy"
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
  MACTEM_KIT_OVERRIDE=([$rel]="$copy")
  if ! mactem_swiftc "$dir/harness" "$HERE/main.swift" > "$dir/build.log" 2>&1; then
    MACTEM_KIT_OVERRIDE=()
    echo "  FAIL  source mutation '$name' does not compile:"
    sed 's/^/        /' "$dir/build.log"
    return
  fi
  MACTEM_KIT_OVERRIDE=()
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
source_mutant() {   # source_mutant <name> <file among the harness's sources> <targets> <old> <new> [<old> <new>]...
  if [[ "$2" == */* ]]; then kit_source_mutant "$@"; return; fi
  local name=$1 file=$2 spec=$3; shift 3
  local dir="$WORK/source-$name" copy
  mkdir -p "$dir"
  copy="$dir/$file"
  local -a found=(${(M)MACTEM_SOURCES:#*/$file})
  if (( ${#found} != 1 )); then
    echo "  FAIL  source mutation '$name': $file is among the harness's sources ${#found} times, not once"
    return
  fi
  cp "${found[1]}" "$copy"
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
  local -a saved=("${MACTEM_SOURCES[@]}") edited=()
  local src
  for src in "${saved[@]}"; do
    if [[ "${src:t}" == "$file" ]]; then edited+=("$copy"); else edited+=("$src"); fi
  done
  if (( ${#edited} == 0 )) || [[ "${edited[(r)$copy]}" != "$copy" ]]; then
    echo "  FAIL  source mutation '$name': $file is not among the harness's sources (tools/lib/sources.manifest, group metadata)"
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

# The tag walker.
# (1) the object's maps cut at `ImageList.N.` instead of `ImageList.N.ImageTags.`: every key keeps `ImageTags.`.
source_mutant_run walker-prefix-cut FormatoDM/DM4Experiment.swift \
  'read:dm-test_STEM_image-dm3-IL2 highTensionKV|read:dm-test_STEM_image-dm3-IL2 C2 numbers' \
  'for (k, v) in numbers where k.hasPrefix(tags) { tagNumbers[String(k.dropFirst(tags.count))] = v }' \
  'for (k, v) in numbers where k.hasPrefix(root) { tagNumbers[String(k.dropFirst(root.count))] = v }' \
  'for (k, v) in strings where k.hasPrefix(tags) { tagStrings[String(k.dropFirst(tags.count))] = v }' \
  'for (k, v) in strings where k.hasPrefix(root) { tagStrings[String(k.dropFirst(root.count))] = v }'
# (1b) the registered M2 itself: the object's maps keep `ImageList.N.ImageTags.` on every key.
source_mutant_run walker-prefix-kept FormatoDM/DM4Experiment.swift \
  'read:dm-test_STEM_image-dm3-IL2 highTensionKV|read:dm-test_STEM_image-dm3-IL2 C2 numbers' \
  'tagNumbers[String(k.dropFirst(tags.count))] = v' 'tagNumbers[k] = v' \
  'tagStrings[String(k.dropFirst(tags.count))] = v' 'tagStrings[k] = v'
# (1c) the registered M4 itself: the stack builder's `source.Tags at creation.` keys are not kept.
source_mutant_run walker-creation-dropped FormatoDM/DM4Experiment.swift \
  'read:dm-test_stackbuilder_imagestack-dm3-IL2 highTensionKV|read:dm-test_stackbuilder_imagestack-dm3-IL2 C2 numbers' \
  'for (k, v) in numbers where k.hasPrefix(tags) {' 'for (k, v) in numbers where k.hasPrefix(tags) && !k.hasPrefix(tags + "source.") {' \
  'for (k, v) in strings where k.hasPrefix(tags) {' 'for (k, v) in strings where k.hasPrefix(tags) && !k.hasPrefix(tags + "source.") {'
# (2) every zero unit of a uint16 string kept: the NUL a fixed-width GMS string field ends with stays in the text.
source_mutant_run walker-zero-units-kept FormatoDM/DM4Experiment.swift \
  'read:planted-dm4-date-nul acquired|read:planted-dm4-date-nul C2 strings' \
  'strings[path] = String(decoding: units.filter { $0 > 0 }, as: UTF16.self)' \
  'strings[path] = String(decoding: units, as: UTF16.self)'
# (3) the object's prefix without its closing dot: `ImageList.1` also collects the tags of `ImageList.10` and `.11`
# (cut at `.ImageTags.`), which carry keys of their own in planted-dm4-eleven-objects.
source_mutant_run walker-prefix-without-dot FormatoDM/DM4Experiment.swift \
  'read:planted-dm4-eleven-objects C2 numbers|read:planted-dm4-eleven-objects C2 strings' \
  'for (k, v) in numbers where k.hasPrefix(tags) { tagNumbers[String(k.dropFirst(tags.count))] = v }' \
  'for (k, v) in numbers where k.hasPrefix("ImageList.\(n)") && k.contains(".ImageTags.") { tagNumbers[String(k[k.range(of: ".ImageTags.")!.upperBound...])] = v }' \
  'for (k, v) in strings where k.hasPrefix(tags) { tagStrings[String(k.dropFirst(tags.count))] = v }' \
  'for (k, v) in strings where k.hasPrefix("ImageList.\(n)") && k.contains(".ImageTags.") { tagStrings[String(k[k.range(of: ".ImageTags.")!.upperBound...])] = v }'
# (4) the strings of a bare tag stream (tag 65027) not returned.
source_mutant_run walker-tagtree-strings-lost FormatoDM/DM4Experiment.swift \
  'read:rsciio-dm-tiff-65027 C2 tag stream strings|read:rsciio-dm-tiff-65027 mode' \
  $'Source.data(data))\n        return (walk.numbers, walk.strings)' $'Source.data(data))\n        return (walk.numbers, [:])'

# (5) a tag label decoded as lossy UTF-8, as the walker of mac4DSTEM be10cce0 did: the lone 0xB5 byte of "(µA)" becomes U+FFFD.
source_mutant_run walker-labels-utf8-lossy FormatoDM/DM4Experiment.swift \
  'read:dm-test_STEM_image-dm3-IL2 C2 numbers|read:rsciio-dm-tiff-65027 C2 tag stream numbers' \
  'return String(bytes: b, encoding: .utf8) ?? String(b.map { Character(Unicode.Scalar($0)) })' \
  'return String(decoding: b, as: UTF8.self)'
# (6) a tag label always decoded as Latin-1 (ncempy's way): a label that is valid UTF-8 comes out as two characters.
source_mutant_run walker-labels-latin1 FormatoDM/DM4Experiment.swift \
  'read:planted-dm4-utf8-label C2 numbers' \
  'return String(bytes: b, encoding: .utf8) ?? String(b.map { Character(Unicode.Scalar($0)) })' \
  'return String(b.map { Character(Unicode.Scalar($0)) })'

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

# Tag 65027 in tiff(data:, convention: .app) and the kit's slice guard: FormatoKit's FormatoTIFF/AcquisitionMetadataTIFF.swift (the reader left the app
# at the kit switch, step 2; the kit's copy is edited through MACTEM_KIT_OVERRIDE, as the walker's is).
# (13) the tag never looked at.
source_mutant_run tiff-65027-not-read FormatoTIFF/AcquisitionMetadataTIFF.swift \
  'read:rsciio-dm-tiff-65027 highTensionKV|read:planted-tiff-65027-dm highTensionKV' \
  'dmTagStream(page[65027])' 'dmTagStream(page[65028])'
# (13b) the DM tree read behind a tag 34683 that exists but is not text (the registered rule is the tag's existence).
source_mutant_run tiff-65027-behind-non-text-velox FormatoTIFF/AcquisitionMetadataTIFF.swift \
  'read:planted-tiff-velox-tag-not-text-and-dm highTensionKV' \
  'if page[34683] == nil, let stream = dmTagStream(page[65027]),' \
  'if xmlText(page[34683]) == nil, let stream = dmTagStream(page[65027]),'
# (14) the DM tree tried before the Velox document (and without the guard that keeps it behind one).
source_mutant_run tiff-dm-before-velox-source FormatoTIFF/AcquisitionMetadataTIFF.swift \
  'read:planted-tiff-velox-and-dm highTensionKV' \
  $'        if let xml = xmlText(page[34683]) { return velox(xml, convention: convention) }\n        if page[34683] == nil, let stream = dmTagStream(page[65027]),\n           let tree = try? DM4Experiment.tagTree(data: stream) {\n            return dm(numbers: tree.numbers, strings: tree.strings, convention: convention)\n        }\n' \
  $'        if let stream = dmTagStream(page[65027]),\n           let tree = try? DM4Experiment.tagTree(data: stream) {\n            return dm(numbers: tree.numbers, strings: tree.strings, convention: convention)\n        }\n        if let xml = xmlText(page[34683]) { return velox(xml, convention: convention) }\n'

# (15) the bounds guard of the kit's TIFFFile.slice (ByteReader.check) removed: a tag value whose count runs past the end of the
# file is sliced out of range and the reader TRAPS (exit 133 by signal). Caught only because the two overrunning plants run in a
# child process of the harness, which reports the trap as its own failed check (main.swift, `isolate`).
source_mutant_run tiff-slice-bounds-guard-removed FormatoTIFF/TIFFFile.swift \
  'read:planted-tiff-65027-overruns-by-one survives|read:planted-tiff-65027-overruns-far survives' \
  'guard offset >= 0, n >= 0, n <= data.count, offset <= data.count - n else { throw TIFFError.truncated(name) }' \
  'guard offset >= 0, n >= 0 else { throw TIFFError.truncated(name) }'

total=$(( ${#mutations} + source_mutations ))
if (( caught != total )); then
  echo "metadata-parity: negative controls: $caught of $total caught by their checks"
  exit 1
fi
echo "metadata-parity: negative controls: $total of $total caught by their checks"
