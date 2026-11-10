# tools/lib/unit-skips.sh — the unit gate's skipped tests, named and held to tools/unit-skips.allow. Sourced by tools/run-tests.sh;
# tools/lib/unit-skips-selftest.sh checks it (the inventory runs that on every push).
#
# The allow file lists each test that may skip, one per line: Class.method<TAB>condition<TAB>reason, the condition one of
# sem-data (the SEM reference data under References/sem-data, which tools/parity/sem/fetch-data.sh fetches), real-data (the owner's
# data folder or an opt-in variable, never on a runner), metal (no Metal device) or sandbox (no security-scoped bookmark). Lines that
# start with # and empty lines are comments. With MACTEM_REQUIRE_SEM_DATA=1 (the nightly unit job, after it fetched that data) a
# sem-data line allows nothing.

# The tests a result bundle skipped, one line each, sorted: "unit: SKIPPED Class.method: <reason>", named as run-tests.sh's
# executed_tests_from_json names them. The reason is the case's first "Failure Message" node (where xcresulttool puts the XCTSkip
# message), or "no reason recorded" without one. `xcresulttool get test-results tests` JSON on stdin.
skipped_tests_from_json() {
  jq -r 'def skips($suite): (if .nodeType == "Test Suite" then .name else $suite end) as $s
           | if .nodeType == "Test Case" then
               (select(.result == "Skipped")
                | ((.nodeIdentifier // ($s + "/" + .name)) | sub("\\(\\)$"; "") | sub("/"; ".")) as $t
                | ([.. | objects | select(.nodeType == "Failure Message") | .name] | first // "no reason recorded") as $why
                | "unit: SKIPPED " + $t + ": " + ($why | gsub("\n"; " ")))
             else (.children[]? | skips($s)) end;
         .testNodes[] | skips("?")' | LC_ALL=C sort -u
}

# unit_skips_check <unlisted|ran> <allow file>: the one reader of the allow file and of the skip lines on stdin. `unlisted` prints
# each skipped Class.method the file does not allow, once, and exits 1 when it printed any; `ran` prints each listed test that did
# not skip, with its condition, in the file's order. Either exits 2, naming the line, when the file cannot be read or a line is
# not Class.method<TAB>condition<TAB>reason (a malformed line would otherwise allow nothing, or the wrong test). Plain POSIX awk:
# macOS's awk runs it, and so does Linux's mawk.
unit_skips_check() {
  awk -v mode="$1" -v allow="$2" -v require="${MACTEM_REQUIRE_SEM_DATA:-}" '
    BEGIN {
      while ((got = (getline line < allow)) > 0) {
        lines++
        if (line ~ /^#/ || line ~ /^[[:space:]]*$/) continue
        if (split(line, f, "\t") != 3 || f[1] !~ /^[^.[:space:]]+\.test[^.[:space:]]*$/ ||
            f[2] !~ /^(sem-data|real-data|metal|sandbox)$/ || f[3] ~ /^[[:space:]]*$/) {
          print "unit-skips: " allow ":" lines ": not Class.method<TAB>condition<TAB>reason (sem-data, real-data, metal or sandbox): " line > "/dev/stderr"
          bad = 1; continue
        }
        if (f[1] in condition) { print "unit-skips: " allow ":" lines ": " f[1] " is listed twice" > "/dev/stderr"; bad = 1; continue }
        condition[f[1]] = f[2]; order[++listed] = f[1]
      }
      if (got < 0) { print "unit-skips: cannot read " allow > "/dev/stderr"; bad = 1 }
      if (bad) exit 2
    }
    {
      if (!sub(/^unit: SKIPPED /, "")) next
      name = $0; sub(/:.*$/, "", name)
      skipped[name] = 1
      if (mode == "unlisted" && !(name in printed) && (!(name in condition) || (require == "1" && condition[name] == "sem-data"))) {
        printed[name] = 1; print name; unlisted++
      }
    }
    END {
      if (bad) exit 2
      if (mode == "ran") { for (i = 1; i <= listed; i++) if (!(order[i] in skipped)) print order[i] " (" condition[order[i]] ")" }
      if (mode == "unlisted" && unlisted > 0) exit 1
    }' -
}

# unlisted_skips <allow file>: skip lines ("unit: SKIPPED Class.method: <reason>") on stdin; prints each skipped test the allow file
# does not list, or lists as sem-data while MACTEM_REQUIRE_SEM_DATA=1, and exits 1 when there is one (2: the file is unreadable or
# malformed).
unlisted_skips() {
  unit_skips_check unlisted "$1"
}

# listed_not_skipped <allow file>: skip lines on stdin; prints each listed test that did not skip, "Class.method (condition)": an
# entry that may have gone stale, reported and never failed (the nightly's sem-data entries run by design).
listed_not_skipped() {
  unit_skips_check ran "$1"
}
