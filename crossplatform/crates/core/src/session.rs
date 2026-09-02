//! Session decisions: the types a session runs under and the pure steps between transcription and
//! delivery. Orchestration (threads, audio, hotkeys, UI) belongs to the app; this module owns the
//! rules so they are testable without any of that.

use crate::engine::Engine;
use crate::lexicon::Lexicon;
use crate::polish::{PolishContext, PolishIntensity, PolishVerdict, Polisher, PolishedText, WritingStyle};

/// Text as the transcriber heard it. Only a `Transcriber` mints one.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct RawTranscript(pub(crate) String);

impl RawTranscript {
    /// Engines live in another crate; this is the one door.
    pub fn from_engine(text: String) -> Self {
        RawTranscript(text.trim().to_string())
    }

    pub fn text(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, thiserror::Error)]
pub enum TranscriptionFailure {
    #[error("engine not ready: {0}")]
    NotReady(String),
    #[error("transcription failed: {0}")]
    Failed(String),
}

/// What the dictation should read like: what was said, or what was meant to be written.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TranscriptMode {
    Verbatim,
    Smart,
}

/// What every engine is told before it hears the utterance. Engines ignore what they cannot use.
#[derive(Clone, Debug)]
pub struct TranscriptionHints {
    pub vocabulary: Vec<String>,
    pub mode: TranscriptMode,
}

impl Default for TranscriptionHints {
    fn default() -> Self {
        TranscriptionHints { vocabulary: Vec::new(), mode: TranscriptMode::Verbatim }
    }
}

/// A batch engine: the whole utterance at release.
pub trait Transcriber: Send + Sync {
    /// Mono 16 kHz samples in, the words said out. Blocking; the app runs it off the UI thread.
    fn transcribe(&self, samples_16k: &[f32], hints: &TranscriptionHints) -> Result<RawTranscript, TranscriptionFailure>;
}

/// A streaming engine: audio in while the key is held, partials on the way, one final at the end.
pub trait LiveTranscriber: Send + Sync {
    /// Non-blocking: connection and streaming happen on the session's own thread.
    fn start(&self, hints: &TranscriptionHints) -> Box<dyn LiveTranscription>;
}

pub trait LiveTranscription: Send {
    /// Mono 16 kHz samples as they arrive. Non-blocking.
    fn feed(&mut self, samples_16k: &[f32]);
    /// Committed text plus the current interim guess, for the pill.
    fn partial(&self) -> String;
    /// Ends the audio and waits (bounded) for the final. Blocking; run it off the UI thread.
    fn finish(self: Box<Self>) -> Result<RawTranscript, TranscriptionFailure>;
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PolishMode {
    Off,
    Light,
    Full,
}

impl PolishMode {
    pub fn intensity(self) -> Option<PolishIntensity> {
        match self {
            PolishMode::Off => None,
            PolishMode::Light => Some(PolishIntensity::Light),
            PolishMode::Full => Some(PolishIntensity::Full),
        }
    }
}

/// The rules a session runs under, snapshotted at press. Later settings changes cannot affect a
/// session in flight.
#[derive(Clone, Debug)]
pub struct SessionRules {
    pub engine: Engine,
    pub style: WritingStyle,
    pub polish: PolishMode,
    pub lexicon: Lexicon,
}

/// What a session does with its text: the single representation of "dictate vs bake-off".
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum SessionPlan {
    Dictate,
    Bakeoff { expected: Option<String>, run_id: String, take_id: String, engines: Vec<Engine> },
}

/// Text bound for the target, with its provenance.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum InsertableText {
    Polished { polished: PolishedText, spoken: RawTranscript },
    Raw(RawTranscript),
    /// Dictionary rewrites applied over a polished or raw base — the base is kept, not flattened.
    Rewritten { text: String, over: Box<InsertableText> },
}

