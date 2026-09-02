//! Orchestration: the coordinator as an egui app. Syncs between concepts live here and nowhere else.
//! Press → snapshot rules and plan → record. Release → worker thread transcribes and delivers →
//! insert, or (bake-off) wait for the rival's text in our own arena buffer, then score.

use crate::panes;
use crate::settings::Settings;
use hearsay_backends::audio::Recording;
use hearsay_backends::hotkey::{GestureEvent, HoldGestureMonitor};
use hearsay_backends::insert::PasteInserter;
use hearsay_core::bakeoff::{BakeoffRecord, BakeoffStore, RivalOutcome, SCRIPT};
use hearsay_core::engine::{Engine, PrivacyClass};
use hearsay_core::history::{DictationRecord, HistoryStore, RecordedOutcome};
use hearsay_core::keystore::KeyStore;
use hearsay_core::lexicon::Lexicon;
use hearsay_core::paths::support_dir;
use hearsay_core::polish::{PolishContext, PolishRejection, Polisher, WritingStyle};
use hearsay_core::session::{deliver, InsertableText, InsertionBlock, InsertionEvidence, InsertionOutcome, Inserter, RawTranscript, SessionPlan, SessionRules, Transcriber};
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
    Polishing,
    WatchingRival,
}

impl FinishingStep {
    pub fn label(self) -> &'static str {
        match self {
            FinishingStep::Transcribing => "transcribing",
            FinishingStep::Polishing => "polishing",
            FinishingStep::WatchingRival => "watching rival",
        }
    }
}

pub struct Session {
    rules: SessionRules,
    plan: SessionPlan,
}

/// What a finished take produced, for the overlay and history.
#[derive(Clone, Debug)]
pub enum SessionOutcome {
    Landed { outcome: InsertionOutcome, total_ms: u64 },
    Compared { ours_ms: u64, rival: RivalOutcome },
    NothingHeard,
    Failed { reason: String, salvaged: bool },
}

pub enum Phase {
    Idle,
    Listening(Session, Recording),
    Finishing(Session, FinishingStep),
    Settled(SessionOutcome, Instant),
}

/// Worker → UI: the result of transcription + delivery for one take.
enum WorkerMessage {
    Step(FinishingStep),
    Delivered { text: InsertableText, ms: u64, rejection: Option<PolishRejection> },
    NothingHeard,
    Failed(String),
    ModelReady(Result<Arc<dyn Transcriber>, String>),
    Downloaded(Result<(), String>),
}

/// A bake-off take waiting for its two halves: our text from the worker, the rival's from the arena buffer.
struct PendingTake {
    baseline: String,
    since: Instant,
    expected: Option<String>,
    run_id: String,
    ours: Option<(InsertableText, u64)>,
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
    transcriber: Option<Arc<dyn Transcriber>>,
    polisher: Option<Arc<dyn Polisher>>,
    pending_take: Option<PendingTake>,
    worker_tx: Sender<WorkerMessage>,
    worker_rx: Receiver<WorkerMessage>,
    overlay_level: f32,
}

