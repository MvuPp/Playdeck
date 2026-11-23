#!/bin/sh
# Builds Playdeck.app (release) into Playdeck/build/.
#   scripts/build-app.sh                      -> ad hoc signature
#   SIGN_IDENTITY="Mon certificat" scripts/build-app.sh   -> stable signature (no Keychain re-prompt after each build)
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product Playdeck
BIN="$(swift build -c release --show-bin-path)/Playdeck"
APP=build/Playdeck.app
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
# Version = latest git tag without its "v" (v0.1.0 -> 0.1.0).
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
VERSION=${VERSION:-0.1.0}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Playdeck"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"  # regenerate with: swift scripts/make-icon.swift

# CFBundleIdentifier "Playdeck": same UserDefaults domain as `swift run Playdeck`, so both share settings and folders.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>Playdeck</string>
    <key>CFBundleName</key><string>Playdeck</string>
    <key>CFBundleDisplayName</key><string>Playdeck</string>
    <key>CFBundleExecutable</key><string>Playdeck</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "OK : $(pwd)/$APP"
echo "Installer : cp -R \"$(pwd)/$APP\" /Applications/"
