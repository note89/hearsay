use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub enum RecordedOutcome {
    #[serde(rename = "inserted")]
    Inserted,
    #[serde(rename = "copiedToClipboard")]
    CopiedToClipboard,
    #[serde(rename = "targetLost")]
    TargetLost,
}

#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct DictationRecord {
    pub id: String,
    /// Seconds since the Unix epoch.
    pub at: f64,
    pub spoken: String,
    pub delivered: String,
    #[serde(rename = "appName")]
    pub app_name: String,
    pub outcome: RecordedOutcome,
}

impl DictationRecord {
    pub fn new(spoken: &str, delivered: &str, app_name: &str, outcome: RecordedOutcome) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            at: now(),
            spoken: spoken.to_string(),
            delivered: delivered.to_string(),
            app_name: app_name.to_string(),
            outcome,
        }
    }
}

pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// Newest first, capped. The trash of dictation: whatever did not land is still here.
pub struct HistoryStore {
    file: PathBuf,
    cap: usize,
    pub records: Vec<DictationRecord>,
}

impl HistoryStore {
    pub fn new(dir: &Path) -> Self {
        let file = dir.join("history.json");
        let records = fs::read_to_string(&file).ok().and_then(|c| serde_json::from_str(&c).ok()).unwrap_or_default();
        Self { file, cap: 200, records }
    }

    pub fn record(&mut self, record: DictationRecord) {
        self.records.insert(0, record);
        self.records.truncate(self.cap);
        self.save();
    }

    pub fn delete(&mut self, id: &str) {
        self.records.retain(|r| r.id != id);
        self.save();
    }

    pub fn clear(&mut self) {
        self.records.clear();
        self.save();
    }

    fn save(&self) {
        if let Some(dir) = self.file.parent() {
            let _ = fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_vec(&self.records) {
            let _ = fs::write(&self.file, json);
            crate::keystore::restrict_permissions(&self.file);
        }
    }
}
