#!/bin/bash
set -e

APP_NAME="QuickNote"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

echo "Building $APP_NAME..."

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# Generate app icon
echo "Generating icon..."
swift Resources/make_icon.swift
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
cp Resources/AppIcon.icns "$RES_DIR/AppIcon.icns"

swiftc \
    Sources/main.swift \
    Sources/AppDelegate.swift \
    Sources/NoteView.swift \
    -o "$MACOS_DIR/$APP_NAME" \
    -framework AppKit \
    -framework Carbon \
    -target arm64-apple-macos13.0

cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

echo ""
echo "Done: $APP_DIR"
echo "Run with:  open $BUILD_DIR/$APP_NAME.app"
