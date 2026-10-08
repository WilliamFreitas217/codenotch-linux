//! Linux: jump back to the terminal that hosts a Claude session, and tell which kind of
//! desktop session the notch is running in.
//!
//! The Windows build walks the parent chain from the session's `claude` pid up to the terminal's
//! window. The same idea works here, with two differences:
//!
//!   * the process tree comes from `/proc/<pid>/stat` instead of a ToolHelp snapshot;
//!   * "find the window that belongs to a pid, and raise it" depends on the display server.
//!       - X11 (and XWayland clients): `wmctrl -lp` lists `window-id desktop pid ...`,
//!         `wmctrl -ia <id>` raises it. `xdotool` is the fallback.
//!       - Sway: `swaymsg -t get_tree` carries `pid` per view, `[con_id=N] focus` raises it.
//!       - Hyprland: `hyprctl clients -j` carries `pid` and `address`, `focuswindow` raises it.
//!       - GNOME / KDE on Wayland: no stable, unprivileged way to raise another client's window,
//!         so this returns false and the caller shows the "could not jump" hint.
//!
//! Everything that decides something (which window wins, which backend to use, how a line is
//! parsed) is a pure function with tests; only `run` touches the system.

use std::process::Command;

use serde_json::Value;

/// How many ancestors of the Claude process are considered: node -> shell -> terminal -> ...
const MAX_DEPTH: usize = 12;

// ---------------------------------------------------------------------------------------------
// Process tree
// ---------------------------------------------------------------------------------------------

/// Parent pid out of the text of `/proc/<pid>/stat`.
///
/// The second field is the command name in parentheses and may itself contain spaces and
/// parentheses, so the fields after it are located from the *last* `)`.
pub fn parse_ppid(stat: &str) -> Option<u32> {
    let rest = &stat[stat.rfind(')')? + 1..];
    let mut fields = rest.split_whitespace();
    fields.next()?; // state
    fields.next()?.parse().ok()
}

fn parent_of(pid: u32) -> Option<u32> {
    let text = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    parse_ppid(&text)
}

/// `pid` followed by its ancestors, nearest first, stopping at init, at a loop, or at `MAX_DEPTH`.
pub fn ancestor_chain_with(pid: u32, parent: impl Fn(u32) -> Option<u32>) -> Vec<u32> {
    let mut chain = vec![pid];
    let mut cur = pid;
    while chain.len() < MAX_DEPTH {
        match parent(cur) {
            Some(p) if p > 1 && !chain.contains(&p) => {
                chain.push(p);
                cur = p;
            }
            _ => break,
        }
    }
    chain
}

