import Foundation
import Transcription

enum PrivacyClass: Equatable {
    case onDevice
    case cloud
}

/// The general LLMs hearsay will transcribe with via OpenRouter. One at a time: the dedicated ASR
/// engines are the product, this is the comparison point. Adding one is one case + one row.
enum OpenRouterModel: String, CaseIterable, Equatable {
    case geminiFlash = "google/gemini-3.7-flash"

    var pricePer100kWords: String {
        switch self {
        case .geminiFlash: return "~$1.45 per 100k words"
        }
    }

    var label: String {
        switch self {
        case .geminiFlash: return "Gemini 3.7 Flash"
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
    case geminiTranscribeLive

    static var all: [Engine] {
        [.appleLocal, .elevenLabsScribe, .geminiTranscribeLive] + OpenRouterModel.allCases.map { .openRouter($0) }
    }

    /// Wire key: persisted in Settings and stamped on BakeoffRecords. `init(wireKey:)` is its exact inverse.
    var wireKey: String {
        switch self {
        case .appleLocal: return "apple-local"
        case .openRouter(let model): return model.rawValue
        case .elevenLabsScribe: return "elevenlabs/\(ElevenLabsTranscriber.modelID)"
        case .geminiTranscribeLive: return "google/\(GeminiLiveTranscriber.modelID)"
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
        case .openRouter(let model): return "Google · \(model.label) (via OpenRouter)"
        case .elevenLabsScribe: return "ElevenLabs · Scribe v2"
        case .geminiTranscribeLive: return "Google · Gemini 3.5 Transcribe (live)"
        }
    }

    var detail: String {
        switch self {
        case .appleLocal: return "SpeechAnalyzer on the Neural Engine, works offline · $0"
        case .openRouter(let model): return "General LLM listening to the audio, via OpenRouter · \(model.pricePer100kWords)"
        case .elevenLabsScribe: return "ElevenLabs Scribe v2 cloud, dedicated ASR, 90+ languages, mixes them mid-sentence · ~$2.45 per 100k words"
        case .geminiTranscribeLive: return "Google cloud, streaming ASR with live partials, 85+ languages, mixes them mid-sentence · ~$6 per 100k words, free tier in preview"
        }
    }

    /// Two or three words: chips, pills and leaderboard rows.
    var shortLabel: String {
        switch self {
        case .appleLocal: return "Apple"
        case .openRouter(let model): return model.label
        case .elevenLabsScribe: return "Scribe v2"
        case .geminiTranscribeLive: return "Gemini Live"
        }
    }

    /// Streams text while you speak. In a race the pill shows the first such engine's partials.
    var deliversPartials: Bool {
        switch self {
        case .appleLocal, .geminiTranscribeLive: return true
        case .openRouter, .elevenLabsScribe: return false
        }
    }

    /// Only the Apple engine needs a locale; the cloud engines detect language themselves.
    /// Exhaustive on purpose: a new engine must decide this explicitly.
    var needsLocale: Bool {
        switch self {
        case .appleLocal: return true
        case .openRouter, .elevenLabsScribe, .geminiTranscribeLive: return false
        }
    }

    var requiredKey: String? {
        switch self {
        case .appleLocal: return nil
        case .openRouter: return "OPENROUTER_API_KEY"
        case .elevenLabsScribe: return "ELEVEN_LABS_API_KEY"
        case .geminiTranscribeLive: return "GEMINI_API_KEY"
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
        case .openRouter, .elevenLabsScribe, .geminiTranscribeLive: return .cloud
        }
    }

    func makeTranscriber(locale: Locale) -> (any Transcriber)? {
        switch self {
        case .appleLocal: return SpeechAnalyzerTranscriber(locale: locale)
        case .openRouter(let model): return OpenRouterTranscriber(model: model.rawValue)
        case .elevenLabsScribe: return ElevenLabsTranscriber()
        case .geminiTranscribeLive: return GeminiLiveTranscriber()
        }
    }
}
