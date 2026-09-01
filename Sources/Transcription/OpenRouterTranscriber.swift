import AVFoundation
import Foundation

public enum OpenRouterFailure: Error {
    case badResponse(String)
}

/// Cloud engine for comparison runs: ships the whole utterance as WAV to an audio-capable LLM via OpenRouter.
/// No partials — one shot at end of input.
public final class OpenRouterTranscriber: Transcriber {
    public static let defaultModel = "google/gemini-2.5-flash-lite"

    public static var keyAvailable: Bool { KeyStore.value("OPENROUTER_API_KEY") != nil }

    private let model: String
    private let localeHint: Locale
    private let key: String

    /// nil when no OPENROUTER_API_KEY is available.
    public init?(model: String = OpenRouterTranscriber.defaultModel, locale: Locale) {
        guard let key = KeyStore.value("OPENROUTER_API_KEY") else { return nil }
        self.key = key
        self.model = model
        self.localeHint = locale
    }

    public func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let (model, locale, key) = (model, localeHint, key)
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    var accumulator = WavAccumulator()
                    for await buffer in audio { try accumulator.append(buffer) }
                    let text = try await Self.request(wav: accumulator.wavData(), model: model, locale: locale, key: key)
                    continuation.yield(.final(RawTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines))))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func request(wav: Data, model: String, locale: Locale, key: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let language = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        let body: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "Transcribe this audio verbatim. Expected language: \(language). Output only the transcript text — no quotes, no commentary."],
                    ["type": "input_audio", "input_audio": ["data": wav.base64EncodedString(), "format": "wav"]],
                ],
            ]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenRouterFailure.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "unreadable")
        }
        return content
    }
}
