#!/bin/zsh
# Adapted from mac4DSTEM (tools/lib/run-harnesses-selftest.sh).
# Self-test of tools/lib/run-harnesses.sh: a red harness in the middle does not stop the ones after it, the summary names
# it, and the run fails. Needs no data and builds nothing; the inventory runs it on every push.
set -euo pipefail
. "$(dirname "$0")/run-harnesses.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/run-harnesses-selftest.XXXXXX")"
trap 'rm -rf "$work"' EXIT
for h in first red last; do
  mkdir -p "$work/$h"
  if [[ $h == red ]]; then printf '#!/bin/sh\nexit 3\n' > "$work/$h/run.sh"
  else printf '#!/bin/sh\ntouch "%s/%s.ran"\n' "$work" "$h" > "$work/$h/run.sh"; fi
  chmod +x "$work/$h/run.sh"
done
out="$(run_harnesses "$work" first red last)" && rc=0 || rc=$?
fail() { echo "run-harnesses-selftest: $1"; echo "$out"; exit 1; }
(( rc == 1 )) || fail "a red harness must fail the run (got exit $rc)"
[[ -f "$work/first.ran" && -f "$work/last.ran" ]] || fail "the harness after the red one did not run"
[[ "$out" == *"red FAILED (exit 3"* ]] || fail "the red harness is not reported with its exit code"
[[ "$out" == *"1 of 3 failed: red"* ]] || fail "the summary does not name the red harness"
out="$(run_harnesses "$work" first last)" || fail "an all-green run failed"
[[ "$out" == *"all 2 passed"* ]] || fail "an all-green run has no summary"
echo "run-harnesses-selftest: a red harness is reported and the rest still run"
