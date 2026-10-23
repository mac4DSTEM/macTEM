#!/bin/zsh
# macTEM's own since 2026-10-15 (first adapted from mac4DSTEM 7d6fdbd1's, which no longer has it): the lock commit and
# clone; the presence check names the DigitalMicrograph test files macTEM reads, and an existing checkout is verified
# (a git checkout, HEAD at the lock, clean) or refused, never repaired in place.
# The rosettasciio source + test-data lock — fetched, not vendored.
#
# macTEM reads RosettaSciIO's GMS-written DigitalMicrograph test files (tools/parity/dm4-reader-parity, case 2) and
# will read its EMD/TIFF test files when those readers land. Its test data is GPL-3.0-or-later and excluded from
# its wheels, and committing third-party bytes is not needed to test against them, so they are fetched with the
# pin into the gitignored References/ folder. The commit is mac4DSTEM's lock, so the two apps read the same files.
#
# The harness trusts this tree's own registry.txt for the files' hashes, so the tree must BE the lock: a directory
# that only held the probe file, or a checkout with local edits, was accepted before (review, 2026-10-12).
set -euo pipefail

RSCIIO_LOCK_COMMIT="049e7d7070e84779b499adaf3295beee9facb004"   # main, 2026-10-05, version 0.14.0 (mac4DSTEM's lock)
RSCIIO_REPO="https://github.com/hyperspy/rosettasciio.git"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/References/rosettasciio"
PROBE="rsciio/tests/data/digitalmicrograph/2D/test_STEM_image.dm3"

refuse() {  # <what is wrong> [<the fix in place>]
  echo "fetch-rsciio: REFUSED — References/rosettasciio $1." >&2
  [[ -z "${2:-}" ]] || echo "  Fix in place: $2" >&2
  echo "  Or delete References/rosettasciio and re-run this script to clone the lock afresh (network)." >&2
  exit 1
}

if [[ -e "$DEST" ]]; then
  upgit() { git --no-optional-locks -C "$DEST" "$@"; }
  [[ -e "$DEST/.git" ]] || refuse "is not a git checkout, so nothing says it is the lock"
  have="$(upgit rev-parse --verify HEAD 2>/dev/null)" || refuse "has no readable HEAD"
  [[ "$have" == "$RSCIIO_LOCK_COMMIT" ]] \
    || refuse "is at $have, the lock is $RSCIIO_LOCK_COMMIT" \
              "git -C References/rosettasciio fetch origin $RSCIIO_LOCK_COMMIT && git -C References/rosettasciio checkout $RSCIIO_LOCK_COMMIT"
  dirty="$(upgit status --porcelain --untracked-files=normal)" || refuse "cannot be read by git status"
  if [[ -n "$dirty" ]]; then
    print -r -- "$dirty" | head -10 | sed 's/^/  /' >&2
    refuse "has local changes (above)" "git -C References/rosettasciio stash -u (or checkout/clean them away)"
  fi
  [[ -f "$DEST/$PROBE" ]] || refuse "at the lock has no $PROBE"
  echo "fetch-rsciio: lock present (HEAD = $RSCIIO_LOCK_COMMIT, clean)"
  exit 0
fi

mkdir -p "$ROOT/References"
echo "fetch-rsciio: cloning rosettasciio at $RSCIIO_LOCK_COMMIT into References/" >&2
git clone -q --filter=blob:none "$RSCIIO_REPO" "$DEST"
git -C "$DEST" checkout -q "$RSCIIO_LOCK_COMMIT"
[[ -f "$DEST/$PROBE" ]] || { echo "fetch-rsciio: $PROBE is missing at the lock" >&2; exit 1; }
echo "fetch-rsciio: ready"
