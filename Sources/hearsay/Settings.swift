import Foundation
import Observation

enum PolishMode: String {
    case off
    case local
}

enum AppMode: String {
    /// Normal use: text lands in the target.
    case dictate
    /// Comparison: never insert; watch the field for the rival's text and log both.
    case bakeoff
}

@MainActor @Observable
final class Settings {
    private enum Key {
        static let locale = "locale"
        static let polish = "polish"
        static let mode = "mode"
        static let engine = "engine"
        static let history = "historyEnabled"
        static let fieldContext = "fieldContextEnabled"
    }

    private static let defaultLocale = "en-US"

    var locale: Locale {
        didSet { UserDefaults.standard.set(locale.identifier, forKey: Key.locale) }
    }

    var polish: PolishMode {
        didSet { UserDefaults.standard.set(polish.rawValue, forKey: Key.polish) }
    }

    var mode: AppMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Key.mode) }
    }

    var engine: Engine {
        didSet { UserDefaults.standard.set(engine.wireKey, forKey: Key.engine) }
    }

    var historyEnabled: Bool {
        didSet { UserDefaults.standard.set(historyEnabled, forKey: Key.history) }
    }

    var fieldContextEnabled: Bool {
        didSet { UserDefaults.standard.set(fieldContextEnabled, forKey: Key.fieldContext) }
    }

    init() {
        let defaults = UserDefaults.standard
        locale = Locale(identifier: defaults.string(forKey: Key.locale) ?? Self.defaultLocale)
        polish = PolishMode(rawValue: defaults.string(forKey: Key.polish) ?? "") ?? .local
        mode = AppMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .dictate
        engine = defaults.string(forKey: Key.engine).flatMap(Engine.init(wireKey:)) ?? .appleLocal
        historyEnabled = defaults.object(forKey: Key.history) as? Bool ?? true
        fieldContextEnabled = defaults.object(forKey: Key.fieldContext) as? Bool ?? true
    }
}
