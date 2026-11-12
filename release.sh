#!/bin/bash
# Builds a release others can run: signed with a Developer ID, notarized by Apple, stapled, zipped.
# Prints the zip path and its SHA-256, which the Homebrew cask needs.
#
# Uses the same notarization profile as the other apps signed on this Mac. To create it on a new Mac,
# a person runs this in their own terminal (it asks for an app-specific password):
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id <apple-id> --team-id <team-id>
set -euo pipefail
cd "$(dirname "$0")"

# The one place that names who signs the app.
export CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: LEAD MEDIA AS (D79LWN85PJ)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notchfocus-notary}"

app="build/20-20-20.app"

zip_app() {
  rm -f "$zip"
  COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr "$app" "$zip"
}

./build.sh test
build/20-20-20-test.app/Contents/MacOS/20-20-20-test --self-test

./build.sh
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
zip="build/20-20-20-$version.zip"
codesign --verify --deep --strict "$app"

zip_app
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"

# The zip that ships must contain the stapled app, so it is made again.
zip_app
spctl --assess --type execute --verbose=2 "$app"

echo "$zip"
shasum -a 256 "$zip" | cut -d' ' -f1
