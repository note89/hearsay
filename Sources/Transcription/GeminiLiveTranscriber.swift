import AVFoundation
import Foundation

public enum GeminiLiveFailure: Error {
    case socket(String)
}

/// Google's streaming ASR over the Live API. Audio goes up while the key is held; the server commits
/// segments at pauses and streams its current guess in between. The final is the committed text once
/// the stream has drained. Language is always auto-detected, so mid-sentence mixing works.
public final class GeminiLiveTranscriber: Transcriber {
    public static let modelID = "gemini-3.5-transcribe-live"

    public static var keyAvailable: Bool { KeyStore.value("GEMINI_API_KEY") != nil }

    private static let sampleRate = 16000.0
    private static let chunkFrames = 1600 // 100 ms
    private static let drainQuiet: Duration = .milliseconds(300)
    private static let drainIdleGrace: Duration = .milliseconds(1200)
    private static let drainCap: Duration = .seconds(6)
    private static let pollInterval: Duration = .milliseconds(20)
    private static let maxVocabulary = 1000

    private let key: String

    /// nil when no GEMINI_API_KEY is available.
    public init?() {
        guard let key = KeyStore.value("GEMINI_API_KEY") else { return nil }
        self.key = key
    }

    public func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, hints: TranscriptionHints) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let key = key
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let text = try await Self.run(audio: audio, hints: hints, key: key) { partial in
                        continuation.yield(.partial(partial))
                    }
                    continuation.yield(.final(RawTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines))))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: session

    private static func run(audio: AsyncStream<AVAudioPCMBuffer>, hints: TranscriptionHints, key: String, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(key)")!
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        try await send(setup(hints), on: socket)

        let transcript = LiveTranscript()
        let reader = Task {
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let d): data = d
                    case .string(let s): data = Data(s.utf8)
                    @unknown default: continue
                    }
                    for update in parse(data) {
                        switch update {
                        case .committed(let text): await transcript.commit(text)
                        case .interim(let text): await transcript.setInterim(text)
                        case .turnComplete: await transcript.close()
                        }
                    }
                    partial(await transcript.partialText)
                    if await transcript.isClosed { return }
                }
            } catch {
                await transcript.close()
            }
        }
        defer { reader.cancel() }

        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        var converter = AudioBufferConverter(to: target)
        var pending = Data()
        for await buffer in audio {
            guard let out = try converter.convert(buffer), let channel = out.int16ChannelData?[0] else { continue }
            pending.append(Data(bytes: channel, count: Int(out.frameLength) * 2))
            if pending.count >= chunkFrames * 2 {
                try await send(audioChunk(pending), on: socket)
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty { try await send(audioChunk(pending), on: socket) }
        try await send(["realtimeInput": ["audioStreamEnd": true]], on: socket)
        await transcript.audioEnded()

        // Drain: the server's turn end, else quiet after a post-end commit, else a bounded wait.
        let ended = ContinuousClock.now
        while ContinuousClock.now - ended < drainCap {
            if await transcript.isClosed { break }
            if let settled = await transcript.settledSince(quiet: drainQuiet) { _ = settled; break }
            if await transcript.nothingPending, ContinuousClock.now - ended >= drainIdleGrace { break }
            try await Task.sleep(for: pollInterval)
        }
        return await transcript.finalText
    }

    private enum ServerUpdate {
        case committed(String)
        case interim(String)
        case turnComplete
    }

    private static func parse(_ data: Data) -> [ServerUpdate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["serverContent"] as? [String: Any] else { return [] }
        var updates: [ServerUpdate] = []
        if let text = (content["inputTranscription"] as? [String: Any])?["text"] as? String { updates.append(.committed(text)) }
        if let text = (content["interimInputTranscription"] as? [String: Any])?["text"] as? String { updates.append(.interim(text)) }
        if content["turnComplete"] as? Bool == true { updates.append(.turnComplete) }
        return updates
    }

    private static func setup(_ hints: TranscriptionHints) -> [String: Any] {
        var transcription: [String: Any] = [
            "languageCodes": [String](),
            "mode": hints.mode == .smart ? "SMART" : "VERBATIM",
        ]
        if !hints.vocabulary.isEmpty { transcription["customVocabulary"] = Array(hints.vocabulary.prefix(maxVocabulary)) }
        return [
            "setup": [
                "model": "models/\(modelID)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": transcription,
            ],
        ]
    }

    private static func audioChunk(_ pcm: Data) -> [String: Any] {
        ["realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]]
    }

    private static func send(_ object: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            throw GeminiLiveFailure.socket(String(describing: error))
        }
    }
}

/// The live take: committed segments, the interim guess, and whether the server is done.
private actor LiveTranscript {
    private var committed: [String] = []
    private var interim = ""
    private var closed = false
    private var ended = false
    private var commitsAfterEnd = 0
    private var lastCommit: ContinuousClock.Instant?

    func commit(_ text: String) {
        committed.append(text)
        interim = ""
        lastCommit = .now
        if ended { commitsAfterEnd += 1 }
    }

    func setInterim(_ text: String) { interim = text }
    func close() { closed = true }
    func audioEnded() { ended = true }

    var isClosed: Bool { closed }
    var partialText: String { [committed.joined(separator: " "), interim].filter { !$0.isEmpty }.joined(separator: " ") }
    var finalText: String { committed.isEmpty ? interim : committed.joined(separator: " ") }
    var nothingPending: Bool { interim.isEmpty && commitsAfterEnd == 0 }

    /// Non-nil once a commit arrived after the audio ended and the line has been quiet since.
    func settledSince(quiet: Duration) -> ContinuousClock.Instant? {
        guard commitsAfterEnd > 0, let last = lastCommit, ContinuousClock.now - last >= quiet else { return nil }
        return last
    }
}
