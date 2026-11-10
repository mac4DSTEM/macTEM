# Adapted from mac4DSTEM (tools/lib/run-harnesses.sh).
# run_harnesses <harness root> <name>... : runs each harness's run.sh in turn and keeps going past a red one, so one run
# reports every failure instead of stopping at the first. Prints a summary and returns 1 when any harness failed.
# Sourced by tools/run-tests.sh; tools/lib/run-harnesses-selftest.sh checks it (the inventory runs that on every push).
run_harnesses() {
  local root=$1; shift
  local -a failed=()
  local name started finished rc
  for name in "$@"; do
    started=$(date +%s)
    echo "==> $name"
    if "$root/$name/run.sh"; then rc=0; else rc=$?; fi
    finished=$(date +%s)
    if (( rc == 0 )); then
      echo "<== $name ($((finished - started)) s)"
    else
      echo "<== $name FAILED (exit $rc, $((finished - started)) s)"
      failed+=("$name")
    fi
  done
  if (( ${#failed[@]} )); then
    echo "harnesses: ${#failed[@]} of $# failed: ${failed[*]}"
    return 1
  fi
  echo "harnesses: all $# passed"
}
