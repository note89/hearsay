import Foundation
import Testing

@testable import hearsay

struct SessionTests {
    @Test @MainActor func stoppedCoordinatorIgnoresLateGesturePress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "hearsay.tests.session.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let coordinator = Coordinator(directory: directory, defaults: defaults)
        coordinator.pressed()
        guard case .idle = coordinator.phase else {
            Issue.record("A stopped coordinator processed a late press")
            return
        }
        #expect(!coordinator.sessionInFlight)
    }
}
