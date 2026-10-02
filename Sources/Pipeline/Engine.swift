import Foundation
import Transcription

public enum PrivacyClass: Equatable, Sendable {
    case onDevice
    case cloud
}

/// The general LLMs hearsay will transcribe with via OpenRouter. One at a time: the dedicated ASR
/// engines are the product, this is the comparison point. Adding one is one case + one row.
public enum OpenRouterModel: String, CaseIterable, Equatable, Sendable {
    case geminiFlash = "google/gemini-3.7-flash"

    public var pricePer100kWords: String {
        switch self {
        case .geminiFlash: return "~$1.45 per 100k words"
        }
    }

    public var label: String {
        switch self {
        case .geminiFlash: return "Gemini 3.7 Flash"
        }
    }
}

/// The engine concept: who turns audio into text, at what cost and privacy.
/// One type owns identity (wire key), display, availability, and construction. A new engine is one
/// new case here — plus, if it needs an on-device model, a provisioning path in the Coordinator.
public enum Engine: Equatable, Codable, Sendable {
    case appleLocal
    case local(LocalSpeechModel)
    case openRouter(OpenRouterModel)
    case elevenLabsScribe
    case geminiTranscribeLive

    public static var all: [Engine] {
        [.appleLocal] + LocalSpeechModel.allCases.map { .local($0) }
            + [.elevenLabsScribe, .geminiTranscribeLive] + OpenRouterModel.allCases.map { .openRouter($0) }
    }

    /// Wire key: persisted in Settings and stamped on BakeoffRecords. `init(wireKey:)` is its exact inverse.
    public var wireKey: String {
        switch self {
        case .appleLocal: return "apple-local"
        case .local(let model): return model.wireKey
        case .openRouter(let model): return model.rawValue
        case .elevenLabsScribe: return "elevenlabs/\(ElevenLabsTranscriber.modelID)"
        case .geminiTranscribeLive: return "google/\(GeminiLiveTranscriber.modelID)"
        }
    }

    public init?(wireKey: String) {
        if let match = Engine.all.first(where: { $0.wireKey == wireKey }) {
            self = match
        } else {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let engine = Engine(wireKey: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown engine: \(value)"))
        }
        self = engine
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireKey)
    }

    public var label: String {
        switch self {
        case .appleLocal: return "Apple on-device ($0)"
        case .local(let model): return model.label
        case .openRouter(let model): return "Google · \(model.label) (via OpenRouter)"
        case .elevenLabsScribe: return "ElevenLabs · Scribe v2"
        case .geminiTranscribeLive: return "Google · Gemini 3.5 Transcribe (live)"
        }
    }

    public var detail: String {
        switch self {
        case .appleLocal: return "SpeechAnalyzer on the Neural Engine, works offline · $0"
        case .local(let model): return model.detail
        case .openRouter(let model): return "General LLM listening to the audio, via OpenRouter · \(model.pricePer100kWords)"
        case .elevenLabsScribe:
            return "ElevenLabs Scribe v2 cloud, dedicated ASR, 90+ languages, mixes them mid-sentence · ~$2.45 per 100k words"
        case .geminiTranscribeLive:
            return
                "Google cloud, streaming ASR with live partials, 85+ languages, mixes them mid-sentence · ~$6 per 100k words, free tier in preview"
        }
    }

    /// Two or three words: chips, pills and leaderboard rows.
    public var shortLabel: String {
        switch self {
        case .appleLocal: return "Apple"
        case .local(let model): return model.label
        case .openRouter(let model): return model.label
        case .elevenLabsScribe: return "Scribe v2"
        case .geminiTranscribeLive: return "Gemini Live"
        }
    }

    /// Streams text while you speak. In a race the pill shows the first such engine's partials.
    public var deliversPartials: Bool {
        switch self {
        case .appleLocal, .geminiTranscribeLive: return true
        case .local, .openRouter, .elevenLabsScribe: return false
        }
    }

    /// Only the Apple engine needs a locale; the cloud engines detect language themselves.
    /// Exhaustive on purpose: a new engine must decide this explicitly.
    public var needsLocale: Bool {
        switch self {
        case .appleLocal: return true
        case .local(let model): return model.needsLocale
        case .openRouter, .elevenLabsScribe, .geminiTranscribeLive: return false
        }
    }

    public var requiredKey: String? {
        switch self {
        case .appleLocal, .local: return nil
        case .openRouter: return "OPENROUTER_API_KEY"
        case .elevenLabsScribe: return "ELEVEN_LABS_API_KEY"
        case .geminiTranscribeLive: return "GEMINI_API_KEY"
        }
    }

    /// Cheap: KeyStore caches the key file until it changes.
    public var isAvailable: Bool {
        guard let requiredKey else { return true }
        return KeyStore.value(requiredKey) != nil
    }

    public var privacyClass: PrivacyClass {
        switch self {
        case .appleLocal, .local: return .onDevice
        case .openRouter, .elevenLabsScribe, .geminiTranscribeLive: return .cloud
        }
    }

    public func transcriptionLimit(audioDuration: Duration) -> Duration {
        privacyClass == .onDevice ? max(.seconds(15), min(.seconds(300), audioDuration)) : .seconds(15)
    }

    public func makeTranscriber(locale: Locale, localModelDirectory: URL? = nil) -> (any Transcriber)? {
        switch self {
        case .appleLocal: return SpeechAnalyzerTranscriber(locale: locale)
        case .local(let model):
            guard let localModelDirectory else { return nil }
            return LocalModelTranscriber(model: model, directory: localModelDirectory, locale: locale)
        case .openRouter(let model): return OpenRouterTranscriber(model: model.rawValue)
        case .elevenLabsScribe: return ElevenLabsTranscriber()
        case .geminiTranscribeLive: return GeminiLiveTranscriber()
        }
    }
}
