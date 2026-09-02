import AVFoundation
import Foundation

public enum ElevenLabsFailure: Error {
    case badResponse(String)
}

/// ElevenLabs Scribe — dedicated cloud ASR, for comparison runs. One shot at end of input.
public final class ElevenLabsTranscriber: Transcriber {
    public static let modelID = "scribe_v2"

    public static var keyAvailable: Bool { KeyStore.value("ELEVEN_LABS_API_KEY") != nil }

    private let key: String

    /// nil when no ELEVEN_LABS_API_KEY is available. Scribe detects the language itself.
    public init?() {
        guard let key = KeyStore.value("ELEVEN_LABS_API_KEY") else { return nil }
        self.key = key
    }

    public func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, hints: TranscriptionHints) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let key = key
        return oneShotWavTranscription(audio) { wav in try await Self.request(wav: wav, key: key) }
    }

    private static func request(wav: Data, key: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let boundary = "hearsay-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model_id", modelID)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"utterance.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw ElevenLabsFailure.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "unreadable")
        }
        return text
    }
}
