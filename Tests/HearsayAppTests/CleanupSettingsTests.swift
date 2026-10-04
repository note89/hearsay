import Foundation
import Pipeline
import Polish
import Testing

@testable import hearsay

struct CleanupSettingsTests {
    @Test @MainActor func providerAndModelChoicesSurviveRestart() throws {
        let suite = "CleanupSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        #expect(settings.polishEngine == .onDevice)
        #expect(settings.cloudCleanupModel == .recommended)
        settings.polishEngine = .ollama
        settings.ollamaModel = "small-model:latest"
        settings.cloudCleanupModel = .geminiFlash
        let reloaded = Settings(defaults: defaults)
        #expect(reloaded.polishEngine == .ollama)
        #expect(reloaded.ollamaModel == "small-model:latest")
        #expect(reloaded.cloudCleanupModel == .geminiFlash)
        reloaded.ollamaModel = nil
        #expect(Settings(defaults: defaults).ollamaModel == nil)
    }
}
