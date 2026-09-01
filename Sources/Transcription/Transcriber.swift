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

public protocol Transcriber {
    /// One utterance in; partials out, ending in exactly one `.final`.
    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptionEvent, Error>
}
