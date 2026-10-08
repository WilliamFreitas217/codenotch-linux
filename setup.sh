#!/usr/bin/env bash
# Codenotch for Ubuntu: fetch upstream, add the Linux pieces, build.
#
#   ./setup.sh            install deps (asks for sudo), clone, patch, test, build
#   ./setup.sh --no-deps  skip the apt step
#   UPSTREAM_REF=main ./setup.sh   build a newer upstream than the one this was written against
#
# Re-running is safe: app/ is rebuilt from a fresh copy of upstream each time.
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UPSTREAM_URL=https://github.com/vinzdg/codenotch.git
# The commit the overlay was written and read against (upstream main, 2026-10-06).
UPSTREAM_REF=${UPSTREAM_REF:-bcb28894d1514fef5a810595d64b44a3817c2076}

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. system packages
if [ "${1:-}" != "--no-deps" ]; then
  say "System packages (WebKitGTK, GTK, AppIndicator, window tools)"
  pkgs="build-essential pkg-config git curl python3 \
        libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev \
        librsvg2-dev libsoup-3.0-dev libssl-dev libxdo-dev \
        wmctrl xdotool"
  # shellcheck disable=SC2086
  sudo apt-get update -qq && sudo apt-get install -y $pkgs
fi

# rustup puts cargo in ~/.cargo/bin and only a *new* shell picks that up; load it here so a fresh
# install works without reopening the terminal.
# shellcheck disable=SC1091
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
command -v cargo >/dev/null || die "Rust not found. Install it with:  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   (then run: bash setup.sh --no-deps)"
pkg-config --exists webkit2gtk-4.1 || die "webkit2gtk-4.1 dev files missing (run without --no-deps)"

# ---------------------------------------------------------------- 2. upstream
say "Fetching upstream ($UPSTREAM_REF)"
# A full clone is ~175 MB (design images in the history). Reuse one that is already here; otherwise
# fetch only the pinned commit. GitHub serves a commit by its full sha; if that ever fails, fall
# back to a full clone.
UP="$HERE/upstream"
if [ -d "$UP/.git" ] && git -C "$UP" cat-file -e "$UPSTREAM_REF^{commit}" 2>/dev/null; then
  echo "reusing the existing clone"
else
  rm -rf "$UP"
  mkdir -p "$UP"
  if git -C "$UP" init --quiet \
     && git -C "$UP" remote add origin "$UPSTREAM_URL" \
     && git -C "$UP" fetch --quiet --depth 1 origin "$UPSTREAM_REF" 2>/dev/null; then
    echo "fetched only $UPSTREAM_REF"
  else
    echo "shallow fetch by sha not available, doing a full clone (slow)"
    rm -rf "$UP"
    git clone --quiet "$UPSTREAM_URL" "$UP"
  fi
fi
git -C "$UP" checkout --quiet -f "$UPSTREAM_REF" 2>/dev/null || git -C "$UP" checkout --quiet -f FETCH_HEAD
[ -d "$UP/windows/codenotch/src" ] || die "upstream layout changed: windows/codenotch/src not found"

say "Copying the Tauri port into app/ (keeping the build cache)"
CACHE="$HERE/.target-cache"
rm -rf "$CACHE"
[ -d "$HERE/app/target" ] && mv "$HERE/app/target" "$CACHE"
rm -rf "$HERE/app"
cp -R "$UP/windows" "$HERE/app"
[ -d "$CACHE" ] && mv "$CACHE" "$HERE/app/target"

# ---------------------------------------------------------------- 3. overlay
say "Adding the Linux modules and wiring them in"
cp "$HERE/overlay/linux_focus.rs" "$HERE/app/codenotch/src/linux_focus.rs"
cp "$HERE/overlay/codex_spend.rs" "$HERE/app/codenotch/src/codex_spend.rs"

python3 - "$HERE/app/codenotch/src" <<'PY'
import pathlib, sys

src = pathlib.Path(sys.argv[1])

def patch(name, old, new):
    p = src / name
    text = p.read_text()
    if text.count(old) != 1:
        sys.exit(f"{name}: expected exactly one occurrence of the anchor, found {text.count(old)}.\n"
                 f"Upstream changed; adjust setup.sh or pin UPSTREAM_REF.\nanchor:\n{old}")
    p.write_text(text.replace(old, new))
    print(f"patched {name}")

patch("main.rs",
      "mod focus;\n",
      "mod focus;\n#[cfg(not(windows))]\nmod linux_focus;\nmod codex_spend;\n")

# Enterprise / Business workspace accounts report a monthly spend cap instead of 5-hour and weekly
# windows. When the reply has no windows, show that cap as one (Codex's /status calls it
# "Monthly credit limit").
patch("codex.rs",
      "let windows = windows_from_usage(&v);\n                    if !windows.is_empty() {\n",
      "let mut windows = windows_from_usage(&v);\n"
      "                    if windows.is_empty() {\n"
      "                        windows.extend(crate::codex_spend::spend_window(&v));\n"
      "                    }\n"
      "                    if !windows.is_empty() {\n")

patch("focus.rs",
      "#[cfg(not(windows))]\npub fn focus_terminal(_claude_pid: u32) -> bool {\n    false\n}\n",
      "#[cfg(not(windows))]\npub fn focus_terminal(claude_pid: u32) -> bool {\n    crate::linux_focus::focus_terminal(claude_pid)\n}\n")

# The hook binary is looked up (and the app launched by the hook) with a hard-coded ".exe".
patch("hooks_install.rs",
      '.join("codenotch-hook.exe");',
      '.join(format!("codenotch-hook{}", std::env::consts::EXE_SUFFIX));')
patch("../../codenotch-hook/src/main.rs",
      'dir.join("codenotch.exe");',
      'dir.join(format!("codenotch{}", std::env::consts::EXE_SUFFIX));')

# "Start at sign-in" writes the binary straight into the autostart entry. Under Wayland the notch
# must be an X11 (XWayland) client to place itself, so the entry goes through `env`.
patch("autostart.rs",
      r'Exec=\"{}\" --silent\nTerminal=false',
      r'Exec=env GDK_BACKEND=x11 \"{}\" --silent\nTerminal=false')
PY

# ---------------------------------------------------------------- 4. launcher scripts
install -m 0755 "$HERE/scripts/run-linux.sh"        "$HERE/app/scripts/run-linux.sh"
install -m 0755 "$HERE/scripts/doctor-linux.sh"     "$HERE/app/scripts/doctor-linux.sh"
install -m 0755 "$HERE/scripts/install-desktop.sh"  "$HERE/app/scripts/install-desktop.sh"

# ---------------------------------------------------------------- 5. test + build
cd "$HERE/app"
say "Unit tests for the new modules (release profile, so the build below reuses it)"
cargo test --release -p codenotch -- linux_focus codex_spend 2>&1 | tail -20

say "Building (first build compiles SQLite and Tauri: expect 5-15 minutes)"
cargo build --release

say "Done"
echo "Binary:   $HERE/app/target/release/codenotch"
echo "Next:     $HERE/app/scripts/doctor-linux.sh   then   $HERE/app/scripts/run-linux.sh"
