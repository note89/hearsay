use crate::{DisplayServer, KeystrokeInjection};
use enigo::{Direction, Enigo, Key, Keyboard, Settings};
use hearsay_core::session::{InsertionBlock, InsertionEvidence, InsertionOutcome, Inserter};
use std::thread;
use std::time::Duration;

/// Clipboard + paste keystroke. No portable way to verify the target accepted it, so the evidence is
/// always `Posted`; the previous clipboard is restored only if nothing else wrote to it meanwhile.
/// The key-event handle is created per call on the calling thread (it is not `Send` on macOS).
pub struct PasteInserter;

const SETTLE: Duration = Duration::from_millis(250);

impl PasteInserter {
    pub fn new() -> Self {
        Self
    }

    fn paste_keystroke(&self) -> Result<(), String> {
        let mut enigo = Enigo::new(&Settings::default()).map_err(|e| format!("no input connection: {e}"))?;
        let modifier = if cfg!(target_os = "macos") { Key::Meta } else { Key::Control };
        enigo.key(modifier, Direction::Press).map_err(|e| e.to_string())?;
        enigo.key(Key::Unicode('v'), Direction::Click).map_err(|e| e.to_string())?;
        enigo.key(modifier, Direction::Release).map_err(|e| e.to_string())
    }
}

impl Default for PasteInserter {
    fn default() -> Self {
        Self::new()
    }
}

impl Inserter for PasteInserter {
    fn insert(&self, text: &str) -> InsertionOutcome {
        let mut clipboard = match arboard::Clipboard::new() {
            Ok(clipboard) => clipboard,
            Err(e) => {
                log::warn!("insert: clipboard unavailable: {e}");
                return InsertionOutcome::Lost;
            }
        };
        let previous = clipboard.get_text().ok();
        if let Err(e) = clipboard.set_text(text) {
            log::warn!("insert: clipboard write failed: {e}");
            return InsertionOutcome::Lost;
        }
        if DisplayServer::current() == DisplayServer::Wayland && KeystrokeInjection::probe() == KeystrokeInjection::Refused {
            // GNOME and friends: native windows ignore injected keystrokes, XWayland windows still
            // take the paste. Best effort, clipboard kept for a manual Ctrl+V, and the pill says so.
            let _ = self.paste_keystroke();
            return InsertionOutcome::CopiedToClipboard(InsertionBlock::InjectionUnavailable);
        }
        if let Err(e) = self.paste_keystroke() {
            log::warn!("insert: paste keystroke failed: {e}");
            return InsertionOutcome::CopiedToClipboard(InsertionBlock::KeystrokeFailed);
        }
        thread::sleep(SETTLE);
        if let Some(previous) = previous {
            if clipboard.get_text().ok().as_deref() == Some(text) {
                let _ = clipboard.set_text(previous);
            }
        }
        InsertionOutcome::Inserted { evidence: InsertionEvidence::Posted }
    }

    fn copy(&self, text: &str) {
        if let Ok(mut clipboard) = arboard::Clipboard::new() {
            let _ = clipboard.set_text(text);
        }
    }
}
