#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="Charmera"
BUNDLE_DIR="$SCRIPT_DIR/build/$APP_NAME.app"
CONTENTS="$BUNDLE_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "Building $APP_NAME..."
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Copy executable
cp ".build/release/$APP_NAME" "$MACOS/$APP_NAME"

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"

# Copy bundled ffmpeg if present
if [ -f "$RESOURCES/../../../ffmpeg/ffmpeg" ]; then
    cp "$SCRIPT_DIR/../ffmpeg/ffmpeg" "$RESOURCES/ffmpeg"
elif command -v ffmpeg &>/dev/null; then
    echo "Note: No bundled ffmpeg found. Videos will require ffmpeg in PATH."
fi

# Copy icon if present
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# Copy gallery template
TEMPLATE_SRC="$SCRIPT_DIR/../template"
if [ -d "$TEMPLATE_SRC" ]; then
    cp -R "$TEMPLATE_SRC" "$RESOURCES/template"
    echo "Bundled gallery template."
fi

# Code sign (use Developer ID if available, otherwise ad-hoc)
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}' || true)
if [ -n "${IDENTITY:-}" ]; then
    echo "Signing with: $IDENTITY"
    codesign --force --deep --options runtime --sign "$IDENTITY" "$BUNDLE_DIR"
else
    echo "Ad-hoc signing..."
    codesign --force --deep --sign - "$BUNDLE_DIR"
fi

echo "Built: $BUNDLE_DIR"
echo ""
echo "To run:  open $BUNDLE_DIR"
echo "To DMG:  ./dmg.sh"
