use hearsay_core::engine::ELEVENLABS_MODEL_ID;
use hearsay_core::session::{RawTranscript, TranscriptionFailure, Transcriber};
use serde_json::Value;

/// ElevenLabs Scribe — dedicated cloud ASR, detects the language itself.
pub struct ScribeTranscriber {
    key: String,
}

impl ScribeTranscriber {
    pub fn new(key: String) -> Self {
        Self { key }
    }
}

impl Transcriber for ScribeTranscriber {
    fn transcribe(&self, samples_16k: &[f32]) -> Result<RawTranscript, TranscriptionFailure> {
        let wav = super::wav_from_samples(samples_16k);
        let form = reqwest::blocking::multipart::Form::new()
            .text("model_id", ELEVENLABS_MODEL_ID)
            .part("file", reqwest::blocking::multipart::Part::bytes(wav).file_name("utterance.wav").mime_str("audio/wav").map_err(|e| TranscriptionFailure::Failed(e.to_string()))?);
        let response = super::http()
            .post("https://api.elevenlabs.io/v1/speech-to-text")
            .header("xi-api-key", &self.key)
            .multipart(form)
            .send()
            .map_err(|e| TranscriptionFailure::Failed(format!("request: {e}")))?;
        let status = response.status();
        let json: Value = response.json().map_err(|e| TranscriptionFailure::Failed(format!("body: {e}")))?;
        if !status.is_success() {
            return Err(TranscriptionFailure::Failed(format!("http {status}")));
        }
        json["text"].as_str().map(|t| RawTranscript::from_engine(t.to_string())).ok_or_else(|| TranscriptionFailure::Failed("unexpected response shape".into()))
    }
}
