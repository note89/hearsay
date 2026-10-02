import Foundation
import Testing

@testable import Transcription

private final class MemoryCredentials: CredentialStorage {
    var entries: [String: String] = [:]
    func value(for name: String) -> String? { entries[name] }
    func save(_ value: String, for name: String) throws { entries[name] = value }
    func remove(_ name: String) throws { entries.removeValue(forKey: name) }
}

private final class KeyStoreFixture {
    let directory: URL
    let credentials = MemoryCredentials()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearsay-keystore-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func store(environment: [String: String] = [:], shellProfile: URL? = nil) -> APIKeyStore {
        APIKeyStore(directory: directory, environment: environment, shellProfile: shellProfile, credentials: credentials)
    }
}

struct KeyStoreTests {
    @Test func keychainTakesPrecedenceAndRemovingItRestoresEnvironmentFallback() throws {
        let fixture = try KeyStoreFixture()
        let store = fixture.store(environment: [APIKeyProvider.openRouter.rawValue: "synthetic-environment-key"])
        #expect(store.status(.openRouter) == .available(.environment))
        try store.save(" synthetic-keychain-key \n", for: .openRouter)
        #expect(store.value(APIKeyProvider.openRouter.rawValue) == "synthetic-keychain-key")
        #expect(store.status(.openRouter) == .available(.keychain))
        try store.remove(.openRouter)
        #expect(store.value(APIKeyProvider.openRouter.rawValue) == "synthetic-environment-key")
        #expect(store.status(.openRouter) == .available(.environment))
        #expect(fixture.credentials.entries.isEmpty)
    }

    @Test func legacyFilePrecedesShellProfileAndRefreshesWhenChanged() throws {
        let fixture = try KeyStoreFixture()
        let shell = fixture.directory.appendingPathComponent("synthetic-shell-profile")
        let file = fixture.directory.appendingPathComponent("keys.env")
        try "export GEMINI_API_KEY=synthetic-shell-key\n".write(to: shell, atomically: true, encoding: .utf8)
        let store = fixture.store(shellProfile: shell)
        #expect(store.status(.gemini) == .available(.shellProfile))
        try "GEMINI_API_KEY=synthetic-file-key\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(store.value(APIKeyProvider.gemini.rawValue) == "synthetic-file-key")
        #expect(store.status(.gemini) == .available(.legacyFile))
        try "GEMINI_API_KEY=synthetic-file-key-updated\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(store.value(APIKeyProvider.gemini.rawValue) == "synthetic-file-key-updated")
        try FileManager.default.removeItem(at: file)
        #expect(store.value(APIKeyProvider.gemini.rawValue) == "synthetic-shell-key")
    }

    @Test func malformedSavedKeysNeverReachCredentialStorage() throws {
        let fixture = try KeyStoreFixture()
        let store = fixture.store()
        for invalid in ["", " \n ", "synthetic key", "synthetic\nkey", "synthetic\u{0000}key"] {
            #expect(throws: (any Error).self) { try store.save(invalid, for: .elevenLabs) }
        }
        #expect(store.status(.elevenLabs) == .missing)
        #expect(fixture.credentials.entries.isEmpty)
    }

    @Test func removingAbsentKeySucceedsWithoutChangingOtherProviders() throws {
        let fixture = try KeyStoreFixture()
        let store = fixture.store()
        try store.save("synthetic-key", for: .elevenLabs)
        try store.remove(.gemini)
        #expect(store.status(.gemini) == .missing)
        #expect(store.status(.elevenLabs) == .available(.keychain))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("keys.env").path))
    }

    @Test func legacyParserHandlesQuotesCommentsAndExportWithoutExecutingAnything() {
        let values = APIKeyStore.parse(
            """
            # ignored=value
            export OPENROUTER_API_KEY = "synthetic#key" # note
            ELEVEN_LABS_API_KEY='synthetic=value'
            GEMINI_API_KEY=synthetic-unquoted-key # note
            EMPTY_KEY=
            BROKEN_KEY='unterminated
            BROKEN_SUFFIX="synthetic" garbage
            INVALID NAME=synthetic
            LITERAL_KEY=$(synthetic-command)
            """)
        #expect(values["OPENROUTER_API_KEY"] == "synthetic#key")
        #expect(values["ELEVEN_LABS_API_KEY"] == "synthetic=value")
        #expect(values["GEMINI_API_KEY"] == "synthetic-unquoted-key")
        #expect(values["LITERAL_KEY"] == "$(synthetic-command)")
        #expect(values["EMPTY_KEY"] == nil)
        #expect(values["BROKEN_KEY"] == nil)
        #expect(values["BROKEN_SUFFIX"] == nil)
        #expect(values["INVALID NAME"] == nil)
    }
}
