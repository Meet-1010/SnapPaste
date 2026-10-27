#!/bin/bash
# Builds SnapPaste and optionally installs or launches it.
#
#   scripts/build.sh            # Release build into build/DerivedData
#   scripts/build.sh --run      # build, then launch the built app
#   scripts/build.sh --install  # build, replace /Applications/SnapPaste.app, launch it
#
# Set CONFIGURATION=Debug for a debug build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/$CONFIGURATION/SnapPaste.app"

echo "Building SnapPaste ($CONFIGURATION)…"
xcodebuild -project SnapPaste.xcodeproj -scheme SnapPaste -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED" build -quiet
codesign --verify --strict "$APP"
echo "Built $APP"

case "${1:-}" in
  --run)
    pkill -x SnapPaste 2>/dev/null || true
    open "$APP"
    ;;
  --install)
    pkill -x SnapPaste 2>/dev/null || true
    sleep 0.5
    if [ -d /Applications/SnapPaste.app ]; then
      # Keep the previous copy recoverable in the Trash instead of deleting it.
      mv /Applications/SnapPaste.app "$HOME/.Trash/SnapPaste-$(date +%Y%m%d-%H%M%S).app"
    fi
    ditto "$APP" /Applications/SnapPaste.app
    echo "Installed /Applications/SnapPaste.app"
    open /Applications/SnapPaste.app
    ;;
  "")
    ;;
  *)
    echo "Unknown option: $1" >&2
    exit 1
    ;;
esac
