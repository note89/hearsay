import Foundation

/// A session keeps its identity for its entire lifetime, including delayed completions.
public protocol SessionIdentity {
    var token: UUID { get }
}

/// The coordinator's phase, with ownership checks shared by production and generated tests.
public enum SessionPhase<Session: SessionIdentity, Step, Outcome> {
    case idle
    case listening(Session)
    case finishing(Session, Step)
    case settled(Outcome)

    public var activeSession: Session? {
        switch self {
        case .listening(let session), .finishing(let session, _): return session
        case .idle, .settled: return nil
        }
    }

    public var isInFlight: Bool { activeSession != nil }

    /// A running app alone is insufficient: an old task can return after stop and restart.
    public func canComplete(_ token: UUID, running: Bool, cancelled: Bool) -> Bool {
        guard running, !cancelled, case .finishing(let session, _) = self else { return false }
        return session.token == token
    }

    /// Duplicate key-up events cannot release the same session twice.
    @discardableResult
    public mutating func release(to step: Step) -> Session? {
        guard case .listening(let session) = self else { return nil }
        self = .finishing(session, step)
        return session
    }

    @discardableResult
    public mutating func advance(_ token: UUID, to step: Step) -> Bool {
        guard case .finishing(let session, _) = self, session.token == token else { return false }
        self = .finishing(session, step)
        return true
    }

    @discardableResult
    public mutating func complete(_ token: UUID, with outcome: Outcome, running: Bool, cancelled: Bool) -> Bool {
        guard canComplete(token, running: running, cancelled: cancelled) else { return false }
        self = .settled(outcome)
        return true
    }
}

extension SessionPhase: Equatable where Session: Equatable, Step: Equatable, Outcome: Equatable {}
