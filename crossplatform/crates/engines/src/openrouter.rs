use hearsay_core::polish::{self, PolishContext, PolishGuard, PolishIntensity, PolishRejection, PolishVerdict, Polisher, WritingStyle};
use hearsay_core::session::{RawTranscript, TranscriptionFailure, TranscriptionHints, Transcriber};
use serde_json::{json, Value};

const CHAT_URL: &str = "https://openrouter.ai/api/v1/chat/completions";

fn chat(key: &str, body: Value) -> Result<String, String> {
    let response = super::http()
        .post(CHAT_URL)
        .bearer_auth(key)
        .json(&body)
        .send()
        .map_err(|e| format!("request: {e}"))?;
    let status = response.status();
    let json: Value = response.json().map_err(|e| format!("body: {e}"))?;
    if !status.is_success() {
        return Err(format!("http {status}"));
    }
    json["choices"][0]["message"]["content"].as_str().map(String::from).ok_or_else(|| "unexpected response shape".to_string())
}

/// Audio-capable LLM via OpenRouter — a cloud comparison engine. Detects the language itself.
pub struct OpenRouterTranscriber {
    model: String,
    key: String,
}

impl OpenRouterTranscriber {
    pub fn new(model: &str, key: String) -> Self {
        Self { model: model.to_string(), key }
    }
}

impl Transcriber for OpenRouterTranscriber {
    fn transcribe(&self, samples_16k: &[f32], hints: &TranscriptionHints) -> Result<RawTranscript, TranscriptionFailure> {
        let wav = super::wav_from_samples(samples_16k);
        let body = json!({
            "model": self.model,
            "messages": [{
                "role": "user",
                "content": [
                    {"type": "text", "text": transcription_prompt(hints)},
                    {"type": "input_audio", "input_audio": {"data": crate::base64::encode(&wav), "format": "wav"}}
                ]
            }]
        });
        chat(&self.key, body).map(RawTranscript::from_engine).map_err(TranscriptionFailure::Failed)
    }
}

/// Cloud polish through OpenRouter, guarded like every polisher. Opt-in: the field context and
/// dictionary terms travel with the prompt, so this is only offered when no local model exists.
pub struct OpenRouterPolisher {
    model: String,
    key: String,
}

impl OpenRouterPolisher {
    pub const DEFAULT_MODEL: &'static str = "google/gemini-2.5-flash-lite";

    pub fn new(key: String) -> Self {
        Self { model: Self::DEFAULT_MODEL.to_string(), key }
    }
}

impl Polisher for OpenRouterPolisher {
    fn polish(&self, spoken: &str, style: WritingStyle, intensity: PolishIntensity, context: &PolishContext) -> PolishVerdict {
        let body = json!({
            "model": self.model,
            "temperature": 0,
            "messages": [
                {"role": "system", "content": polish::instructions(style, intensity)},
                {"role": "user", "content": polish::prompt(spoken, context)}
            ]
        });
        match chat(&self.key, body) {
            Ok(candidate) => PolishGuard::verdict(spoken, &candidate),
            Err(e) => PolishVerdict::KeepRaw(PolishRejection::Failed(e)),
        }
    }
}

/// Verbatim always: the polish concept owns cleanup. Dictionary terms ride along as spelling hints.
fn transcription_prompt(hints: &TranscriptionHints) -> String {
    let mut prompt = String::from("Transcribe this audio verbatim, in its original language (it may mix languages mid-sentence; keep the mix). Output only the transcript text — no quotes, no commentary.");
    if !hints.vocabulary.is_empty() {
        prompt.push_str(" Spell these terms exactly when you hear them: ");
        prompt.push_str(&hints.vocabulary.join(", "));
        prompt.push('.');
    }
    prompt
}
