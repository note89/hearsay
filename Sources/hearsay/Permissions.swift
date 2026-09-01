import AppKit
import ApplicationServices
import AVFoundation

struct PermissionReport: Equatable {
    var microphone: Bool
    var accessibility: Bool
    var inputMonitoring: Bool
}

enum PermissionPane {
    case microphone
    case accessibility
    case inputMonitoring

    fileprivate var anchor: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        }
    }
}

enum Permissions {
    /// Prompts for whatever is missing. Accessibility and Input Monitoring open System Settings and need a relaunch after granting.
    @MainActor
    static func request() async -> PermissionReport {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let accessibility = AXIsProcessTrustedWithOptions(options)
        let inputMonitoring = CGRequestListenEventAccess()
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        return PermissionReport(microphone: microphone, accessibility: accessibility, inputMonitoring: inputMonitoring)
    }

    static func check() -> PermissionReport {
        PermissionReport(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
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
            try? process.run()
            NSApp.terminate(nil)
        }
    }
}
