import Foundation
import Lexicon
import Polish
import Transcription

public enum PolishMode: String, Codable, Sendable {
    case off, light, full

    public var transcriptMode: TranscriptMode { self == .off ? .verbatim : .smart }
}

public enum PolishEngine: String, Codable, Sendable {
    case onDevice, openRouter, ollama
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

    static func within(_ limit: Duration, work: @escaping () async -> PolishVerdict) async -> PolishVerdict {
        let completion = CleanupCompletion()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard completion.install(continuation) else { return }
                let worker = Task {
                    guard !Task.isCancelled else { return }
                    completion.resolve(await work())
                }
                completion.track(worker)
                let timer = Task {
                    do { try await Task.sleep(for: limit) } catch { return }
                    completion.resolve(.keepRaw(.timeout))
                }
                completion.track(timer)
            }
        } onCancel: {
            completion.resolve(.keepRaw(.cancelled))
        }
    }
}

private final class CleanupCompletion: @unchecked Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<PolishVerdict, Never>)
        case completed(PolishVerdict)
    }

    private let lock = NSLock()
    private var state = State.pending
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<PolishVerdict, Never>) -> Bool {
        lock.lock()
        switch state {
        case .pending:
            state = .waiting(continuation)
            lock.unlock()
            return true
        case .completed(let verdict):
            lock.unlock()
            continuation.resume(returning: verdict)
            return false
        case .waiting:
            lock.unlock()
            preconditionFailure("CleanupCompletion.install: continuation already installed")
        }
    }

    func track(_ task: Task<Void, Never>) {
        lock.lock()
        if case .completed = state {
            lock.unlock()
            task.cancel()
        } else {
            tasks.append(task)
            lock.unlock()
        }
    }

    func resolve(_ verdict: PolishVerdict) {
        lock.lock()
        if case .completed = state {
            lock.unlock()
            return
        }
        let continuation: CheckedContinuation<PolishVerdict, Never>?
        if case .waiting(let waiting) = state { continuation = waiting } else { continuation = nil }
        state = .completed(verdict)
        let pendingTasks = tasks
        tasks.removeAll()
        lock.unlock()
        for task in pendingTasks { task.cancel() }
        continuation?.resume(returning: verdict)
    }
}
