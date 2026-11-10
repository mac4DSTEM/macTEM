# tools/lib/app-warnings.sh — the unit gate's compiler warnings in the app's own sources and tests. Sourced by tools/run-tests.sh;
# tools/lib/app-warnings-selftest.sh checks it (the inventory runs that on every push).
#
# `core` holds TEMCore and TEMSession to zero warnings; this holds macTEM/ (App, UI) and macTEMTests/ to zero too (#335). A package
# checkout, DerivedData and the project file are not the app's sources and are not counted.

# app_warnings <root> <xcodebuild log>: prints each distinct `warning:` line whose path is under <root>/macTEM/ or
# <root>/macTEMTests/, once, the first 200 of them, then "unit: N app warnings", and exits 1 when N > 0. The root is matched as
# given and as resolved (`${root:A}`), since the compiler names a file by its resolved path where the tree is reached through a
# symlink. The number is a cold build's (CI): a warm DerivedData recompiles little and so prints few. Plain POSIX awk: macOS's awk
# runs it, and so does Linux's mawk. Exits 2 when the log cannot be read.
app_warnings() {
  local root="$1" log="$2"
  [[ -r "$log" ]] || { echo "unit: cannot read the build log $log for the app's warnings" >&2; return 2; }
  awk -v root="$root/" -v real="${root:A}/" '
    function under(dir) { return index($0, root dir "/") == 1 || index($0, real dir "/") == 1 }
    (under("macTEM") || under("macTEMTests")) && index($0, ": warning:") && !seen[$0]++ { if (++n <= 200) print }
    END {
      if (n > 200) print "  (" (n - 200) " more, not listed)"
      print "unit: " (n + 0) " app warnings"
      exit (n > 0)
    }' "$log"
}
