//! Engines: the mechanisms behind the transcription and polish concepts. Each is a plain
//! implementation of a core trait; the app picks one per session from `Engine`.

mod base64;
pub mod elevenlabs;
pub mod gemini_live;
pub mod openrouter;
#[cfg(feature = "local-stt")]
pub mod whisper;

use hearsay_core::engine::Engine;
use hearsay_core::keystore::KeyStore;
use hearsay_core::session::{LiveTranscriber, RawTranscript, TranscriptionFailure, TranscriptionHints, Transcriber};
use std::path::Path;
use std::sync::Arc;

/// A loaded engine, in the shape it works in: batch takes the whole utterance at release; live takes
/// audio during the hold and hands back partials.
#[derive(Clone)]
pub enum EngineHandle {
    Batch(Arc<dyn Transcriber>),
    Live(Arc<dyn LiveTranscriber>),
}

impl EngineHandle {
    /// The whole utterance at once — the CLI and file bake-offs. Live engines stream it in one go.
    pub fn transcribe(&self, samples_16k: &[f32], hints: &TranscriptionHints) -> Result<RawTranscript, TranscriptionFailure> {
        match self {
            EngineHandle::Batch(t) => t.transcribe(samples_16k, hints),
            EngineHandle::Live(l) => {
                let mut session = l.start(hints);
                session.feed(samples_16k);
                session.finish()
            }
        }
    }
}

/// Loads the engine. `Err(NotReady)` when its key is missing or its model file is absent.
pub fn make_engine(engine: Engine, keys: &KeyStore, models_dir: &Path) -> Result<EngineHandle, TranscriptionFailure> {
    fn key(keys: &KeyStore, name: &str) -> Result<String, TranscriptionFailure> {
        keys.value(name).ok_or_else(|| TranscriptionFailure::NotReady(format!("{name} missing")))
    }
    match engine {
        Engine::Whisper(model) => {
            #[cfg(feature = "local-stt")]
            {
                let path = models_dir.join(model.file_name());
                if !path.exists() {
                    return Err(TranscriptionFailure::NotReady(format!("model missing: {}", path.display())));
                }
                whisper::WhisperTranscriber::load(&path, model).map(|t| EngineHandle::Batch(Arc::new(t)))
            }
            #[cfg(not(feature = "local-stt"))]
            {
                let _ = (model, models_dir);
                Err(TranscriptionFailure::NotReady("built without local-stt".into()))
            }
        }
        Engine::OpenRouter(model) => Ok(EngineHandle::Batch(Arc::new(openrouter::OpenRouterTranscriber::new(model.id(), key(keys, "OPENROUTER_API_KEY")?)))),
        Engine::ElevenLabsScribe => Ok(EngineHandle::Batch(Arc::new(elevenlabs::ScribeTranscriber::new(key(keys, "ELEVEN_LABS_API_KEY")?)))),
        Engine::GeminiTranscribeLive => Ok(EngineHandle::Live(Arc::new(gemini_live::GeminiLiveTranscriber::new(key(keys, "GEMINI_API_KEY")?)))),
    }
}

/// Cloud engines share one shape: the utterance as WAV bytes, one request, one text.
fn wav_from_samples(samples_16k: &[f32]) -> Vec<u8> {
    let mut acc = hearsay_core::wav::Accumulator::new(hearsay_core::wav::TARGET_RATE, 1);
    acc.append(samples_16k);
    acc.wav_data()
}

const REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(12);

fn http() -> reqwest::blocking::Client {
    reqwest::blocking::Client::builder().timeout(REQUEST_TIMEOUT).build().expect("http client")
}
