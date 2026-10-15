//! Finished replies and permission requests for Codex and Cursor, read off activity.rs's own
//! readings: a task that was working and is gone has finished, one that turns to waiting is asking.
//! The answer itself comes from where each tool keeps it: Codex's rollout (its task_complete event
//! carries the final message, CLI and desktop app alike), Cursor's state.vscdb (the chat's last AI
//! bubble). Both end in the history (inbox.rs) and, with reply previews on, the card.

use crate::activity::Activity;
use crate::AppState;
use std::time::Duration;
use tauri::{AppHandle, Manager};

const OURS: [&str; 2] = ["codex", "cursor"];

pub fn changed(app: &AppHandle, before: &[Activity], after: &[Activity]) {
    let (done, asks) = transitions(before, after);
    if done.is_empty() && asks.is_empty() {
        return;
    }
    let pt = crate::resolved_lang(&app.state::<AppState>().cfg.lock().unwrap().lang) == "pt-BR";
    for a in asks {
        let text = if pt { "Precisa da sua aprovação" } else { "Needs your approval" };
        crate::inbox::push(app, "attention", &a.provider, a.name.clone(), text.into(), String::new());
    }
    for (provider, name) in done {
        let app = app.clone();
        std::thread::spawn(move || finished(&app, &provider, &name, pt));
    }
}

/// (provider, name) of the tasks that stopped working, and the tasks that newly wait on you.
/// A task is known by its provider and name, which is all an Activity carries.
fn transitions<'a>(before: &[Activity], after: &'a [Activity]) -> (Vec<(String, String)>, Vec<&'a Activity>) {
    let same = |a: &Activity, b: &Activity| a.provider == b.provider && a.name == b.name;
    let done = before
        .iter()
        .filter(|b| OURS.contains(&b.provider.as_str()) && !after.iter().any(|a| same(a, b)))
        .map(|b| (b.provider.clone(), b.name.clone()))
        .collect();
    let asks = after
        .iter()
        .filter(|a| OURS.contains(&a.provider.as_str()) && a.state == "waiting")
        .filter(|a| !before.iter().any(|b| same(a, b) && b.state == "waiting"))
        .collect();
    (done, asks)
}

fn finished(app: &AppHandle, provider: &str, name: &str, pt: bool) {
    // The final message can land a moment after the tool stops looking busy
    let mut found = None;
    for _ in 0..4 {
        std::thread::sleep(Duration::from_millis(800));
        found = if provider == "codex" { codex_reply(name) } else { cursor_reply(name) };
        if found.is_some() {
            break;
        }
    }
    let Some((title, text)) = found else { return };
    let body = crate::reply_preview::clean(&text);
    if body.is_empty() {
        return;
    }
    crate::inbox::push(app, "reply", provider, title.clone(), body.clone(), String::new());
    if !app.state::<AppState>().cfg.lock().unwrap().reply_preview {
        return;
    }
    let label = crate::provider_label(provider);
    let subtitle = if pt { format!("{label} terminou") } else { format!("{label} finished") };
    crate::reset_alert::enqueue_reply(
        app,
        crate::reply_preview::Reply { provider: provider.into(), session: String::new(), title, subtitle, body },
    );
}

// ---------------- Codex ----------------

/// The newest rollout's final answer, when its last turn ended normally. The title is the thread's
/// own when activity.rs had one (the desktop app), else the folder Codex ran in.
// ponytail: newest rollout = the one that just finished; two Codex sessions ending together can swap texts
fn codex_reply(name: &str) -> Option<(String, String)> {
    let path = crate::codex::newest_rollout()?;
    let text = codex_final_message(&crate::codex::tail_text(&path)?, crate::now_ms())?;
    let title = if name != "Codex" { name.to_string() } else { codex_folder(&path).unwrap_or_else(|| "Codex".into()) };
    Some((title, text))
}

