#!/bin/bash
# Builds "Spark Control.app" into ./build.
# Usage: ./build-app.sh [--open | --install]   (--install copies to /Applications and launches it)
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64

APP="build/Spark Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/SparkControl" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# A real identity keeps the app's code identity stable across builds, so macOS remembers its Local Network
# permission; ad-hoc signing (CI, or no certificate) makes every build a new app that macOS may silently block.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
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
