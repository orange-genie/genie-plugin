#!/bin/bash
# Build OrangeGenie.app (menu-bar shell). Unsigned alpha — testers clear quarantine to open.
set -e
cd "$(dirname "$0")"
APP="OrangeGenie.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O main.swift -o "$APP/Contents/MacOS/OrangeGenie"
cp Info.plist "$APP/Contents/Info.plist"
[ -f icon.png ] && cp icon.png "$APP/Contents/Resources/icon.png"
echo "APPL????" > "$APP/Contents/PkgInfo"
echo "✓ built $APP — run:  open $APP   (or ./$APP/Contents/MacOS/OrangeGenie for console logs)"
