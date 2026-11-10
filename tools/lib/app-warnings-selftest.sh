#!/bin/zsh
# Self-test of tools/lib/app-warnings.sh: on a planted xcodebuild log, a warning in macTEM/UI and one in macTEMTests fail the check
# and are each listed once although the log repeats one; warnings in a package checkout, in DerivedData and in the project file are
# not counted; a log with none of the app's passes with "0 app warnings"; a tree reached through a symlink matches by its resolved
# path; an unreadable log is refused. Needs no build; the inventory runs it on every push.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/app-warnings.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/app-warnings-selftest.XXXXXX")"
trap 'rm -rf "$work"' EXIT
work="${work:A}"
out=""
fail() { echo "app-warnings-selftest: $1"; print -r -- "$out"; exit 1; }

root="$work/macTEM-tree"
mkdir -p "$root/macTEM/UI" "$root/macTEMTests"
ui="$root/macTEM/UI/ImageRoom.swift:12:9: warning: initialization of immutable value 'unused' was never used"
test="$root/macTEMTests/ImageStackTests.swift:40:13: warning: 'try' has no effect"
cat > "$work/red.log" <<LOG
CompileSwift normal arm64 $root/macTEM/UI/ImageRoom.swift
$ui
$ui
$test
$work/DerivedData/SourcePackages/checkouts/SpectroKit/Sources/SpectroKit/Fit.swift:3:1: warning: a package's own warning
$work/DerivedData/Build/Intermediates.noindex/macTEM.build/Debug/GeneratedAssetSymbols.swift:1:1: warning: generated
$root/macTEM.xcodeproj: warning: The macOS deployment target is set to 10.0
$root/macTEM/UI/ImageRoom.swift:20:5: error: not a warning
** TEST SUCCEEDED **
LOG
out="$(app_warnings "$root" "$work/red.log")" && rc=0 || rc=$?
(( rc == 1 )) || fail "a warning in macTEM/UI and one in macTEMTests must fail the check (got exit $rc)"
[[ "$out" == "$ui"$'\n'"$test"$'\n'"unit: 2 app warnings" ]] \
  || fail "the check does not list the app's two warnings once each, and them alone, with the count"

grep -v ': warning: initialization\|: warning: .try' "$work/red.log" > "$work/green.log"
out="$(app_warnings "$root" "$work/green.log")" || fail "a log with no warning of the app's own must pass"
[[ "$out" == "unit: 0 app warnings" ]] || fail "a log with no warning of the app's own does not say 0"

# The tree reached through a symlink: the compiler names the resolved path.
ln -s "$root" "$work/link"
out="$(app_warnings "$work/link" "$work/red.log")" && rc=0 || rc=$?
(( rc == 1 )) && [[ "$out" == *"unit: 2 app warnings" ]] || fail "a tree reached through a symlink misses its warnings (got exit $rc)"

out="$(app_warnings "$root" "$work/no-such.log" 2>&1)" && rc=0 || rc=$?
(( rc == 2 )) || fail "an unreadable log must be refused, not read as no warnings (got exit $rc)"
echo "app-warnings-selftest: the app's warnings fail by name, once each; packages, DerivedData and the project file are not counted"
