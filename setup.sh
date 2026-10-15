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
cp "$HERE/overlay/reply_preview.rs" "$HERE/app/codenotch/src/reply_preview.rs"
cp "$HERE/overlay/reply-card.html"  "$HERE/app/codenotch/ui/reply-card.html"
cp "$HERE/overlay/inbox.rs"         "$HERE/app/codenotch/src/inbox.rs"

python3 - "$HERE/app/codenotch/src" "$HERE/overlay/inbox.js" <<'PY'
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
      "mod focus;\n#[cfg(not(windows))]\nmod linux_focus;\n#[cfg(target_os = \"linux\")]\nmod linux_x11;\nmod codex_spend;\nmod chime;\nmod reply_preview;\nmod inbox;\n")

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
      "pub struct Store {\n    map: HashMap<String, Session>,\n    /// A sound owed by the last transition, played (and cleared) by broadcast()\n    pub chime: Option<&'static str>,\n    /// (id, title, prompt) of a turn that just finished, for reply_preview::fire in broadcast()\n    pub reply: Option<(String, String, String)>,\n    /// (id, title, request) of a turn that just stopped to ask, for the history (inbox.rs)\n    pub ask: Option<(String, String, String)>,\n}\n")
patch("state.rs",
      "        // Broadcast only on a visible change, so the watcher's rapid appends cannot cause a storm\n        (\n",
      "        let chime = crate::chime::sound_for(&before.0, &s.state);\n"
      "        let reply = (chime == Some(\"complete\")).then(|| (s.id.clone(), s.title.clone(), s.prompt.clone()));\n"
      "        let ask = (chime == Some(\"message-new-instant\")).then(|| (s.id.clone(), s.title.clone(), s.attn.clone()));\n"
      "        // Broadcast only on a visible change, so the watcher's rapid appends cannot cause a storm\n        let changed = (\n")
patch("state.rs",
      "        ) != before\n    }\n\n    pub fn dismiss",
      "        ) != before;\n        if chime.is_some() {\n            self.chime = chime;\n        }\n        if reply.is_some() {\n            self.reply = reply;\n        }\n        if ask.is_some() {\n            self.ask = ask;\n        }\n        changed\n    }\n\n    pub fn dismiss")
