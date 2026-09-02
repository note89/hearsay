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
    BakeoffSentence { text: "The p99 latency spiked to 250ms after we enabled HTTP/2 on the load balancer.", language: "en-US" },
    BakeoffSentence { text: "Schedule the retro for 3pm CET and invite both the Lisbon and Stockholm teams.", language: "en-US" },
    BakeoffSentence { text: "The invoice totals €1,250 plus 23% VAT.", language: "en-US" },
    BakeoffSentence { text: "Merge the pull request from Alex and tag version 2.4.1.", language: "en-US" },
    BakeoffSentence { text: "Hej, kan du skicka fakturan för augusti senast på fredag?", language: "sv-SE" },
    BakeoffSentence { text: "Kan du merga branchen innan lunch? The CI is green now.", language: "sv-SE + en-US" },
    BakeoffSentence { text: "Vi deployar till staging ikväll, so don't push anything to main after 6pm.", language: "sv-SE + en-US" },
    BakeoffSentence { text: "Olá, podes enviar a fatura de agosto até sexta-feira?", language: "pt-PT" },
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

/// What one engine made of one take. A timeout or an error is a result, not a missing row:
/// in a benchmark, not answering is a loss.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum EngineOutcome {
    Scored { spoken: String, ours: String, ms: u64 },
    Failed { reason: String },
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct EngineResult {
    /// The engine's wire key.
    pub engine: String,
    pub outcome: EngineOutcome,
}

/// One reading of one sentence: every contender's result and the rival's, timed from the same key-up.
#[derive(Clone, PartialEq, Debug)]
pub struct Take {
    pub id: String,
    pub at: f64,
    pub app: String,
    /// The script sentence on screen when this take was recorded — alignment as a fact on the record.
    pub expected: Option<String>,
    /// Observed once per take, so it lives here and not on each result.
    pub rival: RivalOutcome,
    /// One per engine raced, in race order. Never empty: a take is made from at least one result.
    pub results: Vec<EngineResult>,
}

/// The on-disk line: one per engine result, flat, shared with the macOS app. `take` regroups rows;
/// rows written before races had none and become one take each. `oursStatus` absent means scored.
#[derive(Serialize, Deserialize)]
struct FlatRow {
    at: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    take: Option<String>,
    app: String,
    engine: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    expected: Option<String>,
    #[serde(rename = "oursStatus", default, skip_serializing_if = "Option::is_none")]
    ours_status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    spoken: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ours: Option<String>,
    #[serde(rename = "oursMs", default, skip_serializing_if = "Option::is_none")]
    ours_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    failure: Option<String>,
    #[serde(rename = "rivalStatus")]
    rival_status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    rival: Option<String>,
    #[serde(rename = "rivalMs", default, skip_serializing_if = "Option::is_none")]
    rival_ms: Option<u64>,
}

struct ParsedRow {
    take_id: String,
    at: f64,
    app: String,
    expected: Option<String>,
    rival: RivalOutcome,
    result: EngineResult,
}

impl FlatRow {
    fn from_take(take: &Take, result: &EngineResult) -> Self {
        let (ours_status, spoken, ours, ours_ms, failure) = match &result.outcome {
            EngineOutcome::Scored { spoken, ours, ms } => ("scored", Some(spoken.clone()), Some(ours.clone()), Some(*ms), None),
            EngineOutcome::Failed { reason } => ("failed", None, None, None, Some(reason.clone())),
        };
        let (rival, rival_ms) = match &take.rival {
            RivalOutcome::Landed { text, ms } => (Some(text.clone()), Some(*ms)),
            _ => (None, None),
        };
        FlatRow {
            at: take.at,
            take: Some(take.id.clone()),
            app: take.app.clone(),
            engine: result.engine.clone(),
            expected: take.expected.clone(),
            ours_status: Some(ours_status.to_string()),
            spoken,
            ours,
            ours_ms,
            failure,
            rival_status: take.rival.status().to_string(),
            rival,
            rival_ms,
        }
    }

