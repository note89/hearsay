//! Orchestration: the coordinator as an egui app. Syncs between concepts live here and nowhere else.
//! Press → snapshot rules and plan → record. Release → worker thread transcribes and delivers →
//! insert, or (bake-off) wait for the rival's text in our own arena buffer, then score.

use crate::panes;
use crate::settings::Settings;
use hearsay_backends::audio::Recording;
use hearsay_backends::hotkey::{GestureEvent, HoldGestureMonitor};
use hearsay_backends::insert::PasteInserter;
use hearsay_core::bakeoff::{BakeoffStore, EngineOutcome, EngineResult, RivalOutcome, Take, SCRIPT};
use hearsay_core::session::Transcriber;
use std::collections::HashMap;
use std::path::Path;
use hearsay_core::session::{LiveTranscription, PolishMode, TranscriptMode, TranscriptionHints};
use hearsay_engines::EngineHandle;
use hearsay_core::engine::{Engine, PrivacyClass};
use hearsay_core::history::{DictationRecord, HistoryStore, RecordedOutcome};
use hearsay_core::keystore::KeyStore;
use hearsay_core::lexicon::Lexicon;
use hearsay_core::paths::support_dir;
use hearsay_core::polish::{PolishContext, PolishRejection, Polisher, WritingStyle};
use hearsay_core::session::{deliver, InsertableText, InsertionBlock, InsertionEvidence, InsertionOutcome, Inserter, RawTranscript, SessionPlan, SessionRules};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Section {
    Dictation,
    Dictionary,
    Style,
    Bakeoff,
    History,
}

impl Section {
    pub const ALL: [Section; 5] = [Section::Dictation, Section::Dictionary, Section::Style, Section::Bakeoff, Section::History];

