#!/bin/zsh
# Builds the macEM download: archive, Developer ID signature, notarized and stapled app, then a signed, notarized and
# stapled DMG. the owner runs it on the Mac with the certificate; it pushes nothing and uploads nothing to GitHub.
#
#   tools/release.sh
#
# Needs the "Developer ID Application" certificate in the login keychain (DEVELOPER_ID_APPLICATION overrides its name; the
# built app's signature is checked against that name) and a notarytool keychain profile (default macem-notary; override
# with NOTARY_PROFILE). Output: build/release/<stamp>/macEM-<version>.dmg and a copy named macEM.dmg for the "latest"
# link. The steps follow mac4DSTEM's tools/release (build-developer-id.sh, notarize.sh, make-dmg.sh); the DMG here is a
# plain hdiutil image with an Applications link, no dmgbuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tools/lib/developer-dir.sh"
. "$ROOT/tools/lib/release-checks.sh"
resolve_mactem_developer_dir

IDENTITY="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Paul Lobpreis (3B8SMSSAX4)}"
PROFILE="${NOTARY_PROFILE:-macem-notary}"
OUT="$ROOT/build/release/$(date +%Y%m%d-%H%M%S)"   # a new folder per run, so a rerun never deletes an earlier archive
ARCHIVE="$OUT/macEM.xcarchive"
APP="$ARCHIVE/Products/Applications/macEM.app"
mkdir -p "$OUT"

[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { echo "The working tree is not clean; commit first so the build has a commit." >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "$IDENTITY" || { echo "No certificate \"$IDENTITY\" in the keychain." >&2; exit 1; }
# A download is built from a release tag, and the app must carry that tag's version (Config/Version.xcconfig, which
# release-please bumps): checked here before the archive and again on the built app.
TAG="$(git -C "$ROOT" describe --exact-match --tags HEAD 2>/dev/null)" || { echo "HEAD is not a release tag; check out the tag to build (git worktree add … vX.Y.Z)." >&2; exit 1; }
EXPECTED="${TAG#v}"
SET="$(sed -n 's/^MARKETING_VERSION = \([0-9.]*\).*/\1/p' "$ROOT/Config/Version.xcconfig")"
[[ "$SET" == "$EXPECTED" ]] || { echo "Config/Version.xcconfig says $SET but the tag is $TAG." >&2; exit 1; }

echo "== Archive ($(git -C "$ROOT" rev-parse --short HEAD))"
# ARCHS=arm64 on the command line: the project's setting does not reach the package targets, and the HDF5
# frameworks FormatoKit embeds are arm64 only (mac4DSTEM tools/lib/release-arch.sh has the story).
xcodebuild archive -project "$ROOT/macTEM.xcodeproj" -scheme macTEM -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" ARCHS=arm64 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" > "$OUT/archive.log" 2>&1 \
  || { tail -30 "$OUT/archive.log"; exit 1; }

echo "== Check the app"
# The executable and the three HDF5 frameworks, each by name, and the shipped demo files (tools/lib/release-checks.sh).
assert_mactem_bundle_arm64_only "$APP"
assert_mactem_demo_data "$APP"
# What notarization refuses, found before the upload instead of after it: the app and each of the three frameworks signed by the
# Developer ID certificate, with the hardened runtime and a secure timestamp.
assert_mactem_bundle_developer_id_signed "$APP" "$IDENTITY"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "get-task-allow" && { echo "The app carries get-task-allow." >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" == "$EXPECTED" ]] || { echo "The built app says $VERSION but the tag is $TAG." >&2; exit 1; }
echo "macEM $VERSION"

echo "== Notarize the app"
ditto -c -k --keepParent "$APP" "$OUT/macEM-submission.zip"
xcrun notarytool submit "$OUT/macEM-submission.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute "$APP"

echo "== DMG"
DMG="$OUT/macEM-$VERSION.dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/macEM.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "macEM $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" > /dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "== Notarize the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"
cp "$DMG" "$OUT/macEM.dmg"
# Up to 1.3 the app was macTEM and its DMG macTEM.dmg: the 2.x releases attach a copy under that name too, so the links and
# bookmarks to releases/latest/download/macTEM.dmg keep working.
cp "$DMG" "$OUT/macTEM.dmg"

echo
echo "Done: $DMG"
echo "Also: $OUT/macEM.dmg (for releases/latest/download/macEM.dmg)"
echo "And:  $OUT/macTEM.dmg (the name up to 1.3; attach it too in 2.x)"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "Size: $(stat -f%z "$DMG") bytes"
