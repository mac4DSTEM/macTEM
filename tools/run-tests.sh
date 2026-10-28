#!/bin/zsh
# PROVENANCE: mac4DSTEM df1e6c994ea5b49c7ec08737628631b204736974 tools/run-tests.sh adapted
# mac4DSTEM's entry point, free-space floor, test-host geometry reset, harness arrays and lane structure, cut to four
# lanes; the unit reconciliation, the core lane and the inventory checks are macTEM's, but for its two checks of what
# the bundle redistributes (NOTICE's dylib hashes and load paths, the bundled folders tracked), ported with the dylibs.
# Changed (EDX room, 2026-10-21): the unit run passes SWIFT_OPTIMIZATION_LEVEL=-O so SpectroKit is optimised (mac4DSTEM ADR 067).
# Re-sync to 5b696589: upstream's only change to this file since 7c180bce (7b349a7b, `core` takes swift build's exit
# from swift build, not from a pipe) is already macTEM's core_build, which reads it from a log; nothing else applies.
# END PROVENANCE
# tools/run-tests.sh — the one entry point to macTEM's gates.
#
#   unit        the XCTest suite (macTEMTests), unsigned, in a scratch DerivedData; then the executed tests are
#               reconciled BY NAME (Class.method, from the result bundle) against the `func test…()` declarations,
#               and any difference fails (a stale bundle, a renamed test or one in the wrong class passes a count)
#   core        `swift build` of the package from a fresh scratch path: TEMCore and TEMSession — the layering gate
#               (a package target cannot reach the app's App/ or UI/), the Swift 6 gate, and zero warnings
#   scientific  the reference harnesses (the `scientific` array below), fail-fast
#   inventory   the repo's own review: the checks below; no build
#
# Read the exit code from the script itself, never through a pipe: redirect to a log, `echo $?` on its own line.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

# Every tools/ directory is in exactly one array; `inventory` fails on one that is not.
scientific=(dm4-reader-parity tiff-reader-parity mrc-reader-parity fft-parity spot-parity crystal-parity metadata-parity ring-calibration-parity hrtem-filter-parity histogram-parity profile-parity velox-image-parity export-parity fft-export-parity sidecar-parity indexing-parity diffraction-room-parity)   # gated: compares Core against a pinned reference
diagnostic=(ellipse-parity ring-fit-parity)   # never gated: machine-local data, or the evidence of a registered item that failed (S2, S3-b)
owner_only=()                    # the owner's own runs
retired=()                       # kept for history, not run
support=(au-ring-pattern crystal-structures)   # not harnesses

# A near-full disk fakes code regressions (mac4DSTEM, 2026-08-06: three runs, three different spurious failure
# sets). 4 GB is mac4DSTEM's floor for the same lanes: 3.2x its measured unit-suite peak (1245 MB).
require_free_space() {
  # `dir`, not `path`: zsh ties `path` to PATH, and a local `path` blanks it.
  local need="$1" what="$2" dir have
  for dir in "$ROOT" "${TMPDIR:-/tmp}"; do
    have="$(df -Pg "$dir" | awk 'NR==2 {print $4}')"
    if [[ -z "$have" ]] || (( have < need )); then
      echo "run-tests.sh: need ${need} GB free for ${what}, have ${have:-?} GB on ${dir}" >&2
      echo "  Free space and re-run; a near-full disk fakes code regressions." >&2
      exit 69
    fi
  done
}

# The unit tests' host is the app, unsigned and so unsandboxed: it restores the window and split geometry the last
# unsigned build saved. In mac4DSTEM a saved 915-pt window with a 278-pt sidebar aborted every launch in the
# constraint loop (2026-09-28) and turned the gate red on unchanged code; macTEM copies that shell, so the gate
# starts from the default geometry and says which keys it cleared.
clear_test_host_geometry() {
  local domain="$HOME/Library/Preferences/com.mac4dstem.macTEM.plist" key
  [[ -f "$domain" ]] || return 0
  defaults export "$domain" - | plutil -p - \
    | sed -n 's/^  "\(NSWindow Frame [^"]*\)" =>.*/\1/p; s/^  "\(NSSplitView Subview Frames [^"]*\)" =>.*/\1/p' \
    | while IFS= read -r key; do
        echo "run-tests.sh: clearing the test host's saved geometry: $key"
        defaults delete "$domain" "$key"
      done
}

