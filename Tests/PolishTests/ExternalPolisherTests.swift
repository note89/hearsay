import Foundation
import Testing

@testable import Polish

private final class ReplyProtocol: URLProtocol, @unchecked Sendable {
    static var reply: ((URLRequest) throws -> (Int, String))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, text) = try Self.reply(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    var data = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite(.serialized)
struct ExternalPolisherTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplyProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test(arguments: CloudCleanupModel.allCases)
    func cloudUsesSelectedModelAndKeepsFieldContextPrivate(_ model: CloudCleanupModel) async throws {
        ReplyProtocol.reply = { request in
            let body = try requestBody(request)
            #expect(body["model"] as? String == model.rawValue)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let messages = try #require(body["messages"] as? [[String: String]])
            let text = try #require(messages.last?["content"])
            #expect(text.contains("Keycloak"))
            #expect(!text.contains("PRIVATE_CURSOR_CONTEXT"))
            let reasoning = try #require(body["reasoning"] as? [String: Any])
            if model == .glmFlash { #expect(reasoning["effort"] as? String == "low") }
            if model == .geminiFlash { #expect(reasoning["effort"] as? String == "low") }
            let provider = try #require(body["provider"] as? [String: Any])
            #expect(provider["sort"] as? String == "throughput")
            #expect(provider["max_price"] != nil)
            return (200, "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"Send the invoice\"}}]}")
        }
        let session = session()
        defer { session.invalidateAndCancel() }
        let verdict = await OpenRouterPolisher(key: "test-key", model: model.rawValue, session: session).polish(
            "um send the invoice", style: .chat, intensity: .full,
            context: PolishContext(fieldText: "PRIVATE_CURSOR_CONTEXT", terms: ["Keycloak"]))
        if case .accept(let cleaned) = verdict { #expect(cleaned.text == "Send the invoice") } else { Issue.record("Cleanup failed") }
    }

    @Test func ollamaUsesLocalServerWithoutThinkingOrFieldContext() async throws {
        ReplyProtocol.reply = { request in
            #expect(request.url?.host == "localhost")
            #expect(request.url?.path == "/api/chat")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = try requestBody(request)
            #expect(body["model"] as? String == "small-model:latest")
            #expect(body["stream"] as? Bool == false)
            #expect(body["think"] as? Bool == false)
            #expect(body["keep_alive"] as? String == "10m")
            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(messages.last?["content"]?.contains("Keycloak") == true)
            #expect(messages.allSatisfy { !$0.values.contains(where: { $0.contains("PRIVATE_CURSOR_CONTEXT") }) })
            return (200, "{\"done\":true,\"done_reason\":\"stop\",\"message\":{\"content\":\"Send the invoice\"}}")
        }
        let session = session()
        defer { session.invalidateAndCancel() }
        let verdict = await OllamaPolisher(model: "small-model:latest", session: session).polish(
            "um send the invoice", style: .chat, intensity: .full,
            context: PolishContext(fieldText: "PRIVATE_CURSOR_CONTEXT", terms: ["Keycloak"]))
        if case .accept(let cleaned) = verdict { #expect(cleaned.text == "Send the invoice") } else { Issue.record("Cleanup failed") }
    }

    @Test func catalogListsModelsWithSmallestDownloadsFirst() async throws {
        ReplyProtocol.reply = { request in
            #expect(request.url?.path == "/api/tags")
            return (200, "{\"models\":[{\"name\":\"large\",\"size\":10000},{\"name\":\"small\",\"size\":100}]}")
        }
        let session = session()
        defer { session.invalidateAndCancel() }
        #expect(try await OllamaPolisher.models(session: session).map(\.name) == ["small", "large"])
    }

    @Test(arguments: [
        (404, "{}"), (200, "{}"), (200, "{\"done\":false,\"message\":{\"content\":\"send\"}}"),
        (200, "{\"done\":true,\"done_reason\":\"length\",\"message\":{\"content\":\"send\"}}"),
    ])
    func unavailableOrIncompleteOllamaKeepsRaw(_ response: (Int, String)) async {
        ReplyProtocol.reply = { _ in response }
        let session = session()
        defer { session.invalidateAndCancel() }
        let verdict = await OllamaPolisher(model: "test", session: session).polish(
            "send the invoice", style: .plain, intensity: .full, context: .none)
        if case .keepRaw = verdict {} else { Issue.record("Incomplete cleanup must not be inserted") }
    }

    @Test func truncatedCloudCleanupKeepsRaw() async {
        ReplyProtocol.reply = { _ in (200, "{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"send\"}}]}") }
        let session = session()
        defer { session.invalidateAndCancel() }
        let verdict = await OpenRouterPolisher(key: "test", session: session).polish(
            "send the invoice", style: .plain, intensity: .full, context: .none)
        if case .keepRaw = verdict {} else { Issue.record("Truncated cleanup must not be inserted") }
    }
}
