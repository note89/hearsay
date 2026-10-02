import CryptoKit
import Foundation
import Lexicon
import Pipeline
import Polish

public struct BenchmarkCase: Codable, Sendable {
    public let id: String
    public let audio: String
    public let locale: String
    public let style: WritingStyle
    public let spoken: String?
    public let expected: String
    public let wispr: String?
    public let fieldContext: String?
}

public struct BenchmarkRewrite: Codable, Sendable {
    public let from: String
    public let to: String
}

public struct BenchmarkSuite: Codable, Sendable {
    public let schemaVersion: Int
    public let name: String
    public let vocabulary: [String]
    public let rewrites: [BenchmarkRewrite]
    public let cases: [BenchmarkCase]

    public var lexicon: Lexicon {
        Lexicon(entries: vocabulary.map(LexiconEntry.term) + rewrites.map { .rewrite(from: $0.from, to: $0.to) })
    }

    public static func load(at directory: URL) throws -> BenchmarkSuite {
        let suite = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("suite.json")))
        guard suite.schemaVersion == 1 else { throw BenchmarkError("BenchmarkSuite.load: unsupported schemaVersion") }
        guard !suite.cases.isEmpty else { throw BenchmarkError("BenchmarkSuite.load: add at least one case") }
        guard Set(suite.cases.map(\.id)).count == suite.cases.count else {
            throw BenchmarkError("BenchmarkSuite.load: duplicate case IDs")
        }
        for item in suite.cases {
            guard safeID(item.id), !item.locale.isEmpty else { throw BenchmarkError("BenchmarkSuite.load: invalid case \(item.id)") }
            guard !item.audio.isEmpty, !item.audio.hasPrefix("/"), !item.audio.split(separator: "/").contains("..") else {
                throw BenchmarkError("BenchmarkSuite.load: audio must be a relative path inside the corpus: \(item.id)")
            }
        }
        return suite
    }

    public func fingerprint(in directory: URL) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var digest = SHA256()
        digest.update(data: try encoder.encode(self))
        for item in cases {
            let file = try FileHandle(forReadingFrom: directory.appendingPathComponent(item.audio))
            defer { try? file.close() }
            while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum ReplayPacing: String, Codable, Sendable {
    case realtime, immediate
}

public struct BenchmarkPipeline: Codable, Sendable {
    public let id: String
    public let engine: Engine
    public let polish: PolishMode
    public let polishEngine: PolishEngine
    public let polishModel: String?
}

public struct BenchmarkConfiguration: Codable, Sendable {
    public let schemaVersion: Int
    public let repetitions: Int
    public let pacing: ReplayPacing
    public let execution: BenchmarkExecution
    public let pipelines: [BenchmarkPipeline]

    public func selecting(pipelines: [BenchmarkPipeline]? = nil, execution: BenchmarkExecution? = nil) -> Self {
        Self(
            schemaVersion: schemaVersion, repetitions: repetitions, pacing: pacing,
            execution: execution ?? self.execution, pipelines: pipelines ?? self.pipelines)
    }

    public func includingAllModels() -> Self {
        let candidates = Engine.all.map { engine in
            BenchmarkPipeline(
                id: engine.wireKey.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression),
                engine: engine, polish: .full, polishEngine: .onDevice, polishModel: nil)
        }
        return selecting(pipelines: candidates)
    }

    public static func load(at url: URL) throws -> Self {
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard config.schemaVersion == 1, (1...100).contains(config.repetitions), !config.pipelines.isEmpty else {
            throw BenchmarkError("BenchmarkConfiguration.load: expected version 1, 1–100 repetitions, and at least one pipeline")
        }
        guard Set(config.pipelines.map(\.id)).count == config.pipelines.count, config.pipelines.allSatisfy({ safeID($0.id) }) else {
            throw BenchmarkError("BenchmarkConfiguration.load: pipeline IDs must be unique letters, digits, underscores or hyphens")
        }
        for pipeline in config.pipelines where pipeline.polishModel != nil {
            guard pipeline.polishEngine == .openRouter, pipeline.polish != .off, pipeline.polishModel?.isEmpty == false else {
                throw BenchmarkError("BenchmarkConfiguration.load: polishModel requires active OpenRouter cleanup")
            }
        }
        return config
    }
}

public struct BenchmarkError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

private func safeID(_ value: String) -> Bool {
    !value.isEmpty
        && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0)
        }
}
