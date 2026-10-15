//! Sounds: a Claude Code turn that ends (or stops to ask for permission), like the macOS app's
//! session chime, and the reset card's notification sound, which upstream leaves silent off Windows.

use crate::state::{ST_ATTENTION, ST_DONE, ST_RUNNING};

/// The freedesktop sound to play when a session goes from `before` to `after`, if any. Only the
/// falling edge of work counts: a session that was already done and is now asking (Claude Code's
/// "waiting for your input" nudge) or one the watcher meets for the first time stays quiet.
pub fn sound_for(before: &str, after: &str) -> Option<&'static str> {
    if before != ST_RUNNING {
        return None;
    }
    match after {
        ST_DONE => Some("complete"),
        ST_ATTENTION => Some("message-new-instant"),
        _ => None,
    }
}

/// Plays a freedesktop sound by name, off the calling thread. canberra-gtk-play goes through the
/// desktop's sound theme and honours "alert sounds off"; the stock file through paplay / pw-play
/// is the fallback only when it is not installed, so a muted desktop stays muted.
#[cfg(target_os = "linux")]
pub fn play(name: &'static str) {
    use std::process::{Command, Stdio};
    std::thread::spawn(move || {
        let file = format!("/usr/share/sounds/freedesktop/stereo/{name}.oga");
        let tries: [(&str, Vec<&str>); 3] = [
            ("canberra-gtk-play", vec!["-i", name]),
            ("paplay", vec![&file]),
            ("pw-play", vec![&file]),
        ];
        for (prog, args) in tries {
            let ran = Command::new(prog)
                .args(args)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
            if ran.is_ok() {
                return;
            }
        }
    });
}

#[cfg(not(target_os = "linux"))]
pub fn play(_name: &'static str) {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::ST_IDLE;

    #[test]
    fn only_the_end_of_a_running_turn_chimes() {
        assert_eq!(sound_for(ST_RUNNING, ST_DONE), Some("complete"));
        assert_eq!(sound_for(ST_RUNNING, ST_ATTENTION), Some("message-new-instant"));
        assert_eq!(sound_for(ST_RUNNING, ST_RUNNING), None);
        assert_eq!(sound_for(ST_DONE, ST_ATTENTION), None);
        assert_eq!(sound_for(ST_IDLE, ST_DONE), None);
        assert_eq!(sound_for(ST_ATTENTION, ST_DONE), None);
    }
}