const SETTLE_DISPLAY: Duration = Duration::from_millis(1400);
const BAKEOFF_DISPLAY: Duration = Duration::from_secs(4);
const RIVAL_TIMEOUT: Duration = Duration::from_secs(8);
const RIVAL_GRACE: Duration = Duration::from_millis(400);

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
            transcriber: None,
            pending_take: None,
            worker_tx,
            worker_rx,
            overlay_level: 0.0,
            settings,
        };
        hearsay_core::lexicon::ensure_file(&app.dictionary_path);
        app.activate_engine();
        app
    }

    /// Resolves the chosen engine to the one sessions run on and loads it on a thread.
    pub fn activate_engine(&mut self) {
        self.transcriber = None;
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
            let result = hearsay_engines::make_transcriber(engine, &keys, &models_dir).map(Arc::from).map_err(|e| e.to_string());
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
                Phase::Finishing(_, step) => format!("{}…", step.label()),
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
            let position = self.bakeoff.records.len();
            SessionPlan::Bakeoff { expected: SCRIPT.get(position).map(|s| s.text.to_string()), run_id: self.bakeoff.run_id.clone() }
        } else {
            SessionPlan::Dictate
        };
        match Recording::start() {
            Ok(recording) => {
                self.phase = Phase::Listening(Session { rules, plan }, recording);
            }
            Err(e) => self.settle(SessionOutcome::Failed { reason: format!("microphone: {e}"), salvaged: false }),
        }
    }

    fn released(&mut self) {
        let Phase::Listening(session, recording) = std::mem::replace(&mut self.phase, Phase::Idle) else { return };
        let samples = recording.stop();
        if let SessionPlan::Bakeoff { expected, run_id } = &session.plan {
            self.pending_take = Some(PendingTake { baseline: self.bakeoff_text.clone(), since: Instant::now(), expected: expected.clone(), run_id: run_id.clone(), ours: None, rival: None });
        }
        let Some(transcriber) = self.transcriber.clone() else {
            self.settle(SessionOutcome::Failed { reason: "engine not ready".into(), salvaged: false });
            return;
        };
        let polisher = self.polisher.clone();
        let rules = session.rules.clone();
        let tx = self.worker_tx.clone();
        std::thread::spawn(move || {
            if samples.len() < 1600 {
                let _ = tx.send(WorkerMessage::NothingHeard);
                return;
            }
            let started = Instant::now();
            let raw: RawTranscript = match transcriber.transcribe(&samples) {
                Ok(raw) => raw,
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Failed(e.to_string()));
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
        self.phase = Phase::Finishing(session, FinishingStep::Transcribing);
    }

    fn drain_worker(&mut self) {
        while let Ok(message) = self.worker_rx.try_recv() {
            match message {
                WorkerMessage::ModelReady(Ok(t)) => {
                    log::info!("activate_engine: {} ready", self.active_engine().label());
                    self.transcriber = Some(t);
                    self.engine_status = EngineStatus::Ready;
                }
                WorkerMessage::ModelReady(Err(e)) => {
                    log::warn!("activate_engine: {} failed: {e}", self.active_engine().label());
                    self.engine_status = EngineStatus::Failed;
                    self.engine_error = e;
                }
                WorkerMessage::Downloaded(Ok(())) => self.activate_engine(),
                WorkerMessage::Downloaded(Err(e)) => {
                    self.engine_status = EngineStatus::Failed;
                    self.engine_error = format!("download: {e}");
                }
                WorkerMessage::Step(step) => {
                    if let Phase::Finishing(session, _) = std::mem::replace(&mut self.phase, Phase::Idle) {
                        self.phase = Phase::Finishing(session, step);
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
        let Phase::Finishing(session, _) = std::mem::replace(&mut self.phase, Phase::Idle) else { return };
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
                self.phase = Phase::Finishing(session, FinishingStep::WatchingRival);
                if let Some(take) = self.pending_take.as_mut() {
                    take.ours = Some((text, ms));
                }
                self.last_timing = Some((ms, 0));
            }
        }
    }

    /// The arena is our own buffer: the rival's inserted text is whatever changed since press.
    fn watch_rival(&mut self) {
        let Some(take) = self.pending_take.as_mut() else { return };
        if take.rival.is_none() {
            if self.bakeoff_text != take.baseline {
                let latency = take.since.elapsed();
                if latency >= RIVAL_GRACE || take.since.elapsed() > RIVAL_TIMEOUT {
                    let inserted = inserted_text(&take.baseline, &self.bakeoff_text);
                    take.rival = Some(RivalOutcome::Landed { text: inserted, ms: latency.as_millis() as u64 });
                }
            } else if take.since.elapsed() > RIVAL_TIMEOUT {
                take.rival = Some(RivalOutcome::TimedOut);
            }
        }
        if let (Some((text, ms)), Some(rival)) = (take.ours.clone(), take.rival.clone()) {
            let take = self.pending_take.take().expect("pending take");
            let Phase::Finishing(session, _) = std::mem::replace(&mut self.phase, Phase::Idle) else { return };
            if take.run_id == self.bakeoff.run_id {
                self.bakeoff.append(BakeoffRecord {
                    at: hearsay_core::history::now(),
                    app: "hearsay-rs".into(),
                    engine: session.rules.engine.wire_key(),
                    expected: take.expected,
                    spoken: text.spoken().to_string(),
                    ours: text.text().to_string(),
                    ours_ms: ms,
                    rival: rival.clone(),
                });
                self.bakeoff_text.clear();
            } else {
                log::info!("finish: bake-off run was reset during the take — record dropped");
            }
            self.settle(SessionOutcome::Compared { ours_ms: ms, rival });
        }
    }

    fn settle(&mut self, outcome: SessionOutcome) {
        self.phase = Phase::Settled(outcome, Instant::now());
    }

    fn expire_settled(&mut self) {
        if let Phase::Settled(outcome, since) = &self.phase {
            let display = if matches!(outcome, SessionOutcome::Compared { .. }) { BAKEOFF_DISPLAY } else { SETTLE_DISPLAY };
            if since.elapsed() > display {
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
        self.watch_rival();
        self.expire_settled();
        if let Phase::Listening(_, recording) = &self.phase {
            self.overlay_level = recording.level();
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
            Phase::Listening(..) => ("listening…".into(), egui::Color32::from_white_alpha(150)),
            Phase::Finishing(_, step) => (format!("{}…", step.label()), egui::Color32::from_white_alpha(200)),
            Phase::Settled(outcome, _) => match outcome {
                SessionOutcome::Landed { outcome: InsertionOutcome::Inserted { evidence: InsertionEvidence::Verified }, total_ms, .. } => (format!("inserted · {total_ms} ms"), egui::Color32::LIGHT_GREEN),
                SessionOutcome::Landed { outcome: InsertionOutcome::Inserted { evidence: InsertionEvidence::Posted }, total_ms, .. } => (format!("sent · {total_ms} ms"), egui::Color32::LIGHT_GREEN),
                SessionOutcome::Landed { outcome: InsertionOutcome::CopiedToClipboard(_), .. } => ("copied — could not insert".into(), egui::Color32::from_rgb(255, 166, 87)),
                SessionOutcome::Compared { ours_ms, rival: RivalOutcome::Landed { ms, .. } } => (format!("ours {ours_ms} ms · rival {ms} ms"), egui::Color32::LIGHT_GREEN),
                SessionOutcome::Compared { ours_ms, rival } => (format!("ours {ours_ms} ms · rival {}", rival.status()), egui::Color32::from_rgb(255, 166, 87)),
                SessionOutcome::NothingHeard => ("nothing heard".into(), egui::Color32::from_rgb(255, 166, 87)),
                SessionOutcome::Failed { reason, salvaged } => (if *salvaged { format!("{reason} — draft copied") } else { reason.clone() }, egui::Color32::from_rgb(255, 166, 87)),
            },
            Phase::Idle => unreachable!(),
        };
        let listening = matches!(self.phase, Phase::Listening(..));
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
                    ui.painter().rect_filled(rect, 23.0, egui::Color32::from_black_alpha(220));
                    ui.painter().rect_stroke(rect, 23.0, egui::Stroke::new(1.0_f32, egui::Color32::from_white_alpha(36)), egui::StrokeKind::Inside);
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
                    ui.painter().text(egui::pos2(x, rect.center().y), egui::Align2::LEFT_CENTER, &content.0, egui::FontId::proportional(13.0), content.1);
                });
            },
        );
    }
}
