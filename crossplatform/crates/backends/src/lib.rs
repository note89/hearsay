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

/// What a Wayland compositor lets us do with keystrokes.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum KeystrokeInjection {
    /// zwp_virtual_keyboard_v1 is offered: Hyprland, Sway, river, and other wlroots compositors.
    VirtualKeyboard,
    /// Not offered: GNOME. Only XWayland windows would receive a keystroke.
    Refused,
}

impl KeystrokeInjection {
    #[cfg(target_os = "linux")]
    pub fn probe() -> Self {
        if wayland_probe::has_global("zwp_virtual_keyboard_manager_v1") { KeystrokeInjection::VirtualKeyboard } else { KeystrokeInjection::Refused }
    }

    #[cfg(not(target_os = "linux"))]
    pub fn probe() -> Self {
        KeystrokeInjection::Refused
    }
}

#[cfg(target_os = "linux")]
mod wayland_probe {
    use wayland_client::protocol::wl_registry;
    use wayland_client::{Connection, Dispatch, QueueHandle};

    struct Globals(Vec<String>);

    impl Dispatch<wl_registry::WlRegistry, ()> for Globals {
        fn event(state: &mut Self, _: &wl_registry::WlRegistry, event: wl_registry::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
            if let wl_registry::Event::Global { interface, .. } = event {
                state.0.push(interface);
            }
        }
    }

    /// One registry roundtrip against $WAYLAND_DISPLAY. False when there is no compositor to ask.
    pub fn has_global(name: &str) -> bool {
        let Ok(connection) = Connection::connect_to_env() else { return false };
        let mut queue = connection.new_event_queue();
        let handle = queue.handle();
        let _registry = connection.display().get_registry(&handle, ());
        let mut globals = Globals(Vec::new());
        if queue.roundtrip(&mut globals).is_err() {
            return false;
        }
        globals.0.iter().any(|g| g == name)
    }
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
