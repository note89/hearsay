import Observation
import ServiceManagement

enum LoginItemStatus: Equatable {
    case disabled
    case enabled
    case needsApproval
    case unavailable
}

@MainActor @Observable
final class LaunchAtLogin {
    private(set) var status: LoginItemStatus = .disabled
    private(set) var errorMessage: String?

    init() { refresh() }

    var isEnabled: Bool { status == .enabled || status == .needsApproval }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .notRegistered: status = .disabled
        case .enabled: status = .enabled
        case .requiresApproval: status = .needsApproval
        case .notFound: status = .unavailable
        @unknown default: status = .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
