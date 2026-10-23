#!/bin/zsh
# The DiffractoKit source lock for the scientific harnesses — fetched, not vendored (ADR 025).
#
# The app builds DiffractoKit as a Swift package (Package.swift, exact; the tag is the pin in Package.resolved). A harness compiles the kit's three modules
# (DiffractoCore, DiffractoScattering, DiffractoGeometry) from sources with swiftc (tools/lib/sources.manifest,
# `mactem_diffractokit`), so it needs the same sources as files: this script clones github.com/mac4DSTEM/DiffractoKit
# into the gitignored References/DiffractoKit at the revision Package.resolved pins, refuses a checkout at any other
# commit or with local edits (never repaired in place), and refuses a kit whose Package.swift enables upcoming features
# other than the ones MACTEM_CORE_FLAGS (sources.manifest) compiles it with, so a harness never checks the kit under
# settings the app does not build it with.
#
#   fetch-diffractokit.sh          ensure References/DiffractoKit is the pin; prints its path on the last line
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/References/DiffractoKit"
REPO="https://github.com/mac4DSTEM/DiffractoKit.git"
RESOLVED="$ROOT/Package.resolved"
PROBE="Sources/DiffractoGeometry/RingIndexing.swift"

refuse() {  # <what is wrong> [<the fix in place>]
  echo "fetch-diffractokit: REFUSED — $1." >&2
  [[ -z "${2:-}" ]] || echo "  Fix in place: $2" >&2
  exit 1
}

[[ -f "$RESOLVED" ]] || refuse "no Package.resolved at the repo root (run swift package resolve)"
# The pin is the one Package.resolved records for the package whose identity is "diffractokit".
pin="$(awk '/"identity" *: *"diffractokit"/ { f = 1 } f && /"revision"/ { gsub(/[",]/, "", $3); print $3; exit }' "$RESOLVED")"
[[ "$pin" =~ ^[0-9a-f]{40}$ ]] || refuse "Package.resolved names no 40-hex DiffractoKit revision (found '$pin')"

if [[ -e "$DEST" ]]; then
  dk() { git --no-optional-locks -C "$DEST" "$@"; }
  [[ -e "$DEST/.git" ]] || refuse "References/DiffractoKit is not a git checkout" "delete it and re-run this script"
  have="$(dk rev-parse --verify HEAD 2>/dev/null)" || refuse "References/DiffractoKit has no readable HEAD"
  [[ "$have" == "$pin" ]] || refuse "References/DiffractoKit is at $have, Package.resolved pins $pin" \
    "git -C References/DiffractoKit fetch --tags origin && git -C References/DiffractoKit checkout $pin"
  dirty="$(dk status --porcelain --untracked-files=normal)" || refuse "References/DiffractoKit cannot be read by git status"
  if [[ -n "$dirty" ]]; then
    print -r -- "$dirty" | head -10 | sed 's/^/  /' >&2
    refuse "References/DiffractoKit has local changes (above)" "git -C References/DiffractoKit stash -u"
  fi
else
  mkdir -p "$ROOT/References"
  echo "fetch-diffractokit: cloning DiffractoKit at $pin into References/" >&2
  git clone -q "$REPO" "$DEST"
  git -C "$DEST" checkout -q "$pin"
fi
[[ -f "$DEST/$PROBE" ]] || refuse "the pin has no $PROBE"

# The kit's own upcoming features against the harness flags.
kit_features="$(sed -nE 's/.*enableUpcomingFeature\("([A-Za-z]+)"\).*/\1/p' "$DEST/Package.swift" | sort -u)"
harness_features="$(sed -nE 's/^[[:space:]]*-enable-upcoming-feature ([A-Za-z]+).*/\1/p' "$ROOT/tools/lib/sources.manifest" | sort -u)"
[[ -n "$kit_features" && "$kit_features" == "$harness_features" ]] \
  || refuse "the kit enables [$(print -r -- $kit_features | tr '\n' ' ')] and MACTEM_CORE_FLAGS [$(print -r -- $harness_features | tr '\n' ' ')]" \
            "change MACTEM_CORE_FLAGS and TEMCore's Package.swift settings together, in a registered item"
echo "fetch-diffractokit: lock present (HEAD = $pin, clean)" >&2
echo "$DEST"
