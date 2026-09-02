use crate::keystore::KeyStore;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PrivacyClass {
    OnDevice,
    Cloud,
}

/// whisper.cpp models hearsay knows how to fetch and label. Adding one is one variant + one row.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum WhisperModel {
    BaseEn,
    LargeV3Turbo,
}

impl WhisperModel {
    pub const ALL: [WhisperModel; 2] = [WhisperModel::BaseEn, WhisperModel::LargeV3Turbo];

    pub fn id(self) -> &'static str {
        match self {
            WhisperModel::BaseEn => "base.en",
            WhisperModel::LargeV3Turbo => "large-v3-turbo",
        }
    }

    pub fn file_name(self) -> String {
        format!("ggml-{}.bin", self.id())
    }

    pub fn download_url(self) -> String {
        format!("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{}", self.file_name())
    }

    pub fn blurb(self) -> &'static str {
        match self {
            WhisperModel::BaseEn => "English only, ~150 MB, fast",
            WhisperModel::LargeV3Turbo => "99 languages with auto-detect, ~1.6 GB, best local accuracy",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum OpenRouterModel {
    GeminiFlashLite,
    GeminiFlash,
}

impl OpenRouterModel {
    pub const ALL: [OpenRouterModel; 2] = [OpenRouterModel::GeminiFlashLite, OpenRouterModel::GeminiFlash];

    pub fn id(self) -> &'static str {
        match self {
            OpenRouterModel::GeminiFlashLite => "google/gemini-2.5-flash-lite",
            OpenRouterModel::GeminiFlash => "google/gemini-2.5-flash",
        }
    }

    pub fn price_per_100k_words(self) -> &'static str {
        match self {
            OpenRouterModel::GeminiFlashLite => "~$0.50 per 100k words",
            OpenRouterModel::GeminiFlash => "~$1.85 per 100k words",
        }
    }
}

/// The engine concept: who turns audio into text, at what cost and privacy. One type owns identity
/// (wire key), display, availability and privacy. Wire keys are shared with the macOS app so bake-off
/// records are comparable across platforms.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Engine {
    Whisper(WhisperModel),
    OpenRouter(OpenRouterModel),
    ElevenLabsScribe,
}

pub const ELEVENLABS_MODEL_ID: &str = "scribe_v2";

impl Engine {
    pub fn all() -> Vec<Engine> {
        let mut all: Vec<Engine> = WhisperModel::ALL.iter().map(|m| Engine::Whisper(*m)).collect();
        all.push(Engine::ElevenLabsScribe);
        all.extend(OpenRouterModel::ALL.iter().map(|m| Engine::OpenRouter(*m)));
        all
    }

    /// Persisted in settings and stamped on bake-off records. `parse` is its exact inverse.
    pub fn wire_key(&self) -> String {
        match self {
            Engine::Whisper(m) => format!("whisper/{}", m.id()),
            Engine::OpenRouter(m) => m.id().to_string(),
            Engine::ElevenLabsScribe => format!("elevenlabs/{ELEVENLABS_MODEL_ID}"),
        }
    }

    pub fn parse(wire_key: &str) -> Option<Engine> {
        Engine::all().into_iter().find(|e| e.wire_key() == wire_key)
    }

    pub fn label(&self) -> String {
        match self {
            Engine::Whisper(m) => format!("Whisper · {} (local, $0)", m.id()),
            Engine::OpenRouter(m) => format!("OpenRouter · {}", m.id()),
            Engine::ElevenLabsScribe => "ElevenLabs · Scribe".to_string(),
        }
    }

    pub fn detail(&self) -> String {
        match self {
            Engine::Whisper(m) => format!("whisper.cpp on this machine, works offline · {}", m.blurb()),
            Engine::OpenRouter(m) => format!("Google cloud via OpenRouter · {}", m.price_per_100k_words()),
            Engine::ElevenLabsScribe => "ElevenLabs Scribe v2 cloud, dedicated ASR, 90+ languages, mixes them mid-sentence · ~$2.45 per 100k words".to_string(),
        }
    }

    pub fn required_key(&self) -> Option<&'static str> {
        match self {
            Engine::Whisper(_) => None,
            Engine::OpenRouter(_) => Some("OPENROUTER_API_KEY"),
            Engine::ElevenLabsScribe => Some("ELEVEN_LABS_API_KEY"),
        }
    }

    pub fn is_available(&self, keys: &KeyStore) -> bool {
        match self.required_key() {
            None => true,
            Some(name) => keys.value(name).is_some(),
        }
    }

    pub fn privacy_class(&self) -> PrivacyClass {
        match self {
            Engine::Whisper(_) => PrivacyClass::OnDevice,
            Engine::OpenRouter(_) | Engine::ElevenLabsScribe => PrivacyClass::Cloud,
        }
    }

    pub fn default_engine() -> Engine {
        Engine::Whisper(WhisperModel::BaseEn)
    }
}

#[cfg(test)]
mod tests {
    use super::Engine;

    #[test]
    fn wire_key_round_trips_for_every_engine() {
        for engine in Engine::all() {
            assert_eq!(Engine::parse(&engine.wire_key()), Some(engine));
        }
        assert_eq!(Engine::parse("apple-local"), None);
        assert_eq!(Engine::parse("evil-model"), None);
    }
}
