import Foundation

public enum RivalObservation: Sendable {
    case landed(text: String, latency: Duration)
    /// The field is not readable (web view, unknown element).
    case unobservable
    case timedOut(after: Duration)
    /// The watch was cancelled before it could conclude — not a measurement.
    case abandoned
}

/// Watches a field for text another app inserts, timed from the same key-up we reacted to.
/// Reads the field through a closure so this module knows nothing about how fields are addressed.
public enum RivalWatch {
    static let pollInterval: Duration = .milliseconds(15)
    /// After the first change, wait this long and re-read so a rival that inserts in pieces is captured whole.
    static let completionGrace: Duration = .milliseconds(400)

    @MainActor
    public static func observe(
        read: @escaping @MainActor () -> String?,
        baseline: String,
        since: ContinuousClock.Instant,
        timeout: Duration
    ) async -> RivalObservation {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            guard let now = read() else { return .unobservable }
            if now != baseline {
                let latency = clock.now - since
                do { try await Task.sleep(for: completionGrace) } catch { return .abandoned }
                let settled = read() ?? now
                return .landed(text: inserted(from: baseline, to: settled), latency: latency)
            }
            do { try await Task.sleep(for: pollInterval) } catch { return .abandoned }
        }
        return .timedOut(after: timeout)
    }

    /// The text that appeared: strip the common prefix and suffix the field already had.
    static func inserted(from before: String, to after: String) -> String {
        let prefix = zip(before, after).prefix { $0 == $1 }.count
        let beforeRest = before.dropFirst(prefix)
        let afterRest = after.dropFirst(prefix)
        let suffix = zip(beforeRest.reversed(), afterRest.reversed()).prefix { $0 == $1 }.count
        return String(afterRest.dropLast(suffix)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
