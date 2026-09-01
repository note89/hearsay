import AppKit
import History
import SwiftUI

/// The quick menu: mid-flow actions only. Configuration lives in the settings window.
struct MenuView: View {
    let coordinator: Coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open hearsay…") { openSettingsWindow() }
        Divider()
        Text(statusLine)
        if let timing = coordinator.lastTiming {
            Text("last: \(timing.transcribe.milliseconds) ms transcribe · \(timing.polish.milliseconds) ms polish · \(timing.insert.milliseconds) ms insert")
        }
        Divider()
        Menu("Language: \(coordinator.settings.locale.displayName)") {
            ForEach(coordinator.availableLocales, id: \.identifier) { locale in
                Button {
                    coordinator.select(locale: locale)
                } label: {
                    Text(locale.identifier == coordinator.settings.locale.identifier ? "✓ \(locale.displayName)" : "    \(locale.displayName)")
                }
            }
        }
        if let last = coordinator.history.records.first {
            Button("Copy last dictation") { coordinator.copy(record: last) }
        }
        if !allPermissionsGranted {
            Divider()
            Button("⚠ Fix permissions…") { openSettingsWindow() }
        }
        Divider()
        Button("Relaunch") { Relaunch.now() }
        Button("Quit hearsay") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var allPermissionsGranted: Bool {
        let report = Permissions.check()
        return report.microphone && report.accessibility && report.inputMonitoring
    }

    private func openSettingsWindow() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var statusLine: String {
        switch coordinator.gesture {
        case .denied: return "Input Monitoring denied — grant it, then Relaunch"
        case .stopped: return "starting…"
        case .listening: break
        }
        switch coordinator.engine {
        case .preparing: return "preparing…"
        case .downloadingModel(let locale): return "downloading \(locale.displayName) model…"
        case .failed(let message): return "engine failed: \(message)"
        case .ready: break
        }
        switch coordinator.phase {
        case .idle, .settled:
            switch coordinator.settings.mode {
            case .dictate: return "hold fn+shift to dictate"
            case .bakeoff: return "bake-off mode — hold fn+shift, both apps listen"
            }
        case .listening: return "listening…"
        case .finishing(_, let step): return "\(step.label)…"
        }
    }
}
