#!/bin/zsh
# The SpectroKit source lock — fetched, not vendored (ADR 019; since 0.4.0 the readers are FormatoKit's, ADR 026, and no harness
# compiles SpectroKit: this keeps the pin checked for the EDX room).
#
# The app builds SpectroKit as a Swift package (Package.swift, exact; the tag is the pin in Package.resolved). A harness compiles production sources into
# one module with swiftc (tools/lib/sources.manifest), so it needs the same SpectroKit sources as files: this script
# clones github.com/mac4DSTEM/SpectroKit into the gitignored References/SpectroKit at the revision Package.resolved pins,
# and refuses a checkout at any other commit or with local edits (never repaired in place), as fetch-rsciio.sh does.
#
#   fetch-spectrokit.sh          ensure References/SpectroKit is the pin; prints its path on the last line
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/References/SpectroKit"
REPO="https://github.com/mac4DSTEM/SpectroKit.git"
RESOLVED="$ROOT/Package.resolved"
PROBE="Sources/SpectroCore/Spectroscopy/SpectrumImageOpening.swift"

refuse() {  # <what is wrong> [<the fix in place>]
  echo "fetch-spectrokit: REFUSED — $1." >&2
  [[ -z "${2:-}" ]] || echo "  Fix in place: $2" >&2
  exit 1
}

[[ -f "$RESOLVED" ]] || refuse "no Package.resolved at the repo root (run swift package resolve)"
# The pin is the one Package.resolved records for the package whose identity is "spectrokit".
pin="$(awk '/"identity" *: *"spectrokit"/ { f = 1 } f && /"revision"/ { gsub(/[",]/, "", $3); print $3; exit }' "$RESOLVED")"
[[ "$pin" =~ ^[0-9a-f]{40}$ ]] || refuse "Package.resolved names no 40-hex SpectroKit revision (found '$pin')"

if [[ -e "$DEST" ]]; then
  sk() { git --no-optional-locks -C "$DEST" "$@"; }
  [[ -e "$DEST/.git" ]] || refuse "References/SpectroKit is not a git checkout" "delete it and re-run this script"
  have="$(sk rev-parse --verify HEAD 2>/dev/null)" || refuse "References/SpectroKit has no readable HEAD"
  [[ "$have" == "$pin" ]] || refuse "References/SpectroKit is at $have, Package.resolved pins $pin" \
    "git -C References/SpectroKit fetch --tags origin && git -C References/SpectroKit checkout $pin"
  dirty="$(sk status --porcelain --untracked-files=normal)" || refuse "References/SpectroKit cannot be read by git status"
  if [[ -n "$dirty" ]]; then
    print -r -- "$dirty" | head -10 | sed 's/^/  /' >&2
    refuse "References/SpectroKit has local changes (above)" "git -C References/SpectroKit stash -u"
  fi
else
  mkdir -p "$ROOT/References"
  echo "fetch-spectrokit: cloning SpectroKit at $pin into References/" >&2
  git clone -q "$REPO" "$DEST"
  git -C "$DEST" checkout -q "$pin"
fi
[[ -f "$DEST/$PROBE" ]] || refuse "the pin has no $PROBE"
echo "fetch-spectrokit: lock present (HEAD = $pin, clean)" >&2
echo "$DEST"
