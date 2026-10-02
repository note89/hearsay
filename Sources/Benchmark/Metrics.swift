import Bakeoff
import Foundation

public struct TextScore: Codable, Sendable {
    public let wer: Double
    public let characterErrorRate: Double
    public let exact: Bool

    public init(reference: String, hypothesis: String) {
        let ref = Self.canonical(reference)
        let hyp = Self.canonical(hypothesis)
        wer = Scorer.wer(reference: ref, hypothesis: hyp)
        let a = Array(ref)
        let b = Array(hyp)
        var previous = Array(0...b.count)
        for (index, char) in a.enumerated() {
            var row = [index + 1] + Array(repeating: 0, count: b.count)
            for (other, candidate) in b.enumerated() {
                row[other + 1] = min(previous[other + 1] + 1, row[other] + 1, previous[other] + (char == candidate ? 0 : 1))
            }
            previous = row
        }
        characterErrorRate = Double(previous[b.count]) / Double(max(1, a.count))
        exact = ref == hyp
    }

    private static func canonical(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct BenchmarkOutput: Codable, Sendable {
    public let raw: String
    public let delivered: String
    public let rawScore: TextScore?
    public let finalScore: TextScore
    public let wisprScore: TextScore?
    public let cleanupRejection: String?
    public let audioMs: Int
    public let setupMs: Int
    public let modelStartup: ModelStartup
    public let modelLoadMs: Int
    public let firstPartialMs: Int?
    public let transcriptionMs: Int
    public let afterAudioMs: Int
    public let polishMs: Int
    public let totalMs: Int
    public let finalAfterAudioMs: Int
}

public enum ModelStartup: String, Codable, Sendable {
    case notApplicable, cold, resident
}

public enum BenchmarkOutcome: Codable, Sendable {
    case completed(BenchmarkOutput)
    case failed(reason: String, totalMs: Int)
}

public struct BenchmarkMeasurement: Codable, Sendable {
    public let caseID: String
    public let pipelineID: String
    public let repetition: Int
    public let outcome: BenchmarkOutcome
}

public struct BenchmarkReport: Codable, Sendable {
    public let schemaVersion: Int
    public let createdAt: Date
    public let suite: BenchmarkSuite
    public let suiteFingerprint: String
    public let configuration: BenchmarkConfiguration
    public let codeRevision: String
    public let operatingSystem: String
    public let modelVersions: [String: String]
    public let cleanupPrompts: [String: String]
    public let measurements: [BenchmarkMeasurement]

    public static func load(at url: URL) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(Self.self, from: Data(contentsOf: url))
        guard report.schemaVersion == 1 else { throw BenchmarkError("BenchmarkReport.load: unsupported version") }
        return report
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension Duration {
    var benchmarkMilliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