/// Walking back from the end: a task_complete from the last two minutes gives the answer (an older
/// one is a turn already told about), turn_aborted means there is none, a newer turn that it is open
fn codex_final_message(tail: &str, now: u64) -> Option<String> {
    for line in tail.lines().rev() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { continue };
        match v.pointer("/payload/type").and_then(|t| t.as_str()) {
            Some("task_complete") => {
                let at = v["timestamp"]
                    .as_str()
                    .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                    .map(|d| d.timestamp_millis().max(0) as u64)?;
                if now.saturating_sub(at) > 120_000 {
                    return None;
                }
                return v.pointer("/payload/last_agent_message").and_then(|m| m.as_str()).map(str::to_string);
            }
            Some("turn_aborted") | Some("task_started") | Some("user_message") => return None,
            _ => {}
        }
    }
    None
}

fn codex_folder(rollout: &std::path::Path) -> Option<String> {
    let db = dirs::home_dir()?.join(".codex").join("state_5.sqlite");
    let conn = rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    let cwd: String = conn
        .query_row("SELECT cwd FROM threads WHERE rollout_path = ?1", [rollout.to_string_lossy()], |r| r.get(0))
        .ok()?;
    std::path::Path::new(&cwd).file_name().map(|n| n.to_string_lossy().into_owned())
}

// ---------------- Cursor ----------------

/// The most recent chat by that name: its last AI bubble with text, unless the run was aborted
fn cursor_reply(name: &str) -> Option<(String, String)> {
    let conn = rusqlite::Connection::open_with_flags(crate::cursor::store_url()?, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    let mut stmt = conn
        .prepare("SELECT composerId, value FROM composerHeaders WHERE isArchived = 0 ORDER BY recency DESC LIMIT 40")
        .ok()?;
    let id = stmt
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
        .ok()?
        .flatten()
        .find(|(_, v)| {
            serde_json::from_str::<serde_json::Value>(v)
                .ok()
                .and_then(|h| h.get("name").and_then(|n| n.as_str()).map(|n| n == name))
                .unwrap_or(false)
        })?
        .0;
    let kv = |key: String| -> Option<serde_json::Value> {
        let v: String = conn.query_row("SELECT value FROM cursorDiskKV WHERE key = ?1", [key], |r| r.get(0)).ok()?;
        serde_json::from_str(&v).ok()
    };
    let data = kv(format!("composerData:{id}"))?;
    if data["status"] == "aborted" {
        return None;
    }
    let text = data["fullConversationHeadersOnly"]
        .as_array()?
        .iter()
        .rev()
        .take_while(|h| h["type"] == 2) // the AI's bubbles after your last message
        .filter_map(|h| kv(format!("bubbleId:{id}:{}", h["bubbleId"].as_str()?)))
        .find_map(|b| b["text"].as_str().filter(|t| !t.trim().is_empty()).map(str::to_string))?;
    Some((name.to_string(), text))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn act(provider: &str, name: &str, state: &str) -> Activity {
        Activity { provider: provider.into(), state: state.into(), name: name.into(), detail: String::new(), since: 0 }
    }

    #[test]
    fn gone_is_done_and_newly_waiting_asks() {
        let before = [act("codex", "Codex", "busy"), act("cursor", "Fix", "busy"), act("cursor", "Old", "waiting"), act("gemini", "Ag", "busy")];
        let after = [act("cursor", "Fix", "waiting"), act("cursor", "Old", "waiting")];
        let (done, asks) = transitions(&before, &after);
        assert_eq!(done, vec![("codex".to_string(), "Codex".to_string())]); // not Antigravity
        assert_eq!(asks.len(), 1);
        assert_eq!(asks[0].name, "Fix");
    }

    #[test]
    fn only_a_completed_codex_turn_has_an_answer() {
        let done = r#"{"type":"response_item","payload":{"type":"message","role":"assistant"}}
{"timestamp":"2026-10-15T12:00:00.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Pronto."}}
{"type":"event_msg","payload":{"type":"token_count"}}"#;
        let aborted = r#"{"timestamp":"2026-10-15T12:00:00.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"old"}}
{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"event_msg","payload":{"type":"turn_aborted"}}"#;
        let at = 1_792_065_600_000; // 2026-10-15T12:00:00Z
        assert_eq!(codex_final_message(done, at + 5_000).as_deref(), Some("Pronto."));
        assert_eq!(codex_final_message(done, at + 600_000), None); // already told about
        assert_eq!(codex_final_message(aborted, at + 5_000), None);
    }
}
