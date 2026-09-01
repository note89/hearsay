import Foundation

/// Text after cleanup. Only a `Polisher` can mint one.
public struct PolishedText: Equatable, Sendable {
    public let text: String

    init(text: String) {
        self.text = text
    }
}

/// How far polish may go. "Off" is the caller not calling.
public enum PolishIntensity: Sendable {
    /// Written form only: punctuation, capitalization, fillers, explicit self-corrections. Wording kept.
    case light
    /// Intent-faithful and dense: rephrase, densify, retro-correct mishearings, structure.
    case full
}

public enum WritingStyle: String, Sendable {
    case plain
    case chat
    case email
    case code
    case markdown
}

public enum PolishRejection: Equatable, Sendable {
    case modelUnavailable
    case empty
    case meaningDrift
    case timeout
    case failed(String)

    /// Case name only — safe for logs; `failed`'s payload may echo prompt content.
    public var label: String {
        switch self {
        case .modelUnavailable: return "modelUnavailable"
        case .empty: return "empty"
        case .meaningDrift: return "meaningDrift"
        case .timeout: return "timeout"
        case .failed: return "failed"
        }
    }
}

public enum PolishVerdict: Sendable {
    case accept(PolishedText)
    case keepRaw(PolishRejection)
}

/// On-device reference material for a polish pass. Never uploaded: the polish model runs locally
/// regardless of which transcription engine produced the spoken text.
public struct PolishContext: Sendable {
    public let fieldText: String?
    public let terms: [String]

    public static let none = PolishContext(fieldText: nil, terms: [])

    public init(fieldText: String?, terms: [String]) {
        self.fieldText = fieldText
        self.terms = terms
    }
}

public protocol Polisher {
    func polish(_ spoken: String, style: WritingStyle, intensity: PolishIntensity, context: PolishContext) async -> PolishVerdict
}

/// DECISION_POLISH_GUARD (Nils, 2026-08-31): polish is intent-faithful, not word-faithful —
/// densifying and rephrasing are wanted. Block only catastrophes: answering instead of cleaning,
/// hallucinated content, or rambling far past what was said.
public enum PolishGuard {
    static let maxInventedShare = 0.6
    static let minKeptShare = 0.25
    static let maxLengthRatio = 1.5
    /// A two-word utterance may legitimately double when punctuated or expanded; the ratio alone is too strict for it.
    static let lengthSlackWords = 3

    public static func verdict(spoken: String, candidate: String) -> PolishVerdict {
        let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .keepRaw(.empty) }

        let spokenWords = contentWords(spoken)
        let candidateWords = contentWords(cleaned)
        guard !spokenWords.isEmpty, !candidateWords.isEmpty else { return .accept(PolishedText(text: cleaned)) }

        let spokenSet = Set(spokenWords)
        let candidateSet = Set(candidateWords)
        let inventedShare = Double(candidateWords.filter { !spokenSet.contains($0) }.count) / Double(candidateWords.count)
        let keptShare = Double(spokenWords.filter { candidateSet.contains($0) }.count) / Double(spokenWords.count)
        let grewPastSpoken = Double(candidateWords.count) > maxLengthRatio * Double(spokenWords.count) + Double(lengthSlackWords)
        if inventedShare > maxInventedShare || keptShare < minKeptShare || grewPastSpoken { return .keepRaw(.meaningDrift) }
        return .accept(PolishedText(text: cleaned))
    }

    private static let fillers: Set<String> = [
        "um", "uh", "uhm", "hmm", "mm", "like", "so", "okay", "ok", "yeah",
        "eh", "öh", "öhm", "hm", "liksom", "typ", "alltså", "ba",
        "tipo", "né", "então", "hã", "ãh",
    ]

    static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
            .filter { !fillers.contains($0) }
    }
}