    /// `None` when the fields do not form a legal state.
    fn parsed(self) -> Option<ParsedRow> {
        let rival = match (self.rival_status.as_str(), self.rival, self.rival_ms) {
            ("landed", Some(text), Some(ms)) => RivalOutcome::Landed { text, ms },
            ("unobservable", None, None) => RivalOutcome::Unobservable,
            ("timedOut", None, None) => RivalOutcome::TimedOut,
            ("abandoned", None, None) => RivalOutcome::Abandoned,
            _ => return None,
        };
        let outcome = match (self.ours_status.as_deref().unwrap_or("scored"), self.spoken, self.ours, self.ours_ms, self.failure) {
            ("scored", Some(spoken), Some(ours), Some(ms), None) => EngineOutcome::Scored { spoken, ours, ms },
            ("failed", None, None, None, Some(reason)) => EngineOutcome::Failed { reason },
            _ => return None,
        };
        Some(ParsedRow {
            take_id: self.take.unwrap_or_else(|| format!("legacy-{}", self.at)),
            at: self.at,
            app: self.app,
            expected: self.expected,
            rival,
            result: EngineResult { engine: self.engine, outcome },
        })
    }
}

impl Take {
    /// JSON lines → takes. Rows regroup by take id in first-seen order; the take's facts come from
    /// its first row; a second row for the same engine in one take is a corrupt line and is dropped.
    pub fn from_jsonl(content: &str) -> Vec<Take> {
        let rows = content.lines().filter_map(|line| serde_json::from_str::<FlatRow>(line).ok()?.parsed());
        let mut takes: Vec<Take> = Vec::new();
        for row in rows {
            match takes.iter_mut().find(|t| t.id == row.take_id) {
                Some(take) => {
                    if !take.results.iter().any(|r| r.engine == row.result.engine) {
                        take.results.push(row.result);
                    }
                }
                None => takes.push(Take { id: row.take_id, at: row.at, app: row.app, expected: row.expected, rival: row.rival, results: vec![row.result] }),
            }
        }
        takes
    }

    /// One JSON line per result, newline-terminated.
    pub fn to_jsonl(&self) -> String {
        let mut out = String::new();
        for result in &self.results {
            if let Ok(line) = serde_json::to_string(&FlatRow::from_take(self, result)) {
                out.push_str(&line);
                out.push('\n');
            }
        }
        out
    }
}

/// The comparison run: takes in memory for the pane, appended to bakeoff.jsonl on disk.
pub struct BakeoffStore {
    dir: PathBuf,
    file: PathBuf,
    pub takes: Vec<Take>,
    /// A session records only into the run it started in.
    pub run_id: String,
}

impl BakeoffStore {
    pub fn new(dir: &Path) -> Self {
        let file = dir.join("bakeoff.jsonl");
        let takes = fs::read_to_string(&file).map(|c| Take::from_jsonl(&c)).unwrap_or_default();
        Self { dir: dir.to_path_buf(), file, takes, run_id: uuid::Uuid::new_v4().to_string() }
    }

    pub fn append(&mut self, take: Take) {
        let lines = take.to_jsonl();
        let _ = fs::create_dir_all(&self.dir);
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&self.file) {
            let _ = f.write_all(lines.as_bytes());
        }
        crate::keystore::restrict_permissions(&self.file);
        self.takes.push(take);
    }

    /// Removes the newest take, every engine's row of it, so the script position falls back to it.
    pub fn delete_last(&mut self) {
        if self.takes.pop().is_some() {
            self.rewrite();
        }
    }

    /// Archives the current run and starts fresh under a new identity.
    pub fn reset_run(&mut self) {
        if self.file.exists() {
            let stamp = crate::history::now() as u64;
            let _ = fs::rename(&self.file, self.dir.join(format!("bakeoff.run-{stamp}.jsonl")));
        }
        self.takes.clear();
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
        self.takes.clear();
        self.run_id = uuid::Uuid::new_v4().to_string();
    }

    pub fn archived_run_count(&self) -> usize {
        fs::read_dir(&self.dir)
            .map(|d| d.flatten().filter(|e| { let n = e.file_name().to_string_lossy().to_string(); n.starts_with("bakeoff.run-") && n.ends_with(".jsonl") }).count())
            .unwrap_or(0)
    }

    fn rewrite(&self) {
        let data: String = self.takes.iter().map(Take::to_jsonl).collect();
        let _ = fs::write(&self.file, data);
        crate::keystore::restrict_permissions(&self.file);
    }
}

#[derive(Clone, PartialEq, Debug)]
pub enum ScoredOutcome {
    Scored { ours: String, ms: u64, wer: f64 },
    Failed { reason: String },
}

#[derive(Clone, Debug)]
pub struct ScoredResult {
    pub engine: String,
    pub outcome: ScoredOutcome,
}

