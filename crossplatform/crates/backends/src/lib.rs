//! Mechanisms. Each file is one platform capability behind one concept; none of them know about
//! the others or about the session.

pub mod audio;
pub mod hotkey;
pub mod insert;

/// The session's display server: what a global hotkey and a paste keystroke can reach.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DisplayServer {
    X11,
    /// No global hotkeys, no injected keystrokes into native windows.
    Wayland,
    /// macOS or Windows: the OS itself.
    System,
}

impl DisplayServer {
    pub fn current() -> Self {
        if !cfg!(target_os = "linux") {
            return DisplayServer::System;
        }
        let session = std::env::var("XDG_SESSION_TYPE").unwrap_or_default();
        if session == "wayland" || (session.is_empty() && std::env::var_os("WAYLAND_DISPLAY").is_some()) {
            DisplayServer::Wayland
        } else {
            DisplayServer::X11
        }
    }
}
