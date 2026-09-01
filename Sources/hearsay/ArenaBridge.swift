import Foundation

struct ArenaStatus: Codable {
    let engine: String
    let engineLabel: String
    let mode: String
    let locale: String
    let polish: String
}

struct ArenaControl: Codable {
    let engine: String?
    let mode: String?
}

/// File-based bridge between the app and the local bake-off arena page:
/// the app writes status.json on every settings change; the page writes control.json to request changes.
@MainActor
final class ArenaBridge {
    private let statusURL: URL
    private let controlURL: URL
    private var appliedControlDate: Date?

    init(directory: URL) {
        statusURL = directory.appendingPathComponent("status.json")
        controlURL = directory.appendingPathComponent("control.json")
        appliedControlDate = Self.modificationDate(of: controlURL)   // stale control from a past session is not a request
    }

    func publish(_ status: ArenaStatus) {
        try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: statusURL, options: .atomic)
    }

    /// Consumes the pending control request; a torn or undecodable file is left pending so the next poll retries.
    func consumePendingControl() -> ArenaControl? {
        guard let date = Self.modificationDate(of: controlURL), date != appliedControlDate else { return nil }
        guard let data = try? Data(contentsOf: controlURL),
              let control = try? JSONDecoder().decode(ArenaControl.self, from: data) else { return nil }
        appliedControlDate = date
        return control
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