#[derive(Clone, Debug)]
pub struct ScoredTake {
    pub take: Take,
    pub expected: String,
    pub results: Vec<ScoredResult>,
    /// `None` when the rival's text never landed for this take.
    pub rival_wer: Option<f64>,
}

/// One engine over a run: its own numbers over every take it scored, and its record against the
/// rival over the takes both scored.
#[derive(Clone, Debug)]
pub struct EngineSummary {
    pub engine_key: String,
    pub scored: usize,
    pub failed: usize,
    pub mean_ours_wer: f64,
    pub mean_ours_ms: u64,
    pub wins: usize,
    pub losses: usize,
    pub ties: usize,
    pub mean_rival_wer: f64,
    pub mean_rival_ms: u64,
}

impl EngineSummary {
    /// Takes both this engine and the rival scored.
    pub fn decided(&self) -> usize {
        self.wins + self.losses + self.ties
    }
}

#[derive(Default)]
struct Tally {
    scored: usize,
    failed: usize,
    ours_wer: f64,
    ours_ms: u64,
    wins: usize,
    losses: usize,
    ties: usize,
    rival_wer: f64,
    rival_ms: u64,
}

/// Scores a run: takes with an expected sentence, every engine's result in each, and a leaderboard.
/// Pure over takes.
#[derive(Clone, Debug, Default)]
pub struct RunSummary {
    pub takes: Vec<ScoredTake>,
    /// Every engine that appears in the run, best first: lower mean WER, then lower mean ms.
    /// Engines that scored nothing come last.
    pub leaderboard: Vec<EngineSummary>,
}

impl RunSummary {
    pub fn leader(&self) -> Option<&EngineSummary> {
        self.leaderboard.iter().find(|e| e.scored > 0)
    }

