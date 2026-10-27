#!/bin/sh
# Removes SnapPaste installed by install.sh. Your settings file is left in ~/.config/SnapPaste.
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
pkill -x snappaste 2>/dev/null || true
rm -f "$BIN/snappaste" "$DATA/applications/snappaste.desktop" "$DATA/icons/hicolor/256x256/apps/snappaste.png"
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/SnapPaste.desktop"
echo "SnapPaste removed."
