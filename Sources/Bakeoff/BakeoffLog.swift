import Foundation

public enum RivalStatus: String, Codable, Sendable {
    case landed
    case unobservable
    case timedOut
}

/// One utterance, both contenders, one clock. Appended as JSON lines; scored live by scripts/bakeoff-arena.ts.
public struct BakeoffRecord: Codable, Sendable {
    public let at: Date
    public let app: String
    public let engine: String
    public let spoken: String
    public let ours: String
    public let oursMs: Int
    public let rivalStatus: RivalStatus
    public let rival: String?
    public let rivalMs: Int?

    public init(app: String, engine: String, spoken: String, ours: String, oursMs: Int, rival observation: RivalObservation) {
        at = Date()
        self.app = app
        self.engine = engine
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

public struct BakeoffLog {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("bakeoff.jsonl")
    }

    public func append(_ record: BakeoffRecord) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = try JSONEncoder().encode(record)
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL)
        }
    }
}
