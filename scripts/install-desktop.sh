#!/bin/sh
# Put Codenotch in the application menu. The entry goes through run-linux.sh so it keeps the
# X11/XWayland settings. Start at login is the app's own toggle (setup.sh patches it for X11).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
icon="$root/codenotch/icons/128x128.png"
[ -f "$icon" ] || icon=codenotch

apps=${XDG_DATA_HOME:-$HOME/.local/share}/applications
mkdir -p "$apps"
cat > "$apps/codenotch.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Codenotch
Comment=Usage limits and session state for Claude Code, Codex and Cursor
Exec="$root/scripts/run-linux.sh"
Icon=$icon
Terminal=false
Categories=Development;Utility;
EOF
echo "menu entry:  $apps/codenotch.desktop"

