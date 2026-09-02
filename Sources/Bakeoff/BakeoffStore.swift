import Foundation
import Observation

/// What the rival did for one take. Decoding parses the flat on-disk fields into this union;
/// a line that does not form a legal state is dropped rather than admitted.
public enum RivalOutcome: Equatable, Sendable {
    case landed(text: String, ms: Int)
    case unobservable
    case timedOut
    case abandoned

    public init(_ observation: RivalObservation) {
        switch observation {
        case .landed(let text, let latency): self = .landed(text: text, ms: Int(latency / .milliseconds(1)))
        case .unobservable: self = .unobservable
        case .timedOut: self = .timedOut
        case .abandoned: self = .abandoned
        }
    }

    public var status: String {
        switch self {
        case .landed: return "landed"
        case .unobservable: return "unobservable"
        case .timedOut: return "timedOut"
        case .abandoned: return "abandoned"
        }
    }
}

/// What one engine made of one take. A timeout or an error is a result, not a missing row:
/// in a benchmark, not answering is a loss.
public enum EngineOutcome: Equatable, Sendable {
    case scored(spoken: String, ours: String, ms: Int)
    case failed(reason: String)
}

public struct EngineResult: Equatable, Sendable, Identifiable {
    public var id: String { engine }
    /// The engine's wire key.
    public let engine: String
    public let outcome: EngineOutcome

    public init(engine: String, outcome: EngineOutcome) {
        self.engine = engine
        self.outcome = outcome
    }
}

/// One reading of one sentence: every contender's result and the rival's, timed from the same key-up.
public struct Take: Equatable, Sendable, Identifiable {
    public let id: String
    public let at: Date
    public let app: String
    /// The script sentence on screen when this take was recorded — alignment as a fact on the record.
    public let expected: String?
    /// Observed once per take, so it lives here and not on each result.
    public let rival: RivalOutcome
    /// One per engine raced, in race order. Never empty: a take is made from at least one result.
    public let results: [EngineResult]

    public init(id: String, at: Date = Date(), app: String, expected: String?, rival: RivalOutcome, results: [EngineResult]) {
        self.id = id
        self.at = at
        self.app = app
        self.expected = expected
        self.rival = rival
        self.results = results
    }
}

/// The on-disk line: one per engine result, flat, shared with the Rust app. `take` regroups rows;
/// rows written before races had none and become one take each. `oursStatus` absent means scored.
private struct FlatRow: Codable {
    let at: Date
    let take: String?
    let app: String
    let engine: String
    let expected: String?
    let oursStatus: String?
    let spoken: String?
    let ours: String?
    let oursMs: Int?
    let failure: String?
    let rivalStatus: String
    let rival: String?
    let rivalMs: Int?

    struct Parsed {
        let takeID: String
        let at: Date
        let app: String
        let expected: String?
        let rival: RivalOutcome
        let result: EngineResult
    }

    init(take: Take, result: EngineResult) {
        at = take.at
        self.take = take.id
        app = take.app
        engine = result.engine
        expected = take.expected
        switch result.outcome {
        case .scored(let spoken, let ours, let ms):
            oursStatus = "scored"
            self.spoken = spoken
            self.ours = ours
            oursMs = ms
            failure = nil
        case .failed(let reason):
            oursStatus = "failed"
            spoken = nil
            ours = nil
            oursMs = nil
            failure = reason
        }
        rivalStatus = take.rival.status
        if case .landed(let text, let ms) = take.rival {
            rival = text
            rivalMs = ms
        } else {
            rival = nil
            rivalMs = nil
        }
    }

