#!/bin/sh
# What is this machine, and what would stop Codenotch from working on it?
# Read-only: it prints, it changes nothing.
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
miss() { printf '  [MISS] %s\n' "$*"; }

echo "Session"
echo "  XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-<unset>}  DISPLAY=${DISPLAY:-<unset>}  WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
echo "  XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-<unset>}"
case "${XDG_SESSION_TYPE:-}" in
  x11)     ok "X11 session: positioning, always-on-top and terminal jump-back all work natively" ;;
  wayland) [ -n "${DISPLAY:-}" ] && ok "Wayland with XWayland: the notch runs as an X11 client" \
                                  || miss "Wayland without XWayland: the notch cannot be placed" ;;
  *)       warn "could not tell the session type" ;;
esac

echo "Tools used for terminal jump-back (X11)"
for t in wmctrl xdotool; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" || warn "$t not installed  (sudo apt install $t)"
done

echo "System libraries"
for l in webkit2gtk-4.1 gtk+-3.0 ayatana-appindicator3-0.1; do
  pkg-config --exists "$l" 2>/dev/null && ok "$l" || miss "$l  (run setup.sh without --no-deps)"
done

echo "Tray icon"
case "${XDG_CURRENT_DESKTOP:-}" in
  *GNOME*|*Unity*|*ubuntu*)
    if gnome-extensions list --enabled 2>/dev/null | grep -qi appindicator; then
      ok "AppIndicator extension is enabled"
    else
      warn "no AppIndicator extension enabled: the tray icon will not show (the notch still works)"
      warn "  Ubuntu: sudo apt install gnome-shell-extension-appindicator, then log out and in"
    fi ;;
  *) ok "not GNOME: tray support is built in" ;;
esac

echo "Credentials the notch reads (presence only, nothing is opened)"
[ -f "$HOME/.claude/.credentials.json" ] && ok "Claude Code  ~/.claude/.credentials.json" || warn "Claude Code credentials not found (run 'claude' and sign in)"
[ -f "$HOME/.codex/auth.json" ]           && ok "Codex        ~/.codex/auth.json"           || warn "Codex login not found (skip if you do not use Codex)"
[ -f "$HOME/.config/Cursor/User/globalStorage/state.vscdb" ] && ok "Cursor       state.vscdb" || warn "Cursor state not found (skip if you do not use Cursor)"

echo "Binary"
bin="$root/target/release/codenotch"
if [ -x "$bin" ]; then
  ok "$bin"
  echo
  echo "codenotch's own diagnosis:"
  "$root/scripts/run-linux.sh" doctor 2>&1 | sed 's/^/  /'
else
  warn "not built yet (cargo build --release)"
fi
