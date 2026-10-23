#!/bin/zsh
# The FormatoKit source lock for the scientific harnesses — fetched, not vendored (ADR 026).
#
# The app builds FormatoKit as a Swift package (Package.swift, exact; the tag is the pin in Package.resolved). A harness
# compiles the kit's four modules (FormatoCore, FormatoHDF5, FormatoDM, FormatoEMD) from sources with swiftc
# (tools/lib/sources.manifest, `mactem_kit_build`), so it needs the same sources as files: this script clones
# github.com/mac4DSTEM/FormatoKit into the gitignored References/FormatoKit at the revision Package.resolved pins,
# refuses a checkout at any other commit or with local edits (never repaired in place), and refuses a kit whose
# Package.swift enables upcoming features other than the ones MACTEM_CORE_FLAGS (sources.manifest) compiles it with, so a
# harness never checks the kit under settings the app does not build it with. libhdf5 is no longer a resource of the kit (0.4.0: three framework binaries); the files they are built from are in the checkout at
# tools/xcframework/vendored/ (the harnesses that read HDF5 name a re-signed copy of it).
#
#   fetch-formatokit.sh          ensure References/FormatoKit is the pin; prints its path on the last line
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/References/FormatoKit"
REPO="https://github.com/mac4DSTEM/FormatoKit.git"
RESOLVED="$ROOT/Package.resolved"
PROBE="Sources/FormatoEMD/VeloxEMDReader.swift"

refuse() {  # <what is wrong> [<the fix in place>]
  echo "fetch-formatokit: REFUSED — $1." >&2
  [[ -z "${2:-}" ]] || echo "  Fix in place: $2" >&2
  exit 1
}

[[ -f "$RESOLVED" ]] || refuse "no Package.resolved at the repo root (run swift package resolve)"
# The pin is the one Package.resolved records for the package whose identity is "formatokit".
pin="$(awk '/"identity" *: *"formatokit"/ { f = 1 } f && /"revision"/ { gsub(/[",]/, "", $3); print $3; exit }' "$RESOLVED")"
[[ "$pin" =~ ^[0-9a-f]{40}$ ]] || refuse "Package.resolved names no 40-hex FormatoKit revision (found '$pin')"

if [[ -e "$DEST" ]]; then
  dk() { git --no-optional-locks -C "$DEST" "$@"; }
  [[ -e "$DEST/.git" ]] || refuse "References/FormatoKit is not a git checkout" "delete it and re-run this script"
  have="$(dk rev-parse --verify HEAD 2>/dev/null)" || refuse "References/FormatoKit has no readable HEAD"
  [[ "$have" == "$pin" ]] || refuse "References/FormatoKit is at $have, Package.resolved pins $pin" \
    "git -C References/FormatoKit fetch --tags origin && git -C References/FormatoKit checkout $pin"
  dirty="$(dk status --porcelain --untracked-files=normal)" || refuse "References/FormatoKit cannot be read by git status"
  if [[ -n "$dirty" ]]; then
    print -r -- "$dirty" | head -10 | sed 's/^/  /' >&2
    refuse "References/FormatoKit has local changes (above)" "git -C References/FormatoKit stash -u"
  fi
else
  mkdir -p "$ROOT/References"
  echo "fetch-formatokit: cloning FormatoKit at $pin into References/" >&2
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
echo "fetch-formatokit: lock present (HEAD = $pin, clean)" >&2
echo "$DEST"
