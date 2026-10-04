import AVFoundation

/// Shape shared by the cloud engines: accumulate the utterance as WAV, one request at end of input,
/// exactly one `.final`. Engines supply only the request.
func oneShotWavTranscription(
    _ audio: AsyncStream<AVAudioPCMBuffer>,
    request: @escaping @Sendable (Data) async throws -> String
) -> AsyncThrowingStream<TranscriptionEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task.detached {
            do {
                let transcript = try await wavTranscript(audio, request: request)
                continuation.yield(.final(transcript))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// The request boundary is shared with deterministic cancellation tests.
func wavTranscript(
    _ audio: AsyncStream<AVAudioPCMBuffer>,
    request: @escaping @Sendable (Data) async throws -> String
) async throws -> RawTranscript {
    var accumulator = WavAccumulator()
    for await buffer in audio {
        try Task.checkCancellation()
        try accumulator.append(buffer)
    }
    // Cancellation terminates AsyncStream iteration normally; it must not start a request.
    try Task.checkCancellation()
    try accumulator.finish()
    try Task.checkCancellation()
    let text = try await request(accumulator.wavData())
    try Task.checkCancellation()
    return RawTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
}