impl InsertableText {
    pub fn text(&self) -> &str {
        match self {
            InsertableText::Polished { polished, .. } => polished.text(),
            InsertableText::Raw(raw) => raw.text(),
            InsertableText::Rewritten { text, .. } => text,
        }
    }

    pub fn spoken(&self) -> &str {
        match self {
            InsertableText::Polished { spoken, .. } => spoken.text(),
            InsertableText::Raw(raw) => raw.text(),
            InsertableText::Rewritten { over, .. } => over.spoken(),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum InsertionEvidence {
    /// The field was re-read and had changed.
    Verified,
    /// Events were posted; the target could not be re-read to confirm.
    Posted,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum InsertionBlock {
    AllStrategiesFailed,
    NoFrontmostApp,
    TargetLost,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum InsertionOutcome {
    Inserted { evidence: InsertionEvidence },
    CopiedToClipboard(InsertionBlock),
}

pub trait Inserter: Send + Sync {
    fn insert(&self, text: &str) -> InsertionOutcome;
    fn copy(&self, text: &str);
}

/// Everything between "the engine heard this" and "this text is ready to land":
/// polish under the session's rules (guarded), then dictionary rewrites.
pub fn deliver(rules: &SessionRules, raw: RawTranscript, polisher: &dyn Polisher, context: &PolishContext) -> (InsertableText, Option<crate::polish::PolishRejection>) {
    let mut rejection = None;
    let mut delivered = match rules.polish.intensity() {
        None => InsertableText::Raw(raw),
        Some(intensity) => match polisher.polish(raw.text(), rules.style, intensity, context) {
            PolishVerdict::Accept(polished) => InsertableText::Polished { polished, spoken: raw },
            PolishVerdict::KeepRaw(why) => {
                rejection = Some(why);
                InsertableText::Raw(raw)
            }
        },
    };
    if let Some(rewritten) = rules.lexicon.rewrite_result(delivered.text()) {
        delivered = InsertableText::Rewritten { text: rewritten, over: Box::new(delivered) };
    }
    (delivered, rejection)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lexicon;
    use crate::polish::{PolishGuard, PolishRejection};

    struct EchoPolisher(&'static str);
    impl Polisher for EchoPolisher {
        fn polish(&self, spoken: &str, _: WritingStyle, _: PolishIntensity, _: &PolishContext) -> PolishVerdict {
            PolishGuard::verdict(spoken, self.0)
        }
    }

    fn rules(polish: PolishMode) -> SessionRules {
        SessionRules { engine: Engine::default_engine(), style: WritingStyle::Plain, polish, lexicon: Lexicon::from_entries(&lexicon::parse("mprox -> mprocs")) }
    }

    #[test]
    fn polish_off_keeps_raw_but_still_rewrites() {
        let (text, rejection) = deliver(&rules(PolishMode::Off), RawTranscript::from_engine("run mprox now".into()), &EchoPolisher("unused"), &PolishContext::default());
        assert_eq!(text.text(), "run mprocs now");
        assert_eq!(text.spoken(), "run mprox now");
        assert!(rejection.is_none());
        assert!(matches!(text, InsertableText::Rewritten { over, .. } if matches!(*over, InsertableText::Raw(_))));
    }

    #[test]
    fn guard_rejection_falls_back_to_raw() {
        let (text, rejection) = deliver(&rules(PolishMode::Full), RawTranscript::from_engine("send the invoice".into()), &EchoPolisher("Certainly! Here is a plan for your finances with many steps."), &PolishContext::default());
        assert_eq!(text.text(), "send the invoice");
        assert_eq!(rejection, Some(PolishRejection::MeaningDrift));
    }

    #[test]
    fn accepted_polish_keeps_provenance() {
        let (text, _) = deliver(&rules(PolishMode::Light), RawTranscript::from_engine("um send the invoice".into()), &EchoPolisher("Send the invoice."), &PolishContext::default());
        assert!(matches!(text, InsertableText::Polished { .. }));
        assert_eq!(text.spoken(), "um send the invoice");
    }
}
