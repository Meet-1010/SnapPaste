#!/bin/sh
# Installs SnapPaste for the current user (no root needed).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
mkdir -p "$BIN" "$APPS" "$ICONS"
install -m 755 "$HERE/snappaste" "$BIN/snappaste"
install -m 644 "$HERE/snappaste.png" "$ICONS/snappaste.png"
sed "s|^Exec=.*|Exec=$BIN/snappaste|" "$HERE/snappaste.desktop" > "$APPS/snappaste.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" >/dev/null 2>&1 || true
echo "Installed SnapPaste to $BIN/snappaste"
echo "Start it from your app launcher, or run: snappaste"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Note: add $BIN to your PATH to run 'snappaste' from a terminal." ;; esac
