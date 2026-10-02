import Foundation
import LocalAuthentication
import Security

public enum APIKeyProvider: String, CaseIterable, Identifiable, Sendable {
    case openRouter = "OPENROUTER_API_KEY"
    case elevenLabs = "ELEVEN_LABS_API_KEY"
    case gemini = "GEMINI_API_KEY"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .elevenLabs: return "ElevenLabs"
        case .gemini: return "Google Gemini"
        }
    }

    public var keysURL: URL {
        switch self {
        case .openRouter: return URL(string: "https://openrouter.ai/settings/keys")!
        case .elevenLabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        }
    }
}

public enum APIKeySource: Equatable, Sendable {
    case keychain
    case environment
    case legacyFile
    case shellProfile

    public var label: String {
        switch self {
        case .keychain: return "Saved in Keychain"
        case .environment: return "Available from the environment"
        case .legacyFile: return "Available from keys.env"
        case .shellProfile: return "Available from your shell profile"
        }
    }
}

public enum APIKeyStatus: Equatable, Sendable {
    case missing
    case available(APIKeySource)

    public var label: String {
        switch self {
        case .missing: return "No key saved"
        case .available(let source): return source.label
        }
    }

    public var hasSavedKey: Bool { self == .available(.keychain) }
}

public enum APIKeyFailure: LocalizedError {
    case empty
    case invalidCharacters
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .empty: return "Enter an API key before saving."
        case .invalidCharacters: return "An API key must be a single line without spaces."
        case .keychain(let status):
            return "Keychain could not save this change (error \(status))."
        }
    }
}

protocol CredentialStorage {
    func value(for name: String) -> String?
    func save(_ value: String, for name: String) throws
    func remove(_ name: String) throws
}

private struct KeychainStorage: CredentialStorage {
    let service: String

    private func query(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecAttrSynchronizable as String: false,
        ]
    }

    func value(for name: String) -> String? {
        var query = query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String, for name: String) throws {
        let data = Data(value.utf8)
        let result = SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query(name)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw APIKeyFailure.keychain(added) }
        } else if result != errSecSuccess {
            throw APIKeyFailure.keychain(result)
        }
    }

    func remove(_ name: String) throws {
        let result = SecItemDelete(query(name) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw APIKeyFailure.keychain(result) }
    }
}

/// Credentials entered in Settings are stored in the local Keychain. Existing environment and
/// keys.env installations keep working; the shell-profile fallback supports developer launches.
final class APIKeyStore: @unchecked Sendable {
    private let directory: URL
    private let environment: [String: String]
    private let shellProfile: URL?
    private let credentials: any CredentialStorage
    private let lock = NSLock()
    private var cache: (modified: Date?, size: UInt64?, values: [String: String])?

    init(directory: URL, environment: [String: String], shellProfile: URL?, credentials: any CredentialStorage) {
        self.directory = directory
        self.environment = environment
        self.shellProfile = shellProfile
        self.credentials = credentials
    }

    func value(_ name: String) -> String? { resolved(name)?.value }

    func status(_ provider: APIKeyProvider) -> APIKeyStatus {
        resolved(provider.rawValue).map { .available($0.source) } ?? .missing
    }

    func save(_ value: String, for provider: APIKeyProvider) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIKeyFailure.empty }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw APIKeyFailure.invalidCharacters
        }
        lock.lock()
        defer { lock.unlock() }
        try credentials.save(trimmed, for: provider.rawValue)
    }

    func remove(_ provider: APIKeyProvider) throws {
        lock.lock()
        defer { lock.unlock() }
        try credentials.remove(provider.rawValue)
    }

    private func resolved(_ name: String) -> (value: String, source: APIKeySource)? {
        lock.lock()
        defer { lock.unlock() }
        if let key = nonempty(credentials.value(for: name)) { return (key, .keychain) }
        if let key = nonempty(environment[name]) { return (key, .environment) }
        let file = directory.appendingPathComponent("keys.env")
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = attributes?[.size] as? UInt64
        if cache == nil || cache?.modified != modified || cache?.size != size {
            cache = (modified, size, Self.parse((try? String(contentsOf: file, encoding: .utf8)) ?? ""))
        }
        if let key = cache?.values[name] { return (key, .legacyFile) }
        if let shellProfile,
            let content = try? String(contentsOf: shellProfile, encoding: .utf8),
            let key = Self.parse(content)[name]
        {
            return (key, .shellProfile)
        }
        return nil
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    static func parse(_ content: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("export ") { trimmed = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0) })
            else { continue }
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                let rest = value.dropFirst()
                guard let close = rest.firstIndex(of: quote) else { continue }
                let suffix = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
                guard suffix.isEmpty || suffix.hasPrefix("#") else { continue }
                value = String(rest[..<close])
            } else if let comment = value.firstIndex(of: "#") {
                value = String(value[..<comment]).trimmingCharacters(in: .whitespaces)
            }
            if !value.isEmpty { values[name] = value }
        }
        return values
    }
}

public enum KeyStore {
    private static let lock = NSLock()
    private static var store = makeStore(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hearsay"))

    public static func configure(directory: URL) {
        lock.lock()
        defer { lock.unlock() }
        store = makeStore(directory: directory)
    }

    public static func value(_ name: String) -> String? { currentStore().value(name) }
    public static func status(_ provider: APIKeyProvider) -> APIKeyStatus { currentStore().status(provider) }
    public static func save(_ value: String, for provider: APIKeyProvider) throws { try currentStore().save(value, for: provider) }
    public static func remove(_ provider: APIKeyProvider) throws { try currentStore().remove(provider) }

    private static func currentStore() -> APIKeyStore {
        lock.lock()
        defer { lock.unlock() }
        return store
    }

    private static func makeStore(directory: URL) -> APIKeyStore {
        APIKeyStore(
            directory: directory,
            environment: ProcessInfo.processInfo.environment,
            shellProfile: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".zshrc"),
            credentials: KeychainStorage(service: "computer.borrowed.hearsay.api-keys"))
    }
}
