import Foundation
import Observation
import os

public enum RecordedOutcome: String, Codable, Sendable {
    case inserted
    case copiedToClipboard
    case targetLost
}

public struct DictationRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let at: Date
    public let spoken: String
    public let delivered: String
    public let appName: String
    public let outcome: RecordedOutcome

    public init(spoken: String, delivered: String, appName: String, outcome: RecordedOutcome) {
        id = UUID()
        at = Date()
        self.spoken = spoken
        self.delivered = delivered
        self.appName = appName
        self.outcome = outcome
    }
}

/// Newest first, capped. The trash of dictation: whatever did not land is still here.
@MainActor @Observable
public final class HistoryStore {
    public private(set) var records: [DictationRecord] = []

    private let fileURL: URL
    private let cap: Int
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "hearsay", category: "history")

    public init(directory: URL, cap: Int = 200) {
        fileURL = directory.appendingPathComponent("history.json")
        self.cap = cap
        records = load()
    }

    public func clear() {
        records = []
        save()
    }

    public func delete(id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    public func record(_ record: DictationRecord) {
        records.insert(record, at: 0)
        if records.count > cap { records.removeLast(records.count - cap) }
        save()
    }

    private func load() -> [DictationRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([DictationRecord].self, from: data)
        } catch {
            log.error("HistoryStore.load: unreadable history, starting empty: \(error)")
            return []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            log.error("HistoryStore.save: \(error)")
        }
    }
}
