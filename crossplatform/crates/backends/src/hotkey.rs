use crate::DisplayServer;
use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum GestureEvent {
    Pressed,
    Released,
}

/// Whether the chord is currently down, as one source reports it. Transitions are the events.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum ChordState {
    Down,
    Up,
}

/// The utterance concept's mechanism: a system-wide push-to-talk chord with press and release.
/// fn is not a modifier off-Mac, so the default is Ctrl+Alt+Space. Registered with the window
/// system where one exists; read from the keyboard devices on Wayland, which has no global hotkey.
pub struct HoldGestureMonitor {
    source: GestureSource,
    held: bool,
}

enum GestureSource {
    WindowSystem { _manager: GlobalHotKeyManager, id: u32 },
    #[cfg(target_os = "linux")]
    KeyboardDevices(keyboard_devices::ChordReader),
}

#[derive(Debug, thiserror::Error)]
pub enum GestureMonitorFailure {
    #[error("hotkey registration: {0}")]
    Registration(String),
    #[error("Wayland session: there is no global hotkey, and the keyboard devices could not be read ({0}). Add yourself to the input group — sudo usermod -aG input $USER — then log out and in.")]
    KeyboardDevices(String),
}

impl HoldGestureMonitor {
    pub fn default_chord() -> HotKey {
        HotKey::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::Space)
    }

    pub fn new(chord: HotKey) -> Result<Self, GestureMonitorFailure> {
        let source = match DisplayServer::current() {
            #[cfg(target_os = "linux")]
            DisplayServer::Wayland => GestureSource::KeyboardDevices(keyboard_devices::ChordReader::open().map_err(GestureMonitorFailure::KeyboardDevices)?),
            _ => Self::register(chord)?,
        };
        Ok(Self { source, held: false })
    }

    fn register(chord: HotKey) -> Result<GestureSource, GestureMonitorFailure> {
        let manager = GlobalHotKeyManager::new().map_err(|e| GestureMonitorFailure::Registration(e.to_string()))?;
        manager.register(chord).map_err(|e| GestureMonitorFailure::Registration(e.to_string()))?;
        Ok(GestureSource::WindowSystem { _manager: manager, id: chord.id() })
    }

    /// Where the chord is heard, for the settings pane and the log.
    pub fn source_label(&self) -> &'static str {
        match self.source {
            GestureSource::WindowSystem { .. } => "system hotkey",
            #[cfg(target_os = "linux")]
            GestureSource::KeyboardDevices(_) => "keyboard devices under /dev/input",
        }
    }

    /// Drain pending chord changes; call from the UI loop. Only transitions are reported.
    pub fn poll(&mut self) -> Vec<GestureEvent> {
        let mut events = Vec::new();
        match &mut self.source {
            GestureSource::WindowSystem { id, .. } => {
                while let Ok(event) = GlobalHotKeyEvent::receiver().try_recv() {
                    if event.id() != *id {
                        continue;
                    }
                    let state = match event.state() {
                        HotKeyState::Pressed => ChordState::Down,
                        HotKeyState::Released => ChordState::Up,
                    };
                    Self::transition(&mut self.held, state, &mut events);
                }
            }
            #[cfg(target_os = "linux")]
            GestureSource::KeyboardDevices(reader) => {
                for state in reader.poll() {
                    Self::transition(&mut self.held, state, &mut events);
                }
            }
        }
        events
    }

    fn transition(held: &mut bool, state: ChordState, events: &mut Vec<GestureEvent>) {
        match (state, *held) {
            (ChordState::Down, false) => {
                *held = true;
                events.push(GestureEvent::Pressed);
            }
            (ChordState::Up, true) => {
                *held = false;
                events.push(GestureEvent::Released);
            }
            _ => {}
        }
    }
}

#[cfg(target_os = "linux")]
mod keyboard_devices {
    use super::ChordState;
    use evdev::{Device, EventSummary, KeyCode};
    use std::os::fd::AsRawFd;

    /// Ctrl+Alt+Space read straight from every keyboard under /dev/input. Non-blocking; the UI
    /// loop polls. Needs read access to the event nodes (the `input` group on most distributions).
    pub struct ChordReader {
        devices: Vec<Device>,
        ctrl: bool,
        alt: bool,
        space: bool,
    }

    impl ChordReader {
        pub fn open() -> Result<Self, String> {
            let mut devices = Vec::new();
            for (_, device) in evdev::enumerate() {
                let Some(keys) = device.supported_keys() else { continue };
                if keys.contains(KeyCode::KEY_SPACE) && keys.contains(KeyCode::KEY_LEFTCTRL) {
                    // SAFETY: fcntl on a descriptor this Device owns; O_NONBLOCK only changes read behaviour.
                    unsafe {
                        libc::fcntl(device.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK);
                    }
                    devices.push(device);
                }
            }
            if devices.is_empty() {
                let nodes_exist = std::fs::read_dir("/dev/input")
                    .map(|dir| dir.flatten().any(|entry| entry.file_name().to_string_lossy().starts_with("event")))
                    .unwrap_or(false);
                return Err(if nodes_exist { "no readable keyboard: permission denied on /dev/input/event*".into() } else { "no input devices under /dev/input".into() });
            }
            Ok(Self { devices, ctrl: false, alt: false, space: false })
        }

        /// The chord state after each relevant key event, in order.
        pub fn poll(&mut self) -> Vec<ChordState> {
            let mut states = Vec::new();
            for device in &mut self.devices {
                let Ok(events) = device.fetch_events() else { continue };
                for event in events {
                    let EventSummary::Key(_, key, value) = event.destructure() else { continue };
                    let down = match value {
                        0 => false,
                        1 => true,
                        _ => continue, // autorepeat
                    };
                    match key {
                        KeyCode::KEY_LEFTCTRL | KeyCode::KEY_RIGHTCTRL => self.ctrl = down,
                        KeyCode::KEY_LEFTALT | KeyCode::KEY_RIGHTALT => self.alt = down,
                        KeyCode::KEY_SPACE => self.space = down,
                        _ => continue,
                    }
                    states.push(if self.ctrl && self.alt && self.space { ChordState::Down } else { ChordState::Up });
                }
            }
            states
        }
    }
}