// ---------------------------------------------------------------------------------------------
// Which desktop session is this
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionKind {
    X11,
    Wayland,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Compositor {
    Sway,
    Hyprland,
    Kde,
    Gnome,
    Other,
}

/// The environment variables the detection reads, so tests can supply their own.
#[derive(Debug, Default, Clone)]
pub struct Env {
    pub xdg_session_type: Option<String>,
    pub wayland_display: Option<String>,
    pub display: Option<String>,
    pub xdg_current_desktop: Option<String>,
    pub sway_sock: Option<String>,
    pub hypr_signature: Option<String>,
}

impl Env {
    pub fn from_process() -> Env {
        let get = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        Env {
            xdg_session_type: get("XDG_SESSION_TYPE"),
            wayland_display: get("WAYLAND_DISPLAY"),
            display: get("DISPLAY"),
            xdg_current_desktop: get("XDG_CURRENT_DESKTOP"),
            sway_sock: get("SWAYSOCK"),
            hypr_signature: get("HYPRLAND_INSTANCE_SIGNATURE"),
        }
    }
}

pub fn detect(env: &Env) -> (SessionKind, Compositor) {
    let session = match env.xdg_session_type.as_deref().map(str::to_ascii_lowercase).as_deref() {
        Some("x11") => SessionKind::X11,
        Some("wayland") => SessionKind::Wayland,
        // XDG_SESSION_TYPE is not always exported (plain startx, some display managers):
        // fall back on which socket variable is present, Wayland first.
        _ if env.wayland_display.is_some() => SessionKind::Wayland,
        _ if env.display.is_some() => SessionKind::X11,
        _ => SessionKind::Unknown,
    };

    let desktop = env.xdg_current_desktop.as_deref().unwrap_or("").to_ascii_lowercase();
    let compositor = if env.hypr_signature.is_some() || desktop.contains("hyprland") {
        Compositor::Hyprland
    } else if env.sway_sock.is_some() || desktop.contains("sway") {
        Compositor::Sway
    } else if desktop.contains("kde") || desktop.contains("plasma") {
        Compositor::Kde
    } else if desktop.contains("gnome") || desktop.contains("ubuntu") || desktop.contains("unity") {
        Compositor::Gnome
    } else {
        Compositor::Other
    };
    (session, compositor)
}

/// One line for `doctor` and the log: what was detected and what that means for the notch.
pub fn describe(env: &Env) -> String {
    let (session, compositor) = detect(env);
    let note = match (session, compositor) {
        (SessionKind::X11, _) => "X11: the notch positions itself and stays on top natively",
        (SessionKind::Wayland, Compositor::Sway | Compositor::Hyprland) => {
            "Wayland: runs through XWayland; terminal jump-back works natively through the compositor"
        }
        (SessionKind::Wayland, _) => {
            "Wayland: runs through XWayland (GDK_BACKEND=x11); terminal jump-back is not available here"
        }
        (SessionKind::Unknown, _) => "no display session detected",
    };
    format!("session={session:?} compositor={compositor:?} — {note}")
}

// ---------------------------------------------------------------------------------------------
// Picking the window
// ---------------------------------------------------------------------------------------------

/// A top-level window as a backend reports it: an opaque id (as the backend wants it back) and
/// the pid that owns it.
pub type Candidate = (String, u32);

/// Of all windows, the one owned by the *farthest* ancestor of the Claude process: that is the
/// terminal host rather than the shell or node in the middle. `chain[0]` is Claude itself.
pub fn pick_best(candidates: &[Candidate], chain: &[u32]) -> Option<String> {
    let mut best: Option<(usize, &str)> = None;
    for (id, pid) in candidates {
        if *pid == 0 {
            continue;
        }
        if let Some(depth) = chain.iter().position(|p| p == pid) {
            if best.map(|(d, _)| depth > d).unwrap_or(true) {
                best = Some((depth, id));
            }
        }
    }
    best.map(|(_, id)| id.to_string())
}

/// `wmctrl -lp` lines: `0x04200003  0 3189   host  Window title`.
pub fn parse_wmctrl(out: &str) -> Vec<Candidate> {
    out.lines()
        .filter_map(|line| {
            let mut f = line.split_whitespace();
            let id = f.next()?;
            f.next()?; // desktop
            let pid: u32 = f.next()?.parse().ok()?;
            id.starts_with("0x").then(|| (id.to_string(), pid))
        })
        .collect()
}

/// Every view of a Sway tree (`swaymsg -t get_tree`), by container id.
pub fn parse_sway_tree(json: &str) -> Vec<Candidate> {
    fn walk(node: &Value, out: &mut Vec<Candidate>) {
        if let (Some(id), Some(pid)) = (
            node.get("id").and_then(Value::as_i64),
            node.get("pid").and_then(Value::as_u64),
        ) {
            if pid > 0 {
                out.push((id.to_string(), pid as u32));
            }
        }
        for key in ["nodes", "floating_nodes"] {
            if let Some(children) = node.get(key).and_then(Value::as_array) {
                for child in children {
                    walk(child, out);
                }
            }
        }
    }
    let mut out = Vec::new();
    if let Ok(root) = serde_json::from_str::<Value>(json) {
        walk(&root, &mut out);
    }
    out
}

/// `hyprctl clients -j`: an array of objects carrying `address` and `pid`.
pub fn parse_hypr_clients(json: &str) -> Vec<Candidate> {
    let Ok(Value::Array(clients)) = serde_json::from_str::<Value>(json) else {
        return Vec::new();
    };
    clients
        .iter()
        .filter_map(|c| {
            let addr = c.get("address")?.as_str()?;
            let pid = c.get("pid")?.as_u64()? as u32;
            Some((addr.to_string(), pid))
        })
        .collect()
}

// ---------------------------------------------------------------------------------------------
// Talking to the system
// ---------------------------------------------------------------------------------------------

fn run(program: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(program).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

fn log(msg: &str) {
    crate::applog(msg);
}

fn focus_x11(chain: &[u32]) -> bool {
    if let Some(listing) = run("wmctrl", &["-lp"]) {
        if let Some(id) = pick_best(&parse_wmctrl(&listing), chain) {
            if run("wmctrl", &["-ia", &id]).is_some() {
                return true;
            }
        }
    }
    // Without wmctrl (or when it finds nothing) ask xdotool, nearest-to-the-top ancestor first.
    for pid in chain.iter().rev() {
        let Some(found) = run("xdotool", &["search", "--onlyvisible", "--pid", &pid.to_string()]) else {
            continue;
        };
        if let Some(id) = found.lines().next().map(str::trim).filter(|s| !s.is_empty()) {
            if run("xdotool", &["windowactivate", id]).is_some() {
                return true;
            }
        }
    }
    false
}

fn focus_sway(chain: &[u32]) -> bool {
    let Some(tree) = run("swaymsg", &["-t", "get_tree"]) else { return false };
    let Some(id) = pick_best(&parse_sway_tree(&tree), chain) else { return false };
    run("swaymsg", &[&format!("[con_id={id}] focus")]).is_some()
}

fn focus_hyprland(chain: &[u32]) -> bool {
    let Some(clients) = run("hyprctl", &["clients", "-j"]) else { return false };
    let Some(addr) = pick_best(&parse_hypr_clients(&clients), chain) else { return false };
    run("hyprctl", &["dispatch", "focuswindow", &format!("address:{addr}")]).is_some()
}

/// Raise the terminal that hosts `claude_pid`. Returns false when it cannot be done here; the
/// page then says so, as it does on Windows.
pub fn focus_terminal(claude_pid: u32) -> bool {
    if claude_pid == 0 {
        return false;
    }
    let chain = ancestor_chain_with(claude_pid, parent_of);
    let env = Env::from_process();
    let (session, compositor) = detect(&env);

    let ok = match (session, compositor) {
        (SessionKind::Wayland, Compositor::Sway) => focus_sway(&chain) || focus_x11(&chain),
        (SessionKind::Wayland, Compositor::Hyprland) => focus_hyprland(&chain) || focus_x11(&chain),
        // GNOME and KDE on Wayland expose no way to raise a native client's window. A terminal
        // running through XWayland is still visible to X11 tools, so try that and no more.
        (SessionKind::Wayland, _) => focus_x11(&chain),
        (SessionKind::X11, _) => focus_x11(&chain),
        (SessionKind::Unknown, _) => false,
    };
    if !ok {
        log(&format!(
            "focus_terminal: no window found for pid {claude_pid} (chain {chain:?}); {}",
            describe(&env)
        ));
    }
    ok
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn ancestor_chain_from_map(pid: u32, map: &HashMap<u32, u32>) -> Vec<u32> {
        ancestor_chain_with(pid, |p| map.get(&p).copied())
    }

    #[test]
    fn ppid_survives_awkward_command_names() {
        assert_eq!(parse_ppid("4242 (node) S 4100 4242 4100 0 -1 0"), Some(4100));
        assert_eq!(parse_ppid("77 (my (weird) name) R 12 77 12 0"), Some(12));
        assert_eq!(parse_ppid("garbage"), None);
        assert_eq!(parse_ppid("9 (x)"), None);
    }

    #[test]
    fn chain_stops_at_init_loops_and_depth() {
        let map: HashMap<u32, u32> = [(500, 400), (400, 300), (300, 1), (1, 0)].into();
        assert_eq!(ancestor_chain_from_map(500, &map), vec![500, 400, 300]);

        let looped: HashMap<u32, u32> = [(10, 11), (11, 10)].into();
        assert_eq!(ancestor_chain_from_map(10, &looped), vec![10, 11]);

        let deep: HashMap<u32, u32> = (2..100u32).map(|p| (p, p + 1)).collect();
        assert_eq!(ancestor_chain_from_map(2, &deep).len(), MAX_DEPTH);

        assert_eq!(ancestor_chain_from_map(999, &HashMap::new()), vec![999]);
    }

    fn env(session: &str, desktop: &str) -> Env {
        Env {
            xdg_session_type: Some(session.into()),
            xdg_current_desktop: Some(desktop.into()),
            ..Env::default()
        }
    }

    #[test]
    fn ubuntu_x11_and_wayland_are_told_apart() {
        assert_eq!(detect(&env("x11", "ubuntu:GNOME")), (SessionKind::X11, Compositor::Gnome));
        assert_eq!(detect(&env("wayland", "ubuntu:GNOME")), (SessionKind::Wayland, Compositor::Gnome));
        assert_eq!(detect(&env("Wayland", "KDE")), (SessionKind::Wayland, Compositor::Kde));
    }

    #[test]
    fn compositor_sockets_beat_the_desktop_name() {
        let sway = Env { wayland_display: Some("wayland-1".into()), sway_sock: Some("/run/sway".into()), ..Env::default() };
        assert_eq!(detect(&sway), (SessionKind::Wayland, Compositor::Sway));
        let hypr = Env { wayland_display: Some("wayland-1".into()), hypr_signature: Some("abc".into()), ..Env::default() };
        assert_eq!(detect(&hypr), (SessionKind::Wayland, Compositor::Hyprland));
    }

    #[test]
    fn missing_session_type_falls_back_on_sockets() {
        let only_x = Env { display: Some(":0".into()), ..Env::default() };
        assert_eq!(detect(&only_x).0, SessionKind::X11);
        let both = Env { display: Some(":0".into()), wayland_display: Some("wayland-0".into()), ..Env::default() };
        assert_eq!(detect(&both).0, SessionKind::Wayland);
        assert_eq!(detect(&Env::default()).0, SessionKind::Unknown);
    }

    #[test]
    fn describe_is_honest_about_gnome_wayland() {
        let text = describe(&env("wayland", "ubuntu:GNOME"));
        assert!(text.contains("not available"), "{text}");
        assert!(describe(&env("x11", "ubuntu:GNOME")).contains("natively"));
    }

    #[test]
    fn the_terminal_host_beats_the_shell() {
        // chain: claude(100) <- bash(90) <- gnome-terminal-server(80)
        let chain = [100, 90, 80];
        let windows = vec![
            ("0x1".to_string(), 555),   // unrelated
            ("0x2".to_string(), 80),    // the terminal
            ("0x3".to_string(), 90),    // would only happen with a shell that owns a window
        ];
        assert_eq!(pick_best(&windows, &chain), Some("0x2".into()));
        assert_eq!(pick_best(&windows, &[1000]), None);
        assert_eq!(pick_best(&[("0x9".into(), 0)], &[0, 5]), None, "pid 0 is never a match");
    }

    #[test]
    fn wmctrl_listing_is_parsed() {
        let out = "0x03a00007  0 12345  host Terminal — bash\n\
                   0x04200003 -1 678    host Desktop\n\
                   not a window line\n\
                   0x05000001  1 abc    host bad pid\n";
        assert_eq!(
            parse_wmctrl(out),
            vec![("0x03a00007".to_string(), 12345), ("0x04200003".to_string(), 678)]
        );
    }

    #[test]
    fn sway_tree_yields_views_including_floating_ones() {
        let tree = r#"{
          "id": 1, "pid": null,
          "nodes": [
            {"id": 4, "nodes": [
               {"id": 7, "pid": 3001, "nodes": [], "floating_nodes": []}
            ], "floating_nodes": [
               {"id": 9, "pid": 3002, "nodes": [], "floating_nodes": []}
            ]}
          ],
          "floating_nodes": []
        }"#;
        assert_eq!(
            parse_sway_tree(tree),
            vec![("7".to_string(), 3001), ("9".to_string(), 3002)]
        );
        assert!(parse_sway_tree("not json").is_empty());
    }

    #[test]
    fn hyprland_clients_are_parsed() {
        let json = r#"[{"address":"0x55aa","pid":4000,"class":"kitty"},{"address":"0x55bb","pid":0},{"class":"no-address","pid":1}]"#;
        assert_eq!(
            parse_hypr_clients(json),
            vec![("0x55aa".to_string(), 4000), ("0x55bb".to_string(), 0)]
        );
        assert!(parse_hypr_clients("{}").is_empty());
    }
}
