#!/bin/bash
# Builds "Spark Control.app" into ./build.
# Usage: ./build-app.sh [--open | --install]   (--install copies to /Applications and launches it)
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64

APP="build/Spark Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/SparkControl "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ -n "${1:-}" ]; then
  pkill -x SparkControl 2>/dev/null || true
  while pgrep -x SparkControl >/dev/null; do sleep 0.2; done  # let the old copy fully exit
  if [ "$1" = "--install" ]; then
    ditto "$APP" "/Applications/Spark Control.app"
    APP="/Applications/Spark Control.app"
  fi
  open "$APP"
fi
