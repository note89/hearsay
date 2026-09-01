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
    /// Identity of the current run; a session records only into the run it started in.
    public private(set) var runID = UUID()

    private let directory: URL
    private let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("bakeoff.jsonl")
        Self.repairPermissionsAndPurgeOrphans(in: directory)
        records = Self.load(from: fileURL)
    }

    public func append(_ record: BakeoffRecord) {
        records.append(record)
        guard var line = try? JSONEncoder().encode(record) else { return }
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: fileURL.path), let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: line, attributes: [.posixPermissions: 0o600])
        }
    }

    /// Removes the newest take so the script position falls back to it.
    public func deleteLast() {
        guard !records.isEmpty else { return }
        records.removeLast()
        rewriteFile()
    }

    /// Archives the current run and starts fresh under a new identity.
    public func resetRun() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let archived = fileURL.deletingPathExtension().appendingPathExtension("run-\(stamp).jsonl")
            try? FileManager.default.moveItem(at: fileURL, to: archived)
        }
        records = []
        runID = UUID()
    }

    /// Deletes the current run and every archived one.
    public func deleteAllRuns() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix("bakeoff") && name.hasSuffix(".jsonl") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        records = []
        runID = UUID()
    }

    public var archivedRunCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("bakeoff.run-") && $0.hasSuffix(".jsonl") }.count
    }

    private func rewriteFile() {
        let encoder = JSONEncoder()
        var data = Data()
        for record in records {
            guard let line = try? encoder.encode(record) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Files written before the permission rules existed may be world-readable; the arena-era
    /// server files are orphans. Both are repaired every launch.
    private static func repairPermissionsAndPurgeOrphans(in directory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let path = directory.appendingPathComponent(name).path
            if ["status.json", "control.json", "bakeoff-refs.jsonl"].contains(name) || name.hasPrefix("bakeoff-refs-") {
                try? fm.removeItem(atPath: path)
            } else {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
    }

    private static func load(from url: URL) -> [BakeoffRecord] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return content.split(separator: "\n").compactMap { line in
            try? decoder.decode(BakeoffRecord.self, from: Data(line.utf8))
        }
    }
}
