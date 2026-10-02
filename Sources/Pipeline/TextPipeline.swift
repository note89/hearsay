import Foundation
import Lexicon
import Polish
import Transcription

public enum PolishMode: String, Codable, Sendable {
    case off, light, full

    public var transcriptMode: TranscriptMode { self == .off ? .verbatim : .smart }
}

public enum PolishEngine: String, Codable, Sendable {
    case onDevice, openRouter
}

public indirect enum InsertableText: Sendable {
    case polished(PolishedText, spoken: RawTranscript)
    case raw(RawTranscript)
    case rewritten(text: String, over: InsertableText)

    public var text: String {
        switch self {
        case .polished(let polished, _): return polished.text
        case .raw(let raw): return raw.text
        case .rewritten(let text, _): return text
        }
    }

    public var spoken: String {
        switch self {
        case .polished(_, let raw): return raw.text
        case .raw(let raw): return raw.text
        case .rewritten(_, let base): return base.spoken
        }
    }
}

public struct CleanupResult {
    public let delivered: InsertableText
    public let rejection: PolishRejection?
    public let polishDuration: Duration
}

/// The app and recorded benchmarks use the same cleanup deadline, guard, and dictionary rewrites.
public enum TextPipeline {
    public static func finish(
        _ raw: RawTranscript, mode: PolishMode, style: WritingStyle,
        lexicon: Lexicon, polisher: any Polisher, fieldContext: String?
    ) async -> CleanupResult {
        var delivered = InsertableText.raw(raw)
        var rejection: PolishRejection?
        var duration = Duration.zero
        if mode != .off, !raw.text.isEmpty {
            let start = ContinuousClock.now
            let words = raw.text.split(whereSeparator: \.isWhitespace).count
            let limit = min(Duration.seconds(6) + .milliseconds(70) * words, .seconds(40))
            let verdict = await within(limit) {
                await polisher.polish(
                    raw.text, style: style, intensity: mode == .light ? .light : .full,
                    context: PolishContext(fieldText: fieldContext, terms: lexicon.terms)
                )
            }
            switch verdict {
            case .accept(let polished): delivered = .polished(polished, spoken: raw)
            case .keepRaw(let reason): rejection = reason
            }
            duration = ContinuousClock.now - start
        }
        if let rewritten = lexicon.rewriteResult(of: delivered.text) {
            delivered = .rewritten(text: rewritten, over: delivered)
        }
        return CleanupResult(delivered: delivered, rejection: rejection, polishDuration: duration)
    }

    private static func within(_ limit: Duration, work: @escaping () async -> PolishVerdict) async -> PolishVerdict {
        let completion = CleanupCompletion()
        return await withCheckedContinuation { continuation in
            let worker = Task { completion.resume(continuation, with: await work()) }
            Task {
                try? await Task.sleep(for: limit)
                completion.resume(continuation, with: .keepRaw(.timeout))
                worker.cancel()
            }
        }
    }
}

private final class CleanupCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func resume(_ continuation: CheckedContinuation<PolishVerdict, Never>, with verdict: PolishVerdict) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(returning: verdict)
    }
}
