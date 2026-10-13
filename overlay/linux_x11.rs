//! Linux: turn on Xlib's thread support before anything else touches X11.
//!
//! Some machines abort at startup with
//!
//! ```text
//! [xcb] Unknown sequence number while processing reply
//! [xcb] Most likely this is a multi-threaded client and XInitThreads has not been called
//! codenotch: xcb_io.c: _XReply: Assertion `!xcb_xlib_threads_sequence_lost' failed.
//! ```
//!
//! That is Xlib being used from more than one thread (the WebKitGTK / graphics-driver side of a
//! Tauri window does this on some GPU and driver combinations) in a process that never asked Xlib
//! to lock. The remedy GTK's own maintainers give is to call `XInitThreads()` first thing, before
//! GTK is initialised, since GTK does not do it for you. Firefox, Chromium and Qt do the same.
//!
//! The call is cheap and harmless on machines that never hit the problem. libX11 is opened at run
//! time through `x11-dl` (already part of the Tauri dependency tree), so nothing is linked in and a
//! machine without libX11 simply skips it.

/// Call once, at the top of `main`, before the event loop or any window exists.
/// Returns whether Xlib accepted the request.
pub fn init_threads() -> bool {
    match x11_dl::xlib::Xlib::open() {
        Ok(xlib) => {
            // Nonzero is success. Calling it a second time is a no-op.
            let ok = unsafe { (xlib.XInitThreads)() } != 0;
            // Keep libX11 mapped: its thread-lock state lives inside the library, and dropping the
            // handle would close it.
            std::mem::forget(xlib);
            if !ok {
                crate::applog("xlib: XInitThreads reported failure");
            }
            ok
        }
        Err(e) => {
            crate::applog(&format!("xlib: libX11 not loadable, skipping XInitThreads ({e:?})"));
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Whether this machine has libX11 at all, decided the same way the code under test does.
    fn has_xlib() -> bool {
        x11_dl::xlib::Xlib::open().is_ok()
    }

    #[test]
    fn it_works_without_a_display_and_is_safe_to_repeat() {
        // XInitThreads needs no X server, so this runs on a headless machine too.
        let first = init_threads();
        let second = init_threads();
        if has_xlib() {
            assert!(first, "libX11 is present, XInitThreads should succeed");
            assert!(second, "a repeat call must stay harmless");
        } else {
            assert!(!first && !second, "no libX11: skipped, not crashed");
        }
    }

    #[test]
    fn it_is_safe_to_call_while_other_threads_exist() {
        let workers: Vec<_> = (0..4).map(|_| std::thread::spawn(init_threads)).collect();
        for w in workers {
            let r = w.join().expect("no panic");
            assert_eq!(r, has_xlib());
        }
    }
}
