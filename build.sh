#!/bin/zsh
# Build Glint.app with SwiftPM (no Xcode). Usage: ./build.sh [run]
set -euo pipefail
cd "${0:A:h}"

# ponytail: the default swift-build backend needs full Xcode; native works with Command Line Tools only.
swift build -c release --build-system native 2> >(grep -v "has been deprecated" >&2)
APP=build/Glint.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp .build/release/Glint "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/"

# A stable signing identity keeps the Screen Recording grant across rebuilds.
IDENTITY="${CSX_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == run ]]; then
  pkill -x Glint || true
  open "$APP"
fi
