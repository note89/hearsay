import AVFoundation
import AppKit
import ApplicationServices

enum MicrophonePermission: Equatable {
    case notRequested
    case granted
    case denied
    case restricted
}

struct PermissionReport: Equatable {
    let microphonePermission: MicrophonePermission
    let accessibility: Bool
    let inputMonitoring: Bool

    var microphone: Bool { microphonePermission == .granted }
    var allGranted: Bool { microphone && accessibility && inputMonitoring }

    func isGranted(_ pane: PermissionPane) -> Bool {
        switch pane {
        case .microphone: return microphone
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        }
    }
}

enum PermissionPane: CaseIterable, Identifiable, Hashable {
    case microphone
    case inputMonitoring
    case accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    var detail: String {
        switch self {
        case .microphone: return "Hear your voice while you hold the shortcut."
        case .inputMonitoring: return "Detect the hold shortcut in every app."
        case .accessibility: return "Insert the finished text at your cursor. Without it, text is copied."
        }
    }

    fileprivate var anchor: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        }
    }
}

enum Permissions {
    /// Permission prompts only follow a click on the corresponding setup action.
    @MainActor
    static func request(_ pane: PermissionPane) async -> PermissionReport {
        switch pane {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                openSettings(pane)
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openSettings(pane) }
        }
        return check()
    }

    static func check() -> PermissionReport {
        let microphone: MicrophonePermission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notRequested
        case .denied: microphone = .denied
        case .restricted: microphone = .restricted
        @unknown default: microphone = .restricted
        }
        return PermissionReport(
            microphonePermission: microphone,
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess()
        )
    }

    static func openSettings(_ pane: PermissionPane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

enum Relaunch {
    static func now() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            do {
                try process.run()
                NSApp.terminate(nil)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Hearsay could not relaunch"
                alert.runModal()
            }
        }
    }
}
