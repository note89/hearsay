//! The comparison concept: measure ours against a rival on identical audio, one clock.

use crate::scorer;
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct BakeoffSentence {
    pub text: &'static str,
    pub language: &'static str,
}

/// The read-aloud script. One sentence per hold, in order. Same script as the macOS app.
pub const SCRIPT: &[BakeoffSentence] = &[
    BakeoffSentence { text: "Quick update before the demo: the migration finished last night, the staging database is back up, and the p95 latency is stable around 180ms. I still need to rewrite the onboarding email, chase the accountant about the August invoice, and confirm the venue for Thursday. If anything breaks with the OAuth flow, roll back to version 2.4.1 and ping me on Slack instead of email.", language: "en-US" },
    BakeoffSentence { text: "The deploy failed because the OAuth token expired, so CI rolled back to the previous release.", language: "en-US" },
    BakeoffSentence { text: "Ping me at dev@example.com when the Kubernetes cluster is back up.", language: "en-US" },
    BakeoffSentence { text: "The p99 latency spiked to 250ms after we enabled HTTP/2 on the load balancer.", language: "en-US" },
    BakeoffSentence { text: "Add a TODO to refactor the parseTranscript function before Thursday's demo.", language: "en-US" },
    BakeoffSentence { text: "Schedule the retro for 3pm CET and invite both the Lisbon and Stockholm teams.", language: "en-US" },
    BakeoffSentence { text: "I need three things: update the invoice, email the accountant, and book the flights.", language: "en-US" },
    BakeoffSentence { text: "The build takes 4 minutes and 30 seconds, down from 7 minutes.", language: "en-US" },
    BakeoffSentence { text: "Their deployment won't work there, and they're aware of it.", language: "en-US" },
    BakeoffSentence { text: "Merge the pull request from Alex and tag version 2.4.1.", language: "en-US" },
    BakeoffSentence { text: "The invoice totals €1,250 plus 23% VAT.", language: "en-US" },
    BakeoffSentence { text: "Let's use PostgreSQL instead of SQLite for the order database.", language: "en-US" },
    BakeoffSentence { text: "Honestly the overlay looks great, ship it.", language: "en-US" },
    BakeoffSentence { text: "Hej, kan du skicka fakturan för augusti senast på fredag?", language: "sv-SE" },
    BakeoffSentence { text: "Kan du pusha branchen till GitHub innan standupen imorgon?", language: "sv-SE" },
    BakeoffSentence { text: "Fakturan är på tolvtusen kronor exklusive moms.", language: "sv-SE" },
    BakeoffSentence { text: "Boka två biljetter till Lissabon den fjortonde september.", language: "sv-SE" },
    BakeoffSentence { text: "Olá, podes enviar a fatura de agosto até sexta-feira?", language: "pt-PT" },
    BakeoffSentence { text: "Marca dois bilhetes para Lisboa no dia catorze de setembro.", language: "pt-PT" },
];

/// What the rival did for one take. The on-disk format is flat (status + optional fields) and
/// shared with the macOS app; decoding parses it into this union and drops illegal lines.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum RivalOutcome {
    Landed { text: String, ms: u64 },
    Unobservable,
    TimedOut,
    Abandoned,
}

impl RivalOutcome {
    pub fn status(&self) -> &'static str {
        match self {
            RivalOutcome::Landed { .. } => "landed",
            RivalOutcome::Unobservable => "unobservable",
            RivalOutcome::TimedOut => "timedOut",
            RivalOutcome::Abandoned => "abandoned",
        }
    }
}

#[derive(Clone, PartialEq, Debug)]
pub struct BakeoffRecord {
    pub at: f64,
    pub app: String,
    pub engine: String,
    /// The script sentence on screen when this take was recorded — alignment as a fact on the record.
    pub expected: Option<String>,
    pub spoken: String,
    pub ours: String,
    pub ours_ms: u64,
    pub rival: RivalOutcome,
}

#[derive(Serialize, Deserialize)]
struct FlatRecord {
    at: f64,
    app: String,
    engine: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    expected: Option<String>,
    spoken: String,
    ours: String,
    #[serde(rename = "oursMs")]
    ours_ms: u64,
    #[serde(rename = "rivalStatus")]
    rival_status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    rival: Option<String>,
    #[serde(rename = "rivalMs", default, skip_serializing_if = "Option::is_none")]
    rival_ms: Option<u64>,
}

