import AVFoundation

/// Text as the transcriber heard it. Only a `Transcriber` can mint one.
public struct RawTranscript: Equatable, Sendable {
    public let text: String

    init(text: String) {
        self.text = text
    }
}

public enum TranscriptionEvent: Sendable {
    case partial(String)
    case final(RawTranscript)
}

/// Contract violations any engine can commit; engine-specific failures live with their engines.
public enum TranscriptionFailure: Error {
    case endedWithoutFinal
}

/// What the dictation should read like: what was said, or what was meant to be written.
public enum TranscriptMode: Sendable, Equatable {
    case verbatim
    case smart
}

/// What every engine is told before it hears the utterance. Engines ignore what they cannot use.
public struct TranscriptionHints: Sendable {
    public let vocabulary: [String]
    public let mode: TranscriptMode

    public init(vocabulary: [String], mode: TranscriptMode) {
        self.vocabulary = vocabulary
        self.mode = mode
    }

    public static let none = TranscriptionHints(vocabulary: [], mode: .verbatim)
}

public protocol Transcriber {
    /// One utterance in; partials out, ending in exactly one `.final`.
    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, hints: TranscriptionHints) -> AsyncThrowingStream<TranscriptionEvent, Error>
}
