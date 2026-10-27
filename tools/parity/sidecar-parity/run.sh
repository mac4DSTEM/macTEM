#!/bin/zsh
# tools/parity/sidecar-parity — macTEM's session sidecar (archive: roadmap-registrations-2026-10-15.md V1-2 slice A, ADR 020; slice B step 1, ADR 021: `SidecarHDF5`,
# `SessionSidecarFile` and `SessionLineage`, TEMCore, compiled into one module from tools/lib/sources.manifest group `sidecar`)
# against h5py 3.16.0 (pinned: tools/lib/references-lock.txt, tools/lib/python.sh). Classified `scientific` in tools/run-tests.sh.
# Pre-registration: archive: roadmap-registrations-2026-10-15.md "V1-2 Session sidecar", the block "Completed at pickup (2026-10-13 night)" (slice A: P1–P4) and
# "Slice B, step 1 — ADR 021, registered 2026-10-14, before code" (the fixed-length strings: P1–P3, the fuzz). README.md says more.
#
#   run.sh                      the whole gate: the clauses, the fuzz (once, on the unmutated sources), every negative control
#   run.sh --only <regex>       the gate without the fuzz, then only the controls whose name matches (a partial run, for
#                               re-aiming or re-running a control; it prints no pass line)
#                               (SIDECAR_PARITY_FUZZ=1 in the environment keeps the fuzz in a partial run: with --only '^$', the gate and the fuzz alone)
#   run.sh --check-edits        applies every control's edit to a copy of its source and stops: a fast way to see which
#                               controls a source change has broken (a control that does not apply fails LOUDLY, never drops)
#
#   run.sh   reference.py plants every input and its truth (the pixel sets, the sidecars h5py writes, the plan Swift writes
#            from); the harness (main.swift) writes the planted sessions with the sidecar code and records what it handed
#            the writer; reference.py reads those files back with h5py and checks them against the plan; the harness then
#            reads and refuses every sidecar h5py wrote, checks the name rule and the restore verdict, and merges h5py's
#            reading into one report; then every mutation of the sources under test, each a scratch copy of one file
#            with one edit, must fail the check named for it, or the gate fails for being blind. Every Swift read of a file
#            that could be damaged runs in its own process with a deadline (fuzz.swift), the fuzz included.
#
# Pass: "sidecar-parity: all passed", then "sidecar-parity: negative controls: N of N caught by their checks", exit 0.
# The controls are the nine registered mutations and then every guard and rule the plan reaches (the Gate B refuter's plants and
# the fixes that review led to: the removal cascade, the refused add, the newer schema, the minimum reader first, the name in
# UTF-16 units, the link to nothing, dates to the nearest millisecond, a slash written as it is), ADR 021's (the variable-length
# check removed, moved after the read, or refusing as malformed; the cap; the padding; the writer's form), and the controls of
# the harness itself (the HDF5 library it loads is the named copy; the fuzz driver reports a hang, a crash, a silent change and
# an unnamed outcome from a stub reader).
# TEMCore sources come from tools/lib/sources.manifest, group `sidecar` (FormatoKit's FormatoHDF5 module from the checkout its
# pin names); libhdf5 is FormatoKit's, from its pin, re-signed in the scratch directory and named by FORMATO_HDF5_PATH (the
# kit's loader reads that variable first; the app has no loader of its own since the FormatoKit 0.5.0 switch). h5py reads and writes with its own bundled HDF5.
set -euo pipefail
ONLY=""
CHECK_EDITS=0
GATE_EXTRA=()    # arguments added to the harness's gate by a control (the dense fuzz's second-opinion windows: `--fuzz-dense`)
while (( $# )); do
  case "$1" in
    --only) (( $# >= 2 )) || { echo "usage: run.sh [--only <control name regex> | --check-edits]"; exit 64; }; ONLY=$2; shift 2 ;;
    --check-edits) CHECK_EDITS=1; shift ;;
    *) echo "usage: run.sh [--only <control name regex> | --check-edits]"; exit 64 ;;
  esac
done
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactem-sidecar-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

. "$ROOT/tools/lib/python.sh"
resolve_mactem_python "$ROOT"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

# libhdf5 finds libsz and libaec beside itself (@loader_path), so the three are copied together and signed ad hoc again.
# They are FormatoKit's, the vendored files its three framework binaries are built from (ADR 026; no copy is committed here): the pinned checkout's.
FORMATO_KIT="$("$ROOT/tools/lib/fetch-formatokit.sh" | tail -1)" || { echo "sidecar-parity: FormatoKit is not at its pin"; exit 65; }
mkdir -p "$WORK/hdf5"
for lib in libhdf5.dylib libaec.0.dylib libsz.2.dylib; do
  [[ -f "$FORMATO_KIT/tools/xcframework/vendored/$lib" ]] || { echo "sidecar-parity: $lib is not in FormatoKit's tools/xcframework/vendored"; exit 66; }
  cp "$FORMATO_KIT/tools/xcframework/vendored/$lib" "$WORK/hdf5/$lib"
  codesign -f -s - "$WORK/hdf5/$lib" > /dev/null 2>&1
  codesign --verify "$WORK/hdf5/$lib"
done
export FORMATO_HDF5_PATH="$WORK/hdf5/libhdf5.dylib"

if (( ! CHECK_EDITS )); then "$PYTHON_BIN" -I -B "$HERE/reference.py" plant "$WORK/ref"; fi

. "$ROOT/tools/lib/sources.manifest"
mactem_sources "$ROOT" sidecar
SWIFT_FILES=("$HERE/main.swift" "$HERE/fuzz.swift" "$HERE/marks.swift" "$ROOT/macTEMTests/TestHDF5Binding.swift")   # the planting binding is the unit tests'
if (( ! CHECK_EDITS )); then mactem_swiftc "$WORK/harness" "${SWIFT_FILES[@]}"; fi

# gate <harness> <out-dir> [--fuzz]: Swift writes the planted sessions, h5py reads them back, the harness checks everything
# and merges h5py's reading in; with --fuzz it also fuzzes the sidecars it wrote (the one unmutated run). Its exit status is
# the harness's own (0 passed, 1 failures).
gate() {
  local harness=$1 out=$2; shift 2
  set -- "$@" "${GATE_EXTRA[@]}"
  mkdir -p "$out"
  "$harness" --write "$WORK/ref" "$out" || echo "sidecar-parity: the write step exited $?"
  "$PYTHON_BIN" -I -B "$HERE/reference.py" readback "$WORK/ref" "$out"
  "$harness" "$WORK/ref" "$out" "$@"
}

# The fuzz runs once, here, on the unmutated sources (a mutant is held to the clauses that need no fuzz; the fuzz driver itself
# is held by its own controls at the end).
if (( ! CHECK_EDITS )); then
  if [[ -n "$ONLY" && -z "${SIDECAR_PARITY_FUZZ:-}" ]]; then gate "$WORK/harness" "$WORK/out"; else gate "$WORK/harness" "$WORK/out" --fuzz; fi
fi

# Negative controls. The files below are macTEM's own and are never edited here: each mutant compiles the harness again
# against an edited COPY of one of them (SessionSidecarFile.swift or SessionLineage.swift) in the scratch directory. The edit
# must apply exactly once (a changed line makes the mutation fail LOUDLY, to be re-aimed), the build must succeed, and the
# mutant must then be caught: the harness exits exactly 1 (its own failure exit; a crash by signal is never a catch) AND its
# log holds a failure of EVERY check the mutation targets (`|` separates them; a check is named by the text between "  FAIL  "
# and ": " at the START of a line). The whole gate runs for each mutant: its Swift writes, h5py reads, and the harness checks.
DATA="$ROOT/Sources/TEMCore/Data"
caught=0
total=0

failed_check() {   # failed_check <log> <name>: does <log> hold a "  FAIL  " line that STARTS with check <name> and ": "?
  awk -v want="  FAIL  $2: " 'index($0, want) == 1 { hit = 1 } END { exit !hit }' "$1"
}
caught_by() {      # caught_by <log> <rc> <'|'-separated targets>
  local log=$1 rc=$2 spec=$3 name
  (( rc == 1 )) || return 1
  grep -qE '^sidecar-parity: [0-9]+ FAILURES in [0-9]+ checks' "$log" || return 1
  for name in "${(@s:|:)spec}"; do failed_check "$log" "$name" || return 1; done
}

selected() {       # selected <control name>: does this run include the control?
  [[ -z "$ONLY" ]] || [[ "$1" =~ $ONLY ]]
}

KIT_FILE="Sources/FormatoHDF5/HDF5RootAttributes.swift"   # the file layer moved into FormatoKit 0.5.0 (the session sidecar's file layer)
source_mutant() {  # source_mutant <file in Sources/TEMCore/Data> <name> <targets> <old> <new> [<old> <new>]...
  # An <old> that starts with `KIT:` is an edit of FormatoKit's HDF5RootAttributes.swift (the pinned checkout's copy, overridden
  # for this one build), where the code that SessionSidecarFile.swift used to hold now lives; the rest are edits of FILE.
  local FILE=$1 name=$2 spec=$3; shift 3
  selected "$name" || return 0
  total=$(( total + 1 ))
  local dir="$WORK/source-$name" copy kitcopy="" old
  mkdir -p "$dir"
  copy="$dir/$FILE"
  cp "$DATA/$FILE" "$copy"
  while (( $# >= 2 )); do
    old=$1
    local target="$copy" label="$FILE"
    if [[ "$old" == KIT:* ]]; then
      old="${old#KIT:}"
      if [[ -z "$kitcopy" ]]; then kitcopy="$dir/kit-HDF5RootAttributes.swift"; cp "$FORMATO_KIT/$KIT_FILE" "$kitcopy"; fi
      target="$kitcopy"; label="FormatoKit's HDF5RootAttributes.swift"
    fi
    "$PYTHON_BIN" -I -B -c '
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("source mutation: expected exactly one occurrence of the edit target, found %d: %s" % (text.count(old), old))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
' "$target" "$old" "$2" || { echo "  FAIL  source mutation '$name' does not apply to $label"; return; }
    shift 2
  done
  if (( CHECK_EDITS )); then caught=$(( caught + 1 )); echo "  ok    the edits of '$name' apply to $FILE${kitcopy:+ and the kit's file}"; return; fi
  local -a saved=("${MACTEM_SOURCES[@]}") edited=()
  local src
  for src in "${saved[@]}"; do
    if [[ "${src:t}" == "$FILE" ]]; then edited+=("$copy"); else edited+=("$src"); fi
  done
  if [[ "${edited[(r)$copy]}" != "$copy" ]]; then
    echo "  FAIL  source mutation '$name': $FILE is not among the harness's sources (tools/lib/sources.manifest, group sidecar)"
    return
  fi
  MACTEM_SOURCES=("${edited[@]}")
  if [[ -n "$kitcopy" ]]; then MACTEM_KIT_OVERRIDE[$KIT_FILE]="$kitcopy"; fi
  if ! mactem_swiftc "$dir/harness" "${SWIFT_FILES[@]}" > "$dir/build.log" 2>&1; then
    MACTEM_SOURCES=("${saved[@]}"); unset "MACTEM_KIT_OVERRIDE[$KIT_FILE]"
    echo "  FAIL  source mutation '$name' does not compile:"
    sed 's/^/        /' "$dir/build.log"
    return
  fi
  MACTEM_SOURCES=("${saved[@]}"); unset "MACTEM_KIT_OVERRIDE[$KIT_FILE]"
  local log="$dir/mutant.log" rc
  set +e
  gate "$dir/harness" "$dir/out" > "$log" 2>&1
  rc=$?
  set -e
  if caught_by "$log" $rc "$spec"; then
    caught=$(( caught + 1 ))
    echo "  ok    mutation '$name' is caught by its check '${spec//|/' and '}'"
  else
    echo "  FAIL  mutation '$name' exited $rc without failing its check '${spec//|/' and '}':"
    sed 's/^/        /' "$log" | head -${SIDECAR_PARITY_SHOW:-40}
  fi
}

# 1. the minimum-reader check skipped: a sidecar that demands a newer reader is read (P2).
source_mutant SessionSidecarFile.swift min-reader-skipped \
  'swift reads newer-min-reader|swift reads newer-min-reader-invalid-rest' \
  'guard minReader <= schema else { throw Refusal.newerMinReader(found: minReader, supported: schema) }' ''
# 2. a foreign file read as a sidecar: a file with no identity marker is taken for schema 1.
source_mutant SessionSidecarFile.swift foreign-read-as-sidecar \
  'swift reads foreign-lookalike|swift reads foreign-bare' \
  $'guard let identity = try HDF5RootAttributes.read([identityAttribute], from: url)[identityAttribute] else {\n            throw Refusal.foreign\n        }' \
  'let identity = try HDF5RootAttributes.read([identityAttribute], from: url)[identityAttribute] ?? "1"'
# 3. (retired 2026-10-14, ADR 023 d') the 4 MiB cap removed from the read. A text over the object header's 64 KiB is in dense storage, which
#    the reader now refuses before it looks at any attribute, so no file reaches the cap check and the mutant is equivalent.
# 4. a cycle accepted.
source_mutant SessionLineage.swift cycle-accepted \
  'swift decodes lineage-cycle|swift decodes lineage-self-cycle|swift decodes lineage-long-cycle' \
  'guard !hasCycle() else { throw .cycle }' '_ = hasCycle()'
# 5. ids reused after a delete: the next id is recomputed from the nodes that are left. (Re-aimed 2026-10-14: the orphan cascade
#    that followed the delete is now one pass, `sweepOrphans()`.)
source_mutant SessionLineage.swift ids-reused-after-delete \
  'h5py marks lineage next_id|h5py marks lineage node ids' \
  $'        nodes.remove(at: index)\n        sweepOrphans()' \
  $'        nodes.remove(at: index)\n        nextID = (nodes.compactMap { SessionLineage.number(ofID: $0.id) }.max() ?? 0) + 1\n        sweepOrphans()'
# 6. dates in seconds, not milliseconds.
source_mutant SessionLineage.swift dates-in-seconds \
  'h5py marks s1 recorded|h5py marks s2 recorded|h5py many recorded' \
  'let ms = (date.timeIntervalSince1970 * 1000).rounded()' 'let ms = date.timeIntervalSince1970.rounded()'
# 7. the name lower-cased: SCAN.DM4 gets scan.dm4.mactem.h5.
source_mutant SessionSidecarFile.swift name-lower-cased \
  'url SCAN.DM4|h5py marks file name' \
  'appendingPathComponent(name + suffix, isDirectory: false)' 'appendingPathComponent(name.lowercased() + suffix, isDirectory: false)'
# 8. the fingerprint over the display canvas: the pixels normalised onto [0, 1] before they are hashed.
source_mutant SessionLineage.swift fingerprint-over-canvas \
  'fingerprint six|fingerprint ramp-a|h5py marks source json' \
  'pixels.withUnsafeBytes { hasher.update(bufferPointer: $0) }' \
  $'let low = pixels.min() ?? 0, high = pixels.max() ?? 0\n        let canvas = pixels.map { high > low ? ($0 - low) / (high - low) : $0 }\n        canvas.withUnsafeBytes { hasher.update(bufferPointer: $0) }'
# 9. shape and fingerprint swapped in the verdict: a changed shape is "pixels differ", changed pixels are "another image".
source_mutant SessionLineage.swift verdict-shape-and-fingerprint-swapped \
  'verdict shape differs|verdict pixels differ' \
  'guard stored.object == opened.object, stored.width == opened.width, stored.height == opened.height else {' \
  'guard stored.object == opened.object, stored.pixelSHA256 == opened.pixelSHA256 else {' \
  'if stored.pixelSHA256 != opened.pixelSHA256 { return .adoptPixelsDiffer }' \
  'if stored.width != opened.width || stored.height != opened.height { return .adoptPixelsDiffer }'

# Beyond the nine registered, five more of the same kind (each a guard or a rule the plan above exercises):
# 10. an unknown lineage version refused as malformed, not read-only.
source_mutant SessionLineage.swift unknown-version-refused \
  'swift decodes lineage-unknown-version' \
  $'var readOnly = SessionLineage()\n            readOnly.fileVersion = probe.version\n            return readOnly' 'throw .malformed'
# 11. the bound on next_id gone.
source_mutant SessionLineage.swift next-id-bound-removed \
  'swift decodes lineage-next-id-over' \
  'guard nextID >= 1, nextID <= Self.maximumNextID else { throw .badNextID(nextID) }' 'guard nextID >= 1 else { throw .badNextID(nextID) }'
# 12. the 2 000-node cap gone from the guards.
source_mutant SessionLineage.swift node-cap-removed \
  'swift decodes lineage-2001-nodes' \
  'guard nodes.count <= Self.maximumNodes else { throw .tooManyNodes(nodes.count) }' '_ = nodes.count'
# 13. the writer replaces whatever is there: the header read that decides whether it is one of ours is skipped. (Re-aimed
#     2026-10-14: the writer's check is now `requireReplaceable`, the header read plus the newer-schema refusal.)
source_mutant SessionSidecarFile.swift foreign-overwritten \
  'swift refuses to overwrite foreign-bare|swift refuses to overwrite foreign-lookalike|swift refuses to overwrite newer-min-reader' \
  'if existing != nil { try requireReplaceable(url) }' 'if existing != nil { _ = url }'
# 14. a file name stored as given, not under NFC.
source_mutant SessionLineage.swift name-not-nfc \
  'h5py unicode source json|swift identity valid-nfd-name' \
  'self.fileName = fileName.precomposedStringWithCanonicalMapping' 'self.fileName = fileName'

# Beyond those, one control for every guard or rule the plan reaches that the fourteen leave open: the Gate B refuter's plants
# (2026-10-13/14) and the fixes of that review. (Each edit must apply exactly once to the current source.)
# 15. P2's ORDER: the source and the lineage are read before the minimum reader is judged, so a newer file whose rest is not
#     valid UTF-8 is refused for that instead of for the minimum reader.
source_mutant SessionSidecarFile.swift min-reader-judged-after-the-rest \
  'swift reads newer-min-reader-invalid-rest' \
  $'                let header = try readHeader(of: url)\n                betweenReads?()\n                let rest = try HDF5RootAttributes.read([sourceAttribute, lineageAttribute], from: url)' \
  $'                let rest = try HDF5RootAttributes.read([sourceAttribute, lineageAttribute], from: url)\n                betweenReads?()\n                let header = try readHeader(of: url)'
# 16. the identity's own spelling judged before the minimum reader: a "v2" identity beside a minimum reader of 2 is garbled, not newer.
source_mutant SessionSidecarFile.swift identity-judged-before-min-reader \
  'swift reads newer-min-reader-v2-identity|swift refuses to overwrite newer-min-reader-v2-identity' \
  $'        guard minReader <= schema else { throw Refusal.newerMinReader(found: minReader, supported: schema) }\n        guard let found = wholeNumber(identity) else { throw Refusal.malformedAttribute(identityAttribute) }' \
  $'        guard let found = wholeNumber(identity) else { throw Refusal.malformedAttribute(identityAttribute) }\n        guard minReader <= schema else { throw Refusal.newerMinReader(found: minReader, supported: schema) }'
# 17. a write over a sidecar of a newer schema (whose minimum reader is still ours): replaced, dropping what this build cannot read.
source_mutant SessionSidecarFile.swift newer-schema-overwritten \
  'swift refuses to overwrite valid-newer-writer-same-min-reader|swift refuses to overwrite newer-schema-with-future-attribute' \
  'guard header.schema <= schema else { throw Refusal.newerSchema(found: header.schema, supported: schema) }' '_ = header'
# 18-20. the name limit counted in UTF-8 bytes, in characters, or on the composed name (a decomposed "Å" is two units).
source_mutant SessionSidecarFile.swift name-counted-in-bytes \
  'url 255 units (µ)|url 255 units (日)|url 255 units (emoji)|url 256 units (µ)' \
  'let units = sidecar.lastPathComponent.utf16.count' 'let units = sidecar.lastPathComponent.utf8.count'
source_mutant SessionSidecarFile.swift name-counted-in-characters \
  'url 256 units (emoji)|url 256 units (Å)' \
  'let units = sidecar.lastPathComponent.utf16.count' 'let units = sidecar.lastPathComponent.count'
source_mutant SessionSidecarFile.swift name-counted-before-decomposition \
  'url 256 units (Å)' \
  'let units = sidecar.lastPathComponent.utf16.count' 'let units = sidecar.lastPathComponent.precomposedStringWithCanonicalMapping.utf16.count'
# 21. a link to nothing at the sidecar's path is not looked at (the existence question that ignores links): it is replaced.
source_mutant SessionSidecarFile.swift dangling-link-replaced \
  'swift refuses to overwrite dangling-link' \
  'if existing != nil {' 'if FileManager.default.fileExists(atPath: url.path) {'
# 22. an add that cites a removed node is accepted (a removed node stays only for the nodes that already cite it).
source_mutant SessionLineage.swift add-cites-removed-node \
  'swift rules kept|swift rules cascade|h5py kept lineage node ids' \
  'guard let input = node(id: edge.step), input.removed == nil else { throw .danglingInput(step: edge.step, from: id) }' \
  'guard node(id: edge.step) != nil else { throw .danglingInput(step: edge.step, from: id) }'
# 23. an add is not checked against its inputs at all.
source_mutant SessionLineage.swift add-inputs-unchecked \
  'swift rules kept|swift rules cascade' \
  'guard let input = node(id: edge.step), input.removed == nil else { throw .danglingInput(step: edge.step, from: id) }' '_ = edge'
# 24-25. a slash written escaped ("1\/nm") in the lineage, in the identity: not Python's canonical text.
source_mutant SessionLineage.swift lineage-slash-escaped \
  'h5py marks lineage canonical|h5py unicode lineage canonical' \
  $'encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]\n        // try? OK: strings, integers' \
  $'encoder.outputFormatting = [.sortedKeys]\n        // try? OK: strings, integers'
source_mutant SessionLineage.swift identity-slash-escaped \
  'h5py unicode source canonical' \
  $'encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]\n        // try? OK: strings and integers' \
  $'encoder.outputFormatting = [.sortedKeys]\n        // try? OK: strings and integers'
# 26-28. a date recorded to the nearest millisecond (a tie away from zero): half-to-even, truncated, floored.
source_mutant SessionLineage.swift ms-half-to-even \
  'h5py dates s4 recorded|h5py dates s5 recorded|h5py dates s6 recorded|h5py dates s7 recorded' \
  'let ms = (date.timeIntervalSince1970 * 1000).rounded()' 'let ms = (date.timeIntervalSince1970 * 1000).rounded(.toNearestOrEven)'
source_mutant SessionLineage.swift ms-truncated \
  'h5py dates s1 recorded|h5py dates s3 recorded|h5py dates s4 recorded' \
  'let ms = (date.timeIntervalSince1970 * 1000).rounded()' 'let ms = (date.timeIntervalSince1970 * 1000).rounded(.towardZero)'
source_mutant SessionLineage.swift ms-floored \
  'h5py dates s1 recorded|h5py dates s4 recorded' \
  'let ms = (date.timeIntervalSince1970 * 1000).rounded()' 'let ms = (date.timeIntervalSince1970 * 1000).rounded(.down)'
# 29-30. the clamp of a date no millisecond count can hold (-infinity, +infinity) moved out to the Int64 range.
source_mutant SessionLineage.swift ms-clamp-lower-moved \
  'h5py dates s9 recorded' \
  'Int64(min(max(ms, -9e15), 9e15))' 'Int64(min(max(ms, -9e18), 9e15))'
source_mutant SessionLineage.swift ms-clamp-upper-moved \
  'h5py dates s8 recorded' \
  'Int64(min(max(ms, -9e15), 9e15))' 'Int64(min(max(ms, -9e15), 9e18))'
# 31. a null-dataspace attribute (no element) is read as the empty string.
source_mutant SessionSidecarFile.swift null-dataspace-read-as-empty \
  'swift reads null-dataspace-source' \
  'KIT:guard h5.h5sgetNdims(space) == 0, h5.h5sgetNpoints(space) == 1 else {' \
  'guard h5.h5sgetNdims(space) == 0 else {'
# 32-33. the writer's own limits: a NUL in a string, and a string over 4 MiB.
source_mutant SessionSidecarFile.swift nul-written \
  'swift writer nul-lineage|swift writer nul-source' \
  'guard !value.utf8.contains(0) else { throw Refusal.embeddedNUL(name) }' '' \
  'KIT:for (name, value) in attributes where value.utf8.contains(0) { throw HDF5FileError.embeddedNUL(name) }' ''
source_mutant SessionSidecarFile.swift write-cap-removed \
  'swift writer cap-plus-one-lineage|swift writer cap-plus-one-source' \
  'guard bytes <= maxStringBytes else { throw Refusal.stringTooLong(attribute: name, bytes: bytes) }' '_ = bytes'
# 34. a write over a valid sidecar does nothing (a re-save would silently keep the stale one).
source_mutant SessionSidecarFile.swift write-over-existing-is-a-noop \
  'h5py raw replace-valid attributes|h5py raw replace-valid mactem_source|h5py raw replace-valid mactem_lineage' \
  'if existing != nil { try requireReplaceable(url) }' 'if existing != nil { try requireReplaceable(url); return }'
# 35-36. the removal cascade: not run at all (a removed node nobody cites any more stays), and run one level deep only.
source_mutant SessionLineage.swift cascade-not-run \
  'h5py cascade lineage node ids|h5py chain lineage node ids' \
  $'        nodes.remove(at: index)\n        sweepOrphans()\n        return .deleted' \
  $'        nodes.remove(at: index)\n        return .deleted'
source_mutant SessionLineage.swift cascade-one-level-only \
  'h5py cascade lineage node ids|h5py chain lineage node ids' \
  'if citations[edge.step] == 0, let at = position[edge.step], nodes[at].removed != nil { work.append(edge.step) }' ''
# 37-38. a second removal of a kept node overwrites the first date; a removed node is edited by a replace.
source_mutant SessionLineage.swift removed-date-overwritten \
  'h5py kept s2 removed' \
  'if nodes[index].removed == nil { nodes[index].removed = removed }' 'nodes[index].removed = removed'
source_mutant SessionLineage.swift replace-on-removed-node-allowed \
  'swift rules kept|h5py kept s2 fields' \
  ', nodes[index].removed == nil else { return false }' ' else { return false }'
# 39-40. an id with a sign ("s+1") accepted (the digit check dropped), and the identity's 64 KiB cap removed.
source_mutant SessionLineage.swift id-digit-check-dropped \
  'swift decodes lineage-bad-id-plus' \
  $'              digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),\n' ''
source_mutant SessionLineage.swift identity-cap-removed \
  'swift identity source-over-64kib' \
  $'guard byteCount <= maximumJSONBytes else { throw .tooLarge(bytes: byteCount) }\n        // try? OK: any decoding failure is the one named refusal, `.malformed`.\n        guard let identity' \
  $'_ = byteCount\n        // try? OK: any decoding failure is the one named refusal, `.malformed`.\n        guard let identity'

# ADR 021 (slice B, step 1): the reader of the fixed-length form, the writer's form, and the variable-length refusal. The reads
# of the variable-length plants and of the archived hang file run in a child process with a 10 s deadline, so a reader that
# parses the damaged heap fails "swift reads hangcase-flip" by timing out (the 10 s are in the mutant's run) instead of
# stalling the gate.
VL_READS='swift reads vl-identity|swift reads vl-min-reader|swift reads vl-source|swift reads vl-lineage|swift reads hangcase-flip'
# 42. the variable-length check removed: a variable-length string is read (as the pointer it is, into a buffer the size of one),
#     and the damaged one spins in H5Aread.
source_mutant SessionSidecarFile.swift vl-check-removed \
  "$VL_READS" \
  'KIT:guard variable == 0 else { throw HDF5FileError.variableLengthString(name) }' ''
# 43. the variable-length check AFTER the read: every plant is still refused by name, but the hang file's H5Aread never returns
#     (the read's and the replace check's alike).
source_mutant SessionSidecarFile.swift vl-check-after-the-read \
  'swift reads hangcase-flip|swift refuses to overwrite hangcase-flip' \
  'KIT:guard variable == 0 else { throw HDF5FileError.variableLengthString(name) }' '' \
  'KIT:        // The text, then only padding:' $'        guard variable == 0 else { throw HDF5FileError.variableLengthString(name) }\n        // The text, then only padding:'
# 44. a variable-length string refused as malformed, not by name.
source_mutant SessionSidecarFile.swift vl-refused-as-malformed \
  "$VL_READS|swift refuses to overwrite vl-identity|swift refuses to overwrite hangcase-flip" \
  'KIT:throw HDF5FileError.variableLengthString(name)' 'throw HDF5FileError.malformedAttribute(name)'
# 45. (retired 2026-10-14, ADR 023 d') the cap at `<`: equivalent for the same reason as control 3.
# 46. the padding check removed: a NUL followed by more text is read as the text before it, the rest silently lost.
source_mutant SessionSidecarFile.swift padding-check-removed \
  'swift reads nul-then-text-lineage|swift reads nul-then-text-source|swift reads nul-first-lineage|swift reads nul-then-text-identity' \
  'KIT:guard storage[length...].allSatisfy({ $0 == 0 }) else { throw HDF5FileError.malformedAttribute(name) }' ''
# 47. the whole storage taken as the text, padding and all (no cut at the first NUL).
source_mutant SessionSidecarFile.swift padding-taken-as-text \
  'swift reads padded-lineage|swift reads padded-markers|swift reads valid-empty-strings|swift reads all-nul-lineage' \
  'KIT:let length = storage.firstIndex(of: 0) ?? size' 'let length = size'
# 48. the string class not checked: an integer attribute is read as text.
source_mutant SessionSidecarFile.swift string-class-unchecked \
  'swift reads integer-source' \
  'KIT:guard h5.h5tgetClass(type) == 3 else { throw HDF5FileError.malformedAttribute(name) }' ''
# 49-52. the writer's form, each held by the property h5py reads: variable-length (slice A's writer), NULLTERM, one byte longer,
#     ASCII.
# (Re-aimed 2026-10-14: the first aim, h5py's `type` check of the attribute, was never reached. The harness's write step reads
#  every file it wrote back with the Swift reader (P1), and that reader refuses the variable-length string it was just handed,
#  by name: `swift writes marks` fails, no file is recorded, and h5py is told "Swift did not write it" (`h5py marks file`). The
#  control is caught by the two checks that do fail; the writer's form is held by h5py's `type` check in the four controls
#  around it only where the Swift reader would not stand in.)
source_mutant SessionSidecarFile.swift writer-variable-length \
  'swift writes marks|swift writes unicode|h5py marks file' \
  'KIT:guard h5.h5tsetSize(type, stored.count) >= 0, h5.h5tsetCset(type, 1) >= 0, h5.h5tsetStrpad(type, 1) >= 0 else {' \
  'guard h5.h5tsetSize(type, Int(bitPattern: UInt.max) &+ stored.count &* 0) >= 0, h5.h5tsetCset(type, 1) >= 0 else {' \
  'KIT:guard stored.withUnsafeBytes({ h5.h5awrite(attribute, type, $0.baseAddress) }) >= 0 else {' \
  $'guard value.withCString({ characters in\n            var pointer: UnsafePointer<CChar>? = characters\n            return withUnsafePointer(to: &pointer) { h5.h5awrite(attribute, type, $0) }\n        }) >= 0 else {'
source_mutant SessionSidecarFile.swift writer-null-terminated \
  'h5py marks mactem_source strpad|h5py marks mactem_lineage strpad|h5py marks mactem_session_schema strpad' \
  'KIT:h5.h5tsetStrpad(type, 1) >= 0' 'h5.h5tsetStrpad(type, 0) >= 0'
source_mutant SessionSidecarFile.swift writer-one-byte-longer \
  'h5py marks mactem_source size|h5py marks mactem_lineage size|h5py marks mactem_session_schema size|h5py marks mactem_lineage bytes' \
  'KIT:let stored = value.isEmpty ? [UInt8(0)] : Array(value.utf8)' 'let stored = Array(value.utf8) + [UInt8(0)]'
source_mutant SessionSidecarFile.swift writer-ascii \
  'h5py marks mactem_source charset|h5py marks mactem_lineage charset|h5py unicode mactem_lineage charset' \
  'KIT:h5.h5tsetCset(type, 1) >= 0' 'h5.h5tsetCset(type, 0) >= 0'
# 53. the library-version bounds set to (earliest, V18) ((earliest, earliest) is refused by HDF5 2.x as an invalid pair): the file is in the oldest format (superblock version 0, version-1
#     object headers), in which a text over about 65,499 bytes cannot be written at all (Gate B 2026-10-14, finding 2).
source_mutant SessionSidecarFile.swift writer-libver-earliest \
  'h5py marks superblock|h5py marks object headers' \
  'KIT:h5.h5psetLibverBounds(access, 1, 5)' 'h5.h5psetLibverBounds(access, 0, 1)'

# Slice B, the core (archive: roadmap-registrations-2026-10-15.md V1-2, "Slice B, the core"): SessionMarks, SessionRestore and SessionSave through marks.swift and
# marks_reference.py (P1 the restore equals the save; P2 every refusal by name, naming the node; P3 the verdict and the calibration
# note through the restore; the save's checks and its changed-on-disk rule), and the file layer's not-permitted refusal. Each
# mutant is a source mutant of SessionMarks.swift (or SessionSidecarFile.swift) and must fail the check named for it.
source_mutant SessionMarks.swift marks-x-and-y-swapped \
  'h5py mk big s1 parameters x1|swift marks points big|swift marks writes aniso' \
  'parameters[keys.0] = SessionLineage.coordinateString(point.x)
            parameters[keys.1] = SessionLineage.coordinateString(point.y)' 'parameters[keys.0] = SessionLineage.coordinateString(point.y)
            parameters[keys.1] = SessionLineage.coordinateString(point.x)'
source_mutant SessionMarks.swift marks-vertex-not-point-2 \
  'h5py mk aniso s3 parameters x2|swift marks restores restore-three-kinds-and-kept' \
  'private static let pointKeys = [("x1", "y1"), ("x2", "y2"), ("x3", "y3")]' 'private static let pointKeys = [("x1", "y1"), ("x3", "y3"), ("x2", "y2")]'
source_mutant SessionMarks.swift marks-width-not-restored \
  'swift marks widths restore-three-kinds-and-kept' \
  'markWidth = parsed' 'markWidth = 1; _ = parsed'
source_mutant SessionMarks.swift marks-removed-node-drawn \
  'swift marks nodes restore-three-kinds-and-kept' \
  'guard node.removed == nil, let kind = SessionMark.Kind(rawValue: node.kind) else { return nil }' 'guard let kind = SessionMark.Kind(rawValue: node.kind) else { return nil }'
source_mutant SessionMarks.swift marks-x-bound-at-0 \
  'swift marks writes aniso|swift marks restores restore-edges-and-zero-length' \
  'point.x >= -0.5, point.x <= Double(width) - 0.5' 'point.x >= 0, point.x <= Double(width) - 0.5'
source_mutant SessionMarks.swift marks-x-bound-at-W \
  'swift marks writes aniso|swift marks restores restore-edges-and-zero-length' \
  'point.x <= Double(width) - 0.5' 'point.x < Double(width) - 0.5'
source_mutant SessionMarks.swift marks-y-bound-at-0 \
  'swift marks writes aniso|swift marks restores restore-edges-and-zero-length' \
  'point.y >= -0.5, point.y <= Double(height) - 0.5' 'point.y >= 0, point.y <= Double(height) - 0.5'
source_mutant SessionMarks.swift marks-y-bound-at-H \
  'swift marks writes aniso|swift marks restores restore-edges-and-zero-length' \
  'point.y <= Double(height) - 0.5' 'point.y < Double(height) - 0.5'
source_mutant SessionMarks.swift marks-x-bound-uses-height \
  'swift marks writes aniso|swift marks restores restore-edges-and-zero-length' \
  'point.x <= Double(width) - 0.5' 'point.x <= Double(height) - 0.5'
source_mutant SessionMarks.swift marks-grammar-any-double \
  'swift marks refuses grammar-hex|swift marks refuses grammar-leading-point|swift marks refuses grammar-plus' \
  '        let bytes = Array(text.utf8)
        var at = 0' '        if true { return SessionLineage.coordinate(from: text) }
        let bytes = Array(text.utf8)
        var at = 0'
source_mutant SessionMarks.swift marks-leading-point-accepted \
  'swift marks refuses grammar-leading-point' \
  '        guard digits() else { return nil }
        if at < bytes.count, bytes[at] == UInt8(ascii: ".") {' '        _ = digits()
        if at < bytes.count, bytes[at] == UInt8(ascii: ".") {'
source_mutant SessionMarks.swift marks-plus-sign-accepted \
  'swift marks refuses grammar-plus' \
  'if at < bytes.count, bytes[at] == UInt8(ascii: "-") { at += 1 }' 'if at < bytes.count, bytes[at] == UInt8(ascii: "-") || bytes[at] == UInt8(ascii: "+") { at += 1 }'
source_mutant SessionMarks.swift marks-width-leading-zero \
  'swift marks refuses width-leading-zero|swift marks refuses bad-width-first' \
  'bytes[0] != UInt8(ascii: "0"), let value' 'let value'
source_mutant SessionMarks.swift marks-width-max-99 \
  'swift marks refuses width-too-wide' \
  'value <= maximumWidth else { return nil }' 'value <= 99 else { return nil }'
source_mutant SessionMarks.swift marks-other-object-drawn \
  'swift marks nodes restore-three-kinds-and-kept|swift marks restores unjudged-bad-nodes' \
  'guard try value("object") == object, try value("frame") == frame else { return nil }' '_ = try value("object"); _ = try value("frame")'
source_mutant SessionMarks.swift marks-missing-key-wrong-node \
  'swift marks refuses missing-x1' \
  'throw .missingKey(node: node.id, key: key)' 'throw .missingKey(node: "s0", key: key)'
source_mutant SessionMarks.swift marks-point-number-off-by-one \
  'swift marks refuses outside-x-below' \
  'throw .outsideImage(node: node.id, point: index + 1)' 'throw .outsideImage(node: node.id, point: index)'
source_mutant SessionMarks.swift marks-bad-coordinate-defaulted \
  'swift marks refuses grammar-hex|swift marks refuses grammar-nan' \
  'guard let number = coordinate(text) else { throw .badCoordinate(node: node.id, key: key, text: text) }' 'let number = coordinate(text) ?? 0'
source_mutant SessionMarks.swift marks-bad-width-defaulted \
  'swift marks refuses width-text|swift marks refuses width-zero' \
  'guard let parsed = Self.width(text) else { throw .badWidth(node: node.id, text: text) }' 'let parsed = Self.width(text) ?? 1'
source_mutant SessionMarks.swift marks-calibration-note-skipped \
  'swift marks note calibration-x-scale' \
  'if SessionMarks.calibrationDiffers(node, x: x, y: y) { calibrationDiffers = true }' 'if SessionMarks.calibrationDiffers(node, x: x, y: y) { calibrationDiffers = false }'
source_mutant SessionMarks.swift marks-scales-swapped-in-note \
  'swift marks note calibration-same|swift marks note calibration-swapped' \
  'differs(x, scale: "scale_x", unit: "unit_x") || differs(y, scale: "scale_y", unit: "unit_y")' 'differs(x, scale: "scale_y", unit: "unit_y") || differs(y, scale: "scale_x", unit: "unit_x")'
source_mutant SessionMarks.swift marks-plane-swapped \
  'h5py mk aniso s3 results plane' \
  'results["plane"] = angle.plane == .physical ? "physical" : "pixel"' 'results["plane"] = angle.plane == .physical ? "pixel" : "physical"'
source_mutant SessionMarks.swift marks-unit-kept-for-mixed-units \
  'h5py mk mixed s1 results keys' \
  'if let length = distance.physical, let unit = distance.unit {' 'if let unit = distance.unit ?? x?.units { let length = distance.physical ?? distance.pixels'
source_mutant SessionMarks.swift marks-verdict-skipped \
  'swift marks refuses verdict-other-object' \
  'if case .refuse(let sentence) = verdict { throw .otherImage(sentence) }' '_ = verdict'
source_mutant SessionMarks.swift marks-bad-node-skipped-partial-restore \
  'swift marks refuses grammar-hex|swift marks refuses two-bad-nodes-first-named' \
  '} catch { throw .mark(error) }
            guard let mark else' '} catch { kept += 1; continue }
            guard let mark else'
source_mutant SessionMarks.swift marks-save-checks-skipped \
  'swift marks save grammar-hex|swift marks save-disk bad-mark' \
  'try SessionMarks.check(lineage, width: identity.width, height: identity.height, object: identity.object)' 'try SessionMarks.check(SessionLineage(), width: identity.width, height: identity.height, object: identity.object)'
source_mutant SessionMarks.swift marks-changed-on-disk-skipped \
  'swift marks save-disk stale-expectation|swift marks save-disk never-read' \
  'guard let expected = request.expectedOnDisk, onDisk.lineage == expected else { throw .changedOnDisk }' '_ = onDisk'
source_mutant SessionMarks.swift marks-missing-lineage-defaulted \
  'swift marks refuses missing-lineage' \
  'guard let lineageText = contents.lineage else { throw .missingLineage }' 'let lineageText = contents.lineage ?? #"{"next_id":1,"nodes":[],"version":1}"#'
source_mutant SessionMarks.swift marks-missing-source-defaulted \
  'swift marks refuses missing-source' \
  'guard let sourceText = contents.source else { throw .missingSource }' 'let sourceText = contents.source ?? ""'
source_mutant SessionMarks.swift marks-read-only-save-allowed \
  'swift marks save-disk read-only|swift marks save read-only-lineage' \
  'guard !lineage.isReadOnly else { throw .readOnly(lineage.fileVersion) }' ''
source_mutant SessionMarks.swift marks-profile-width-not-recorded \
  'swift marks writes aniso|h5py mk aniso file' \
  'if mark.kind == .profile { parameters["width"] = String(mark.width) }' ''
source_mutant SessionMarks.swift marks-frame-recorded-wrong \
  'h5py mk aniso s1 parameters frame' \
  'var parameters = ["object": object, "frame": frame]' 'var parameters = ["object": object, "frame": "1"]'
source_mutant SessionMarks.swift marks-samples-not-recorded \
  'h5py mk aniso s6 results keys' \
  'if mark.kind == .profile, let samples { results["samples"] = String(samples) }' ''
source_mutant SessionMarks.swift marks-lineage-text-not-kept \
  'swift marks lineage text aniso' \
  'calibrationDiffers: calibrationDiffers, lineageText: lineageText)' 'calibrationDiffers: calibrationDiffers, lineageText: "")'
source_mutant SessionMarks.swift marks-kept-count-not-counted \
  'swift marks kept restore-three-kinds-and-kept' \
  'guard let mark else { kept += 1; continue }' 'guard let mark else { kept += 0; continue }'
source_mutant SessionSidecarFile.swift marks-not-permitted-probe-removed \
  'swift reads unreadable' \
  'KIT:if code == EPERM || code == EACCES { throw HDF5FileError.notPermitted(String(cString: strerror(code))) }' 'if code == EPERM || code == EACCES { _ = code }'
source_mutant SessionSidecarFile.swift marks-not-permitted-eacces-left-out \
  'swift reads unreadable' \
  'KIT:if code == EPERM || code == EACCES {' 'if code == EPERM {'
source_mutant SessionSidecarFile.swift marks-not-permitted-any-failed-probe \
  'swift reads absent|swift reads dangling-link' \
  'KIT:if code == EPERM || code == EACCES {' 'if code != 0 {'

# ADR 023 d' (slice B step 2): the reader's header-only refusal of dense attribute storage. Each dense plant is one h5py wrote and h5py
# proves is in dense storage (the plant's `dense` flag); the compact ones that must not be refused are the valid and foreign plants.
DENSE_READS='swift reads dense-attributes-tracked-order|swift reads dense-attributes-many|swift reads lineage-100kb|swift reads lineage-4mib-exact'
source_mutant SessionSidecarFile.swift dense-check-skipped \
  "$DENSE_READS|swift refuses to overwrite lineage-65600" \
  'KIT:if refuseDenseStorage { try requireCompactAttributes(of: file, h5) }' ''
source_mutant SessionSidecarFile.swift dense-check-after-the-first-attribute \
  'swift reads dense-variable-length-identity|swift refuses to overwrite dense-variable-length-identity' \
  'KIT:if refuseDenseStorage { try requireCompactAttributes(of: file, h5) }' '' \
  'KIT:if let text = try readString(name, of: file, maximumStringBytes: maximumStringBytes, h5) { out[name] = text }' \
  $'if let text = try readString(name, of: file, maximumStringBytes: maximumStringBytes, h5) { out[name] = text }\n                if refuseDenseStorage { try requireCompactAttributes(of: file, h5) }'
# The replace check (the header reads) without the dense refusal, the read's first act keeping it: only the overwrite is held to it.
source_mutant SessionSidecarFile.swift dense-check-in-the-read-only \
  'swift refuses to overwrite dense-attributes-many|swift refuses to overwrite lineage-4mib-exact' \
  'from: url)[identityAttribute] else {' 'from: url, refuseDenseStorage: false)[identityAttribute] else {' \
  'from: url)[minReaderAttribute] else {' 'from: url, refuseDenseStorage: false)[minReaderAttribute] else {' \
  $'                let before = HDF5FileIdentity(ofItemAt: url.path)\n                let header = try readHeader(of: url)' \
  $'                let before = HDF5FileIdentity(ofItemAt: url.path)\n                _ = try HDF5RootAttributes.read([], from: url)\n                let header = try readHeader(of: url)'
source_mutant SessionSidecarFile.swift dense-attribute-message-bit-inverted \
  "swift reads valid-libver-latest|swift reads valid-compact-attributes-tracked-order|$DENSE_READS" \
  'KIT:present & (UInt64(1) << 12) == 0 {' 'present & (UInt64(1) << 12) != 0 {'
source_mutant SessionSidecarFile.swift dense-attribute-count-not-asked \
  'swift reads foreign-no-attributes' \
  'KIT:if present & (UInt64(1) << 21) != 0, present' 'if true, present'
source_mutant SessionSidecarFile.swift dense-accepted-when-attributes-counted \
  "swift reads foreign-no-attributes|$DENSE_READS" \
  'KIT:if present & (UInt64(1) << 21) != 0, present' 'if present & (UInt64(1) << 21) == 0, present'
# The header read together with META_SIZE, which walks the fractal heap and the B-tree: the unit and plain checks cannot tell it from the
# header read (the header bits are the same), only the structure-aware fuzz can: the second opinion's FRHP windows (17 SIGSEGV and 26 hangs
# in its 648) crash or spin it, where the header-only read returns on all of them.
# MEMORY (2026-10-20, FormatoKit 0.5.0 switch): this mutant's child grows to about 30 GB resident before its deadline kills it (two runs:
# 29.8 and 33.0 GB), over the 24 GB cap, so a full run under a 24 GB memory cap is killed here; run it alone, `--only dense-header-read`, under a
# larger cap on an otherwise idle Mac.
GATE_EXTRA=(--fuzz-dense)
source_mutant SessionSidecarFile.swift dense-header-read-with-meta-size \
  'fuzz dense-70k crashes|fuzz dense-70k hangs' \
  'KIT:private static let fieldHeader: UInt32 = 0x0008' 'private static let fieldHeader: UInt32 = 0x0018'
GATE_EXTRA=()

# ADR 023 a (slice B step 2): the writer's 60,000-byte cap on the four attributes' text, the save request's check of the same.
# The cap is held by the raw writes (exactly at it written, one byte over refused by name, and a split between the source and the
# lineage), and every file from empty to within 100 bytes of it by h5py as compact storage (`h5py raw size-N compact`).
source_mutant SessionSidecarFile.swift writer-total-cap-removed \
  'swift writer total-cap-plus-one-lineage|swift writer total-cap-plus-one-split' \
  'guard total <= maxTotalTextBytes else { throw Refusal.sidecarTooLarge(bytes: total) }' '_ = total'
source_mutant SessionSidecarFile.swift writer-total-cap-at-less-than \
  'swift writer total-cap-exact-lineage' \
  'guard total <= maxTotalTextBytes else' 'guard total < maxTotalTextBytes else'
source_mutant SessionSidecarFile.swift writer-total-cap-on-the-lineage-only \
  'swift writer total-cap-plus-one-lineage|swift writer total-cap-plus-one-split' \
  'let total = totalTextBytes(sourceBytes: source.utf8.count, lineageBytes: lineage.utf8.count)' 'let total = totalTextBytes(sourceBytes: 0, lineageBytes: lineage.utf8.count)'
source_mutant SessionMarks.swift marks-save-budget-skipped \
  'swift marks save-disk over-budget' \
  'guard total <= SessionSidecarFile.maxTotalTextBytes else { throw .file(.sidecarTooLarge(bytes: total)) }' '_ = total'
source_mutant SessionMarks.swift marks-save-budget-at-less-than \
  'swift marks save-disk at-budget' \
  'guard total <= SessionSidecarFile.maxTotalTextBytes else' 'guard total < SessionSidecarFile.maxTotalTextBytes else'

# 41. a control of the harness itself, not of the sources: the library check. The named copy is made unloadable and the committed
#     one is offered under the loader's fallback path, so the binding's fall-back to the bare name loads it: the whole gate
#     would still pass on that library (it is the same one), and only the check that the loaded copy is the named one fails.
if selected library-fallback && (( ! CHECK_EDITS )); then
  total=$(( total + 1 ))
  library_log="$WORK/library-control.log"
  set +e
  FORMATO_HDF5_PATH="$WORK/no-such-copy/libhdf5.dylib" DYLD_FALLBACK_LIBRARY_PATH="$WORK/hdf5" \
    "$WORK/harness" "$WORK/ref" "$WORK/out" > "$library_log" 2>&1
  library_rc=$?
  set -e
  if caught_by "$library_log" $library_rc 'libhdf5 is the named copy'; then
    caught=$(( caught + 1 ))
    echo "  ok    the harness's library check fails when the library loaded is not the named copy"
  else
    echo "  FAIL  the harness's library check did not fail (exit $library_rc) when the named copy could not be loaded:"
    sed 's/^/        /' "$library_log" | head -20
  fi
fi

# 54-57. controls of the fuzz driver itself (fuzz.swift): against a stub reader that answers the unmutated file correctly and
#     misbehaves on every mutation, the driver must fail the check for that misbehaviour (and, against a stub that only refuses
#     by name, report nothing). The real fuzz runs once, above; these show it cannot pass blind.
fuzz_driver_control() {  # fuzz_driver_control <misbehaviour> <the check it must fail>
  selected "fuzz-driver-$1" || return 0
  total=$(( total + 1 ))
  if (( CHECK_EDITS )); then caught=$(( caught + 1 )); echo "  ok    (check-edits) the fuzz driver's control '$1' needs no edit"; return; fi
  local log="$WORK/fuzz-driver-$1.log" rc
  set +e
  "$WORK/harness" --fuzz-selftest "$1" "$WORK/fuzz-driver-$1" > "$log" 2>&1
  rc=$?
  set -e
  if caught_by "$log" $rc "$2"; then
    caught=$(( caught + 1 ))
    echo "  ok    the fuzz driver reports a reader that '$1' as '${2//|/' and '}'"
  else
    echo "  FAIL  the fuzz driver did not fail its check '${2//|/' and '}' (exit $rc) against a reader that '$1':"
    sed 's/^/        /' "$log" | head -20
  fi
}
fuzz_driver_control hang 'fuzz selftest hangs'
fuzz_driver_control crash 'fuzz selftest crashes'
fuzz_driver_control silent 'fuzz selftest silent changes'
fuzz_driver_control unnamed 'fuzz selftest unnamed outcomes'
if selected fuzz-driver-ok && (( ! CHECK_EDITS )); then   # the other side: a reader that only refuses by name is not reported
  ok_log="$WORK/fuzz-driver-ok.log"
  set +e
  "$WORK/harness" --fuzz-selftest ok "$WORK/fuzz-driver-ok" > "$ok_log" 2>&1
  ok_rc=$?
  set -e
  if (( ok_rc != 0 )); then
    echo "  FAIL  the fuzz driver failed against a stub reader that only refuses by name (exit $ok_rc):"
    sed 's/^/        /' "$ok_log" | head -20
    exit 1
  fi
  echo "  ok    the fuzz driver reports nothing against a reader that only refuses by name"
fi

if [[ -n "$ONLY" ]]; then
  echo "sidecar-parity: partial run (--only '$ONLY'): $caught of $total controls caught by their checks"
  (( caught == total )) || exit 1
  exit 0
fi
if (( CHECK_EDITS )); then
  echo "sidecar-parity: --check-edits: the edits of $caught of $total controls apply"
  (( caught == total )) || exit 1
  exit 0
fi
if (( caught != total )); then
  echo "sidecar-parity: negative controls: $caught of $total caught by their checks"
  exit 1
fi
echo "sidecar-parity: negative controls: $total of $total caught by their checks"