impl Serialize for BakeoffRecord {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let (rival, rival_ms) = match &self.rival {
            RivalOutcome::Landed { text, ms } => (Some(text.clone()), Some(*ms)),
            _ => (None, None),
        };
        FlatRecord {
            at: self.at,
            app: self.app.clone(),
            engine: self.engine.clone(),
            expected: self.expected.clone(),
            spoken: self.spoken.clone(),
            ours: self.ours.clone(),
            ours_ms: self.ours_ms,
            rival_status: self.rival.status().to_string(),
            rival,
            rival_ms,
        }
        .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for BakeoffRecord {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let flat = FlatRecord::deserialize(deserializer)?;
        let rival = match (flat.rival_status.as_str(), flat.rival, flat.rival_ms) {
            ("landed", Some(text), Some(ms)) => RivalOutcome::Landed { text, ms },
            ("unobservable", None, None) => RivalOutcome::Unobservable,
            ("timedOut", None, None) => RivalOutcome::TimedOut,
            ("abandoned", None, None) => RivalOutcome::Abandoned,
            _ => return Err(serde::de::Error::custom("illegal rival state")),
        };
        Ok(BakeoffRecord { at: flat.at, app: flat.app, engine: flat.engine, expected: flat.expected, spoken: flat.spoken, ours: flat.ours, ours_ms: flat.ours_ms, rival })
    }
}

/// The comparison run: records in memory for the pane, appended to bakeoff.jsonl on disk.
pub struct BakeoffStore {
    dir: PathBuf,
    file: PathBuf,
    pub records: Vec<BakeoffRecord>,
    /// A session records only into the run it started in.
    pub run_id: String,
}

impl BakeoffStore {
    pub fn new(dir: &Path) -> Self {
        let file = dir.join("bakeoff.jsonl");
        let records = fs::read_to_string(&file)
            .map(|c| c.lines().filter_map(|l| serde_json::from_str(l).ok()).collect())
            .unwrap_or_default();
        Self { dir: dir.to_path_buf(), file, records, run_id: uuid::Uuid::new_v4().to_string() }
    }

    pub fn append(&mut self, record: BakeoffRecord) {
        if let Ok(mut line) = serde_json::to_string(&record) {
            line.push('\n');
            let _ = fs::create_dir_all(&self.dir);
            if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&self.file) {
                let _ = f.write_all(line.as_bytes());
            }
            crate::keystore::restrict_permissions(&self.file);
        }
        self.records.push(record);
    }

    /// Removes the newest take so the script position falls back to it.
    pub fn delete_last(&mut self) {
        if self.records.pop().is_some() {
            self.rewrite();
        }
    }

    /// Archives the current run and starts fresh under a new identity.
    pub fn reset_run(&mut self) {
        if self.file.exists() {
            let stamp = crate::history::now() as u64;
            let _ = fs::rename(&self.file, self.dir.join(format!("bakeoff.run-{stamp}.jsonl")));
        }
        self.records.clear();
        self.run_id = uuid::Uuid::new_v4().to_string();
    }

    pub fn delete_all_runs(&mut self) {
        if let Ok(entries) = fs::read_dir(&self.dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.starts_with("bakeoff") && name.ends_with(".jsonl") {
                    let _ = fs::remove_file(entry.path());
                }
            }
        }
        self.records.clear();
        self.run_id = uuid::Uuid::new_v4().to_string();
    }

    pub fn archived_run_count(&self) -> usize {
        fs::read_dir(&self.dir)
            .map(|d| d.flatten().filter(|e| { let n = e.file_name().to_string_lossy().to_string(); n.starts_with("bakeoff.run-") && n.ends_with(".jsonl") }).count())
            .unwrap_or(0)
    }

    fn rewrite(&self) {
        let mut data = String::new();
        for record in &self.records {
            if let Ok(line) = serde_json::to_string(record) {
                data.push_str(&line);
                data.push('\n');
            }
        }
        let _ = fs::write(&self.file, data);
        crate::keystore::restrict_permissions(&self.file);
    }
}

