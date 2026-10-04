import Foundation
import Testing

@testable import Polish

/// Explicit opt-in: sends only the published sample transcripts, never user recordings or history.
struct LiveCleanupProbeTests {
    private struct Corpus: Decodable {
        struct Case: Decodable {
            let id: String
            let spoken: String?
            let expected: String
            let style: WritingStyle
        }
        let vocabulary: [String]
        let cases: [Case]
    }

    private struct Result: Encodable {
        let model: String
        let caseID: String
        let milliseconds: Int
        let verdict: String
        let expected: String
        let delivered: String?
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEARSAY_LIVE_CLEANUP"] == "1"))
    func compareCloudCleanupModels() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let corpus = try JSONDecoder().decode(
            Corpus.self, from: Data(contentsOf: root.appendingPathComponent("Sources/Benchmark/Resources/suite.json")))
        let ids: Set<String> = ["correction", "technical", "list", "swedish", "portuguese", "long-request"]
        var results: [Result] = []
        for model in CloudCleanupModel.allCases.map(\.rawValue) + ["google/gemini-3.7-flash"] {
            for item in corpus.cases where ids.contains(item.id) {
                let start = ContinuousClock.now
                let verdict = await OpenRouterPolisher(key: key, model: model).polish(
                    try #require(item.spoken), style: item.style, intensity: .full,
                    context: PolishContext(fieldText: nil, terms: corpus.vocabulary))
                let duration = ContinuousClock.now - start
                let milliseconds = Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
                let label: String
                let delivered: String?
                switch verdict {
                case .accept(let text):
                    label = "accepted"
                    delivered = text.text
                case .keepRaw(let reason):
                    label = reason.label
                    delivered = nil
                }
                results.append(
                    Result(
                        model: model, caseID: item.id, milliseconds: milliseconds, verdict: label, expected: item.expected,
                        delivered: delivered))
                print("cleanup probe: \(model) / \(item.id): \(milliseconds) ms, \(label)")
            }
        }
        let output = try #require(ProcessInfo.processInfo.environment["HEARSAY_CLEANUP_PROBE_OUTPUT"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: output))
    }
}
