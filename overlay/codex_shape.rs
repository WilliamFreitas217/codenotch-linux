//! Diagnostic only: describe the *shape* of a JSON value for the run log.
//!
//! Used once per run on the few Codex usage fields whose layout is not known yet (credits,
//! spend_control, ...), so the provider can be taught to read them. Numbers, booleans and nulls are
//! shown as they are (they are quotas and flags, not secrets); strings are cut short; a string that
//! looks like an address, or a value stored under a key that looks like a credential, is replaced.

use serde_json::Value;

const MAX_DEPTH: usize = 5;
const MAX_STR: usize = 40;
const MAX_ITEMS: usize = 24;

fn secret_key(key: &str) -> bool {
    let k = key.to_ascii_lowercase();
    ["token", "secret", "password", "key", "email", "authorization", "cookie"]
        .iter()
        .any(|bad| k.contains(bad))
}

pub fn shape(v: &Value) -> String {
    render(v, 0)
}

fn render(v: &Value, depth: usize) -> String {
    match v {
        Value::Null => "null".into(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => {
            if s.contains('@') {
                return "\"<redacted>\"".into();
            }
            let cut: String = s.chars().take(MAX_STR).collect();
            if s.chars().count() > MAX_STR {
                format!("{cut:?}…")
            } else {
                format!("{cut:?}")
            }
        }
        Value::Array(items) => {
            if depth >= MAX_DEPTH {
                return "[…]".into();
            }
            let shown: Vec<String> = items.iter().take(MAX_ITEMS).map(|i| render(i, depth + 1)).collect();
            let more = items.len().saturating_sub(MAX_ITEMS);
            if more > 0 {
                format!("[{}, +{more} more]", shown.join(", "))
            } else {
                format!("[{}]", shown.join(", "))
            }
        }
        Value::Object(map) => {
            if depth >= MAX_DEPTH {
                return "{…}".into();
            }
            let shown: Vec<String> = map
                .iter()
                .take(MAX_ITEMS)
                .map(|(k, val)| {
                    if secret_key(k) {
                        format!("{k}: \"<redacted>\"")
                    } else {
                        format!("{k}: {}", render(val, depth + 1))
                    }
                })
                .collect();
            let more = map.len().saturating_sub(MAX_ITEMS);
            if more > 0 {
                format!("{{{}, +{more} more}}", shown.join(", "))
            } else {
                format!("{{{}}}", shown.join(", "))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn scalars_and_structure_are_kept() {
        let v = json!({"limit": 600, "used": 2, "enabled": true, "next": null, "unit": "credits"});
        let out = shape(&v);
        for part in ["limit: 600", "used: 2", "enabled: true", "next: null", "unit: \"credits\""] {
            assert!(out.contains(part), "{out}");
        }
    }

    #[test]
    fn addresses_and_credential_keys_never_show() {
        let v = json!({"owner": "someone@example.com", "access_token": "abc123", "Api_Key": "k", "ok": "fine"});
        let out = shape(&v);
        assert!(!out.contains("someone"), "{out}");
        assert!(!out.contains("abc123"), "{out}");
        assert!(!out.contains("\"k\""), "{out}");
        assert!(out.contains("ok: \"fine\""), "{out}");
    }

    #[test]
    fn long_strings_deep_nesting_and_long_arrays_are_bounded() {
        let long = "x".repeat(200);
        assert!(shape(&json!(long)).chars().count() < 60);

        let mut deep = json!(1);
        for _ in 0..20 {
            deep = json!({ "a": deep });
        }
        assert!(shape(&deep).contains("{…}"));

        let many: Vec<u32> = (0..100).collect();
        assert!(shape(&json!(many)).contains("+76 more"));
    }
}
