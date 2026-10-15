//! Notification history: finished Claude replies, quota renewals and permission requests, kept in
//! memory so a card that came and went unseen can still be read from the notch's bell (notch.html).

use serde::Serialize;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter};

const KEEP: usize = 40;

#[derive(Clone, Debug, Serialize)]
pub struct Item {
    pub id: u64,
    pub at: u64,
    /// "reply", "reset" or "attention"
    pub kind: &'static str,
    /// Provider id, for the glyph ("claude", "codex", …)
    pub provider: String,
    pub title: String,
    pub text: String,
    /// The Claude session to jump to, when there is one
    pub session: String,
    pub read: bool,
}

// ponytail: in memory only, lost on restart; persist to ~/.config/codenotch if that gets missed
static ITEMS: Mutex<VecDeque<Item>> = Mutex::new(VecDeque::new());
static NEXT: AtomicU64 = AtomicU64::new(1);
/// Settings > Notifications > "Notification history". A flag of its own rather than a config read:
/// push() is called from places that already hold the config lock.
static ENABLED: AtomicBool = AtomicBool::new(true);

pub fn set_enabled(on: bool) {
    ENABLED.store(on, Ordering::Relaxed);
}

pub fn push(app: &AppHandle, kind: &'static str, provider: &str, title: String, text: String, session: String) {
    if !ENABLED.load(Ordering::Relaxed) {
        return;
    }
    let item = Item {
        id: NEXT.fetch_add(1, Ordering::Relaxed),
        at: crate::now_ms(),
        kind,
        provider: provider.to_string(),
        title,
        text,
        session,
        read: false,
    };
    change(app, |items| add(items, item));
}

/// Newest first, the oldest past KEEP dropped
fn add(items: &mut VecDeque<Item>, item: Item) {
    items.push_front(item);
    items.truncate(KEEP);
}

fn change(app: &AppHandle, f: impl FnOnce(&mut VecDeque<Item>)) {
    let list: Vec<Item> = {
        let mut items = ITEMS.lock().unwrap();
        f(&mut items);
        items.iter().cloned().collect()
    };
    let _ = app.emit("inbox", list);
}

#[tauri::command]
pub fn get_inbox() -> Vec<Item> {
    ITEMS.lock().unwrap().iter().cloned().collect()
}

/// The bell's card was opened or the bell clicked: everything in it has been seen
#[tauri::command]
pub fn inbox_seen(app: AppHandle) {
    change(&app, |items| items.iter_mut().for_each(|i| i.read = true));
}

/// A reply card was clicked or dismissed: its answer has been seen
#[tauri::command]
pub fn inbox_read_session(app: AppHandle, session: String) {
    change(&app, |items| {
        items
            .iter_mut()
            .filter(|i| i.kind == "reply" && i.session == session)
            .for_each(|i| i.read = true)
    });
}

#[tauri::command]
pub fn inbox_clear(app: AppHandle) {
    change(&app, |items| items.clear());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: u64) -> Item {
        Item {
            id,
            at: 0,
            kind: "reply",
            provider: "claude".into(),
            title: String::new(),
            text: String::new(),
            session: String::new(),
            read: false,
        }
    }

    #[test]
    fn newest_first_and_capped() {
        let mut items = VecDeque::new();
        for id in 1..=KEEP as u64 + 5 {
            add(&mut items, item(id));
        }
        assert_eq!(items.len(), KEEP);
        assert_eq!(items.front().unwrap().id, KEEP as u64 + 5);
        assert_eq!(items.back().unwrap().id, 6);
    }
}
