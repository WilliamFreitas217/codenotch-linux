//! Codex accounts on a workspace (Enterprise / Business) spend plan have no 5-hour or weekly
//! window. Their limit is a monthly spend cap, reported under `spend_control.individual_limit` in
//! the usage reply, and Codex's own `/status` shows it as "Monthly credit limit".
//!
//! The reply, as observed (numbers arrive as strings, `used_percent` is a rounded integer, `unit`
//! is "usd"):
//!
//! ```text
//! spend_control: { individual_limit: { limit: "600", used: "1.78…", remaining: "598.21…",
//!                                      remaining_percent: 100, used_percent: 0,
//!                                      reset_at: 1793491200, reset_after_seconds: 2089132,
//!                                      source: "workspace_spend_controls", unit: "usd" },
//!                  reached: false }
//! ```
//!
//! The fraction is computed from `used / limit` rather than taken from `used_percent`, which
//! reads 0 until the first whole percent is spent.

use crate::usage::LimitWindow;
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};

fn num(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn now_secs() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// The monthly spend cap as a usage window, or None when the account has no such cap.
pub fn spend_window(v: &Value) -> Option<LimitWindow> {
    spend_window_at(v, now_secs())
}

fn spend_window_at(v: &Value, now_secs: f64) -> Option<LimitWindow> {
    let lim = v.get("spend_control")?.get("individual_limit").filter(|x| x.is_object())?;
    let limit = num(lim.get("limit"))?;
    if !(limit > 0.0) {
        return None;
    }
    let used = num(lim.get("used")).or_else(|| num(lim.get("remaining")).map(|r| limit - r))?;

    let reset_secs = num(lim.get("reset_at"))
        .filter(|s| *s > 0.0)
        .or_else(|| num(lim.get("reset_after_seconds")).filter(|s| *s >= 0.0).map(|d| now_secs + d));

    Some(LimitWindow {
        id: "spend".into(),
        label: "Monthly credit limit".into(),
        used: (used / limit).clamp(0.0, 1.0),
        resets_at: reset_secs.map(|s| (s * 1000.0) as u64),
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// The layout logged by a real Enterprise account.
    fn observed() -> Value {
        json!({
            "plan_type": "ent26",
            "rate_limit": null,
            "spend_control": {
                "individual_limit": {
                    "limit": "600",
                    "remaining": "598.2164157629013",
                    "remaining_percent": 100,
                    "reset_after_seconds": 2089132,
                    "reset_at": 1793491200,
                    "source": "workspace_spend_controls",
                    "unit": "usd",
                    "used": "1.7835842370986938",
                    "used_percent": 0
                },
                "reached": false
            }
        })
    }

    #[test]
    fn the_observed_enterprise_reply_becomes_one_window() {
        let w = spend_window_at(&observed(), 0.0).expect("a window");
        assert_eq!(w.id, "spend");
        assert_eq!(w.label, "Monthly credit limit");
        assert!((w.used - 1.7835842370986938 / 600.0).abs() < 1e-12, "{}", w.used);
        assert!(w.used > 0.0, "must not collapse to the rounded 0 percent");
        assert_eq!(w.resets_at, Some(1_793_491_200_000));
    }

    #[test]
    fn it_survives_numbers_that_arrive_as_json_numbers() {
        let v = json!({"spend_control": {"individual_limit": {"limit": 200, "used": 50, "reset_at": 1700000000}}});
        let w = spend_window_at(&v, 0.0).unwrap();
        assert!((w.used - 0.25).abs() < 1e-12);
    }

    #[test]
    fn used_is_derived_from_remaining_when_it_is_missing() {
        let v = json!({"spend_control": {"individual_limit": {"limit": "100", "remaining": "40"}}});
        assert!((spend_window_at(&v, 0.0).unwrap().used - 0.6).abs() < 1e-12);
    }

    #[test]
    fn a_missing_reset_time_falls_back_on_the_delay() {
        let v = json!({"spend_control": {"individual_limit": {"limit": "10", "used": "1", "reset_after_seconds": 100}}});
        assert_eq!(spend_window_at(&v, 1000.0).unwrap().resets_at, Some(1_100_000));
        let none = json!({"spend_control": {"individual_limit": {"limit": "10", "used": "1"}}});
        assert_eq!(spend_window_at(&none, 0.0).unwrap().resets_at, None);
    }

    #[test]
    fn over_the_cap_is_clamped_to_full() {
        let v = json!({"spend_control": {"individual_limit": {"limit": "10", "used": "25"}}});
        assert_eq!(spend_window_at(&v, 0.0).unwrap().used, 1.0);
    }

    #[test]
    fn accounts_without_a_spend_cap_give_nothing() {
        assert!(spend_window_at(&json!({}), 0.0).is_none());
        assert!(spend_window_at(&json!({"spend_control": null}), 0.0).is_none());
        assert!(spend_window_at(&json!({"spend_control": {"individual_limit": null}}), 0.0).is_none());
        assert!(spend_window_at(&json!({"spend_control": {"individual_limit": {"limit": "0", "used": "0"}}}), 0.0).is_none());
        assert!(spend_window_at(&json!({"spend_control": {"individual_limit": {"limit": "abc", "used": "1"}}}), 0.0).is_none());
        assert!(spend_window_at(&json!({"spend_control": {"individual_limit": {"limit": "10"}}}), 0.0).is_none());
    }
}