#[derive(Clone, Debug)]
pub struct ScoredTake {
    pub record: BakeoffRecord,
    pub expected: String,
    pub ours_wer: f64,
    pub rival_wer: Option<f64>,
}

#[derive(Clone, Debug)]
pub struct EngineSummary {
    pub engine_key: String,
    pub takes: usize,
    pub mean_ours_wer: f64,
    pub mean_ours_ms: u64,
    pub mean_rival_wer: f64,
    pub mean_rival_ms: u64,
}

/// Scores a run: takes with an expected sentence, per-engine means over mutually scored takes,
/// and the verdict counts. Pure over records.
#[derive(Clone, Debug, Default)]
pub struct RunSummary {
    pub takes: Vec<ScoredTake>,
    pub engines: Vec<EngineSummary>,
    pub wins: usize,
    pub losses: usize,
    pub ties: usize,
}

impl RunSummary {
    pub fn decided(&self) -> usize {
        self.wins + self.losses + self.ties
    }

    pub fn from_records(records: &[BakeoffRecord]) -> Self {
        let mut summary = RunSummary::default();
        let mut sums: std::collections::BTreeMap<String, (usize, f64, u64, f64, u64)> = Default::default();
        for record in records {
            let Some(expected) = record.expected.clone() else { continue };
            let ours = scorer::wer(&expected, &record.ours);
            let mut rival_wer = None;
            if let RivalOutcome::Landed { text, ms } = &record.rival {
                let w = scorer::wer(&expected, text);
                rival_wer = Some(w);
                let sum = sums.entry(record.engine.clone()).or_default();
                sum.0 += 1;
                sum.1 += ours;
                sum.2 += record.ours_ms;
                sum.3 += w;
                sum.4 += ms;
                if ours < w { summary.wins += 1 } else if w < ours { summary.losses += 1 } else { summary.ties += 1 }
            }
            summary.takes.push(ScoredTake { record: record.clone(), expected, ours_wer: ours, rival_wer });
        }
        summary.engines = sums
            .into_iter()
            .map(|(engine_key, (n, ow, om, rw, rm))| EngineSummary {
                engine_key,
                takes: n,
                mean_ours_wer: ow / n as f64,
                mean_ours_ms: om / n as u64,
                mean_rival_wer: rw / n as f64,
                mean_rival_ms: rm / n as u64,
            })
            .collect();
        summary
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn take(expected: Option<&str>, ours: &str, ours_ms: u64, rival: RivalOutcome) -> BakeoffRecord {
        BakeoffRecord { at: 0.0, app: "T".into(), engine: "whisper/base.en".into(), expected: expected.map(String::from), spoken: ours.into(), ours: ours.into(), ours_ms, rival }
    }

    #[test]
    fn summary_counts_and_means() {
        let records = vec![
            take(Some("the cache is stale"), "the cache is stale", 300, RivalOutcome::Landed { text: "the cash is stale".into(), ms: 900 }),
            take(Some("send the invoice"), "send the voice", 200, RivalOutcome::Landed { text: "send the invoice".into(), ms: 700 }),
            take(Some("hello there"), "hello there", 100, RivalOutcome::TimedOut),
            take(None, "x", 1, RivalOutcome::Unobservable),
        ];
        let summary = RunSummary::from_records(&records);
        assert_eq!(summary.takes.len(), 3);
        assert_eq!((summary.wins, summary.losses, summary.ties), (1, 1, 0));
        assert_eq!(summary.engines[0].takes, 2);
        assert_eq!((summary.engines[0].mean_ours_ms, summary.engines[0].mean_rival_ms), (250, 800));
        assert!(summary.takes[2].rival_wer.is_none());
    }

    #[test]
    fn record_round_trips_and_rejects_illegal_states() {
        let record = take(Some("a"), "a", 1, RivalOutcome::Landed { text: "b".into(), ms: 5 });
        let json = serde_json::to_string(&record).unwrap();
        assert!(json.contains("\"rivalStatus\":\"landed\""));
        let back: BakeoffRecord = serde_json::from_str(&json).unwrap();
        assert_eq!(back, record);
        let illegal = r#"{"at":0,"app":"T","engine":"e","spoken":"x","ours":"x","oursMs":1,"rivalStatus":"landed"}"#;
        assert!(serde_json::from_str::<BakeoffRecord>(illegal).is_err());
    }
}
