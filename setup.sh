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
cp "$HERE/overlay/linux_x11.rs"   "$HERE/app/codenotch/src/linux_x11.rs"
cp "$HERE/overlay/chime.rs"       "$HERE/app/codenotch/src/chime.rs"

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
      "mod focus;\n#[cfg(not(windows))]\nmod linux_focus;\n#[cfg(target_os = \"linux\")]\nmod linux_x11;\nmod codex_spend;\nmod chime;\n")

# Some machines abort at startup with "[xcb] Unknown sequence number ... XInitThreads has not been
# called". Turn Xlib's thread support on first thing, before GTK exists.
patch("main.rs",
      "fn main() {\n    #[cfg(windows)]\n    adopt_system_proxy();\n",
      "fn main() {\n    // Xlib thread support has to be on before GTK starts (see linux_x11.rs)\n    #[cfg(target_os = \"linux\")]\n    linux_x11::init_threads();\n    #[cfg(windows)]\n    adopt_system_proxy();\n")

# linux_x11.rs opens libX11 through x11-dl. It is already in the tree (tao uses it); this makes it direct.
cargo = src.parent / "Cargo.toml"
text = cargo.read_text()
if "x11-dl" in text or "cfg(target_os = \"linux\")" in text:
    sys.exit("Cargo.toml: already has an x11-dl or linux section; upstream changed, adjust setup.sh")
cargo.write_text(text.rstrip("\n") + "\n\n# Linux: XInitThreads (src/linux_x11.rs)\n[target.'cfg(target_os = \"linux\")'.dependencies]\nx11-dl = \"2\"\n")
print("patched Cargo.toml")

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
patch("focus.rs",
      "#[cfg(not(windows))]\npub fn focus_claude_desktop() -> bool {\n    false\n}\n",
      "#[cfg(not(windows))]\npub fn focus_claude_desktop() -> bool {\n    crate::linux_focus::focus_claude_desktop()\n}\n")

# The hook binary is looked up (and the app launched by the hook) with a hard-coded ".exe".
patch("hooks_install.rs",
      '.join("codenotch-hook.exe");',
      '.join(format!("codenotch-hook{}", std::env::consts::EXE_SUFFIX));')
patch("../../codenotch-hook/src/main.rs",
      'dir.join("codenotch.exe");',
      'dir.join(format!("codenotch{}", std::env::consts::EXE_SUFFIX));')

# Session chime (chime.rs), as on macOS: when a Claude Code turn ends or stops to ask, the store
# remembers which sound is due and broadcast() plays it. Hooks and the transcript watcher both go
# through Store::apply, so this is the one place that sees every transition.
patch("state.rs",
      "pub struct Store {\n    map: HashMap<String, Session>,\n}\n",
      "pub struct Store {\n    map: HashMap<String, Session>,\n    /// A sound owed by the last transition, played (and cleared) by broadcast()\n    pub chime: Option<&'static str>,\n}\n")
patch("state.rs",
      "        // Broadcast only on a visible change, so the watcher's rapid appends cannot cause a storm\n        (\n",
      "        let chime = crate::chime::sound_for(&before.0, &s.state);\n"
      "        // Broadcast only on a visible change, so the watcher's rapid appends cannot cause a storm\n        let changed = (\n")
patch("state.rs",
      "        ) != before\n    }\n\n    pub fn dismiss",
      "        ) != before;\n        if chime.is_some() {\n            self.chime = chime;\n        }\n        changed\n    }\n\n    pub fn dismiss")
patch("main.rs",
      "        let store = st.store.lock().unwrap();\n        let cfg = st.cfg.lock().unwrap();\n        store.snapshot(",
      "        let mut store = st.store.lock().unwrap();\n        let cfg = st.cfg.lock().unwrap();\n"
      "        if let Some(sound) = store.chime.take() {\n            if cfg.session_end_sound {\n                crate::chime::play(sound);\n            }\n        }\n"
      "        store.snapshot(")
patch("config.rs",
      "    pub reset_notification_sound: bool,\n",
      "    pub reset_notification_sound: bool,\n    /// false = no sound when a Claude Code turn ends or stops to ask (chime.rs)\n    #[serde(default = \"yes\")]\n    pub session_end_sound: bool,\n")
