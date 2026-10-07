#!/bin/sh
# Put Codenotch in the application menu (and, with --autostart, start it at login).
# Both entries go through run-linux.sh so they keep the X11/XWayland settings.
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

if [ "${1:-}" = "--autostart" ]; then
  auto=${XDG_CONFIG_HOME:-$HOME/.config}/autostart
  mkdir -p "$auto"
  cat > "$auto/codenotch.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Codenotch
Exec="$root/scripts/run-linux.sh" --silent
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
  echo "autostart:   $auto/codenotch.desktop"
fi
