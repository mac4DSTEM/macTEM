#!/bin/zsh
# Self-test of tools/lib/unit-skips.sh: on a planted result bundle's JSON (as `xcresulttool get test-results tests` prints it) with
# two skipped cases, one listed and one not, the check fails and names the unlisted one; the listed sem-data case fails too while
# MACTEM_REQUIRE_SEM_DATA=1; a run whose every skip is listed passes; a listed test that ran is named, not failed; a malformed line is
# refused; and the committed tools/unit-skips.allow reads cleanly. Needs no data and builds nothing; the inventory runs it on every push.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/unit-skips.sh"
unset MACTEM_REQUIRE_SEM_DATA
work="$(mktemp -d "${TMPDIR:-/tmp}/unit-skips-selftest.XXXXXX")"
trap 'rm -rf "$work"' EXIT
out=""
fail() { echo "unit-skips-selftest: $1"; print -r -- "$out"; exit 1; }

# One case passes, one skips and is listed (sem-data), one skips and is not; the last carries no nodeIdentifier, so it is named by
# its suite.
cat > "$work/tests.json" <<'JSON'
{"testNodes": [{"name": "macTEM", "nodeType": "Test Plan", "result": "Passed", "children": [
  {"name": "macTEMTests", "nodeType": "Unit test bundle", "result": "Passed", "children": [
    {"name": "PlantedTests", "nodeType": "Test Suite", "result": "Passed", "children": [
      {"name": "testRuns()", "nodeIdentifier": "PlantedTests/testRuns()", "nodeType": "Test Case", "result": "Passed"},
      {"name": "testNeedsTheSEMData()", "nodeIdentifier": "PlantedTests/testNeedsTheSEMData()", "nodeType": "Test Case", "result": "Skipped",
       "children": [{"name": "Test skipped - fetch-data.sh has not fetched it", "nodeType": "Failure Message"}]}]},
    {"name": "OtherTests", "nodeType": "Test Suite", "result": "Passed", "children": [
      {"name": "testLostItsFixture()", "nodeType": "Test Case", "result": "Skipped",
       "children": [{"name": "Test skipped - the fixture moved", "nodeType": "Failure Message"}]}]}]}]}]}
JSON
skips="$(skipped_tests_from_json < "$work/tests.json")" || fail "the planted bundle's skips could not be listed"
out="$skips"
[[ "$skips" == "unit: SKIPPED OtherTests.testLostItsFixture: Test skipped - the fixture moved"$'\n'"unit: SKIPPED PlantedTests.testNeedsTheSEMData: Test skipped - fetch-data.sh has not fetched it" ]] \
  || fail "the two skipped cases are not each named with its reason"

printf '# planted\n%s\t%s\t%s\n%s\t%s\t%s\n' PlantedTests.testNeedsTheSEMData sem-data "the SEM data" \
  PlantedTests.testRuns real-data "listed, and it runs" > "$work/one.allow"
out="$(print -r -- "$skips" | unlisted_skips "$work/one.allow")" && rc=0 || rc=$?
(( rc == 1 )) || fail "a skip the allow file does not list must fail the check (got exit $rc)"
[[ "$out" == "OtherTests.testLostItsFixture" ]] || fail "the check does not name the unlisted skip, and it alone"
out="$(export MACTEM_REQUIRE_SEM_DATA=1; print -r -- "$skips" | unlisted_skips "$work/one.allow")" && rc=0 || rc=$?
(( rc == 1 )) && [[ "$out" == "OtherTests.testLostItsFixture"$'\n'"PlantedTests.testNeedsTheSEMData" ]] \
  || fail "with MACTEM_REQUIRE_SEM_DATA=1 the listed sem-data skip must fail as well (got exit $rc)"
out="$(print -r -- "$skips" | listed_not_skipped "$work/one.allow")" || fail "the listed tests that ran could not be read"
[[ "$out" == "PlantedTests.testRuns (real-data)" ]] || fail "a listed test that ran is not named with its condition"

{ cat "$work/one.allow"; printf '%s\t%s\t%s\n' OtherTests.testLostItsFixture real-data "listed now"; } > "$work/all.allow"
out="$(print -r -- "$skips" | unlisted_skips "$work/all.allow")" || fail "a run whose every skip is listed must pass"
[[ -z "$out" ]] || fail "a run whose every skip is listed names one"

printf '%s\t%s\t%s\n' OtherTests.testLostItsFixture gpu "no such condition" > "$work/bad.allow"
out="$(print -r -- "$skips" | unlisted_skips "$work/bad.allow" 2>&1)" && rc=0 || rc=$?
(( rc == 2 )) || fail "a line whose condition is not one of the four must be refused (got exit $rc)"

out="$(unlisted_skips "$here/../unit-skips.allow" < /dev/null 2>&1)" \
  || fail "tools/unit-skips.allow is not Class.method<TAB>condition<TAB>reason on every line"
echo "unit-skips-selftest: an unlisted skip fails by name, a sem-data entry allows none under MACTEM_REQUIRE_SEM_DATA=1, an all-listed run passes"
