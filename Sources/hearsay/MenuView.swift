import AppKit
import History
import SwiftUI

/// The quick menu: mid-flow actions only. Configuration lives in the settings window.
struct MenuView: View {
    let coordinator: Coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openSettingsWindow() }
            .keyboardShortcut(",")
        Divider()
        Text(statusLine)
        Button(coordinator.settings.dictationPaused ? "Resume dictation" : "Pause dictation") {
            coordinator.set(dictationPaused: !coordinator.settings.dictationPaused)
        }
        if let timing = coordinator.lastTiming {
            Text(
                "last: \(timing.transcribe.milliseconds) ms transcribe · \(timing.polish.milliseconds) ms polish · \(timing.insert.milliseconds) ms insert"
            )
        }
        Divider()
        if coordinator.settings.engine.needsLocale {
            Menu("Language: \(coordinator.settings.locale.languageDisplayName)") {
                ForEach(coordinator.languageChoices, id: \.identifier) { locale in
                    Button {
                        coordinator.select(locale: locale)
                    } label: {
                        let selected = locale.language.languageCode == coordinator.settings.locale.language.languageCode
                        Text(selected ? "✓ \(locale.languageDisplayName)" : "    \(locale.languageDisplayName)")
                    }
                }
            }
        }
        if let last = coordinator.history.records.first {
            Button("Copy last dictation") { coordinator.copy(record: last) }
        }
        if !coordinator.permissionReport.allGranted {
            Divider()
            Button("Set up permissions…") { openSettingsWindow() }
        }
        Divider()
        Button("Relaunch") { Relaunch.now() }
        Button("Quit hearsay") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openSettingsWindow() {
        coordinator.refreshPermissions()
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var statusLine: String {
        if coordinator.settings.dictationPaused { return "dictation paused" }
        if !coordinator.permissionReport.microphone { return "allow microphone in Settings to dictate" }
        switch coordinator.gesture {
        case .denied: return "enable Input Monitoring in Settings"
        case .failed: return "shortcut unavailable — retrying"
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
            return coordinator.bakeoffPaneVisible
                ? "bake-off pane open — dictating into it scores" : "hold \(coordinator.settings.shortcut.label) to dictate"
        case .listening: return "listening…"
        case .finishing(_, let step): return "\(step.label)…"
        }
    }
}