patch("main.rs",
      "        let store = st.store.lock().unwrap();\n        let cfg = st.cfg.lock().unwrap();\n        store.snapshot(",
      "        let mut store = st.store.lock().unwrap();\n        let cfg = st.cfg.lock().unwrap();\n"
      "        if let Some(sound) = store.chime.take() {\n            if cfg.session_end_sound {\n                crate::chime::play(sound);\n            }\n        }\n"
      "        if let Some((id, title, prompt)) = store.reply.take() {\n            crate::reply_preview::fire(app, id, title, prompt, cfg.reply_preview);\n        }\n        if let Some((id, title, ask)) = store.ask.take() {\n            crate::inbox::push(app, \"attention\", \"claude\", title, ask, id);\n        }\n"
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

# Reply preview (reply_preview.rs): a finished turn shows the start of the answer in the reset card's
# window and queue, laid out by reply-card.html. Off by default: it puts the answer on screen.
patch("watcher.rs", "\nfn walk(dir: &Path", "\npub fn walk(dir: &Path")
patch("reset_alert.rs",
      "struct QueuedAlert {\n    event: ResetEvent,\n    preview: bool,\n}\n",
      "struct QueuedAlert {\n    event: ResetEvent,\n    preview: bool,\n    reply: Option<crate::reply_preview::Reply>,\n}\n")
patch("reset_alert.rs",
      "fn enqueue_unchecked(app: &AppHandle, event: ResetEvent, preview: bool) {\n"
      "    let queue = &app.state::<AppState>().reset_alerts;\n"
      "    let mut state = queue.state.lock().unwrap();\n"
      "    state.pending.push_back(QueuedAlert { event, preview });\n",
      "fn enqueue_unchecked(app: &AppHandle, event: ResetEvent, preview: bool) {\n"
      "    push(app, QueuedAlert { event, preview, reply: None });\n}\n\n"
      "/// A finished Claude turn (reply_preview.rs), through the same queue and window\n"
      "pub fn enqueue_reply(app: &AppHandle, reply: crate::reply_preview::Reply) {\n"
      "    let event = ResetEvent { provider: \"claude\".into(), window_label: String::new(), used_fraction: 0.0, next_reset_at: None };\n"
      "    push(app, QueuedAlert { event, preview: false, reply: Some(reply) });\n}\n\n"
      "fn push(app: &AppHandle, alert: QueuedAlert) {\n"
      "    let queue = &app.state::<AppState>().reset_alerts;\n"
      "    let mut state = queue.state.lock().unwrap();\n"
      "    state.pending.push_back(alert);\n")
patch("reset_alert.rs",
      "        if let Err(err) = show(&app, queued.event, token) {\n",
      "        let hold = if queued.reply.is_some() { crate::reply_preview::SHOW_FOR } else { SHOW_FOR };\n"
      "        if let Err(err) = show(&app, queued.event, queued.reply, token) {\n")
patch("reset_alert.rs",
      ".wait_timeout_while(state, SHOW_FOR, ",
      ".wait_timeout_while(state, hold, ")
patch("reset_alert.rs",
      "fn show(app: &AppHandle, event: ResetEvent, token: u64)",
      "fn show(app: &AppHandle, event: ResetEvent, reply: Option<crate::reply_preview::Reply>, token: u64)")
patch("reset_alert.rs",
      "show_on_main(&app_for_main, event, token)",
      "show_on_main(&app_for_main, event, reply, token)")
patch("reset_alert.rs",
      "fn show_on_main(app: &AppHandle, event: ResetEvent, token: u64)",
      "fn show_on_main(app: &AppHandle, event: ResetEvent, reply: Option<crate::reply_preview::Reply>, token: u64)")
patch("reset_alert.rs",
      "    let vertical = config::edge_is_vertical(&edge);\n",
      "    let (card_w, card_h) = if reply.is_some() { crate::reply_preview::SIZE } else { (CARD_W, CARD_H) };\n"
      "    let vertical = config::edge_is_vertical(&edge);\n")
patch("reset_alert.rs", ".inner_size(CARD_W, CARD_H)", ".inner_size(card_w, card_h)")
patch("reset_alert.rs", "((CARD_W * density)", "((card_w * density)")
patch("reset_alert.rs", "((CARD_H * density)", "((card_h * density)")
patch("reset_alert.rs",
      'WebviewUrl::App("reset-alert.html".into())',
      'WebviewUrl::App((if reply.is_some() { "reply-card.html" } else { "reset-alert.html" }).into())')
patch("reset_alert.rs",
      "    dismiss_label: String,\n}\n",
      "    dismiss_label: String,\n    body: String,\n    session: String,\n}\n")
patch("reset_alert.rs", "    let payload = CardPayload {\n", "    let mut payload = CardPayload {\n")
patch("reset_alert.rs",
      "        dismiss_label: word_dismiss(&lang).to_string(),\n    };\n",
      "        dismiss_label: word_dismiss(&lang).to_string(),\n        body: String::new(),\n        session: String::new(),\n    };\n"
      "    if let Some(r) = &reply {\n"
      "        payload.title = r.title.clone();\n        payload.subtitle = r.subtitle.clone();\n"
      "        payload.body = r.body.clone();\n        payload.session = r.session.clone();\n    }\n")
# the "complete" chime already played for this one
patch("reset_alert.rs", "    if sound_on {\n", "    if sound_on && reply.is_none() {\n")

patch("config.rs",
      "    pub session_end_sound: bool,\n",
      "    pub session_end_sound: bool,\n    /// true = a finished Claude turn shows the start of its answer in a card (reply_preview.rs)\n    #[serde(default)]\n    pub reply_preview: bool,\n")
patch("config.rs",
      "            session_end_sound: true,\n",
      "            session_end_sound: true,\n            reply_preview: false,\n")
patch("main.rs",
      "#[tauri::command]\nfn get_session_end_sound(",
      "#[tauri::command]\nfn get_reply_preview(app: AppHandle) -> bool {\n"
      "    app.state::<AppState>().cfg.lock().unwrap().reply_preview\n}\n\n"
      "#[tauri::command]\nfn set_reply_preview(app: AppHandle, on: bool) -> bool {\n"
      "    let st = app.state::<AppState>();\n    let mut cfg = st.cfg.lock().unwrap();\n"
      "    cfg.reply_preview = on;\n    config::save(&cfg);\n    on\n}\n\n"
      "#[tauri::command]\nfn get_session_end_sound(")
patch("main.rs",
      "            set_session_end_sound,\n",
      "            set_session_end_sound,\n            get_reply_preview,\n            set_reply_preview,\n            inbox::get_inbox,\n            inbox::inbox_seen,\n            inbox::inbox_read_session,\n            inbox::inbox_clear,\n")
patch(html,
      "          <div class=\"item\"><span>Preview the reset card</span>",
      "          <div class=\"item\"><span>Preview Claude's reply</span><button class=\"switch\" id=\"sw-reply-preview\" role=\"switch\" aria-checked=\"false\" aria-label=\"Preview Claude's reply\"></button></div>\n"
      "          <div class=\"item cap\">When a Claude session finishes, show the start of its answer in a card. Click it to jump to the session.</div>\n"
      "          <div class=\"item\"><span>Preview the reset card</span>")
patch(html,
      "const STATUS_TEXT = {\n",
      "STATIC_TEXT['pt-BR'][\"Preview Claude's reply\"] = 'Prévia da resposta do Claude';\n"
      "STATIC_TEXT['pt-BR']['When a Claude session finishes, show the start of its answer in a card. Click it to jump to the session.'] = 'Quando uma sessão do Claude termina, mostra o início da resposta num card. Clique nele para ir à sessão.';\n"
      "const STATUS_TEXT = {\n")
patch(html,
      "document.getElementById('sw-session-sound').addEventListener('click', () => sessionSound.toggle());\n",
      "document.getElementById('sw-session-sound').addEventListener('click', () => sessionSound.toggle());\n"
      "const replyPreview = remote('get_reply_preview', 'set_reply_preview', \"Preview Claude's reply\", () => drawSwitch(document.getElementById('sw-reply-preview'), replyPreview));\n"
      "document.getElementById('sw-reply-preview').addEventListener('click', () => replyPreview.toggle());\n")
patch(html,
      "  drawSwitch(document.getElementById('sw-session-sound'), sessionSound);\n",
      "  drawSwitch(document.getElementById('sw-session-sound'), sessionSound);\n  drawSwitch(document.getElementById('sw-reply-preview'), replyPreview);\n")
patch(html,
      "    sessionSound.refresh(),\n",
      "    sessionSound.refresh(),\n    replyPreview.refresh(),\n")

# Notification history (inbox.rs): replies (above), permission requests (state.rs) and renewals land
# in it; a bell after the rings shows the unread count, and hovering it lists the history.
patch("reset_alert.rs",
      "pub fn enqueue(app: &AppHandle, event: ResetEvent) {\n    let state = app.state::<AppState>();\n    let config = state.cfg.lock().unwrap();\n",
      "pub fn enqueue(app: &AppHandle, event: ResetEvent) {\n    let state = app.state::<AppState>();\n    let config = state.cfg.lock().unwrap();\n"
      "    let lang = crate::resolved_lang(&config.lang);\n"
      "    crate::inbox::push(app, \"reset\", &event.provider,\n"
      "        format!(\"{} {}\", crate::provider_label(&event.provider), word_renewed(&lang)),\n"
      "        format!(\"{} {} · {} · {}%\", traymenu::label(&event.window_label, &lang), word_renewed(&lang), word_quota_available(&lang), traymenu::pct(event.used_fraction)),\n"
      "        String::new());\n")
notch = "../ui/notch.html"
patch(notch,
      "const listen = window.__TAURI__.event.listen;\n",
      "const listen = window.__TAURI__.event.listen;\n"
      "// Notification history (inbox.rs), newest first; inboxLit = what was unread when its card opened\n"
      "let inbox=[], inboxLit=null;\n")
patch(notch,
      "  #card.show{display:block}\n",
      "  #card.show{display:block}\n"
      "  /* The bell after the rings (inbox.rs): its badge counts what is unread, its card lists the history */\n"
      "  .cell.inbox .ringwrap{display:grid;place-items:center}\n"
      "  .cell.inbox svg.bell{width:calc(26px * var(--k));height:calc(26px * var(--k));fill:none;stroke:var(--ink-3);stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}\n"
      "  .cell.inbox .badge{position:absolute;top:-2px;right:-6px;min-width:18px;height:18px;padding:0 5px;border-radius:9px;background:#FF3F00;color:#fff;font-size:11px;font-weight:700;line-height:18px;text-align:center;display:none}\n"
      "  .cell.inbox.unread .badge{display:block}\n"
      "  .ib-row{display:flex;gap:8px;padding:8px 0;border-top:1px solid var(--card-rule)}\n"
      "  .ib-row:first-of-type{border-top:none}\n"
      "  .ib-row.go{cursor:pointer}\n"
      "  .ib-row.go:hover .ib-title{text-decoration:underline}\n"
      "  .ib-icon{flex:none;width:16px;height:16px;margin-top:1px;display:grid;place-items:center;color:var(--ink-2);font-size:10px;font-weight:700}\n"
      "  .ib-icon svg{width:16px;height:16px;fill:currentColor}\n"
      "  .ib-main{min-width:0;flex:1}\n"
      "  .ib-top{display:flex;gap:6px;align-items:baseline}\n"
      "  .ib-title{font-size:12px;font-weight:600;color:var(--ink-2);flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\n"
      "  .ib-row.new .ib-title::before{content:'';display:inline-block;width:6px;height:6px;border-radius:3px;background:#00FF88;margin-right:6px;vertical-align:middle}\n"
      "  .ib-time{font-size:10px;color:var(--ink-dim);flex:none}\n"
      "  .ib-text{font-size:11px;color:var(--ink-4);line-height:1.4;white-space:pre-line;margin-top:2px;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:3;overflow:hidden}\n"
      "  .ib-row.attention .ib-text{color:#F2FF00}\n"
      "  .ib-foot{display:flex;justify-content:flex-end;margin-top:6px}\n"
      "  .ib-foot button{font:inherit;font-size:11px;color:var(--ink-3);background:transparent;border:1px solid var(--card-line);border-radius:7px;padding:3px 9px;cursor:pointer}\n"
      "  .ib-foot button:hover{color:var(--ink)}\n")
patch(notch,
      "const want=ps.map(p=>p.id+':'+(glyphs[p.base]?glyphs[p.base].kind:'-')).join(',');",
      "const want=ps.map(p=>p.id+':'+(glyphs[p.base]?glyphs[p.base].kind:'-')).join(',')+(inbox.length?',inbox':'');")
patch(notch,
      "      <div class=\"pct\">—</div></div>`).join('');",
      "      <div class=\"pct\">—</div></div>`).join('')+(inbox.length?inboxCellHtml(ps.length):'');")
patch(notch,
      "  reportHot(); // a provider appearing or leaving resizes the pill\n}\n",
      "  renderInboxCell();\n  reportHot(); // a provider appearing or leaving resizes the pill\n}\n")
patch(notch,
      "function hideCard(){card.classList.remove('show');reportHot();}",
      "function hideCard(){card.classList.remove('show');inboxLit=null;reportHot();}")
patch(notch,
      "  if(press&&!dragging&&press.id) refreshRing(press.id);\n",
      "  if(press&&!dragging&&press.id==='inbox') invoke('inbox_seen').catch(()=>{});\n"
      "  else if(press&&!dragging&&press.id) refreshRing(press.id);\n")
patch(notch,
      "// CLAUDE_AUTH_ACTIONS_END\nfunction renderCard(){\n  const c=document.getElementById('card');\n",
      "// CLAUDE_AUTH_ACTIONS_END\n" + pathlib.Path(sys.argv[2]).read_text() +
      "function renderCard(){\n  const c=document.getElementById('card');\n"
      "  if(hoverId==='inbox'){ renderInboxCard(c); return; }\n")

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
cargo test --release -p codenotch -- linux_focus linux_x11 codex_spend chime reply_preview inbox 2>&1 | tail -20

say "Building (first build compiles SQLite and Tauri: expect 5-15 minutes)"
cargo build --release

say "Done"
echo "Binary:   $HERE/app/target/release/codenotch"
echo "Next:     $HERE/app/scripts/doctor-linux.sh   then   $HERE/app/scripts/run-linux.sh"
