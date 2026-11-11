#!/bin/zsh
# Self-test of tools/lib/core-warnings.sh: on a planted `swift build` log, a compiler warning in TEMCore and SwiftPM's own warning
# about an unhandled file fail the check and are listed in order; SwiftPM's notes that it skipped its repository cache are not
# counted, and a log with only those passes; a compiler warning whose words happen to read "skipping cache due to an error" still
# counts; an unreadable log is refused. Needs no build; the inventory runs it on every push.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/core-warnings.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/core-warnings-selftest.XXXXXX")"
trap 'rm -rf "$work"' EXIT
out=""
fail() { echo "core-warnings-selftest: $1"; print -r -- "$out"; exit 1; }

compiler="/runner/macTEM/Sources/TEMCore/Profile.swift:12:9: warning: initialization of immutable value 'unused' was never used"
manifest="warning: 'mactem': found 1 file(s) which are unhandled; explicitly declare them as resources or exclude from the target"
cat > "$work/notes.log" <<'LOG'
Fetching https://github.com/mac4DSTEM/ImagoKit from cache
warning: 'diffractokit': skipping cache due to an error: The file “maintenance.lock” doesn’t exist.
Fetched https://github.com/mac4DSTEM/ImagoKit from cache (0.64s)
warning: 'macemui': skipping cache due to an error: The file “maintenance.lock” doesn’t exist.
Building for debugging...
Build complete! (178.87s)
LOG
{ cat "$work/notes.log"; print -r -- "$compiler"; print -r -- "$manifest"; } > "$work/red.log"

out="$(core_warnings "$work/red.log")" && rc=0 || rc=$?
(( rc == 1 )) || fail "a compiler warning and SwiftPM's unhandled-file warning must fail the check (got exit $rc)"
[[ "$out" == "$compiler"$'\n'"$manifest" ]] || fail "the check does not list the compiler's and SwiftPM's warnings, and them alone"

out="$(core_warnings "$work/notes.log")" || fail "a log whose only warnings are SwiftPM's cache notes must pass"
[[ -z "$out" ]] || fail "SwiftPM's cache notes are listed as warnings"
[[ "$(skipped_caches "$work/notes.log")" == 2 ]] || fail "the two cache notes are not counted as notes"

lookalike="/runner/macTEM/Sources/TEMSession/Log.swift:3:1: warning: skipping cache due to an error: not SwiftPM's note"
print -r -- "$lookalike" > "$work/lookalike.log"
out="$(core_warnings "$work/lookalike.log")" && rc=0 || rc=$?
(( rc == 1 )) && [[ "$out" == "$lookalike" ]] || fail "a compiler warning that reads like the cache note is not counted (got exit $rc)"

out="$(core_warnings "$work/no-such.log" 2>&1)" && rc=0 || rc=$?
(( rc == 2 )) || fail "an unreadable log must be refused, not read as no warnings (got exit $rc)"
echo "core-warnings-selftest: compiler and SwiftPM warnings fail by name; SwiftPM's repository-cache notes are not counted"
