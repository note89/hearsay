import Foundation

/// API keys for the optional cloud engines. Resolution order:
/// process environment → the app's own keys file → an export line in ~/.zshrc (developer convenience).
public enum KeyStore {
    public static let fileURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("hearsay/keys.env")

    public static func value(_ name: String) -> String? {
        if let env = ProcessInfo.processInfo.environment[name], !env.isEmpty { return env }
        if let fromFile = parse(file: fileURL.path, name: name) { return fromFile }
        return parse(file: NSHomeDirectory() + "/.zshrc", name: name)
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
