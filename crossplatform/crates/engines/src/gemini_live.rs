//! Gemini 3.5 Transcribe Live: Google's streaming ASR over the Live API WebSocket. Audio goes up
//! while the key is held; the server commits segments at pauses and streams its current guess in
//! between. The final is the committed text once the stream has drained. Language is always
//! auto-detected, so mid-sentence mixing works.

use hearsay_core::engine::GEMINI_LIVE_MODEL_ID;
use hearsay_core::session::{LiveTranscriber, LiveTranscription, RawTranscript, TranscriptMode, TranscriptionFailure, TranscriptionHints, Transcriber};
use std::io::ErrorKind;
use std::sync::mpsc::{self, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};

const CHUNK_BYTES: usize = 1600 * 2; // 100 ms of pcm16 @ 16 kHz
const READ_TIMEOUT: Duration = Duration::from_millis(30);
const DRAIN_QUIET: Duration = Duration::from_millis(300);
const DRAIN_IDLE_GRACE: Duration = Duration::from_millis(1200);
const DRAIN_CAP: Duration = Duration::from_secs(6);
const MAX_VOCABULARY: usize = 1000;

pub struct GeminiLiveTranscriber {
    key: String,
}

impl GeminiLiveTranscriber {
    pub fn new(key: String) -> Self {
        Self { key }
    }
}

impl LiveTranscriber for GeminiLiveTranscriber {
    fn start(&self, hints: &TranscriptionHints) -> Box<dyn LiveTranscription> {
        let (tx, rx) = mpsc::channel();
        let shared = Arc::new(Mutex::new(LiveTake::default()));
        let (key, hints, take) = (self.key.clone(), hints.clone(), shared.clone());
        let worker = std::thread::spawn(move || session_thread(key, hints, rx, take));
        Box::new(GeminiLiveSession { tx, shared, worker: Some(worker) })
    }
}

/// The CLI and the bake-off on a file: feed everything, then finish.
impl Transcriber for GeminiLiveTranscriber {
    fn transcribe(&self, samples_16k: &[f32], hints: &TranscriptionHints) -> Result<RawTranscript, TranscriptionFailure> {
        let mut session = self.start(hints);
        session.feed(samples_16k);
        session.finish()
    }
}

enum Upstream {
    Audio(Vec<u8>),
    End,
}

/// The live take: committed segments, the interim guess, and whether the server is done.
#[derive(Default)]
struct LiveTake {
    committed: Vec<String>,
    interim: String,
    closed: bool,
    failure: Option<String>,
    last_commit: Option<Instant>,
    commits_after_end: u32,
}

impl LiveTake {
    fn partial(&self) -> String {
        [self.committed.join(" "), self.interim.clone()].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ")
    }

    fn final_text(&self) -> String {
        if self.committed.is_empty() { self.interim.clone() } else { self.committed.join(" ") }
    }
}

pub struct GeminiLiveSession {
    tx: mpsc::Sender<Upstream>,
    shared: Arc<Mutex<LiveTake>>,
    worker: Option<JoinHandle<()>>,
}

impl LiveTranscription for GeminiLiveSession {
    fn feed(&mut self, samples_16k: &[f32]) {
        if samples_16k.is_empty() {
            return;
        }
        let _ = self.tx.send(Upstream::Audio(pcm16(samples_16k)));
    }

    fn partial(&self) -> String {
        self.shared.lock().map(|t| t.partial()).unwrap_or_default()
    }

    fn finish(mut self: Box<Self>) -> Result<RawTranscript, TranscriptionFailure> {
        let _ = self.tx.send(Upstream::End);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        let take = self.shared.lock().map_err(|_| TranscriptionFailure::Failed("session poisoned".into()))?;
        let text = take.final_text();
        match (&take.failure, text.is_empty()) {
            (Some(failure), true) => Err(TranscriptionFailure::Failed(failure.clone())),
            _ => Ok(RawTranscript::from_engine(text)),
        }
    }
}