# The tests a result bundle ran, as Class.method, one per line: every "Test Case" node of
# `xcresulttool get test-results tests` (JSON on stdin), named by its nodeIdentifier ("Class/method()"), or by its
# enclosing "Test Suite" and its name when a node carries no identifier (the schema does not require one).
executed_tests_from_json() {
  jq -r 'def cases($suite): (if .nodeType == "Test Suite" then .name else $suite end) as $s
           | if .nodeType == "Test Case" then (.nodeIdentifier // ($s + "/" + .name))
             else (.children[]? | cases($s)) end;
         .testNodes[] | cases("?")' | sed -E 's#\(\)$##; s#/#.#'
}

# The tests macTEMTests declares, as Class.method: each `func test…()` (no parameters: XCTest runs no other) under
# the top-level type declared before it in its file. A helper type or a top-level func named test… is attributed
# to the wrong name on purpose: it then fails the reconciliation instead of being counted. A name is everything up to
# its parenthesis, not [[:alnum:]_]: awk matches bytes, and a letter such as Å is two (testÅngström ran but was not
# declared, 2026-10-12).
declared_tests() {  # <tests dir>
  local -a files=("$1"/**/*.swift(N.))
  (( ${#files} )) || return 0
  awk '
    FNR == 1 { type = "(file scope)" }
    /^(@[[:alnum:]_]+(\([^)]*\))?[[:space:]]+|(public|package|internal|fileprivate|private|open|final|nonisolated)[[:space:]]+)*(class|extension|struct|enum|actor)[[:space:]]+[[:alpha:]_]/ {
      match($0, /(class|extension|struct|enum|actor)[[:space:]]+[[:alnum:]_]+/)
      type = substr($0, RSTART, RLENGTH); sub(/^[[:alpha:]]+[[:space:]]+/, "", type) }
    /^[[:space:]]*(@[[:alnum:]_]+(\([^)]*\))?[[:space:]]+|(override|nonisolated|public|package|internal|fileprivate|private|open|final|dynamic)[[:space:]]+)*func[[:space:]]+test[^[:space:](]*[[:space:]]*\([[:space:]]*\)/ {
      match($0, /func[[:space:]]+test[^[:space:](]*/)
      name = substr($0, RSTART, RLENGTH); sub(/^func[[:space:]]+/, "", name)
      print type "." name }' "${files[@]}"
}

# Executed against declared, as sorted multisets of Class.method; prints each difference and fails on any. On a
# match, MACTEM_TESTS_MATCHED holds the count.
reconcile_test_names() {  # <xcresult> <tests dir>
  local executed declared diffs n
  MACTEM_TESTS_MATCHED=0
  if ! executed="$(xcrun xcresulttool get test-results tests --path "$1" | executed_tests_from_json)"; then
    echo "unit: cannot list the executed tests from the result bundle"; return 1
  fi
  executed="$(print -r -- "$executed" | sed '/^$/d' | LC_ALL=C sort)"
  declared="$(declared_tests "$2" | LC_ALL=C sort)"
  # `|| true`: diff exits 1 on a difference, which pipefail + errexit would turn into a silent exit here.
  diffs="$({ diff <(print -r -- "$declared") <(print -r -- "$executed") || true; } \
           | sed -nE 's/^< (.*)/  declared, did not run: \1/p; s/^> (.*)/  ran, not declared:     \1/p')"
  if [[ -n "$diffs" ]]; then
    print -r -- "$diffs"
    echo "unit: the tests that ran differ by name from the func test…() declarations in macTEMTests"
    return 1
  fi
  n=${#${(f)executed}}
  if (( n == 0 )); then echo "unit: no test ran and none is declared"; return 1; fi
  MACTEM_TESTS_MATCHED=$n
  echo "unit: $n tests ran = $n declared, matched by Class.method"
}

unit_tests() (
  clear_test_host_geometry
  # Never let an unsigned test build replace the app Xcode launches from its normal DerivedData. MACTEM_DERIVED_DATA
  # (set by `tools/gate.sh unit --warm`, to <gate dir>/dd-unit, outside the tree) reuses a lane's own persistent scratch DerivedData; unset, the build is cold.
  # Tests run in parallel (-parallel-testing-enabled YES), adopted 2026-10-14 after a serial and a parallel run on the
  # same warm tree executed the same 853 names with the same 853/0/0 (26 s serial, 16 s parallel);
  # MACTEM_PARALLEL_TESTING=NO runs them serially, to compare when a test is suspected of depending on order.
  local work rc total passed failed skipped
  work="$(mktemp -d "${TMPDIR:-/tmp}/mactem-unit-tests.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  local -a par=(-parallel-testing-enabled "${MACTEM_PARALLEL_TESTING:-YES}")
  # MACTEM_TEST_WORKERS (set by tools/gate.sh: 8, or 4 while mac4DSTEM holds a heavy.* lock) caps the parallel workers.
  [[ -n "${MACTEM_TEST_WORKERS:-}" ]] && par+=(-parallel-testing-worker-count "$MACTEM_TEST_WORKERS")
  # SWIFT_OPTIMIZATION_LEVEL=-O on the command line is the only setting that reaches a package target in the Test action
  # (the Test action stays Debug for testability): without it SpectroKit builds -Onone, where its hot loops are about 20x
  # slower (mac4DSTEM ADR 067; here the EDX session tests went from 38 s to 1.9 s for one fit).
  # MACTEM_ONLY_TESTING="ClassA ClassB" runs only those test classes (a mutation loop on a warm DerivedData); the by-name
  # reconciliation below is then skipped and the run is not a landing gate.
  local -a only=(-only-testing:macTEMTests)
  if [[ -n "${MACTEM_ONLY_TESTING:-}" ]]; then only=(); local cls; for cls in ${=MACTEM_ONLY_TESTING}; do only+=("-only-testing:macTEMTests/$cls"); done; fi
  # `-testLanguage en -testRegion US`: the unit tests spell numbers with a decimal point; display strings follow the Mac's locale
  # (ShellLayout's glance, ShellControls' scale bar), and locale-specific cases pass their own Locale.
  # CODE_SIGNING_ALLOWED=NO is for this unsigned XCTest path only; never add it to a build you intend to launch.
  LLVM_PROFILE_FILE="$work/default-%p.profraw" \
    xcodebuild test -project "$ROOT/macTEM.xcodeproj" -scheme macTEM \
      -configuration Debug -destination 'platform=macOS' \
      -derivedDataPath "${MACTEM_DERIVED_DATA:-$work/DerivedData}" -resultBundlePath "$work/unit.xcresult" \
      "${only[@]}" "${par[@]}" -testLanguage en -testRegion US \
      SWIFT_OPTIMIZATION_LEVEL=-O \
      CODE_SIGNING_ALLOWED=NO > "$work/unit.log" 2>&1 && rc=0 || rc=$?
  grep -E "error:|: error|\) failed |TEST (SUCCEEDED|FAILED)" "$work/unit.log" | tail -40 || true
  # xcodebuild states some failures only in its "Testing failed:" block, without an `error:` line (a runner without a
  # matching platform, a test host that will not launch); print that block too.
  grep -A12 "^Testing failed:" "$work/unit.log" | head -30 || true
  # A compiler crash prints no `error:` either: its signal and stack dump are the reason.
  grep -E -A8 "Stack dump|PLEASE submit|Segmentation fault|Assertion failed|terminated due to signal|Illegal instruction" "$work/unit.log" | head -40 || true
  echo "unit: xcodebuild exit $rc"
  # Counted from the result bundle, not the log: Xcode 27's parallel runner prints no suite summary, and its
  # stdout can drop a result line when its own debug output interleaves (measured 2026-10-12).
  if ! xcrun xcresulttool get test-results summary --path "$work/unit.xcresult" > "$work/summary.json" 2>/dev/null; then
    echo "unit: no readable result bundle"; return $(( rc == 0 ? 1 : rc ))
  fi
  total="$(plutil -extract totalTestCount raw "$work/summary.json")"
  passed="$(plutil -extract passedTests raw "$work/summary.json")"
  failed="$(plutil -extract failedTests raw "$work/summary.json")"
  skipped="$(plutil -extract skippedTests raw "$work/summary.json")"
  echo "unit: $total tests: $passed passed, $failed failed, $skipped skipped"
  if [[ "$failed" != 0 ]]; then    # name them: the log of a parallel run carries no per-test failure line
    xcrun xcresulttool get test-results tests --path "$work/unit.xcresult" \
      | jq -r '.. | objects | select(.nodeType? == "Test Case" and .result? == "Failed") | "unit: FAILED " + .name' | sort -u | head -40
  fi
  if [[ -n "${MACTEM_ONLY_TESTING:-}" ]]; then
    echo "unit (filtered to ${MACTEM_ONLY_TESTING}): $failed failed of $total"
    if [[ "$failed" != 0 ]]; then
      xcrun xcresulttool get test-results tests --path "$work/unit.xcresult" \
        | jq -r '.. | objects | select(.nodeType? == "Test Case" and .result? == "Failed") | "FAILED " + .name' | sort -u | head -40
    fi
    return $(( failed == 0 ? 0 : 1 ))
  fi
  if ! reconcile_test_names "$work/unit.xcresult" "$ROOT/macTEMTests"; then
    return $(( rc == 0 ? 1 : rc ))
  fi
  (( rc == 0 )) || return $rc
  # A skipped test is a declared XCTSkip (the opt-in real-data tests without their data or variable, a fixture that is absent): it ran by name
  # and said why, so it is not a failure of the gate; a failure is.
  if [[ "$total" != "$MACTEM_TESTS_MATCHED" || "$failed" != 0 || $(( passed + skipped )) != "$total" ]]; then
    echo "unit: $passed of $total passed, $skipped skipped, $MACTEM_TESTS_MATCHED matched by name — a failed test, or a summary that disagrees with the test list"
    return 1
  fi
  echo "unit: $passed tests passed, $skipped skipped by their own XCTSkip, every declared test ran by name"
)

# The UI journeys (macTEMUITests, scheme macTEMUI): the real app, signed, walked as a user would, one screenshot per step. Never part of
# `unit`: `tools/run-tests.sh ui [Journey ...]` runs all of them or the named ones. First run: macOS asks to allow Accessibility for Xcode Helper.
ui_tests() (
  . "$ROOT/tools/lib/gate-dir.sh"
  local gate result rc journeys total passed failed
  gate="$(mactem_gate_dir "$ROOT")"; mkdir -p "$gate"
  result="$gate/ui.xcresult"; rm -rf "$result"
  local -a only
  if (( $# > 0 )); then for journeys in "$@"; do only+=("-only-testing:macTEMUITests/$journeys"); done; else only=(-only-testing:macTEMUITests -skip-testing:macTEMUITests/PerformanceJourney); fi
  # Signed (automatic), unlike the unit gate: the app is launched. Packages still need -O or the demo takes 20 times longer.
  # One UI run at a time on the one screen: macTEM and mac4DSTEM share this lock file, so their runs queue instead of fighting for the window.
  lockf -k -t 1200 "${TMPDIR:-/tmp}/macem-ui-tests.lock" xcodebuild test -project "$ROOT/macTEM.xcodeproj" -scheme macTEMUI -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$gate/dd-ui" -resultBundlePath "$result" "${only[@]}" SWIFT_OPTIMIZATION_LEVEL=-O > "$gate/ui.log" 2>&1 && rc=0 || rc=$?
  grep -E "error:|TEST (SUCCEEDED|FAILED)" "$gate/ui.log" | tail -20 || true
  echo "ui: xcodebuild exit $rc"
  if ! xcrun xcresulttool get test-results summary --path "$result" > "$gate/ui-summary.json" 2>/dev/null; then
    echo "ui: no readable result bundle (log: $gate/ui.log)"; return $(( rc == 0 ? 1 : rc ))
  fi
  total="$(plutil -extract totalTestCount raw "$gate/ui-summary.json")"; passed="$(plutil -extract passedTests raw "$gate/ui-summary.json")"
  failed="$(plutil -extract failedTests raw "$gate/ui-summary.json")"
  echo "ui: $total journeys: $passed passed, $failed failed"
  if [[ "$failed" != 0 ]]; then
    xcrun xcresulttool get test-results tests --path "$result" \
      | jq -r '.. | objects | select(.nodeType? == "Test Case" and .result? == "Failed") | "ui: FAILED " + .name' | sort -u | head -20
  fi
  "$ROOT/tools/lib/ui-screenshots.sh" "$result" "$gate" || true
  return $(( rc == 0 && failed == 0 && total > 0 ? 0 : 1 ))
)

run_harnesses() {
  local name started
  for name in "$@"; do
    started=$(date +%s)
    echo "==> $name"
    "$ROOT/tools/parity/$name/run.sh"
    echo "<== $name ($(( $(date +%s) - started )) s)"
  done
}

# From a fresh scratch path every run: an incremental build compiles nothing and so prints none of the warnings it
# emitted the first time (a second run on the same tree printed 0 of 2, review 2026-10-12). Any `warning:` fails.
core_build() (
  local work rc warnings
  work="$(mktemp -d "${TMPDIR:-/tmp}/mactem-core.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  ( cd "$ROOT" && swift build --scratch-path "$work/build" ) > "$work/core.log" 2>&1 && rc=0 || rc=$?
  grep -vE '^\[[0-9]+ ?/ ?[0-9]+\]' "$work/core.log" || true
  if (( rc != 0 )); then echo "core: swift build exit $rc" >&2; return $rc; fi
  warnings="$(grep -E 'warning:' "$work/core.log" || true)"
  if [[ -n "$warnings" ]]; then
    echo "core: swift build exit 0 but with warnings; TEMCore and TEMSession build with zero (CLAUDE.md):" >&2
    print -r -- "$warnings" >&2
    return 1
  fi
  echo "core: TEMCore + TEMSession built from scratch, 0 warnings"
)

inventory() {
  local rc=0 name dir src f

  echo "== tools classification"
  local -a all=("${scientific[@]}" "${diagnostic[@]}" "${owner_only[@]}" "${retired[@]}" "${support[@]}")
  for name in "${all[@]}"; do
    [[ -d "$ROOT/tools/parity/$name" ]] || { echo "  MISSING tools/parity/$name (classified, not present)"; rc=1; }
  done
  # tools/ holds the scripts, lib/, hooks/, drive/ (the guarded hand-drive helpers) and parity/; every folder under tools/parity/ is in exactly one array.
  for dir in "$ROOT"/tools/*(/N); do
    case "${dir:t}" in lib|hooks|parity|drive) ;; *) echo "  UNEXPECTED folder tools/${dir:t} — harnesses live in tools/parity/"; rc=1 ;; esac
  done
  for dir in "$ROOT"/tools/parity/*(/N); do
    name="${dir:t}"
    (( ${all[(Ie)$name]} )) || { echo "  UNCLASSIFIED tools/parity/$name — add it to one array in tools/run-tests.sh"; rc=1; }
  done

  echo "== harnesses compile Core through tools/lib/sources.manifest"
  # On code lines only — a comment naming the manifest satisfied the old `grep -L sources.manifest` (review,
  # 2026-10-12): every tools/parity/*/run.sh sources the manifest, calls mactem_sources and compiles with mactem_swiftc
  # (which fixes -O, -warnings-as-errors and MACTEM_CORE_FLAGS), and no shell script below tools/*/ runs swiftc any
  # other way. `code` drops comment lines and trailing ` # …` comments; the swiftc scan drops comment lines only.
  local h code
  for name in "${scientific[@]}"; do
    [[ -f "$ROOT/tools/parity/$name/run.sh" ]] || { echo "  MISSING tools/parity/$name/run.sh (the scientific lane runs it)"; rc=1; }
  done
  for h in "$ROOT"/tools/parity/*/run.sh(N); do
    code="$(sed -E '/^[[:space:]]*#/d; s/[[:space:]]+#.*$//' "$h")"
    grep -qE '^[[:space:]]*\. "\$ROOT/tools/lib/sources\.manifest"([[:space:];]|$)' <<< "$code" \
      || { echo "  ${h#$ROOT/}: no code line \`. \"\$ROOT/tools/lib/sources.manifest\"\`"; rc=1; }
    grep -qE '(^|[;&|({[:space:]])mactem_sources[[:space:]]' <<< "$code" \
      || { echo "  ${h#$ROOT/}: no mactem_sources call"; rc=1; }
    grep -qE '(^|[;&|({[:space:]])mactem_swiftc[[:space:]]' <<< "$code" \
      || { echo "  ${h#$ROOT/}: no mactem_swiftc call"; rc=1; }
  done
  local other
  for h in "$ROOT"/tools/*/**/*.sh(N.); do
    other="$(awk '!/^[[:space:]]*#/ && /(^|[^[:alnum:]_])(swiftc|swift-frontend)([^[:alnum:]_]|$)/ { print "  " FNR ": " $0 }' "$h")"
    if [[ -n "$other" ]]; then
      print -r -- "$other"; echo "  ^ ${h#$ROOT/}: compiles Swift outside mactem_swiftc (tools/lib/sources.manifest)"; rc=1
    fi
  done

  echo "== kit boundary (no Accelerate / Metal / vDSP in the app outside tools/kit-boundary.allow)"
  "$ROOT/tools/check-kit-boundary.sh" || rc=1

  echo "== harness flags = TEMCore's settings"
  # A harness must check Core under the settings the app builds it with (mac4DSTEM, 2026-08-19: three of five
  # upcoming features missing from the harness flags).
  local feat
  for feat in $(sed -n '/name: "TEMCore"/,/^        ),/p' "$ROOT/Package.swift" | sed -nE 's/.*enableUpcomingFeature\("([A-Za-z]+)"\).*/\1/p' | sort -u); do
    grep -q -- "-enable-upcoming-feature $feat" "$ROOT/tools/lib/sources.manifest" \
      || { echo "  TEMCore enables $feat; MACTEM_CORE_FLAGS does not"; rc=1; }
  done
  for feat in $(sed -nE 's/.*-enable-upcoming-feature ([A-Za-z]+).*/\1/p' "$ROOT/tools/lib/sources.manifest" | sort -u); do
    sed -n '/name: "TEMCore"/,/^        ),/p' "$ROOT/Package.swift" | grep -q "enableUpcomingFeature(\"$feat\")" \
      || { echo "  MACTEM_CORE_FLAGS enables $feat; TEMCore does not"; rc=1; }
  done
  grep -q -- '-swift-version 6' "$ROOT/tools/lib/sources.manifest" || { echo "  MACTEM_CORE_FLAGS is not Swift 6"; rc=1; }
  grep -q '\.defaultIsolation(' <(sed -n '/name: "TEMCore"/,/^        ),/p' "$ROOT/Package.swift") \
    && { echo "  TEMCore sets a default isolation; it is nonisolated by decision"; rc=1; }

  echo "== DiffractoKit (ADR 025): exact pin, resolved, and the harnesses build it under the kit's own settings"
  # The kit is imported at an exact tag, never a local path; Package.resolved names the revision the harnesses fetch
  # (tools/lib/fetch-diffractokit.sh). The kit's upcoming features must equal MACTEM_CORE_FLAGS: the fetch script refuses a
  # checkout where they differ, and runs here whenever the checkout is on this Mac (CI has none: it only checks the pin).
  local kit_version resolved_version
  kit_version="$(sed -nE 's#.*github\.com/mac4DSTEM/DiffractoKit", exact: "([0-9.]+)".*#\1#p' "$ROOT/Package.swift")"
  resolved_version="$(awk '/"identity" *: *"diffractokit"/ { f = 1 } f && /"version"/ { gsub(/[",]/, "", $3); print $3; exit }' "$ROOT/Package.resolved")"
  [[ -n "$kit_version" && "$kit_version" == "$resolved_version" ]] \
    || { echo "  Package.swift pins DiffractoKit '$kit_version' exact, Package.resolved '$resolved_version'"; rc=1; }
  if [[ -e "$ROOT/References/DiffractoKit/.git" ]]; then
    "$ROOT/tools/lib/fetch-diffractokit.sh" > /dev/null 2> "${TMPDIR:-/tmp}/mactem-fetch-kit.err" \
      || { cat "${TMPDIR:-/tmp}/mactem-fetch-kit.err"; rc=1; }
  else
    echo "  no References/DiffractoKit here: its settings are compared when a harness fetches it"
  fi

  echo "== FormatoKit (ADR 026): exact pin, resolved; FormatoKit built by the harnesses under its own settings"
  # SpectroKit 0.4.0 depends on FormatoKit by tag and both define the process's HDF5 lock through FormatoKit: the two pins are
  # exact in Package.swift and in Package.resolved, and a package missing from either is a failure.
  local kit pkg_version res_version
  for kit in FormatoKit; do   # SpectroKit left the graph 2026-10-16 (no tag pins FormatoKit 0.3.0); re-add with the EDX room
    pkg_version="$(sed -nE "s#.*github\.com/mac4DSTEM/$kit\", exact: \"([0-9.]+)\".*#\1#p" "$ROOT/Package.swift")"
    res_version="$(awk -v id="${kit:l}" '$0 ~ "\"identity\" *: *\"" id "\"" { f = 1 } f && /"version"/ { gsub(/[",]/, "", $3); print $3; exit }' "$ROOT/Package.resolved")"
    [[ -n "$pkg_version" && "$pkg_version" == "$res_version" ]] \
      || { echo "  Package.swift pins $kit '$pkg_version' exact, Package.resolved '$res_version'"; rc=1; }
  done
  if [[ -e "$ROOT/References/FormatoKit/.git" ]]; then
    "$ROOT/tools/lib/fetch-formatokit.sh" > /dev/null 2> "${TMPDIR:-/tmp}/mactem-fetch-formatokit.err" \
      || { cat "${TMPDIR:-/tmp}/mactem-fetch-formatokit.err"; rc=1; }
  else
    echo "  no References/FormatoKit here: its settings are compared when a harness fetches it"
  fi

  echo "== ImagoKit (ADR 027): exact pin, resolved, and the harnesses build it under the kit's own settings"
  local imago_version imago_resolved
  imago_version="$(sed -nE 's#.*github\.com/mac4DSTEM/ImagoKit(\.git)?", exact: "([0-9.]+)".*#\2#p' "$ROOT/Package.swift")"
  imago_resolved="$(awk '/"identity" *: *"imagokit"/ { f = 1 } f && /"version"/ { gsub(/[",]/, "", $3); print $3; exit }' "$ROOT/Package.resolved")"
  [[ -n "$imago_version" && "$imago_version" == "$imago_resolved" ]] \
    || { echo "  Package.swift pins ImagoKit '$imago_version' exact, Package.resolved '$imago_resolved'"; rc=1; }
  if [[ -e "$ROOT/References/ImagoKit/.git" ]]; then
    "$ROOT/tools/lib/fetch-imagokit.sh" > /dev/null 2> "${TMPDIR:-/tmp}/mactem-fetch-imagokit.err" \
      || { cat "${TMPDIR:-/tmp}/mactem-fetch-imagokit.err"; rc=1; }
  else
    echo "  no References/ImagoKit here: its settings are compared when a harness fetches it"
  fi

  # Any import form: an attribute (@preconcurrency, @_exported), an access level, an import kind (`import class`).
  local imports='^[[:space:]]*(@[[:alnum:]_]+(\([^)]*\))?[[:space:]]+)*((public|package|internal|fileprivate|private)[[:space:]]+)?import[[:space:]]+([[:alnum:]_]+[[:space:]]+)?'
  echo "== layering: no SwiftUI or AppKit below the app"
  # MetalKit and Cocoa count as AppKit: a file whose only import is MetalKit compiles NSColor and NSScreen.
  if grep -rnE --include='*.swift' "${imports}(SwiftUI|AppKit|Cocoa|MetalKit)([^[:alnum:]_]|$)" "$ROOT/Sources"; then
    echo "  ^ TEMCore and TEMSession describe no UI (docs/architecture.md)"; rc=1
  fi

  echo "== the UI contract"
  # SwiftUI only: no split views (HSplitView was half of a launch crash in mac4DSTEM), no AppKit in UI/. Comment lines
  # are exempt.
  if grep -nE '^[^/]*\b(HSplitView|VSplitView|NSSplitView|NSSplitViewController)\b' "$ROOT"/macTEM/UI/*.swift; then
    echo "  ^ a split banned by the UI contract (docs/architecture.md)"; rc=1
  fi
  if grep -rnE --include='*.swift' "${imports}(AppKit|Cocoa)([^[:alnum:]_]|$)" "$ROOT/macTEM/UI"; then
    echo "  ^ AppKit imported in UI (docs/architecture.md)"; rc=1
  fi
  # Rule 3: the chrome draws no bar or wash of its own; the science panes are exempt.
  if grep -nE '\.background\((\.bar\)|Color\.[a-zA-Z]+\.opacity)' "$ROOT"/macTEM/UI/*.swift \
       | grep -vE 'PaneOverlays|MetalImageView|ImagePane'; then
    echo "  ^ custom bar or opacity wash in the chrome (UI contract rule 3)"; rc=1
  fi
  # Rule 4: a numeric `.frame(...)` in the chrome comes from LayoutPolicy; the panes and overlays are exempt.
  if grep -nE '\.frame\([^)]*: *[0-9]' "$ROOT"/macTEM/UI/*.swift \
       | grep -vE 'PaneOverlays|ImagePane|LayoutPolicy' | grep -vE 'LayoutPolicy\.|// science'; then
    echo "  ^ a fixed frame outside the science (UI contract rule 4)"; rc=1
  fi

  echo "== files over 1 MiB (tracked, or untracked and not ignored)"
  # The same listing as the copy check: a big file not yet committed is the one to stop (review, 2026-10-12).
  local size big listing allow_file="$ROOT/tools/large-files.allow"
  if ! listing="$(git -C "$ROOT" ls-files -co --exclude-standard -z)"; then
    echo "  git ls-files failed: no file was measured"; rc=1; listing=""
  fi
  while IFS=$'\t' read -r size big; do
    (( size > 1048576 )) || continue
    if awk -F'\t' -v p="$big" '$1 == p { f = 1 } END { exit !f }' "$allow_file"; then
      echo "  $big allowed"
    else
      echo "  $big ($size bytes) NOT IN tools/large-files.allow"; rc=1
    fi
  done < <(cd "$ROOT" && print -rn -- "$listing" | xargs -0 stat -f '%z%t%N' 2>/dev/null)

  # mac4DSTEM's two checks of what the bundle redistributes (its run-tests.sh at 5ba712a0), ported with the dylibs
  # (ADR 008, ADR 019): NOTICE names and hashes each committed dylib, no load command names an absolute path, and every
  # file under a bundled folder reference (Licenses/) is tracked, so a clone builds the bundle a release ships.
  echo "== redistributed binaries (NOTICE names and hashes each)"
  local dl sum
  for dl in "$ROOT"/*.dylib(N); do
    dl="${dl:t}"; sum="$(shasum -a 256 "$ROOT/$dl" | cut -d' ' -f1)"
    if ! grep -q "$dl" "$ROOT/NOTICE"; then
      echo "  UNNAMED   $dl is redistributed and NOTICE does not name it"; rc=1
    elif ! grep -q "$sum" "$ROOT/NOTICE"; then
      echo "  HASH      $dl is $sum; NOTICE states a different one"; rc=1
    else
      printf "  %-36s %s\n" "$dl" "${sum[1,16]}…"
    fi
    if otool -L "$ROOT/$dl" | tail -n +2 | grep -qE '^\s+/(opt|usr/local|Users)/'; then
      echo "  ABSPATH   $dl links against an absolute path; a relocated bundle will not load it"; rc=1
    fi
  done
  echo "== bundled folder references (every file must be tracked)"
  local ref bf why
  for ref in $(grep 'lastKnownFileType = folder' "$ROOT/macTEM.xcodeproj/project.pbxproj" | sed -nE 's/.*path = ([^;]+);.*/\1/p' | tr -d '"'); do
    if [[ ! -d "$ROOT/$ref" ]]; then echo "  MISSING   $ref"; rc=1; continue; fi
    printf "  %-36s %7s files\n" "$ref" "$(find "$ROOT/$ref" -type f | wc -l | tr -d ' ')"
    for bf in $(cd "$ROOT" && find "$ref" -type f); do
      git -C "$ROOT" ls-files --error-unmatch -- "$bf" >/dev/null 2>&1 && continue
      why="$( { git -C "$ROOT" check-ignore -v -- "$bf" 2>/dev/null | grep -v ':!' | cut -d: -f1-2; } || true)"
      echo "  UNTRACKED $bf${why:+   $why}"; rc=1
    done
  done

  # Every accessibility identifier a UI journey uses exists in the app's sources (a dynamic one, "edx.composition.Mg", by its prefix
  # "edx.composition.\(…)"), so a renamed identifier fails here before it fails on screen.
  echo "== UI journey identifiers"
  # The shared package's sources: the sibling checkout during development, else the tag-pinned checkout SwiftPM made (the CI runner has no
  # ../MacEMUI; nightly review 2026-10-23), else none and only this repo's sources are searched.
  local shared="$ROOT/../MacEMUI/Sources" id parent
  if [[ ! -d "$shared" ]]; then
    # (N): a pattern with no match drops out instead of stopping zsh with "no matches found" (CI, 2026-10-27).
    local -a found=( "$ROOT"/.build/checkouts/MacEMUI/Sources(N/) "$ROOT"/../*/SourcePackages/checkouts/MacEMUI/Sources(N/) \
                     "${MACTEM_GATE_DIR:-/nonexistent}"/*/SourcePackages/checkouts/MacEMUI/Sources(N/) )
    shared="${found[1]:-}"
    [[ -n "$shared" ]] || echo "  (no MacEMUI checkout beside this repo: the shell's identifiers are not checked here)"
  fi
  local -a where=("$ROOT/macTEM" "$ROOT/Sources"); [[ -n "$shared" ]] && where+=("$shared")
  for id in $(grep -rhoE '(waitFor|waitValue|element)\("[a-zA-Z]+(\.[a-zA-Z]+)+"' "$ROOT/macTEMUITests" 2>/dev/null | sed -E 's/^[a-zA-Z]+\("//; s/"$//' | sort -u); do
    # The shell's chrome (status bar, rooms, the verb, Output) is MacEMUI's: its identifiers are declared there.
    if grep -rqF "\"$id\"" "${where[@]}"; then continue; fi
    parent="${id%.*}"
    if grep -rqF "\"$parent.\\(" "${where[@]}"; then continue; fi
    if grep -rqF "\"${id%.*.*}.\\(" "${where[@]}"; then continue; fi
    echo "  MISSING   identifier $id is used by a UI journey and no source declares it"; rc=1
  done

  if (( rc == 0 )); then echo "inventory: clean"; else echo "inventory: FAILED"; fi
  return $rc
}

case "${1:-unit}" in
  unit) require_free_space 4 "the xcodebuild unit suite"; unit_tests ;;
  core) core_build ;;
  scientific) require_free_space 4 "the science harnesses"; run_harnesses "${scientific[@]}" ;;
  inventory) inventory ;;
  ui) shift; require_free_space 4 "the UI journeys"; ui_tests "$@" ;;
  *) echo "Usage: tools/run-tests.sh [unit|core|scientific|inventory|ui [Journey ...]]" >&2; exit 64 ;;
esac
