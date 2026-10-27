#!/bin/bash
# Runs the XCTest suite (SnapPasteCore) through the Xcode scheme, which also builds the app target.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
xcodebuild -project SnapPaste.xcodeproj -scheme SnapPaste -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$ROOT/build/DerivedData" test -quiet
echo "All tests passed."
