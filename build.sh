#!/bin/sh
# Builds MemProbe.ipa on macOS with Xcode's command-line tools. The app is only
# ad-hoc signed, with the entitlements it asks for; Sideloadly or AltStore
# re-signs it with your Apple ID when it installs.
set -eu

cd "$(dirname "$0")"
APP=build/Payload/MemProbe.app
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

rm -rf build
mkdir -p "$APP"

xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 \
    -fobjc-arc -O2 -Wall -Wno-unused-result \
    -framework UIKit -framework Foundation \
    src/main.m -o "$APP/MemProbe"

cp src/Info.plist "$APP/Info.plist"
plutil -convert binary1 "$APP/Info.plist"

codesign --force --sign - --entitlements src/entitlements.plist "$APP"
codesign --display --entitlements - "$APP"

(cd build && zip -qr MemProbe.ipa Payload)
echo "build/MemProbe.ipa ready"