patch("config.rs",
      "            reset_notification_sound: true,\n",
      "            reset_notification_sound: true,\n            session_end_sound: true,\n")
# ...and its switch in Settings → Notifications (other languages fall back to the English text)
patch("main.rs",
      "#[tauri::command]\nfn get_reset_notification_sound(",
      "#[tauri::command]\nfn get_session_end_sound(app: AppHandle) -> bool {\n"
      "    app.state::<AppState>().cfg.lock().unwrap().session_end_sound\n}\n\n"
      "#[tauri::command]\nfn set_session_end_sound(app: AppHandle, on: bool) -> bool {\n"
      "    let st = app.state::<AppState>();\n    let mut cfg = st.cfg.lock().unwrap();\n"
      "    cfg.session_end_sound = on;\n    config::save(&cfg);\n    on\n}\n\n"
      "#[tauri::command]\nfn get_reset_notification_sound(")
patch("main.rs",
      "            get_reset_notification_sound,\n",
      "            get_reset_notification_sound,\n            get_session_end_sound,\n            set_session_end_sound,\n")
html = "../ui/settings.html"
patch(html,
      "          <div class=\"item\"><span>Preview the reset card</span>",
      "          <div class=\"item\"><span>Sound when Claude finishes</span><button class=\"switch\" id=\"sw-session-sound\" role=\"switch\" aria-checked=\"false\" aria-label=\"Sound when Claude finishes\"></button></div>\n"
      "          <div class=\"item cap\">Plays when a Claude Code session finishes its turn or stops to ask for permission.</div>\n"
      "          <div class=\"item\"><span>Preview the reset card</span>")
patch(html,
      "const STATUS_TEXT = {\n",
      "STATIC_TEXT['pt-BR']['Sound when Claude finishes'] = 'Som quando o Claude termina';\n"
      "STATIC_TEXT['pt-BR']['Plays when a Claude Code session finishes its turn or stops to ask for permission.'] = 'Toca quando uma sessão do Claude Code termina o turno ou para pedindo permissão.';\n"
      "const STATUS_TEXT = {\n")
patch(html,
      "document.getElementById('sw-reset-sound').addEventListener('click', () => resetSound.toggle());\n",
      "document.getElementById('sw-reset-sound').addEventListener('click', () => resetSound.toggle());\n"
      "const sessionSound = remote('get_session_end_sound', 'set_session_end_sound', 'Sound when Claude finishes', () => drawSwitch(document.getElementById('sw-session-sound'), sessionSound));\n"
      "document.getElementById('sw-session-sound').addEventListener('click', () => sessionSound.toggle());\n")
patch(html,
      "  drawSwitch(document.getElementById('sw-reset-sound'), resetSound);\n",
      "  drawSwitch(document.getElementById('sw-reset-sound'), resetSound);\n  drawSwitch(document.getElementById('sw-session-sound'), sessionSound);\n")
patch(html,
      "    resetSound.refresh(),\n",
      "    resetSound.refresh(),\n    sessionSound.refresh(),\n")
patch("reset_alert.rs",
      "#[cfg(not(windows))]\nfn play_notification_sound() {}\n",
      "#[cfg(not(windows))]\nfn play_notification_sound() {\n    crate::chime::play(\"message\");\n}\n")

# Copilot borrows the session of the GitHub CLI, but upstream only ever looks for "gh.exe".
patch("copilot.rs",
      'cands.push(dir.join("gh.exe"));',
      'cands.push(dir.join(format!("gh{}", std::env::consts::EXE_SUFFIX)));')
patch("copilot.rs",
      'None => "gh.exe not found".into(),',
      'None => "gh not found".into(),')

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
cargo test --release -p codenotch -- linux_focus linux_x11 codex_spend chime 2>&1 | tail -20

say "Building (first build compiles SQLite and Tauri: expect 5-15 minutes)"
cargo build --release

say "Done"
echo "Binary:   $HERE/app/target/release/codenotch"
echo "Next:     $HERE/app/scripts/doctor-linux.sh   then   $HERE/app/scripts/run-linux.sh"
