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
                var accumulator = WavAccumulator()
                for await buffer in audio { try accumulator.append(buffer) }
                let text = try await request(accumulator.wavData())
                continuation.yield(.final(RawTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines))))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
