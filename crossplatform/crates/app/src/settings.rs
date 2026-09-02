use hearsay_core::engine::Engine;
use hearsay_core::session::PolishMode;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

/// Persisted preferences. Engine is stored as its wire key and parsed on load — a stale or
/// unknown key falls back to the default engine rather than being trusted.
#[derive(Serialize, Deserialize)]
struct Stored {
    engine: String,
    polish: String,
    #[serde(default = "yes")]
    history_enabled: bool,
}

fn yes() -> bool {
    true
}

pub struct Settings {
    file: PathBuf,
    pub engine: Engine,
    pub polish: PolishMode,
    pub history_enabled: bool,
}

impl Settings {
    pub fn load(dir: &Path) -> Self {
        let file = dir.join("settings.json");
        let stored: Option<Stored> = fs::read_to_string(&file).ok().and_then(|c| serde_json::from_str(&c).ok());
        let (engine, polish, history_enabled) = match stored {
            Some(s) => (
                Engine::parse(&s.engine).unwrap_or_else(Engine::default_engine),
                match s.polish.as_str() { "light" => PolishMode::Light, "full" => PolishMode::Full, _ => PolishMode::Off },
                s.history_enabled,
            ),
            None => (Engine::default_engine(), PolishMode::Off, true),
        };
        Self { file, engine, polish, history_enabled }
    }

    pub fn save(&self) {
        let stored = Stored {
            engine: self.engine.wire_key(),
            polish: match self.polish { PolishMode::Off => "off", PolishMode::Light => "light", PolishMode::Full => "full" }.to_string(),
            history_enabled: self.history_enabled,
        };
        if let Some(dir) = self.file.parent() {
            let _ = fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_string_pretty(&stored) {
            let _ = fs::write(&self.file, json);
        }
    }
}
