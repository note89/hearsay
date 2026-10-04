import Foundation
import Sessions
import Testing

private struct Snapshot: SessionIdentity, Equatable {
    let token: UUID
    let engine: Int
}

private typealias TestPhase = SessionPhase<Snapshot, Int, Int>

struct SessionProperties {
    @Test func staleCompletionCannotOwnRestartedSession() {
        let old = Snapshot(token: UUID(), engine: 1)
        let new = Snapshot(token: UUID(), engine: 2)
        var phase = TestPhase.listening(old)
        #expect(phase.release(to: 0) == old)
        phase = .idle  // Stop invalidates the old owner even if its task ignores cancellation.
        phase = .listening(new)
        #expect(phase.release(to: 0) == new)
        #expect(!phase.canComplete(old.token, running: true, cancelled: false))
        let advanced = phase.advance(old.token, to: 1)
        #expect(!advanced)
        let staleCompleted = phase.complete(old.token, with: 1, running: true, cancelled: false)
        #expect(!staleCompleted)
        #expect(phase.activeSession == new)
        #expect(phase.canComplete(new.token, running: true, cancelled: false))
        #expect(!phase.canComplete(new.token, running: false, cancelled: false))
        #expect(!phase.canComplete(new.token, running: true, cancelled: true))
        let completed = phase.complete(new.token, with: 2, running: true, cancelled: false)
        #expect(completed)
        let duplicateCompleted = phase.complete(new.token, with: 2, running: true, cancelled: false)
        #expect(!duplicateCompleted)
    }

    @Test func generatedTransitionsPreserveOwnershipAndPressTimeRules() {
        Properties.check(
            seed: 701, cases: 500,
            generate: { generator in (0..<generator.integer(0..<100)).map { _ in generator.integer(0..<8) } },
            property: { events in
                var phase = TestPhase.idle
                var running = false
                var selectedEngine = 0
                var owners: [Snapshot] = []
                for event in events {
                    switch event {
                    case 0: running = true
                    case 1:
                        running = false
                        phase = .idle
                    case 2:
                        if running && !phase.isInFlight {
                            let token = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", owners.count + 1))!
                            let snapshot = Snapshot(token: token, engine: selectedEngine)
                            owners.append(snapshot)
                            phase = .listening(snapshot)
                        }
                    case 3:
                        let before = phase
                        let released = phase.release(to: 0)
                        if case .listening(let owner) = before {
                            if released != owner { return false }
                        } else if released != nil || phase != before {
                            return false
                        }
                    case 4:
                        let captured = phase.activeSession
                        selectedEngine += 1
                        if phase.activeSession != captured { return false }
                    case 5, 6, 7:
                        for owner in owners {
                            let before = phase
                            let allowed = phase.canComplete(owner.token, running: running, cancelled: event == 7)
                            if allowed {
                                if phase.activeSession != owner { return false }
                                if event == 5 {
                                    if !phase.advance(owner.token, to: 1) { return false }
                                    if phase.activeSession != owner { return false }
                                } else if !phase.complete(owner.token, with: owner.engine, running: running, cancelled: false) {
                                    return false
                                }
                            } else {
                                if phase.complete(owner.token, with: owner.engine, running: running, cancelled: event == 7) { return false }
                                if phase != before { return false }
                            }
                        }
                    default: return false
                    }
                    if !running && phase.isInFlight { return false }
                    if let owner = phase.activeSession, !owners.contains(owner) { return false }
                }
                return true
            })
    }
}
