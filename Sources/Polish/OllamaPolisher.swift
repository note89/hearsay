import Foundation

public struct OllamaModel: Decodable, Equatable, Sendable {
    public let name: String
    public let size: Int64
}

/// The local Ollama server owns model loading. Only transcript and dictionary terms are sent,
/// including when that server is configured to use an Ollama cloud model.
public final class OllamaPolisher: Polisher {
    public static let server = URL(string: "http://localhost:11434")!
    private let model: String
    private let session: URLSession

    public init(model: String, session: URLSession = .shared) {
        self.model = model
        self.session = session
    }

    public static func models(session: URLSession = .shared) async throws -> [OllamaModel] {
        var request = URLRequest(url: server.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Catalog: Decodable { let models: [OllamaModel] }
        return try JSONDecoder().decode(Catalog.self, from: data).models.sorted {
            $0.size == $1.size ? $0.name < $1.name : $0.size < $1.size
        }
    }

    public func polish(_ spoken: String, style: WritingStyle, intensity: PolishIntensity, context: PolishContext) async -> PolishVerdict {
        guard !model.isEmpty else { return .keepRaw(.modelUnavailable) }
        var request = URLRequest(url: Self.server.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "keep_alive": "10m",
            "options": ["temperature": 0],
            "messages": [
                ["role": "system", "content": PolishPrompt.instructions(for: style, intensity: intensity)],
                [
                    "role": "user",
                    "content": PolishPrompt.user(spoken: spoken, context: PolishContext(fieldText: nil, terms: context.terms)),
                ],
            ],
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .keepRaw(.failed("Ollama: no HTTP response")) }
            guard http.statusCode == 200 else { return .keepRaw(.failed("Ollama: HTTP \(http.statusCode)")) }
            struct Response: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
                let done: Bool
                let doneReason: String?
                enum CodingKeys: String, CodingKey {
                    case message, done
                    case doneReason = "done_reason"
                }
            }
            let result = try JSONDecoder().decode(Response.self, from: data)
            guard result.done, result.doneReason != "length" else { return .keepRaw(.failed("Ollama: incomplete response")) }
            return PolishGuard.verdict(spoken: spoken, candidate: result.message.content)
        } catch {
            return .keepRaw(.failed("Ollama: \(error.localizedDescription)"))
        }
    }
}
