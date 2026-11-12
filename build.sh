#!/bin/bash
# Builds the app into build/.
#   ./build.sh        the app that gets installed
#   ./build.sh test   a separate test build with shortened times, self-tests and a Quit item
set -euo pipefail
cd "$(dirname "$0")"

variant="${1:-release}"
case "$variant" in
  release)
    name="20-20-20"
    identifier="com.andreaslar.twenty-twenty-twenty"
    flags=(-O)
    sources=(Sources/main.swift)
    ;;
  test)
    name="20-20-20-test"
    identifier="com.andreaslar.twenty-twenty-twenty.test"
    flags=(-Onone -D TESTBUILD)
    sources=(Sources/main.swift Tests/SelfTests.swift)
    ;;
  *)
    echo "usage: ./build.sh [test]" >&2
    exit 2
    ;;
esac

version="1.0.1"
app="build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# The oldest macOS the app runs on is stated here, so it does not follow the Mac that builds it.
swiftc "${flags[@]}" -target arm64-apple-macos26.0 -module-name TwentyTwentyTwenty -module-cache-path build/module-cache \
  -o "$app/Contents/MacOS/$name" "${sources[@]}"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$identifier</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>20-20-20</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Local builds are signed ad hoc. A release sets CODESIGN_IDENTITY to a Developer ID,
# which also turns on the hardened runtime that notarization requires.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$app"
else
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$app"
fi
echo "Built $app"