    pub fn title(self) -> &'static str {
        match self {
            Section::Dictation => "Dictation",
            Section::Dictionary => "Dictionary",
            Section::Style => "Style",
            Section::Bakeoff => "Bake-off",
            Section::History => "History",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FinishingStep {
    Transcribing,
    Racing(usize),
    Polishing,
    WatchingRival,
}

impl FinishingStep {
    pub fn label(self) -> String {
        match self {
            FinishingStep::Transcribing => "transcribing".into(),
            FinishingStep::Racing(count) => format!("racing {count}"),
            FinishingStep::Polishing => "polishing".into(),
            FinishingStep::WatchingRival => "watching rival".into(),
        }
    }
}

pub struct Session {
    rules: SessionRules,
    plan: SessionPlan,
    hints: TranscriptionHints,
}

/// One engine hearing the utterance. A dictation has one; a race has one per engine.
pub struct Contender {
    engine: Engine,
    hearing: Hearing,
}

/// How a contender hears: a batch engine gets the whole take at release (`None` = its model is
/// loaded on the worker), a live engine is fed while the key is held.
pub enum Hearing {
    Batch(Option<Arc<dyn Transcriber>>),
    Live(Box<dyn LiveTranscription>),
}

/// What a finished take produced, for the overlay and history.
#[derive(Clone, Debug)]
pub enum SessionOutcome {
    Landed { outcome: InsertionOutcome, total_ms: u64 },
    /// How a race ended: the first engine with text, and what the rival did.
    Compared { fastest: Option<(Engine, u64)>, rival: RivalOutcome },
    NothingHeard,
    Failed { reason: String, salvaged: bool },
}

pub enum Phase {
    Idle,
    Listening(Session, Recording, Vec<Contender>),
    /// The instant is key-up: every finishing step is bounded from it.
    Finishing(Session, FinishingStep, Instant),
    Settled(SessionOutcome, Instant),
}

/// Worker → UI: the result of transcription + delivery for one take.
enum WorkerMessage {
    Step(FinishingStep),
    Delivered { text: InsertableText, ms: u64, rejection: Option<PolishRejection> },
    NothingHeard,
    Failed(String),
    ModelReady(Result<EngineHandle, String>),
    Raced { take_id: String, result: EngineResult },
    Downloaded(Result<(), String>),
}

/// A bake-off take waiting for its halves: every contender's result from the workers, the rival's
/// text from the arena buffer.
struct PendingTake {
    take_id: String,
    baseline: String,
    since: Instant,
    expected: Option<String>,
    run_id: String,
    /// Race order, for the rows.
    lineup: Vec<Engine>,
    awaiting: Vec<Engine>,
    results: Vec<EngineResult>,
    /// When the arena first changed: the rival's latency. The text is re-read after a grace period.
    rival_first_change: Option<Instant>,
    rival: Option<RivalOutcome>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum EngineStatus {
    Loading,
    Ready,
    MissingModel,
    Downloading,
    Failed,
}

pub struct App {
    pub section: Section,
    pub settings: Settings,
    pub keys: KeyStore,
    pub history: HistoryStore,
    pub bakeoff: BakeoffStore,
    pub dictionary_path: PathBuf,
    pub models_dir: PathBuf,
    pub phase: Phase,
    pub engine_status: EngineStatus,
    pub engine_error: String,
    pub last_timing: Option<(u64, u64)>,
    pub gesture_error: Option<String>,
    pub bakeoff_text: String,
    pub bakeoff_pane_visible: bool,
    hotkey: Option<HoldGestureMonitor>,
    inserter: Arc<PasteInserter>,
    engine_handle: Option<EngineHandle>,
    /// Engines built for races beyond the active one. Cloud engines are cheap to build and cached here.
    engine_handles: HashMap<Engine, EngineHandle>,
    polisher: Option<Arc<dyn Polisher>>,
    pending_take: Option<PendingTake>,
    worker_tx: Sender<WorkerMessage>,
    worker_rx: Receiver<WorkerMessage>,
    overlay_level: f32,
    overlay_partial: String,
}

const SETTLE_DISPLAY: Duration = Duration::from_millis(700);
/// A warning must be readable.
const WARNING_DISPLAY: Duration = Duration::from_millis(2200);
/// The last stretch of the settled pill fades instead of cutting.
const SETTLE_FADE: Duration = Duration::from_millis(250);
const BAKEOFF_DISPLAY: Duration = Duration::from_secs(4);
const RIVAL_TIMEOUT: Duration = Duration::from_secs(8);
const RIVAL_GRACE: Duration = Duration::from_millis(400);
/// No engine, polish or rival watch may hold a session longer than this after key-up.
const FINISH_TIMEOUT: Duration = Duration::from_secs(20);

impl App {
    pub fn new(_cc: &eframe::CreationContext<'_>) -> Self {
        let dir = support_dir();
        let _ = std::fs::create_dir_all(&dir);
        let settings = Settings::load(&dir);
        let keys = KeyStore::new(&dir);
        let (worker_tx, worker_rx) = channel();
        let hotkey = HoldGestureMonitor::new(HoldGestureMonitor::default_chord());
        let (hotkey, gesture_error) = match hotkey {
            Ok(h) => (Some(h), None),
            Err(e) => (None, Some(e.to_string())),
        };
        let mut app = Self {
            section: Section::Dictation,
            polisher: None,
            keys,
            history: HistoryStore::new(&dir),
            bakeoff: BakeoffStore::new(&dir),
            dictionary_path: dir.join("dictionary.txt"),
            models_dir: dir.join("models"),
            phase: Phase::Idle,
            engine_status: EngineStatus::Loading,
            engine_error: String::new(),
            last_timing: None,
            gesture_error,
            bakeoff_text: String::new(),
            bakeoff_pane_visible: false,
            hotkey,
            inserter: Arc::new(PasteInserter::new()),
            engine_handle: None,
            engine_handles: HashMap::new(),
            pending_take: None,
            worker_tx,
            worker_rx,
            overlay_level: 0.0,
            overlay_partial: String::new(),
            settings,
        };
        hearsay_core::lexicon::ensure_file(&app.dictionary_path);
        app.activate_engine();
        app
    }

    /// Resolves the chosen engine to the one sessions run on and loads it on a thread.
    pub fn activate_engine(&mut self) {
        self.engine_handle = None;
        self.engine_status = EngineStatus::Loading;
        let engine = self.settings.engine;
        if let Engine::Whisper(model) = engine {
            if !self.models_dir.join(model.file_name()).exists() {
                self.engine_status = EngineStatus::MissingModel;
                return;
            }
        }
        let keys = KeyStore::new(self.keys.file_path().parent().unwrap_or(&support_dir()));
        let models_dir = self.models_dir.clone();
        let tx = self.worker_tx.clone();
        std::thread::spawn(move || {
            let result = hearsay_engines::make_engine(engine, &keys, &models_dir).map_err(|e| e.to_string());
            let _ = tx.send(WorkerMessage::ModelReady(result));
        });
        self.polisher = self.keys.value("OPENROUTER_API_KEY").map(|key| Arc::new(hearsay_engines::openrouter::OpenRouterPolisher::new(key)) as Arc<dyn Polisher>);
    }

    pub fn download_model(&mut self) {
        let Engine::Whisper(model) = self.settings.engine else { return };
        self.engine_status = EngineStatus::Downloading;
        let dir = self.models_dir.clone();
        let tx = self.worker_tx.clone();
        std::thread::spawn(move || {
            #[cfg(feature = "local-stt")]
            let result = hearsay_engines::whisper::download_model(model, &dir);
            #[cfg(not(feature = "local-stt"))]
            let result = { let _ = (model, dir); Err("built without local-stt".to_string()) };
            let _ = tx.send(WorkerMessage::Downloaded(result));
        });
    }

    pub fn select_engine(&mut self, engine: Engine) {
        self.settings.engine = engine;
        self.settings.save();
        self.activate_engine();
    }

    pub fn active_engine(&self) -> Engine {
        self.settings.engine
    }

    pub fn status_line(&self) -> String {
        if let Some(e) = &self.gesture_error {
            return format!("hotkey unavailable: {e}");
        }
        match self.engine_status {
            EngineStatus::Loading => "loading engine…".into(),
            EngineStatus::MissingModel => "model not downloaded — Dictation pane".into(),
            EngineStatus::Downloading => "downloading model…".into(),
            EngineStatus::Failed => format!("engine failed: {}", self.engine_error),
            EngineStatus::Ready => match &self.phase {
                Phase::Idle | Phase::Settled(..) => if self.bakeoff_pane_visible { "bake-off pane open — dictating into it scores".into() } else { "hold Ctrl+Alt+Space to dictate".into() },
                Phase::Listening(..) => "listening…".into(),
                Phase::Finishing(_, step, _) => format!("{}…", step.label()),
            },
        }
    }

    // MARK: gesture → pipeline

    fn pressed(&mut self, ctx: &egui::Context) {
        match self.phase {
            Phase::Listening(..) | Phase::Finishing(..) => return,
            Phase::Idle | Phase::Settled(..) => {}
        }
        if self.engine_status != EngineStatus::Ready {
            self.settle(SessionOutcome::Failed { reason: "engine not ready".into(), salvaged: false });
            return;
        }
        let rules = SessionRules {
            engine: self.active_engine(),
            style: WritingStyle::Plain,
            polish: self.settings.polish,
            lexicon: Lexicon::load(&self.dictionary_path),
        };
        // Bake-off iff the text would land in our own arena: the pane is front and this window is focused.
        let bakeoff = self.bakeoff_pane_visible && ctx.input(|i| i.viewport().focused.unwrap_or(false));
        let plan = if bakeoff {
            let position = self.bakeoff.takes.len();
            SessionPlan::Bakeoff {
                expected: SCRIPT.get(position).map(|s| s.text.to_string()),
                run_id: self.bakeoff.run_id.clone(),
                take_id: uuid::Uuid::new_v4().to_string(),
                engines: self.racing_engines(),
            }
        } else {
            SessionPlan::Dictate
        };
        if self.engine_handle.is_none() {
            self.settle(SessionOutcome::Failed { reason: "engine not ready".into(), salvaged: false });
            return;
        }
        // dictionary → transcription and style → transcription, in one object every engine receives.
        let hints = TranscriptionHints {
            vocabulary: rules.lexicon.terms.clone(),
            mode: match rules.polish { PolishMode::Off => TranscriptMode::Verbatim, PolishMode::Light | PolishMode::Full => TranscriptMode::Smart },
        };
        let lineup: Vec<Engine> = match &plan {
            SessionPlan::Bakeoff { engines, .. } => engines.clone(),
            SessionPlan::Dictate => vec![rules.engine],
        };
        match Recording::start() {
            Ok(recording) => {
                let contenders: Vec<Contender> = lineup.into_iter().map(|engine| Contender { engine, hearing: self.hearing_for(engine, &hints) }).collect();
                self.overlay_partial.clear();
                self.phase = Phase::Listening(Session { rules, plan, hints }, recording, contenders);
            }
            Err(e) => self.settle(SessionOutcome::Failed { reason: format!("microphone: {e}"), salvaged: false }),
        }
    }

    fn released(&mut self) {
        let Phase::Listening(session, recording, contenders) = std::mem::replace(&mut self.phase, Phase::Idle) else { return };
        let heard_seconds = recording.seconds();
        let tail = Arc::new(recording.take_new());
        let samples = Arc::new(recording.stop());
        let hints = session.hints.clone();
        let tx = self.worker_tx.clone();
        let support = self.keys.file_path().parent().map(Path::to_path_buf).unwrap_or_else(support_dir);
        let models_dir = self.models_dir.clone();
        let plan = session.plan.clone();
        match plan {
            SessionPlan::Dictate => {
                let Some(contender) = contenders.into_iter().next() else { return };
                let polisher = self.polisher.clone();
                let rules = session.rules.clone();
                std::thread::spawn(move || {
                    if heard_seconds < 0.1 {
                        let _ = tx.send(WorkerMessage::NothingHeard);
                        return;
                    }
                    let started = Instant::now();
                    let raw = match hear(contender.hearing, contender.engine, &samples, &tail, &hints, &support, &models_dir) {
                        Ok(raw) => raw,
                        Err(reason) => {
                            let _ = tx.send(WorkerMessage::Failed(reason));
                            return;
                        }
                    };
                    if raw.text().is_empty() {
                        let _ = tx.send(WorkerMessage::NothingHeard);
                        return;
                    }
                    let _ = tx.send(WorkerMessage::Step(FinishingStep::Polishing));
                    let context = PolishContext { field_text: None, terms: rules.lexicon.terms.clone() };
                    let (text, rejection) = match &polisher {
                        Some(p) => deliver(&rules, raw, p.as_ref(), &context),
                        None => deliver(&rules, raw, &NoPolish, &context),
                    };
                    let _ = tx.send(WorkerMessage::Delivered { text, ms: started.elapsed().as_millis() as u64, rejection });
                });
                self.phase = Phase::Finishing(session, FinishingStep::Transcribing, Instant::now());
            }
            SessionPlan::Bakeoff { expected, run_id, take_id, engines } => {
                self.pending_take = Some(PendingTake {
                    take_id: take_id.clone(),
                    baseline: self.bakeoff_text.clone(),
                    since: Instant::now(),
                    expected,
                    run_id,
                    lineup: engines.clone(),
                    awaiting: engines.clone(),
                    results: Vec::new(),
                    rival_first_change: None,
                    rival: None,
                });
                // Every contender is scored on its raw text, each on its own clock from key-up.
                for contender in contenders {
                    let (tx, samples, tail, hints, support, models_dir, take_id) = (tx.clone(), samples.clone(), tail.clone(), hints.clone(), support.clone(), models_dir.clone(), take_id.clone());
                    std::thread::spawn(move || {
                        let started = Instant::now();
                        let outcome = match hear(contender.hearing, contender.engine, &samples, &tail, &hints, &support, &models_dir) {
                            Ok(raw) if raw.text().is_empty() => EngineOutcome::Failed { reason: "nothing heard".into() },
                            Ok(raw) => EngineOutcome::Scored { spoken: raw.text().to_string(), ours: raw.text().to_string(), ms: started.elapsed().as_millis() as u64 },
                            Err(reason) => EngineOutcome::Failed { reason },
                        };
                        let _ = tx.send(WorkerMessage::Raced { take_id, result: EngineResult { engine: contender.engine.wire_key(), outcome } });
                    });
                }
                let step = if engines.len() > 1 { FinishingStep::Racing(engines.len()) } else { FinishingStep::Transcribing };
                self.phase = Phase::Finishing(session, step, Instant::now());
            }
        }
    }

    /// The engines a take races: the user's selection minus any without a key or model. Never empty.
    fn racing_engines(&self) -> Vec<Engine> {
        let lineup: Vec<Engine> = Engine::all().into_iter().filter(|e| self.settings.is_racing(*e) && self.engine_is_runnable(*e)).collect();
        if lineup.is_empty() { vec![self.settings.engine] } else { lineup }
    }

    /// Key present for a cloud engine; model file present for a local one.
    pub fn engine_is_runnable(&self, engine: Engine) -> bool {
        match engine {
            Engine::Whisper(model) => self.models_dir.join(model.file_name()).exists(),
            Engine::OpenRouter(_) | Engine::ElevenLabsScribe | Engine::GeminiTranscribeLive => engine.is_available(&self.keys),
        }
    }

    /// How a contender hears the take. The active engine is already loaded; cloud engines are built
    /// on the spot and cached; a whisper model that is not loaded is loaded on the worker at release.
    fn hearing_for(&mut self, engine: Engine, hints: &TranscriptionHints) -> Hearing {
        let handle = if engine == self.settings.engine {
            self.engine_handle.clone()
        } else if let Some(cached) = self.engine_handles.get(&engine) {
            Some(cached.clone())
        } else if let Engine::Whisper(_) = engine {
            None
        } else {
            let built = hearsay_engines::make_engine(engine, &self.keys, &self.models_dir).ok();
            if let Some(handle) = &built {
                self.engine_handles.insert(engine, handle.clone());
            }
            built
        };
        match handle {
            Some(EngineHandle::Live(live)) => Hearing::Live(live.start(hints)),
            Some(EngineHandle::Batch(batch)) => Hearing::Batch(Some(batch)),
            None => Hearing::Batch(None),
        }
    }

    fn drain_worker(&mut self) {
        while let Ok(message) = self.worker_rx.try_recv() {
            match message {
                WorkerMessage::ModelReady(Ok(t)) => {
                    log::info!("activate_engine: {} ready", self.active_engine().label());
                    self.engine_handle = Some(t);
                    self.engine_status = EngineStatus::Ready;
                }
                WorkerMessage::ModelReady(Err(e)) => {
                    log::warn!("activate_engine: {} failed: {e}", self.active_engine().label());
                    self.engine_status = EngineStatus::Failed;
                    self.engine_error = e;
                }
                WorkerMessage::Raced { take_id, result } => {
                    if let Some(take) = self.pending_take.as_mut() {
                        if take.take_id == take_id {
                            take.awaiting.retain(|e| e.wire_key() != result.engine);
                            take.results.push(result);
                            if take.awaiting.is_empty() {
                                if let Phase::Finishing(session, _, since) = std::mem::replace(&mut self.phase, Phase::Idle) {
                                    self.phase = Phase::Finishing(session, FinishingStep::WatchingRival, since);
                                }
                            }
                        }
                    }
                }
                WorkerMessage::Downloaded(Ok(())) => self.activate_engine(),
                WorkerMessage::Downloaded(Err(e)) => {
                    self.engine_status = EngineStatus::Failed;
                    self.engine_error = format!("download: {e}");
                }
                WorkerMessage::Step(step) => {
                    if let Phase::Finishing(session, _, since) = std::mem::replace(&mut self.phase, Phase::Idle) {
                        self.phase = Phase::Finishing(session, step, since);
                    }
                }
                WorkerMessage::NothingHeard => {
                    self.pending_take = None;
                    self.settle(SessionOutcome::NothingHeard);
                }
                WorkerMessage::Failed(reason) => {
                    self.pending_take = None;
                    log::error!("finish: transcription failed: {reason}");
                    self.settle(SessionOutcome::Failed { reason: "transcription failed".into(), salvaged: false });
                }
                WorkerMessage::Delivered { text, ms, rejection } => {
                    if let Some(rejection) = rejection {
                        log::info!("finish: kept raw ({})", rejection.label());
                    }
                    self.delivered(text, ms);
                }
            }
        }
    }

    fn delivered(&mut self, text: InsertableText, ms: u64) {
        let Phase::Finishing(session, _, _) = std::mem::replace(&mut self.phase, Phase::Idle) else {
            // The session already timed out; the words are still the user's.
            self.inserter.copy(text.text());
            log::warn!("delivered: session was no longer finishing — text copied to the clipboard");
            return;
        };
        match &session.plan {
            SessionPlan::Dictate => {
                let started = Instant::now();
                let outcome = self.inserter.insert(text.text());
                let insert_ms = started.elapsed().as_millis() as u64;
                self.last_timing = Some((ms, insert_ms));
                log::info!("session: ready {ms} ms · insert {insert_ms} ms · {outcome:?}");
                if self.settings.history_enabled {
                    let recorded = match outcome {
                        InsertionOutcome::Inserted { .. } => RecordedOutcome::Inserted,
                        InsertionOutcome::CopiedToClipboard(InsertionBlock::TargetLost) => RecordedOutcome::TargetLost,
                        InsertionOutcome::CopiedToClipboard(_) => RecordedOutcome::CopiedToClipboard,
                    };
                    self.history.record(DictationRecord::new(text.spoken(), text.text(), "—", recorded));
                }
                self.settle(SessionOutcome::Landed { outcome, total_ms: ms + insert_ms });
            }
            SessionPlan::Bakeoff { .. } => {
                log::error!("delivered: a bake-off take reached the dictation path — dropped");
            }
        }
    }

    /// A session that outlives the cap is closed: missing contenders become timed-out rows, a
    /// dictation fails. Late worker text still reaches the clipboard through `delivered`.
    fn expire_finishing(&mut self) {
        let Phase::Finishing(_, _, since) = &self.phase else { return };
        if since.elapsed() < FINISH_TIMEOUT {
            return;
        }
        match self.pending_take.as_mut() {
            Some(take) => {
                for engine in take.awaiting.drain(..) {
                    take.results.push(EngineResult { engine: engine.wire_key(), outcome: EngineOutcome::Failed { reason: "timed out".into() } });
                }
                if take.rival.is_none() {
                    take.rival = Some(RivalOutcome::TimedOut);
                }
            }
            None => {
                log::error!("finish: timed out after {} s", FINISH_TIMEOUT.as_secs());
                self.settle(SessionOutcome::Failed { reason: "timed out".into(), salvaged: false });
            }
        }
    }

    /// The arena is our own buffer: the rival's inserted text is whatever changed since key-up.
    /// Latency is the first change; the text is read again after a grace period so a rival that
    /// inserts in pieces is captured whole — the same rule as the macOS watcher.
    fn watch_rival(&mut self) {
        let Some(take) = self.pending_take.as_mut() else { return };
        if take.rival.is_none() {
            match take.rival_first_change {
                Some(first_change) => {
                    if first_change.elapsed() >= RIVAL_GRACE {
                        let inserted = inserted_text(&take.baseline, &self.bakeoff_text);
                        take.rival = Some(RivalOutcome::Landed { text: inserted, ms: (first_change - take.since).as_millis() as u64 });
                    }
                }
                None => {
                    if self.bakeoff_text != take.baseline {
                        take.rival_first_change = Some(Instant::now());
                    } else if take.since.elapsed() > RIVAL_TIMEOUT {
                        take.rival = Some(RivalOutcome::TimedOut);
                    }
                }
            }
        }
        if take.awaiting.is_empty() && take.rival.is_some() {
            let mut take = self.pending_take.take().expect("pending take");
            let Phase::Finishing(..) = std::mem::replace(&mut self.phase, Phase::Idle) else { return };
            let rival = take.rival.take().expect("rival observed");
            let position = |engine: &str| take.lineup.iter().position(|e| e.wire_key() == engine).unwrap_or(usize::MAX);
            take.results.sort_by_key(|r| position(&r.engine));
            let recorded = Take { id: take.take_id, at: hearsay_core::history::now(), app: "hearsay-rs".into(), expected: take.expected, rival: rival.clone(), results: take.results };
            let fastest = recorded
                .results
                .iter()
                .filter_map(|r| match &r.outcome {
                    EngineOutcome::Scored { ms, .. } => Engine::parse(&r.engine).map(|e| (e, *ms)),
                    EngineOutcome::Failed { .. } => None,
                })
                .min_by_key(|(_, ms)| *ms);
            if take.run_id == self.bakeoff.run_id {
                self.bakeoff.append(recorded);
                self.bakeoff_text.clear();
            } else {
                log::info!("finish: bake-off run was reset during the take — take dropped");
            }
            self.settle(SessionOutcome::Compared { fastest, rival });
        }
    }

    fn settle(&mut self, outcome: SessionOutcome) {
        self.phase = Phase::Settled(outcome, Instant::now());
    }

    fn expire_settled(&mut self) {
        if let Phase::Settled(outcome, since) = &self.phase {
            if since.elapsed() > display_for(outcome) {
                self.phase = Phase::Idle;
            }
        }
    }

    pub fn copy_text(&self, text: &str) {
        self.inserter.copy(text);
    }
}

struct NoPolish;
impl Polisher for NoPolish {
    fn polish(&self, _: &str, _: WritingStyle, _: hearsay_core::polish::PolishIntensity, _: &PolishContext) -> hearsay_core::polish::PolishVerdict {
        hearsay_core::polish::PolishVerdict::KeepRaw(PolishRejection::ModelUnavailable)
    }
}

/// The text that appeared: strip the common prefix and suffix the field already had.
fn inserted_text(before: &str, after: &str) -> String {
    let prefix = before.chars().zip(after.chars()).take_while(|(a, b)| a == b).count();
    let before_rest: Vec<char> = before.chars().skip(prefix).collect();
    let after_rest: Vec<char> = after.chars().skip(prefix).collect();
    let suffix = before_rest.iter().rev().zip(after_rest.iter().rev()).take_while(|(a, b)| a == b).count();
    after_rest[..after_rest.len().saturating_sub(suffix)].iter().collect::<String>().trim().to_string()
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if let Some(hotkey) = self.hotkey.as_mut() {
            for event in hotkey.poll() {
                match event {
                    GestureEvent::Pressed => self.pressed(ctx),
                    GestureEvent::Released => self.released(),
                }
            }
        }
        self.drain_worker();
        self.expire_finishing();
        self.watch_rival();
        self.expire_settled();
        if let Phase::Listening(_, recording, contenders) = &mut self.phase {
            self.overlay_level = recording.level();
            let fresh = recording.take_new();
            let mut pill: Option<String> = None;
            for contender in contenders.iter_mut() {
                if let Hearing::Live(live) = &mut contender.hearing {
                    live.feed(&fresh);
                    if pill.is_none() {
                        pill = Some(live.partial());
                    }
                }
            }
            if let Some(partial) = pill {
                self.overlay_partial = partial;
            }
        }

        egui::SidePanel::left("nav").exact_width(170.0).show(ctx, |ui| {
            ui.add_space(8.0);
            ui.heading("hearsay");
            ui.label(egui::RichText::new(self.status_line()).small().weak());
            ui.separator();
            for section in Section::ALL {
                if ui.selectable_label(self.section == section, section.title()).clicked() {
                    self.section = section;
                }
            }
        });
        let was_visible = self.bakeoff_pane_visible;
        self.bakeoff_pane_visible = self.section == Section::Bakeoff;
        if was_visible != self.bakeoff_pane_visible {
            log::info!("bake-off pane visible: {}", self.bakeoff_pane_visible);
        }
        egui::CentralPanel::default().show(ctx, |ui| {
            egui::ScrollArea::vertical().show(ui, |ui| {
                ui.set_max_width(680.0);
                match self.section {
                    Section::Dictation => panes::dictation(self, ui),
                    Section::Dictionary => panes::dictionary(self, ui),
                    Section::Style => panes::style(self, ui),
                    Section::Bakeoff => panes::bakeoff(self, ui),
                    Section::History => panes::history(self, ui),
                }
            });
        });

        self.overlay(ctx);
        ctx.request_repaint_after(Duration::from_millis(33));
    }
}

impl App {
    /// The overlay: a transparent always-on-top viewport rendering the phase. It has no state of its own.
    fn overlay(&mut self, ctx: &egui::Context) {
        if matches!(self.phase, Phase::Idle) {
            return;
        }
        let monitor = ctx.input(|i| i.viewport().monitor_size).unwrap_or(egui::vec2(1440.0, 900.0));
        let size = egui::vec2(420.0, 64.0);
        let position = egui::pos2((monitor.x - size.x) / 2.0, monitor.y - size.y - 40.0);
        let cloud = matches!(self.active_engine().privacy_class(), PrivacyClass::Cloud);
        let level = self.overlay_level;
        let content: (String, egui::Color32) = match &self.phase {
            Phase::Listening(..) if !self.overlay_partial.is_empty() => (tail(&self.overlay_partial, 48), egui::Color32::from_white_alpha(220)),
            Phase::Listening(..) => ("listening…".into(), egui::Color32::from_white_alpha(150)),
            Phase::Finishing(_, step, _) => (format!("{}…", step.label()), egui::Color32::from_white_alpha(200)),
            Phase::Settled(outcome, _) => match outcome {
                SessionOutcome::Landed { outcome: InsertionOutcome::Inserted { evidence: InsertionEvidence::Verified }, total_ms, .. } => (format!("inserted · {total_ms} ms"), egui::Color32::LIGHT_GREEN),
                SessionOutcome::Landed { outcome: InsertionOutcome::Inserted { evidence: InsertionEvidence::Posted }, total_ms, .. } => (format!("sent · {total_ms} ms"), egui::Color32::LIGHT_GREEN),
                SessionOutcome::Landed { outcome: InsertionOutcome::CopiedToClipboard(_), .. } => ("copied — could not insert".into(), egui::Color32::from_rgb(255, 166, 87)),
                SessionOutcome::Compared { fastest, rival } => {
                    let ours = fastest.map(|(engine, ms)| format!("{} {ms} ms", engine.short_label())).unwrap_or_else(|| "no engine answered".into());
                    match rival {
                        RivalOutcome::Landed { ms, .. } => (format!("{ours} · rival {ms} ms"), if fastest.is_some() { egui::Color32::LIGHT_GREEN } else { egui::Color32::from_rgb(255, 166, 87) }),
                        other => (format!("{ours} · rival {}", other.status()), egui::Color32::from_rgb(255, 166, 87)),
                    }
                }
                SessionOutcome::NothingHeard => ("nothing heard".into(), egui::Color32::from_rgb(255, 166, 87)),
                SessionOutcome::Failed { reason, salvaged } => (if *salvaged { format!("{reason} — draft copied") } else { reason.clone() }, egui::Color32::from_rgb(255, 166, 87)),
            },
            Phase::Idle => unreachable!(),
        };
        let listening = matches!(self.phase, Phase::Listening(..));
        let (quiet, fade) = match &self.phase {
            Phase::Settled(outcome, since) => {
                let remaining = display_for(outcome).saturating_sub(since.elapsed());
                let fade = (remaining.as_secs_f32() / SETTLE_FADE.as_secs_f32()).clamp(0.0, 1.0);
                (matches!(outcome, SessionOutcome::Landed { outcome: InsertionOutcome::Inserted { .. }, .. }), fade)
            }
            _ => (false, 1.0),
        };
        let alpha = |base: u8| (base as f32 * fade) as u8;
        let pill_alpha = alpha(if quiet { 150 } else { 220 });
        let text_color = egui::Color32::from_rgba_unmultiplied(content.1.r(), content.1.g(), content.1.b(), alpha(content.1.a()));
        ctx.show_viewport_immediate(
            egui::ViewportId::from_hash_of("hearsay-overlay"),
            egui::ViewportBuilder::default()
                .with_title("hearsay")
                .with_decorations(false)
                .with_transparent(true)
                .with_always_on_top()
                .with_resizable(false)
                .with_inner_size(size)
                .with_position(position),
            move |ctx, _| {
                egui::CentralPanel::default().frame(egui::Frame::NONE).show(ctx, |ui| {
                    let rect = ui.max_rect().shrink2(egui::vec2(10.0, 9.0));
                    ui.painter().rect_filled(rect, 23.0, egui::Color32::from_black_alpha(pill_alpha));
                    ui.painter().rect_stroke(rect, 23.0, egui::Stroke::new(1.0_f32, egui::Color32::from_white_alpha(alpha(36))), egui::StrokeKind::Inside);
                    let mut x = rect.left() + 20.0;
                    if cloud {
                        ui.painter().text(egui::pos2(x, rect.center().y), egui::Align2::LEFT_CENTER, "cloud", egui::FontId::proportional(10.0), egui::Color32::from_rgb(255, 166, 87));
                        x += 40.0;
                    }
                    if listening {
                        for i in 0..24 {
                            let h = 3.0 + level * 22.0 * (0.4 + 0.6 * ((i as f32 * 0.9).sin().abs()));
                            ui.painter().rect_filled(egui::Rect::from_center_size(egui::pos2(x + i as f32 * 5.0, rect.center().y), egui::vec2(3.0, h)), 1.5, egui::Color32::from_white_alpha(230));
                        }
                        x += 24.0 * 5.0 + 10.0;
                    }
                    ui.painter().text(egui::pos2(x, rect.center().y), egui::Align2::LEFT_CENTER, &content.0, egui::FontId::proportional(13.0), text_color);
                });
            },
        );
    }
}

/// Runs one contender to its text. Blocking; worker threads only.
fn hear(hearing: Hearing, engine: Engine, samples: &[f32], tail: &[f32], hints: &TranscriptionHints, support: &Path, models_dir: &Path) -> Result<RawTranscript, String> {
    match hearing {
        Hearing::Live(mut live) => {
            live.feed(tail);
            live.finish().map_err(|e| e.to_string())
        }
        Hearing::Batch(Some(transcriber)) => transcriber.transcribe(samples, hints).map_err(|e| e.to_string()),
        Hearing::Batch(None) => hearsay_engines::make_engine(engine, &KeyStore::new(support), models_dir)
            .map_err(|e| e.to_string())?
            .transcribe(samples, hints)
            .map_err(|e| e.to_string()),
    }
}

/// How long the settled pill stays: good news is a glance, a warning must be readable, a bake-off
/// verdict has two numbers.
fn display_for(outcome: &SessionOutcome) -> Duration {
    match outcome {
        SessionOutcome::Compared { .. } => BAKEOFF_DISPLAY,
        SessionOutcome::Landed { outcome: InsertionOutcome::Inserted { .. }, .. } => SETTLE_DISPLAY,
        SessionOutcome::Landed { outcome: InsertionOutcome::CopiedToClipboard(_), .. } | SessionOutcome::NothingHeard | SessionOutcome::Failed { .. } => WARNING_DISPLAY,
    }
}

/// The last `max` characters, for the pill.
fn tail(text: &str, max: usize) -> String {
    let count = text.chars().count();
    if count <= max {
        text.to_string()
    } else {
        format!("…{}", text.chars().skip(count - max).collect::<String>())
    }
}