    pub fn from_takes(takes: &[Take]) -> Self {
        let mut summary = RunSummary::default();
        let mut order: Vec<String> = Vec::new();
        let mut tallies: std::collections::HashMap<String, Tally> = Default::default();
        for take in takes {
            let Some(expected) = take.expected.clone() else { continue };
            let rival = match &take.rival {
                RivalOutcome::Landed { text, ms } => Some((scorer::wer(&expected, text), *ms)),
                _ => None,
            };
            let mut results = Vec::new();
            for result in &take.results {
                if !tallies.contains_key(&result.engine) {
                    order.push(result.engine.clone());
                }
                let tally = tallies.entry(result.engine.clone()).or_default();
                match &result.outcome {
                    EngineOutcome::Scored { ours, ms, .. } => {
                        let wer = scorer::wer(&expected, ours);
                        tally.scored += 1;
                        tally.ours_wer += wer;
                        tally.ours_ms += ms;
                        if let Some((rival_wer, rival_ms)) = rival {
                            tally.rival_wer += rival_wer;
                            tally.rival_ms += rival_ms;
                            if wer < rival_wer { tally.wins += 1 } else if rival_wer < wer { tally.losses += 1 } else { tally.ties += 1 }
                        }
                        results.push(ScoredResult { engine: result.engine.clone(), outcome: ScoredOutcome::Scored { ours: ours.clone(), ms: *ms, wer } });
                    }
                    EngineOutcome::Failed { reason } => {
                        tally.failed += 1;
                        results.push(ScoredResult { engine: result.engine.clone(), outcome: ScoredOutcome::Failed { reason: reason.clone() } });
                    }
                }
            }
            summary.takes.push(ScoredTake { take: take.clone(), expected, results, rival_wer: rival.map(|r| r.0) });
        }
        summary.leaderboard = order
            .into_iter()
            .map(|engine_key| {
                let t = &tallies[&engine_key];
                let decided = t.wins + t.losses + t.ties;
                EngineSummary {
                    engine_key,
                    scored: t.scored,
                    failed: t.failed,
                    mean_ours_wer: if t.scored > 0 { t.ours_wer / t.scored as f64 } else { 1.0 },
                    mean_ours_ms: if t.scored > 0 { t.ours_ms / t.scored as u64 } else { 0 },
                    wins: t.wins,
                    losses: t.losses,
                    ties: t.ties,
                    mean_rival_wer: if decided > 0 { t.rival_wer / decided as f64 } else { 1.0 },
                    mean_rival_ms: if decided > 0 { t.rival_ms / decided as u64 } else { 0 },
                }
            })
            .collect();
        summary.leaderboard.sort_by(|a, b| {
            (b.scored > 0)
                .cmp(&(a.scored > 0))
                .then(a.mean_ours_wer.partial_cmp(&b.mean_ours_wer).unwrap_or(std::cmp::Ordering::Equal))
                .then(a.mean_ours_ms.cmp(&b.mean_ours_ms))
        });
        summary
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scored(engine: &str, ours: &str, ms: u64) -> EngineResult {
        EngineResult { engine: engine.into(), outcome: EngineOutcome::Scored { spoken: ours.into(), ours: ours.into(), ms } }
    }

    fn failed(engine: &str) -> EngineResult {
        EngineResult { engine: engine.into(), outcome: EngineOutcome::Failed { reason: "timed out".into() } }
    }

    fn take(id: &str, expected: Option<&str>, rival: RivalOutcome, results: Vec<EngineResult>) -> Take {
        Take { id: id.into(), at: 1.0, app: "T".into(), expected: expected.map(String::from), rival, results }
    }

    fn run() -> Vec<Take> {
        vec![
            take("t1", Some("the cache is stale"), RivalOutcome::Landed { text: "the cash is stale".into(), ms: 900 }, vec![scored("apple-local", "the cache is stale", 300), failed("elevenlabs/scribe_v2")]),
            take("t2", Some("send the invoice"), RivalOutcome::Landed { text: "send the invoice".into(), ms: 700 }, vec![scored("apple-local", "send the voice", 200), scored("elevenlabs/scribe_v2", "send the invoice", 500)]),
            take("t3", Some("hello there"), RivalOutcome::TimedOut, vec![scored("apple-local", "hello there", 100)]),
            take("t4", None, RivalOutcome::Unobservable, vec![scored("apple-local", "x", 1)]),
        ]
    }

    #[test]
    fn summary_scores_every_engine_and_ranks_them() {
        let summary = RunSummary::from_takes(&run());
        assert_eq!(summary.takes.len(), 3, "takes without expected are skipped");
        let apple = summary.leaderboard.iter().find(|e| e.engine_key == "apple-local").unwrap();
        let scribe = summary.leaderboard.iter().find(|e| e.engine_key == "elevenlabs/scribe_v2").unwrap();
        assert_eq!((apple.scored, apple.failed, scribe.scored, scribe.failed), (3, 0, 1, 1));
        assert_eq!((apple.wins, apple.losses, apple.ties), (1, 1, 0));
        assert_eq!((apple.mean_ours_ms, apple.mean_rival_ms), (200, 800), "own mean over all scored, rival mean over decided");
        assert_eq!((scribe.ties, scribe.decided()), (1, 1));
        assert_eq!(summary.leaderboard.iter().map(|e| e.engine_key.as_str()).collect::<Vec<_>>(), ["elevenlabs/scribe_v2", "apple-local"]);
        assert_eq!(summary.leader().unwrap().engine_key, "elevenlabs/scribe_v2");
        assert!(summary.takes[2].rival_wer.is_none());
        assert_eq!(summary.takes[0].results.len(), 2, "a failed engine is still a row in the take");
    }

    #[test]
    fn takes_round_trip_and_legacy_rows_stand_alone() {
        let takes = run();
        let jsonl: String = takes[..2].iter().map(Take::to_jsonl).collect();
        assert!(jsonl.contains("\"oursStatus\":\"failed\""));
        assert_eq!(Take::from_jsonl(&jsonl), takes[..2].to_vec());
        let legacy = r#"{"at":1000,"app":"T","engine":"apple-local","expected":"a","spoken":"a","ours":"a","oursMs":1,"rivalStatus":"landed","rival":"b","rivalMs":5}"#;
        let two = format!("{legacy}\n{}\n", legacy.replace("1000", "2000"));
        let parsed = Take::from_jsonl(&two);
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].results.len(), 1);
        assert_eq!(parsed[0].rival, RivalOutcome::Landed { text: "b".into(), ms: 5 });
    }

    #[test]
    fn illegal_rows_are_dropped() {
        let landed_without_text = r#"{"at":0,"app":"T","engine":"e","spoken":"x","ours":"x","oursMs":1,"rivalStatus":"landed"}"#;
        assert!(Take::from_jsonl(landed_without_text).is_empty());
        let failed_with_text = r#"{"at":0,"take":"z","app":"T","engine":"e","oursStatus":"failed","spoken":"x","rivalStatus":"timedOut"}"#;
        assert!(Take::from_jsonl(failed_with_text).is_empty());
    }
}
