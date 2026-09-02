use hearsay_core::engine::WhisperModel;
use hearsay_core::session::{RawTranscript, TranscriptionFailure, Transcriber};
use std::path::Path;
use std::sync::Mutex;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

/// whisper.cpp on this machine. Batch: the whole utterance at release; language auto-detected on
/// multilingual models.
pub struct WhisperTranscriber {
    context: WhisperContext,
    /// whisper state is not thread-safe; one utterance at a time.
    lock: Mutex<()>,
    model: WhisperModel,
}

impl WhisperTranscriber {
    pub fn load(path: &Path, model: WhisperModel) -> Result<Self, TranscriptionFailure> {
        whisper_rs::install_logging_hooks();   // route whisper.cpp's stderr chatter through `log`
        let context = WhisperContext::new_with_params(&path.to_string_lossy(), WhisperContextParameters::default())
            .map_err(|e| TranscriptionFailure::NotReady(format!("whisper load: {e}")))?;
        Ok(Self { context, lock: Mutex::new(()), model })
    }
}

impl Transcriber for WhisperTranscriber {
    fn transcribe(&self, samples_16k: &[f32]) -> Result<RawTranscript, TranscriptionFailure> {
        let _guard = self.lock.lock().map_err(|_| TranscriptionFailure::Failed("whisper lock poisoned".into()))?;
        let mut state = self.context.create_state().map_err(|e| TranscriptionFailure::Failed(format!("whisper state: {e}")))?;
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_language(Some(if self.model == WhisperModel::BaseEn { "en" } else { "auto" }));
        params.set_translate(false);
        params.set_print_progress(false);
        params.set_print_special(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_suppress_blank(true);
        state.full(params, samples_16k).map_err(|e| TranscriptionFailure::Failed(format!("whisper: {e}")))?;
        let segments = state.full_n_segments().map_err(|e| TranscriptionFailure::Failed(format!("whisper segments: {e}")))?;
        let mut text = String::new();
        for i in 0..segments {
            if let Ok(segment) = state.full_get_segment_text(i) {
                text.push_str(&segment);
            }
        }
        Ok(RawTranscript::from_engine(text))
    }
}

/// Fetches a model into the models directory. Blocking; the app runs it on a thread.
pub fn download_model(model: WhisperModel, models_dir: &Path) -> Result<(), String> {
    std::fs::create_dir_all(models_dir).map_err(|e| e.to_string())?;
    let target = models_dir.join(model.file_name());
    let partial = models_dir.join(format!("{}.partial", model.file_name()));
    let bytes = reqwest::blocking::Client::builder()
        .timeout(None)
        .build()
        .map_err(|e| e.to_string())?
        .get(model.download_url())
        .send()
        .and_then(|r| r.error_for_status())
        .map_err(|e| e.to_string())?
        .bytes()
        .map_err(|e| e.to_string())?;
    std::fs::write(&partial, &bytes).map_err(|e| e.to_string())?;
    std::fs::rename(&partial, &target).map_err(|e| e.to_string())
}