fn pcm16(samples: &[f32]) -> Vec<u8> {
    samples.iter().flat_map(|s| ((s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16).to_le_bytes()).collect()
}

fn fail(shared: &Arc<Mutex<LiveTake>>, what: String) {
    log::warn!("gemini live: {what}");
    if let Ok(mut take) = shared.lock() {
        take.failure = Some(what);
        take.closed = true;
    }
}

fn setup_json(hints: &TranscriptionHints) -> String {
    let mut transcription = serde_json::json!({
        "languageCodes": [],
        "mode": match hints.mode { TranscriptMode::Smart => "SMART", TranscriptMode::Verbatim => "VERBATIM" },
    });
    if !hints.vocabulary.is_empty() {
        transcription["customVocabulary"] = serde_json::json!(hints.vocabulary.iter().take(MAX_VOCABULARY).collect::<Vec<_>>());
    }
    serde_json::json!({
        "setup": {
            "model": format!("models/{GEMINI_LIVE_MODEL_ID}"),
            "generationConfig": { "responseModalities": ["TEXT"] },
            "inputAudioTranscription": transcription,
        }
    })
    .to_string()
}

fn audio_json(pcm: &[u8]) -> String {
    serde_json::json!({ "realtimeInput": { "audio": { "data": crate::base64::encode(pcm), "mimeType": "audio/pcm;rate=16000" } } }).to_string()
}

fn set_read_timeout(socket: &mut WebSocket<MaybeTlsStream<std::net::TcpStream>>) {
    let result = match socket.get_mut() {
        MaybeTlsStream::Plain(s) => s.set_read_timeout(Some(READ_TIMEOUT)),
        #[cfg(not(windows))]
        MaybeTlsStream::Rustls(s) => s.sock.set_read_timeout(Some(READ_TIMEOUT)),
        #[cfg(windows)]
        MaybeTlsStream::NativeTls(s) => s.get_mut().set_read_timeout(Some(READ_TIMEOUT)),
        _ => Ok(()),
    };
    if let Err(e) = result {
        log::warn!("gemini live: read timeout not set: {e}");
    }
}

/// Applies one server message to the take. Logs shapes, never transcript text.
fn apply(shared: &Arc<Mutex<LiveTake>>, text: &str, ended: bool) {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else { return };
    let Some(content) = value.get("serverContent") else {
        log::debug!("gemini live: message keys {:?}", value.as_object().map(|o| o.keys().collect::<Vec<_>>()));
        return;
    };
    let Ok(mut take) = shared.lock() else { return };
    if let Some(t) = content.pointer("/inputTranscription/text").and_then(|v| v.as_str()) {
        log::debug!("gemini live: committed segment, {} chars", t.chars().count());
        take.committed.push(t.to_string());
        take.interim.clear();
        take.last_commit = Some(Instant::now());
        if ended {
            take.commits_after_end += 1;
        }
    }
    if let Some(t) = content.pointer("/interimInputTranscription/text").and_then(|v| v.as_str()) {
        take.interim = t.to_string();
    }
    if content.get("turnComplete").and_then(|v| v.as_bool()) == Some(true) {
        log::debug!("gemini live: turn complete");
        take.closed = true;
    }
}

fn session_thread(key: String, hints: TranscriptionHints, rx: mpsc::Receiver<Upstream>, shared: Arc<Mutex<LiveTake>>) {
    let url = format!("wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key={key}");
    let connected = Instant::now();
    let (mut socket, _) = match tungstenite::connect(url.as_str()) {
        Ok(pair) => pair,
        Err(e) => return fail(&shared, format!("connect: {e}")),
    };
    log::debug!("gemini live: connected in {} ms", connected.elapsed().as_millis());
    set_read_timeout(&mut socket);
    if let Err(e) = socket.send(Message::Text(setup_json(&hints).into())) {
        return fail(&shared, format!("setup: {e}"));
    }
    let mut pending: Vec<u8> = Vec::new();
    let mut ended_at: Option<Instant> = None;
    loop {
        loop {
            match rx.try_recv() {
                Ok(Upstream::Audio(bytes)) => pending.extend(bytes),
                Ok(Upstream::End) => {
                    if !pending.is_empty() {
                        let _ = socket.send(Message::Text(audio_json(&pending).into()));
                        pending.clear();
                    }
                    if let Err(e) = socket.send(Message::Text(serde_json::json!({ "realtimeInput": { "audioStreamEnd": true } }).to_string().into())) {
                        fail(&shared, format!("end: {e}"));
                    }
                    ended_at = Some(Instant::now());
                    break;
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    if ended_at.is_none() {
                        let _ = socket.close(None);
                        return;
                    }
                    break;
                }
            }
        }
        if pending.len() >= CHUNK_BYTES {
            if let Err(e) = socket.send(Message::Text(audio_json(&pending).into())) {
                return fail(&shared, format!("audio: {e}"));
            }
            pending.clear();
        }
        match socket.read() {
            Ok(Message::Text(text)) => apply(&shared, text.as_str(), ended_at.is_some()),
            Ok(Message::Close(frame)) => {
                let reason = frame.map(|f| f.reason.to_string()).unwrap_or_default();
                if let Ok(mut take) = shared.lock() {
                    take.closed = true;
                    if take.committed.is_empty() && take.interim.is_empty() && !reason.is_empty() {
                        take.failure = Some(format!("server closed: {reason}"));
                    }
                }
                break;
            }
            Ok(_) => {}
            Err(tungstenite::Error::Io(e)) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => {
                if let Ok(mut take) = shared.lock() {
                    take.closed = true;
                }
                break;
            }
            Err(e) => {
                fail(&shared, format!("socket: {e}"));
                break;
            }
        }
        if let Some(ended) = ended_at {
            let Ok(take) = shared.lock() else { break };
            if take.closed {
                break;
            }
            let settled = take.commits_after_end > 0 && take.last_commit.is_some_and(|last| last.elapsed() >= DRAIN_QUIET);
            let nothing_pending = take.commits_after_end == 0 && take.interim.is_empty() && ended.elapsed() >= DRAIN_IDLE_GRACE;
            if settled || nothing_pending || ended.elapsed() >= DRAIN_CAP {
                break;
            }
        }
    }
    let _ = socket.close(None);
}
