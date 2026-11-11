# tools/lib/core-warnings.sh — the warnings `core` counts in its `swift build` of the package. Sourced by tools/run-tests.sh;
# tools/lib/core-warnings-selftest.sh checks it (the inventory runs that on every push).
#
# `core` holds TEMCore and TEMSession to zero warnings. Every `warning:` line of the build counts, the compiler's and SwiftPM's
# own (an unhandled file, a deprecated manifest call), with one exception: SwiftPM's note that it skipped its repository cache,
# "warning: '<package>': skipping cache due to an error: …". That note says a clone in ~/Library/Caches/org.swift.swiftpm could
# not be copied, so the package was cloned afresh; it names no source, and the build that follows is the same. On CI it came
# from a restored cache whose git maintenance lock went away during the copy (2026-11-11, twice on one PR: "The file
# "maintenance.lock" doesn't exist"), and it failed a build with no warning in it.

# core_warnings <swift build log>: prints each counted `warning:` line, in the log's order, and exits 1 when there is one and 0
# when there is none. Exits 2 when the log cannot be read. Plain POSIX awk: macOS's awk runs it, and so does Linux's mawk.
core_warnings() {
  local log="$1"
  [[ -r "$log" ]] || { echo "core: cannot read the build log $log for its warnings" >&2; return 2; }
  awk -v cache="^warning: '[^']+': skipping cache due to an error: " '
    /warning:/ && $0 !~ cache { print; n++ }
    END { exit (n > 0) }' "$log"
}

# skipped_caches <swift build log>: how many of SwiftPM's cache notes the log holds (they are not counted as warnings).
skipped_caches() {
  awk -v cache="^warning: '[^']+': skipping cache due to an error: " '$0 ~ cache { n++ } END { print n + 0 }' "$1"
}
