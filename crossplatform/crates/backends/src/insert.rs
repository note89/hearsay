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

    fn paste_keystroke(&self) -> bool {
        let Ok(mut enigo) = Enigo::new(&Settings::default()) else { return false };
        let modifier = if cfg!(target_os = "macos") { Key::Meta } else { Key::Control };
        enigo.key(modifier, Direction::Press).is_ok()
            && enigo.key(Key::Unicode('v'), Direction::Click).is_ok()
            && enigo.key(modifier, Direction::Release).is_ok()
    }
}

impl Default for PasteInserter {
    fn default() -> Self {
        Self::new()
    }
}

impl Inserter for PasteInserter {
    fn insert(&self, text: &str) -> InsertionOutcome {
        let Ok(mut clipboard) = arboard::Clipboard::new() else {
            return InsertionOutcome::CopiedToClipboard(InsertionBlock::AllStrategiesFailed);
        };
        let previous = clipboard.get_text().ok();
        if clipboard.set_text(text).is_err() {
            return InsertionOutcome::CopiedToClipboard(InsertionBlock::AllStrategiesFailed);
        }
        if !self.paste_keystroke() {
            return InsertionOutcome::CopiedToClipboard(InsertionBlock::AllStrategiesFailed);
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
