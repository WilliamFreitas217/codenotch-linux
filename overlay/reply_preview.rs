//! Reply preview: when a Claude turn ends, the reset card's window shows the start of the answer,
//! read from the session's transcript. Clicking the card jumps to the session.

use crate::AppState;
use std::path::PathBuf;
use std::time::Duration;
use tauri::{AppHandle, Manager};

/// Logical size of the reply card (reply-card.html is laid out for exactly this)
pub const SIZE: (f64, f64) = (340.0, 190.0);
pub const SHOW_FOR: Duration = Duration::from_secs(12);
const MAX_CHARS: usize = 600;

pub struct Reply {
    pub session: String,
    pub title: String,
    pub subtitle: String,
    pub body: String,
}

/// Off the calling thread (broadcast() holds the store lock): find the transcript, read the answer,
/// queue the card. Silently does nothing when the answer cannot be found.
pub fn fire(app: &AppHandle, session: String, title: String, prompt: String) {
    let app = app.clone();
    std::thread::spawn(move || {
        let Some(path) = transcript_of(&session) else { return };
        // The Stop hook can land a beat before the final message reaches the transcript
        let mut body = None;
        for _ in 0..4 {
            body = crate::watcher::tail_info(&path).and_then(|t| reply_text(&t.entry));
            if body.is_some() {
                break;
            }
            std::thread::sleep(Duration::from_millis(300));
        }
        let Some(body) = body.map(|b| clean(&b)).filter(|b| !b.is_empty()) else { return };
        let lang = crate::resolved_lang(&app.state::<AppState>().cfg.lock().unwrap().lang);
        let pt = lang == "pt-BR";
        let subtitle = if prompt.is_empty() {
            (if pt { "Claude terminou" } else { "Claude finished" }).to_string()
        } else {
            format!("{}: {prompt}", if pt { "você" } else { "you" })
        };
        crate::reset_alert::enqueue_reply(&app, Reply { session, title, subtitle, body });
    });
}

/// `<session id>.jsonl` under any of the watcher's roots
fn transcript_of(session: &str) -> Option<PathBuf> {
    let name = format!("{session}.jsonl");
    crate::watcher::roots().into_iter().find_map(|root| {
        let mut files = Vec::new();
        crate::watcher::walk(&root, 0, &mut files);
        files.into_iter().find(|p| p.file_name().is_some_and(|n| n == name.as_str()))
    })
}

/// The text of an assistant entry with no tool call, i.e. a turn's final answer
fn reply_text(entry: &serde_json::Value) -> Option<String> {
    if entry.get("type")?.as_str()? != "assistant" {
        return None;
    }
    let blocks = entry.pointer("/message/content")?.as_array()?;
    if blocks.iter().any(|b| b["type"] == "tool_use") {
        return None;
    }
    let text: Vec<&str> = blocks
        .iter()
        .filter(|b| b["type"] == "text")
        .filter_map(|b| b["text"].as_str())
        .collect();
    (!text.is_empty()).then(|| text.join("\n"))
}

/// Markdown to plain lines: no fences, headings, emphasis or table rules; bullets become "•"
fn clean(md: &str) -> String {
    let lines: Vec<String> = md
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with("```") && !l.starts_with("|--") && !l.starts_with("---"))
        .map(|l| {
            let l = l.trim_start_matches('#').trim_start();
            let l = match l.strip_prefix("- ").or_else(|| l.strip_prefix("* ")) {
                Some(rest) => format!("• {rest}"),
                None => l.to_string(),
            };
            l.replace("**", "").replace("__", "").replace('`', "")
        })
        .collect();
    let out = lines.join("\n");
    if out.chars().count() > MAX_CHARS {
        out.chars().take(MAX_CHARS).collect::<String>() + "…"
    } else {
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_a_final_text_answer_counts() {
        let done = json!({"type":"assistant","message":{"content":[{"type":"text","text":"Pronto."}]}});
        let tool = json!({"type":"assistant","message":{"content":[{"type":"text","text":"Vou ler"},{"type":"tool_use","name":"Read"}]}});
        let user = json!({"type":"user","message":{"content":"oi"}});
        assert_eq!(reply_text(&done).as_deref(), Some("Pronto."));
        assert_eq!(reply_text(&tool), None);
        assert_eq!(reply_text(&user), None);
    }

    #[test]
    fn markdown_is_flattened() {
        let md = "## Feito\n\n- **um** item\n* `dois`\n```rust\nfn x() {}\n```\n| a |\n|---|";
        assert_eq!(clean(md), "Feito\n• um item\n• dois\nfn x() {}\n| a |");
        assert_eq!(clean(&"x".repeat(700)).chars().count(), MAX_CHARS + 1);
    }
}
