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
    /// Engines left out of a bake-off race, by wire key. Exclusions, so a new engine races by default.
    #[serde(default)]
    race_exclusions: Vec<String>,
}

fn yes() -> bool {
    true
}

pub struct Settings {
    file: PathBuf,
    pub engine: Engine,
    pub polish: PolishMode,
    pub history_enabled: bool,
    race_exclusions: Vec<String>,
}

impl Settings {
    pub fn load(dir: &Path) -> Self {
        let file = dir.join("settings.json");
        let stored: Option<Stored> = fs::read_to_string(&file).ok().and_then(|c| serde_json::from_str(&c).ok());
        let (engine, polish, history_enabled, race_exclusions) = match stored {
            Some(s) => (
                Engine::parse(&s.engine).unwrap_or_else(Engine::default_engine),
                match s.polish.as_str() { "light" => PolishMode::Light, "full" => PolishMode::Full, _ => PolishMode::Off },
                s.history_enabled,
                s.race_exclusions,
            ),
            None => (Engine::default_engine(), PolishMode::Off, true, Vec::new()),
        };
        Self { file, engine, polish, history_enabled, race_exclusions }
    }

    pub fn is_racing(&self, engine: Engine) -> bool {
        !self.race_exclusions.contains(&engine.wire_key())
    }

    pub fn toggle_racing(&mut self, engine: Engine) {
        let key = engine.wire_key();
        match self.race_exclusions.iter().position(|k| *k == key) {
            Some(index) => { self.race_exclusions.remove(index); }
            None => self.race_exclusions.push(key),
        }
        self.save();
    }

    pub fn save(&self) {
        let stored = Stored {
            engine: self.engine.wire_key(),
            polish: match self.polish { PolishMode::Off => "off", PolishMode::Light => "light", PolishMode::Full => "full" }.to_string(),
            history_enabled: self.history_enabled,
            race_exclusions: self.race_exclusions.clone(),
        };
        if let Some(dir) = self.file.parent() {
            let _ = fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_string_pretty(&stored) {
            let _ = fs::write(&self.file, json);
        }
    }
}
