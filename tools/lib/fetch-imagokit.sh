#!/bin/zsh
# The ImagoKit source lock for the scientific harnesses — fetched, not vendored (ADR 027).
#
# The app builds ImagoKit as a Swift package (Package.swift, exact 0.2.0). A harness compiles the kit's three modules
# (ImagoCore, ImagoFFT, ImagoFilters) from sources with swiftc (tools/lib/sources.manifest,
# `mactem_imagokit`), so it needs the same sources as files: this script clones github.com/mac4DSTEM/ImagoKit
# into the gitignored References/ImagoKit at the revision Package.resolved pins, refuses a checkout at any other
# commit or with local edits (never repaired in place), and refuses a kit whose Package.swift enables upcoming features
# other than the ones MACTEM_CORE_FLAGS (sources.manifest) compiles it with, so a harness never checks the kit under
# settings the app does not build it with.
#
#   fetch-imagokit.sh          ensure References/ImagoKit is the pin; prints its path on the last line
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/References/ImagoKit"
REPO="https://github.com/mac4DSTEM/ImagoKit.git"
RESOLVED="$ROOT/Package.resolved"
PROBE="Sources/ImagoFilters/HRTEMFilter.swift"

refuse() {  # <what is wrong> [<the fix in place>]
  echo "fetch-imagokit: REFUSED — $1." >&2
  [[ -z "${2:-}" ]] || echo "  Fix in place: $2" >&2
  exit 1
}

[[ -f "$RESOLVED" ]] || refuse "no Package.resolved at the repo root (run swift package resolve)"
# The pin is the one Package.resolved records for the package whose identity is "imagokit".
pin="$(awk '/"identity" *: *"imagokit"/ { f = 1 } f && /"revision"/ { gsub(/[",]/, "", $3); print $3; exit }' "$RESOLVED")"
[[ "$pin" =~ ^[0-9a-f]{40}$ ]] || refuse "Package.resolved names no 40-hex ImagoKit revision (found '$pin')"

if [[ -e "$DEST" ]]; then
  dk() { git --no-optional-locks -C "$DEST" "$@"; }
  [[ -e "$DEST/.git" ]] || refuse "References/ImagoKit is not a git checkout" "delete it and re-run this script"
  have="$(dk rev-parse --verify HEAD 2>/dev/null)" || refuse "References/ImagoKit has no readable HEAD"
  [[ "$have" == "$pin" ]] || refuse "References/ImagoKit is at $have, Package.resolved pins $pin" \
    "git -C References/ImagoKit fetch --tags origin && git -C References/ImagoKit checkout $pin"
  dirty="$(dk status --porcelain --untracked-files=normal)" || refuse "References/ImagoKit cannot be read by git status"
  if [[ -n "$dirty" ]]; then
    print -r -- "$dirty" | head -10 | sed 's/^/  /' >&2
    refuse "References/ImagoKit has local changes (above)" "git -C References/ImagoKit stash -u"
  fi
else
  mkdir -p "$ROOT/References"
  echo "fetch-imagokit: cloning ImagoKit at $pin into References/" >&2
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
echo "fetch-imagokit: lock present (HEAD = $pin, clean)" >&2
echo "$DEST"
