#!/bin/zsh
# Builds the macTEM download: archive, Developer ID signature, notarized and stapled app, then a signed, notarized and
# stapled DMG. the owner runs it on the Mac with the certificate; it pushes nothing and uploads nothing to GitHub.
#
#   tools/release.sh
#
# Needs the "Developer ID Application" certificate in the login keychain and a notarytool keychain profile
# (default macem-notary; override with NOTARY_PROFILE). Output: build/release/<stamp>/macTEM-<version>.dmg and a copy
# named macTEM.dmg for the "latest" link. The steps follow mac4DSTEM's tools/release (build-developer-id.sh,
# notarize.sh, make-dmg.sh); the DMG here is a plain hdiutil image with an Applications link, no dmgbuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tools/lib/developer-dir.sh"
resolve_mactem_developer_dir

IDENTITY="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Paul Lobpreis (3B8SMSSAX4)}"
PROFILE="${NOTARY_PROFILE:-macem-notary}"
OUT="$ROOT/build/release/$(date +%Y%m%d-%H%M%S)"   # a new folder per run, so a rerun never deletes an earlier archive
ARCHIVE="$OUT/macTEM.xcarchive"
APP="$ARCHIVE/Products/Applications/macTEM.app"
mkdir -p "$OUT"

[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { echo "The working tree is not clean; commit first so the build has a commit." >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "$IDENTITY" || { echo "No certificate \"$IDENTITY\" in the keychain." >&2; exit 1; }

echo "== Archive ($(git -C "$ROOT" rev-parse --short HEAD))"
# ARCHS=arm64 on the command line: the project's setting does not reach the package targets, and the HDF5
# frameworks FormatoKit embeds are arm64 only (mac4DSTEM tools/lib/release-arch.sh has the story).
xcodebuild archive -project "$ROOT/macTEM.xcodeproj" -scheme macTEM -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" ARCHS=arm64 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" > "$OUT/archive.log" 2>&1 \
  || { tail -30 "$OUT/archive.log"; exit 1; }

echo "== Check the app"
for binary in "$APP/Contents/MacOS/macTEM" "$APP"/Contents/Frameworks/{FormatoLibHDF5,FormatoLibSZ,FormatoLibAEC}.framework/{FormatoLibHDF5,FormatoLibSZ,FormatoLibAEC}(N); do
  [[ "$(lipo -archs "$binary")" == "arm64" ]] || { echo "Not arm64 alone: $binary" >&2; exit 1; }
done
[[ -d "$APP/Contents/Frameworks/FormatoLibHDF5.framework" ]] || { echo "The app is missing FormatoLibHDF5.framework." >&2; exit 1; }
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "get-task-allow" && { echo "The app carries get-task-allow." >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "macTEM $VERSION"

echo "== Notarize the app"
ditto -c -k --keepParent "$APP" "$OUT/macTEM-submission.zip"
xcrun notarytool submit "$OUT/macTEM-submission.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP"

echo "== DMG"
DMG="$OUT/macTEM-$VERSION.dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/macTEM.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "macTEM $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" > /dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "== Notarize the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"
cp "$DMG" "$OUT/macTEM.dmg"

echo
echo "Done: $DMG"
echo "Also: $OUT/macTEM.dmg (for releases/latest/download/macTEM.dmg)"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "Size: $(stat -f%z "$DMG") bytes"
