import Foundation
import Transcription

enum PrivacyClass: Equatable {
    case onDevice
    case cloud
}

/// The OpenRouter models hearsay knows how to price and label. Adding one is one case + one row.
enum OpenRouterModel: String, CaseIterable, Equatable {
    case geminiFlashLite = "google/gemini-2.5-flash-lite"
    case geminiFlash = "google/gemini-2.5-flash"

    var pricePer100kWords: String {
        switch self {
        case .geminiFlashLite: return "~$0.50 per 100k words"
        case .geminiFlash: return "~$1.85 per 100k words"
        }
    }
}

/// The engine concept: who turns audio into text, at what cost and privacy.
/// One type owns identity (wire key), display, availability, and construction. A new engine is one
/// new case here — plus, if it needs an on-device model, a provisioning path in the Coordinator.
enum Engine: Equatable {
    case appleLocal
    case openRouter(OpenRouterModel)
    case elevenLabsScribe

    static var all: [Engine] {
        [.appleLocal, .elevenLabsScribe] + OpenRouterModel.allCases.map { .openRouter($0) }
    }

    /// Wire key: persisted in Settings and stamped on BakeoffRecords. `init(wireKey:)` is its exact inverse.
    var wireKey: String {
        switch self {
        case .appleLocal: return "apple-local"
        case .openRouter(let model): return model.rawValue
        case .elevenLabsScribe: return "elevenlabs/\(ElevenLabsTranscriber.modelID)"
        }
    }

    init?(wireKey: String) {
        if let match = Engine.all.first(where: { $0.wireKey == wireKey }) {
            self = match
        } else {
            return nil
        }
    }

    var label: String {
        switch self {
        case .appleLocal: return "Apple on-device ($0)"
        case .openRouter(let model): return "OpenRouter · \(model.rawValue)"
        case .elevenLabsScribe: return "ElevenLabs · Scribe"
        }
    }

    var detail: String {
        switch self {
        case .appleLocal: return "SpeechAnalyzer on the Neural Engine, works offline · $0"
        case .openRouter(let model): return "Google cloud via OpenRouter · \(model.pricePer100kWords)"
        case .elevenLabsScribe: return "ElevenLabs cloud, dedicated ASR, 99 languages · ~$2.80 per 100k words"
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

    /// Cheap: KeyStore caches the key file until it changes.
    var isAvailable: Bool {
        guard let requiredKey else { return true }
        return KeyStore.value(requiredKey) != nil
    }

    var privacyClass: PrivacyClass {
        switch self {
        case .appleLocal: return .onDevice
        case .openRouter, .elevenLabsScribe: return .cloud
        }
    }

    func makeTranscriber(locale: Locale) -> (any Transcriber)? {
        switch self {
        case .appleLocal: return SpeechAnalyzerTranscriber(locale: locale)
        case .openRouter(let model): return OpenRouterTranscriber(model: model.rawValue)
        case .elevenLabsScribe: return ElevenLabsTranscriber()
        }
    }
}
