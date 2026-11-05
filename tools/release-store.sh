#!/bin/zsh
# Builds the macTEM App Store package from the same release tag as the DMG (macTEM#103; one tag, two builds, decision of
# 2026-11-04). tools/release.sh stays the Developer ID DMG; this is the store flavour beside it, kept as its own script.
#
#   tools/release-store.sh            archive, export a signed .pkg, check it
#   tools/release-store.sh --upload   the same, then validate and upload it to App Store Connect
#
# Needs Xcode signed in to the team's Apple ID (team 3B8SMSSAX4): -allowProvisioningUpdates lets Xcode create the Apple
# Distribution and Mac Installer Distribution certificates and the App Store profile on first use. Validation and upload
# need an App Store Connect API key: ASC_KEY_ID, ASC_ISSUER_ID, the .p8 in ~/.appstoreconnect/private_keys/. Without
# the key it builds and checks the package and stops. STORE_BUILD_NUMBER overrides CURRENT_PROJECT_VERSION for a second
# upload of the same version. Output: build/release/<stamp>/store/macTEM.pkg.
set -euo pipefail

UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=1 ;;
    *) echo "usage: tools/release-store.sh [--upload]" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

TEAM="${DEVELOPMENT_TEAM:-3B8SMSSAX4}"
OUT="$ROOT/build/release/$(date +%Y%m%d-%H%M%S)"   # a new folder per run, so a rerun never deletes an earlier archive
ARCHIVE="$OUT/macTEM-store.xcarchive"
APP="$ARCHIVE/Products/Applications/macTEM.app"
EXPORT="$OUT/store"

[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { echo "The working tree is not clean; commit first so the build has a commit." >&2; exit 1; }
# Built from a release tag, carrying that tag's version (Config/Version.xcconfig, which release-please bumps).
TAG="$(git -C "$ROOT" describe --exact-match --tags HEAD 2>/dev/null)" || { echo "HEAD is not a release tag; check out the tag to build (git worktree add … vX.Y.Z)." >&2; exit 1; }
EXPECTED="${TAG#v}"
SET="$(sed -n 's/^MARKETING_VERSION = \([0-9.]*\).*/\1/p' "$ROOT/Config/Version.xcconfig")"
[[ "$SET" == "$EXPECTED" ]] || { echo "Config/Version.xcconfig says $SET but the tag is $TAG." >&2; exit 1; }
mkdir -p "$OUT"

BUILD_ARGS=()
[[ -n "${STORE_BUILD_NUMBER:-}" ]] && BUILD_ARGS+=("CURRENT_PROJECT_VERSION=$STORE_BUILD_NUMBER")

echo "== App Store archive ($(git -C "$ROOT" rev-parse --short HEAD))"
# ARCHS=arm64 on the command line, as tools/release.sh: the project's setting does not reach the package targets.
# MACEM_STORE_BUILD=YES is the one switch the store build flips: the Sparkle updater (#104) compiles only without it.
xcodebuild archive -project "$ROOT/macTEM.xcodeproj" -scheme macTEM -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" ARCHS=arm64 \
  -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" MACEM_STORE_BUILD=YES \
  "${BUILD_ARGS[@]}" > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; exit 1; }

echo "== Export"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/tools/lib/ExportOptions-AppStore.plist" -allowProvisioningUpdates \
  > "$OUT/export.log" 2>&1 || { tail -30 "$OUT/export.log"; exit 1; }
PKG="$(print -l "$EXPORT"/*.pkg(N) | head -1)"
[[ -f "$PKG" ]] || { echo "The export wrote no .pkg to $EXPORT." >&2; exit 1; }

echo "== Check the package"
pkgutil --check-signature "$PKG" | grep -q "Installer Distribution\|3rd Party Mac Developer Installer" \
  || { echo "$PKG is not signed with an installer distribution certificate." >&2; exit 1; }
for binary in "$APP/Contents/MacOS/macTEM" "$APP"/Contents/Frameworks/{FormatoLibHDF5,FormatoLibSZ,FormatoLibAEC}.framework/{FormatoLibHDF5,FormatoLibSZ,FormatoLibAEC}(N); do
  [[ "$(lipo -archs "$binary")" == "arm64" ]] || { echo "Not arm64 alone: $binary" >&2; exit 1; }
done
codesign -d --entitlements :- "$APP" > "$OUT/store-entitlements.plist" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$OUT/store-entitlements.plist" 2>/dev/null)" == true ]] \
  || { echo "The store app is not sandboxed." >&2; exit 1; }
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$OUT/store-entitlements.plist" >/dev/null 2>&1; then
  echo "The store app carries get-task-allow." >&2; exit 1
fi
[[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ]] || { echo "The app has no privacy manifest." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$APP/Contents/Info.plist" 2>/dev/null)" == false ]] \
  || { echo "Info.plist does not answer the export-compliance question." >&2; exit 1; }
[[ ! -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || { echo "Sparkle is in the store build." >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" == "$EXPECTED" ]] || { echo "The built app says $VERSION but the tag is $TAG." >&2; exit 1; }
echo "macTEM $VERSION: $PKG"

if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
  echo "No App Store Connect API key (ASC_KEY_ID, ASC_ISSUER_ID): built and checked, not validated or uploaded."
  exit 0
fi
echo "== Validate with App Store Connect"
xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
if (( UPLOAD == 1 )); then
  echo "== Upload to App Store Connect"
  xcrun altool --upload-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "Uploaded. The build shows in App Store Connect > TestFlight after processing (minutes to an hour)."
fi
