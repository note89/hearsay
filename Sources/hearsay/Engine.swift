import Foundation
import Transcription

enum PrivacyClass: Equatable {
    case onDevice
    case cloud(provider: String)
}

/// The engine concept: who turns audio into text, at what cost and privacy.
/// One type owns identity (wire key), display, availability, and construction —
/// adding an engine means extending this type and nothing else.
enum Engine: Equatable {
    case appleLocal
    case openRouter(model: String)
    case elevenLabsScribe

    static let openRouterModels = ["google/gemini-2.5-flash-lite", "google/gemini-2.5-flash"]

    static var all: [Engine] {
        [.appleLocal, .elevenLabsScribe] + openRouterModels.map { .openRouter(model: $0) }
    }

    /// Wire key: persisted in Settings and stamped on BakeoffRecords. `init(wireKey:)` is its exact inverse.
    var wireKey: String {
        switch self {
        case .appleLocal: return "apple-local"
        case .openRouter(let model): return model
        case .elevenLabsScribe: return "elevenlabs/\(ElevenLabsTranscriber.modelID)"
        }
    }

    init?(wireKey: String) {
        if wireKey == Engine.appleLocal.wireKey {
            self = .appleLocal
        } else if wireKey == Engine.elevenLabsScribe.wireKey {
            self = .elevenLabsScribe
        } else if Engine.openRouterModels.contains(wireKey) {
            self = .openRouter(model: wireKey)
        } else {
            return nil
        }
    }

    var label: String {
        switch self {
        case .appleLocal: return "Apple on-device ($0)"
        case .openRouter(let model): return "OpenRouter · \(model)"
        case .elevenLabsScribe: return "ElevenLabs · Scribe"
        }
    }

    /// Only the Apple engine needs a locale; the cloud engines detect language themselves.
    /// Exhaustive on purpose: a new engine must decide this explicitly.
    var needsLocale: Bool {
        switch self {
        case .appleLocal: return true
        case .openRouter, .elevenLabsScribe: return false
        }
    }

    var requiredKey: String? {
        switch self {
        case .appleLocal: return nil
        case .openRouter: return "OPENROUTER_API_KEY"
        case .elevenLabsScribe: return "ELEVEN_LABS_API_KEY"
        }
    }

    var isAvailable: Bool {
        guard let requiredKey else { return true }
        return KeyStore.value(requiredKey) != nil
    }

    /// One-line card subtitle for the settings window.
    var detail: String {
        switch self {
        case .appleLocal: return "SpeechAnalyzer on this Mac · works offline · $0"
        case .openRouter(let model): return model.contains("lite") ? "Google cloud via OpenRouter · ~$0.50 per 100k words" : "Google cloud via OpenRouter · ~$1.85 per 100k words"
        case .elevenLabsScribe: return "ElevenLabs cloud · dedicated ASR · ~$2.80 per 100k words"
        }
    }

    var privacyClass: PrivacyClass {
        switch self {
        case .appleLocal: return .onDevice
        case .openRouter: return .cloud(provider: "OpenRouter")
        case .elevenLabsScribe: return .cloud(provider: "ElevenLabs")
        }
    }

    func makeTranscriber(locale: Locale) -> (any Transcriber)? {
        switch self {
        case .appleLocal: return SpeechAnalyzerTranscriber(locale: locale)
        case .openRouter(let model): return OpenRouterTranscriber(model: model)
        case .elevenLabsScribe: return ElevenLabsTranscriber()
        }
    }
}
