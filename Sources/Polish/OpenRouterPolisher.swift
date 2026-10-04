import Foundation

/// Cleanup through a cloud model via OpenRouter: stronger than the on-device model on long rewrites.
/// It receives the transcript and dictionary terms only — field context is dropped here, whatever the
/// caller passed, so nothing read from your screen can leave the Mac.
public final class OpenRouterPolisher: Polisher {
    public static let defaultModel = CloudCleanupModel.recommended.rawValue
    private static let timeout: TimeInterval = 25

    private let key: String
    private let model: String
    private let session: URLSession

    public init(key: String, model: String = OpenRouterPolisher.defaultModel, session: URLSession = .shared) {
        self.key = key
        self.model = model
        self.session = session
    }

    public func polish(_ spoken: String, style: WritingStyle, intensity: PolishIntensity, context: PolishContext) async -> PolishVerdict {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cloudContext = PolishContext(fieldText: nil, terms: context.terms)
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": PolishPrompt.instructions(for: style, intensity: intensity)],
                ["role": "user", "content": PolishPrompt.user(spoken: spoken, context: cloudContext)],
            ],
        ]
        if let preset = CloudCleanupModel(rawValue: model) {
            body["reasoning"] = preset.reasoning
            body["provider"] = preset.provider
            body["max_tokens"] = max(2048, spoken.split(whereSeparator: \.isWhitespace).count * 3 + 1024)
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let http = response as? HTTPURLResponse else { return .keepRaw(.failed("no HTTP response")) }
            if http.statusCode != 200 {
                let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
                return .keepRaw(
                    .failed(http.statusCode == 402 ? "OpenRouter: no credits (\(detail))" : "http \(http.statusCode) \(detail)"))
            }
            guard
                let choice = (json?["choices"] as? [[String: Any]])?.first,
                choice["finish_reason"] as? String != "length",
                let content = (choice["message"] as? [String: Any])?["content"] as? String
            else {
                return .keepRaw(.failed("unexpected response"))
            }
            return PolishGuard.verdict(spoken: spoken, candidate: content)
        } catch {
            return .keepRaw(.failed(String(describing: error)))
        }
    }
}
