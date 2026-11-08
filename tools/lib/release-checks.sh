#!/bin/zsh
# tools/lib/release-checks.sh — what both release scripts check on the app they built: the product, not the settings.
# Adapted from mac4DSTEM (tools/lib/release-arch.sh, assert_mac4dstem_bundle_arm64_only).
#
#   assert_mactem_bundle_arm64_only <app>      the executable and FormatoKit's three HDF5 frameworks: each there, each arm64 alone
#   assert_mactem_demo_data <app>              the four shipped demo files (DemoDocuments.Shipped) in Contents/Resources/DemoData
#   assert_mactem_store_entitlements <plist>   the store app's sandbox entitlements (com.apple.security.*): exactly these three
#
# tools/release.sh calls the first two, tools/release-store.sh all three. Each prints one line per failure and returns non-zero
# after checking everything, so a caller under `set -e` and one in an `if` stop alike. No counter is called `status`, which zsh
# aliases to `$?`.
#
# The three frameworks are named, not globbed. The loop this replaces took them from a brace expansion with zsh's (N) qualifier,
# which drops a path that does not exist, so an app that had lost a framework passed (the store script checked none by name).
# FormatoKit loads libhdf5 at run time rather than linking it: such an app launches, then fails every HDF5, EMD and h5ebsd open.
# mac4DSTEM's release-arch.sh records the same defect. The demo files are named for the same reason: Help > Open Demo Data opens
# nothing, and says nothing, when one is missing (macTEM/App/DemoData.swift).
#
# The store check reads only the com.apple.security.* keys: automatic signing adds com.apple.application-identifier and
# com.apple.developer.team-identifier from the profile. They are the three of macTEM/macTEM.entitlements (AppStoreReleaseTests
# holds the two lists together); the store listing promises no network (docs/app-store/app-privacy.txt), so a network client
# entitlement fails here. The Developer ID build signs with the same file and is not held to the exact set.

# Fails unless $1 is a Mach-O holding arm64 and nothing else.
assert_mactem_arm64_only() {  # <Mach-O>
  local archs
  archs="$(lipo -archs "$1" 2>/dev/null || true)"
  if [[ "$archs" != arm64 ]]; then
    echo "Not arm64 alone: $1 is '${archs:-unreadable}'." >&2
    return 1
  fi
}

# Every Mach-O a user receives: the executable and the three frameworks, each named.
assert_mactem_bundle_arm64_only() {  # <app>
  local app="$1" library arch_failures=0
  assert_mactem_arm64_only "$app/Contents/MacOS/macTEM" || arch_failures=1
  for library in FormatoLibHDF5 FormatoLibSZ FormatoLibAEC; do
    if [[ ! -f "$app/Contents/Frameworks/$library.framework/$library" ]]; then
      echo "The app is missing $library.framework." >&2
      arch_failures=1
      continue
    fi
    assert_mactem_arm64_only "$app/Contents/Frameworks/$library.framework/$library" || arch_failures=1
  done
  return $arch_failures
}

# The demo files Help > Open Demo Data opens, each named and not empty.
assert_mactem_demo_data() {  # <app>
  local app="$1" file demo_failures=0
  for file in nickel_ebsd_large/patterns_v2.h5 EDS_SEM_TM002.hspy ni_mc_mp_20kv_uint8_gzip_opts9.h5 sdss_ferrite_austenite.ang; do
    if [[ ! -s "$app/Contents/Resources/DemoData/$file" ]]; then
      echo "The app is missing its demo file DemoData/$file." >&2
      demo_failures=1
    fi
  done
  return $demo_failures
}

# The store app's com.apple.security.* entitlements, as `codesign -d --entitlements :-` wrote them to $1: exactly the three below,
# each true.
assert_mactem_store_entitlements() {  # <entitlements plist>
  local plist="$1" key keys entitlement_failures=0
  local -a expected=(com.apple.security.app-sandbox com.apple.security.files.bookmarks.app-scope com.apple.security.files.user-selected.read-write)
  keys="$(plutil -convert xml1 -o - "$plist" 2>/dev/null \
    | sed -nE 's#^[[:space:]]*<key>(com\.apple\.security\.[^<]+)</key>[[:space:]]*$#\1#p' | LC_ALL=C sort | tr '\n' ' ' || true)"
  keys="${keys% }"
  if [[ "$keys" != "${expected[*]}" ]]; then
    echo "The store app's sandbox entitlements are [$keys], not [${expected[*]}]." >&2
    entitlement_failures=1
  fi
  for key in "${expected[@]}"; do
    if [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)" != true ]]; then
      echo "The store app's $key is not true." >&2
      entitlement_failures=1
    fi
  done
  return $entitlement_failures
}
