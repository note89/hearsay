use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum GestureEvent {
    Pressed,
    Released,
}

/// The utterance concept's mechanism: a system-wide push-to-talk chord with press and release.
/// fn is not a modifier off-Mac, so the default is Ctrl+Alt+Space.
pub struct HoldGestureMonitor {
    _manager: GlobalHotKeyManager,
    id: u32,
    held: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum GestureMonitorFailure {
    #[error("hotkey registration: {0}")]
    Registration(String),
}

impl HoldGestureMonitor {
    pub fn default_chord() -> HotKey {
        HotKey::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::Space)
    }

    pub fn new(chord: HotKey) -> Result<Self, GestureMonitorFailure> {
        let manager = GlobalHotKeyManager::new().map_err(|e| GestureMonitorFailure::Registration(e.to_string()))?;
        manager.register(chord).map_err(|e| GestureMonitorFailure::Registration(e.to_string()))?;
        Ok(Self { _manager: manager, id: chord.id(), held: false })
    }

    /// Drain pending hotkey events; call from the UI loop. Only transitions are reported.
    pub fn poll(&mut self) -> Vec<GestureEvent> {
        let mut events = Vec::new();
        while let Ok(event) = GlobalHotKeyEvent::receiver().try_recv() {
            if event.id() != self.id {
                continue;
            }
            match (event.state(), self.held) {
                (HotKeyState::Pressed, false) => {
                    self.held = true;
                    events.push(GestureEvent::Pressed);
                }
                (HotKeyState::Released, true) => {
                    self.held = false;
                    events.push(GestureEvent::Released);
                }
                _ => {}
            }
        }
        events
    }
}
