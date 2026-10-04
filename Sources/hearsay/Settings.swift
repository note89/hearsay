import Foundation
import Observation
import Pipeline
import Polish
import Utterance

@MainActor @Observable
final class Settings {
    private enum Key {
        static let locale = "locale"
        static let polish = "polish"
        static let engine = "engine"
        static let history = "historyEnabled"
        static let fieldContext = "fieldContextEnabled"
        static let raceExclusions = "raceExclusions"
        static let polishEngine = "polishEngine"
        static let cloudCleanupModel = "cloudCleanupModel"
        static let ollamaModel = "ollamaModel"
        static let shortcut = "holdShortcut"
        static let paused = "dictationPaused"
    }

    private static let defaultLocale = "en-US"
    private let defaults: UserDefaults

    var shortcut: ModifierChord {
        didSet { defaults.set(shortcut.rawValue, forKey: Key.shortcut) }
    }

    var dictationPaused: Bool {
        didSet { defaults.set(dictationPaused, forKey: Key.paused) }
    }

    var locale: Locale {
        didSet { defaults.set(locale.identifier, forKey: Key.locale) }
    }

    var polish: PolishMode {
        didSet { defaults.set(polish.rawValue, forKey: Key.polish) }
    }

    var polishEngine: PolishEngine {
        didSet { defaults.set(polishEngine.rawValue, forKey: Key.polishEngine) }
    }

    var cloudCleanupModel: CloudCleanupModel {
        didSet { defaults.set(cloudCleanupModel.rawValue, forKey: Key.cloudCleanupModel) }
    }

    var ollamaModel: String? {
        didSet { defaults.set(ollamaModel, forKey: Key.ollamaModel) }
    }

    var engine: Engine {
        didSet { defaults.set(engine.wireKey, forKey: Key.engine) }
    }

    var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Key.history) }
    }

    var fieldContextEnabled: Bool {
        didSet { defaults.set(fieldContextEnabled, forKey: Key.fieldContext) }
    }

    /// Engines left out of a bake-off race, by wire key. Stored as exclusions so a newly added
    /// engine races by default.
    private(set) var raceExclusions: Set<String> {
        didSet { defaults.set(Array(raceExclusions).sorted(), forKey: Key.raceExclusions) }
    }

    func isRacing(_ engine: Engine) -> Bool {
        !raceExclusions.contains(engine.wireKey)
    }

    func toggleRacing(_ engine: Engine) {
        if raceExclusions.contains(engine.wireKey) { raceExclusions.remove(engine.wireKey) } else { raceExclusions.insert(engine.wireKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcut = defaults.string(forKey: Key.shortcut).flatMap(ModifierChord.init(rawValue:)) ?? .fnShift
        dictationPaused = defaults.bool(forKey: Key.paused)
        locale = Locale(identifier: defaults.string(forKey: Key.locale) ?? Self.defaultLocale)
        polish = PolishMode(rawValue: defaults.string(forKey: Key.polish) ?? "") ?? .full
        polishEngine = PolishEngine(rawValue: defaults.string(forKey: Key.polishEngine) ?? "") ?? .onDevice
        cloudCleanupModel = defaults.string(forKey: Key.cloudCleanupModel).flatMap(CloudCleanupModel.init(rawValue:)) ?? .recommended
        ollamaModel = defaults.string(forKey: Key.ollamaModel)
        engine = defaults.string(forKey: Key.engine).flatMap(Engine.init(wireKey:)) ?? .appleLocal
        historyEnabled = defaults.object(forKey: Key.history) as? Bool ?? true
        fieldContextEnabled = defaults.object(forKey: Key.fieldContext) as? Bool ?? true
        raceExclusions = Set(defaults.stringArray(forKey: Key.raceExclusions) ?? [])
    }
}
