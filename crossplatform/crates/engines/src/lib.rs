//! Engines: the mechanisms behind the transcription and polish concepts. Each is a plain
//! implementation of a core trait; the app picks one per session from `Engine`.

pub mod elevenlabs;
pub mod openrouter;
#[cfg(feature = "local-stt")]
pub mod whisper;

use hearsay_core::engine::Engine;
use hearsay_core::keystore::KeyStore;
use hearsay_core::session::{TranscriptionFailure, Transcriber};
use std::path::Path;

/// Builds the transcriber for an engine. `None` when its key is missing or its model file is absent.
pub fn make_transcriber(engine: Engine, keys: &KeyStore, models_dir: &Path) -> Result<Box<dyn Transcriber>, TranscriptionFailure> {
    match engine {
        Engine::Whisper(model) => {
            #[cfg(feature = "local-stt")]
            {
                let path = models_dir.join(model.file_name());
                if !path.exists() {
                    return Err(TranscriptionFailure::NotReady(format!("model missing: {}", path.display())));
                }
                whisper::WhisperTranscriber::load(&path, model).map(|t| Box::new(t) as Box<dyn Transcriber>)
            }
            #[cfg(not(feature = "local-stt"))]
            {
                let _ = (model, models_dir);
                Err(TranscriptionFailure::NotReady("built without local-stt".into()))
            }
        }
        Engine::OpenRouter(model) => keys
            .value("OPENROUTER_API_KEY")
            .map(|key| Box::new(openrouter::OpenRouterTranscriber::new(model.id(), key)) as Box<dyn Transcriber>)
            .ok_or_else(|| TranscriptionFailure::NotReady("OPENROUTER_API_KEY missing".into())),
        Engine::ElevenLabsScribe => keys
            .value("ELEVEN_LABS_API_KEY")
            .map(|key| Box::new(elevenlabs::ScribeTranscriber::new(key)) as Box<dyn Transcriber>)
            .ok_or_else(|| TranscriptionFailure::NotReady("ELEVEN_LABS_API_KEY missing".into())),
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
