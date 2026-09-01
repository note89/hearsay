import Foundation

/// API keys for the optional cloud engines. Resolution order:
/// process environment → the app's own keys file → an export line in ~/.zshrc (developer convenience).
public enum KeyStore {
    private static var directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("hearsay")
    private static var fileURL: URL { directory.appendingPathComponent("keys.env") }

    /// The app owns the support directory; it tells KeyStore where that is once at launch.
    public static func configure(directory: URL) {
        Self.directory = directory
        cache = nil
    }

    private static var cache: (mtime: Date?, values: [String: String])?

    /// Cheap after the first call: file contents are cached until keys.env changes.
    public static func value(_ name: String) -> String? {
        if let env = ProcessInfo.processInfo.environment[name], !env.isEmpty { return env }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        if cache == nil || cache?.mtime != mtime {
            cache = (mtime, parseAll(file: fileURL.path))
        }
        if let fromFile = cache?.values[name] { return fromFile }
        return parse(file: NSHomeDirectory() + "/.zshrc", name: name)
    }

    private static func parseAll(file: String) -> [String: String] {
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in content.split(separator: "\n") {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("export ") { trimmed = String(trimmed.dropFirst("export ".count)) }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            var value = String(trimmed[trimmed.index(after: equals)...])
            if let comment = value.firstIndex(of: "#") { value = String(value[..<comment]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !value.isEmpty { values[String(trimmed[..<equals])] = value }
        }
        return values
    }

    /// Creates the keys file with a commented template when missing, so "API Keys…" always opens something editable.
    @discardableResult
    public static func ensureFile() -> URL {
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path) }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let template = """
            # hearsay API keys — needed only for the optional cloud comparison engines.
            # The default Apple engine is fully on-device and uses no key and no network.

            # https://openrouter.ai/keys — unlocks the Gemini engines:
            OPENROUTER_API_KEY=

            # https://elevenlabs.io — unlocks ElevenLabs Scribe:
            ELEVEN_LABS_API_KEY=
            """
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: fileURL.path, contents: template.data(using: .utf8), attributes: [.posixPermissions: 0o600])
        }
        return fileURL
    }

    private static func parse(file: String, name: String) -> String? {
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n") {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("export ") { trimmed = String(trimmed.dropFirst("export ".count)) }
            guard let equals = trimmed.firstIndex(of: "="), trimmed[..<equals] == name else { continue }
            var value = String(trimmed[trimmed.index(after: equals)...])
            if let comment = value.firstIndex(of: "#") { value = String(value[..<comment]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !value.isEmpty { return value }
        }
        return nil
    }
}