    /// nil when the fields do not form a legal state.
    func parsed() -> Parsed? {
        let rival: RivalOutcome
        switch (rivalStatus, self.rival, rivalMs) {
        case ("landed", let text?, let ms?): rival = .landed(text: text, ms: ms)
        case ("unobservable", nil, nil): rival = .unobservable
        case ("timedOut", nil, nil): rival = .timedOut
        case ("abandoned", nil, nil): rival = .abandoned
        default: return nil
        }
        let outcome: EngineOutcome
        switch (oursStatus ?? "scored", spoken, ours, oursMs, failure) {
        case ("scored", let spoken?, let ours?, let ms?, nil): outcome = .scored(spoken: spoken, ours: ours, ms: ms)
        case ("failed", nil, nil, nil, let reason?): outcome = .failed(reason: reason)
        default: return nil
        }
        return Parsed(takeID: take ?? "legacy-\(at.timeIntervalSince1970)", at: at, app: app, expected: expected, rival: rival, result: EngineResult(engine: engine, outcome: outcome))
    }
}

/// JSON lines ⇄ takes. Public so the test runner can exercise the format without a store.
public enum BakeoffCodec {
    public static func takes(fromJSONL content: String) -> [Take] {
        let decoder = JSONDecoder()
        let rows = content.split(separator: "\n").compactMap { line in
            (try? decoder.decode(FlatRow.self, from: Data(line.utf8)))?.parsed()
        }
        return regroup(rows)
    }

    public static func jsonl(for take: Take) -> Data {
        let encoder = JSONEncoder()
        var data = Data()
        for result in take.results {
            guard let line = try? encoder.encode(FlatRow(take: take, result: result)) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        return data
    }

    /// Rows regroup by take id in first-seen order. The take's facts come from its first row;
    /// a second row for the same engine in one take is a corrupt line and is dropped.
    private static func regroup(_ rows: [FlatRow.Parsed]) -> [Take] {
        var order: [String] = []
        var grouped: [String: (first: FlatRow.Parsed, results: [EngineResult])] = [:]
        for row in rows {
            if var group = grouped[row.takeID] {
                if !group.results.contains(where: { $0.engine == row.result.engine }) {
                    group.results.append(row.result)
                    grouped[row.takeID] = group
                }
            } else {
                order.append(row.takeID)
                grouped[row.takeID] = (row, [row.result])
            }
        }
        return order.map { id in
            let group = grouped[id]!
            return Take(id: id, at: group.first.at, app: group.first.app, expected: group.first.expected, rival: group.first.rival, results: group.results)
        }
    }
}

/// The comparison run: takes in memory for the pane, appended to bakeoff.jsonl on disk.
@MainActor @Observable
public final class BakeoffStore {
    public private(set) var takes: [Take] = []
    /// Identity of the current run; a session records only into the run it started in.
    public private(set) var runID = UUID()

    private let directory: URL
    private let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("bakeoff.jsonl")
        Self.repairPermissionsAndPurgeOrphans(in: directory)
        takes = (try? String(contentsOf: fileURL, encoding: .utf8)).map(BakeoffCodec.takes(fromJSONL:)) ?? []
    }

    public func append(_ take: Take) {
        takes.append(take)
        let lines = BakeoffCodec.jsonl(for: take)
        if FileManager.default.fileExists(atPath: fileURL.path), let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lines)
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: lines, attributes: [.posixPermissions: 0o600])
        }
    }

    /// Removes the newest take, every engine's row of it, so the script position falls back to it.
    public func deleteLast() {
        guard !takes.isEmpty else { return }
        takes.removeLast()
        rewriteFile()
    }

    /// Archives the current run and starts fresh under a new identity.
    public func resetRun() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let archived = fileURL.deletingPathExtension().appendingPathExtension("run-\(stamp).jsonl")
            try? FileManager.default.moveItem(at: fileURL, to: archived)
        }
        takes = []
        runID = UUID()
    }

    /// Deletes the current run and every archived one.
    public func deleteAllRuns() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix("bakeoff") && name.hasSuffix(".jsonl") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        takes = []
        runID = UUID()
    }

    public var archivedRunCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("bakeoff.run-") && $0.hasSuffix(".jsonl") }.count
    }

    private func rewriteFile() {
        var data = Data()
        for take in takes { data.append(BakeoffCodec.jsonl(for: take)) }
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
}
