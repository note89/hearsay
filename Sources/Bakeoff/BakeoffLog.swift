import Foundation
import Observation

public enum RivalStatus: String, Codable, Sendable {
    case landed
    case unobservable
    case timedOut
}

/// One utterance, both contenders, one clock. Appended as JSON lines; scored live by the Bake-off pane.
public struct BakeoffRecord: Codable, Sendable, Identifiable {
    public var id: Date { at }

    public let at: Date
    public let app: String
    public let engine: String
    /// The script sentence on screen when this take was recorded — alignment as a fact on the record.
    public let expected: String?
    public let spoken: String
    public let ours: String
    public let oursMs: Int
    public let rivalStatus: RivalStatus
    public let rival: String?
    public let rivalMs: Int?

    public init(app: String, engine: String, expected: String?, spoken: String, ours: String, oursMs: Int, rival observation: RivalObservation) {
        at = Date()
        self.app = app
        self.engine = engine
        self.expected = expected
        self.spoken = spoken
        self.ours = ours
        self.oursMs = oursMs
        switch observation {
        case .landed(let text, let latency):
            rivalStatus = .landed
            rival = text
            rivalMs = Int(latency / .milliseconds(1))
        case .unobservable:
            rivalStatus = .unobservable
            rival = nil
            rivalMs = nil
        case .timedOut:
            rivalStatus = .timedOut
            rival = nil
            rivalMs = nil
        }
    }
}

/// The comparison run: records in memory for the pane, appended to bakeoff.jsonl on disk.
@MainActor @Observable
public final class BakeoffStore {
    public private(set) var records: [BakeoffRecord] = []

    private let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("bakeoff.jsonl")
        records = Self.load(from: fileURL)
    }

    public func append(_ record: BakeoffRecord) {
        records.append(record)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard var line = try? JSONEncoder().encode(record) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Archives the current run and starts fresh.
    public func resetRun() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let archived = fileURL.deletingPathExtension().appendingPathExtension("run-\(stamp).jsonl")
            try? FileManager.default.moveItem(at: fileURL, to: archived)
        }
        records = []
    }

    private static func load(from url: URL) -> [BakeoffRecord] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return content.split(separator: "\n").compactMap { line in
            try? decoder.decode(BakeoffRecord.self, from: Data(line.utf8))
        }
    }
}
