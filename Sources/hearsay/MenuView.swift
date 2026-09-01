import AppKit
import History
import SwiftUI
import Transcription

struct MenuView: View {
    let coordinator: Coordinator

    var body: some View {
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
        Menu("Engine: \(coordinator.settings.engine.label)") {
            ForEach(Engine.all, id: \.wireKey) { engineOption in
                Button {
                    coordinator.select(engine: engineOption)
                } label: {
                    Text((coordinator.settings.engine == engineOption ? "✓ " : "    ") + engineOption.label + (engineOption.isAvailable ? "" : " — needs key"))
                }
                .disabled(!engineOption.isAvailable)
            }
            Divider()
            Button("API Keys…") { NSWorkspace.shared.open(KeyStore.ensureFile()) }
        }
        Toggle("Polish on-device", isOn: Binding(
            get: { coordinator.settings.polish == .local },
            set: { coordinator.set(polish: $0 ? .local : .off) }
        ))
        Toggle("Bake-off mode — watch Wispr, never insert", isOn: Binding(
            get: { coordinator.settings.mode == .bakeoff },
            set: { coordinator.set(mode: $0 ? .bakeoff : .dictate) }
        ))
        Divider()
        permissionsMenu
        historyMenu
        Divider()
        Button("Relaunch") { Relaunch.now() }
        Button("Quit hearsay") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
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
            case .bakeoff: return "bake-off: hold fn+shift, both apps listen"
            }
        case .listening: return "listening…"
        case .finishing(_, let step): return "\(step.label)…"
        }
    }

    private var permissionsMenu: some View {
        let report = Permissions.check()
        return Menu("Permissions") {
            permissionRow("Microphone", granted: report.microphone, pane: .microphone)
            permissionRow("Accessibility", granted: report.accessibility, pane: .accessibility)
            permissionRow("Input Monitoring", granted: report.inputMonitoring, pane: .inputMonitoring)
        }
    }

    private func permissionRow(_ name: String, granted: Bool, pane: PermissionPane) -> some View {
        Button("\(granted ? "✓" : "✗") \(name)") { Permissions.openSettings(pane) }
    }

    private var historyMenu: some View {
        Menu("History") {
            Toggle("Keep history", isOn: Binding(
                get: { coordinator.settings.historyEnabled },
                set: { coordinator.set(historyEnabled: $0) }
            ))
            Button("Clear history") { coordinator.clearHistory() }
            Divider()
            if coordinator.history.records.isEmpty {
                Text("nothing yet")
            }
            ForEach(coordinator.history.records.prefix(12)) { record in
                Button(Self.title(for: record)) { coordinator.copy(record: record) }
            }
        }
    }

    private static func title(for record: DictationRecord) -> String {
        let preview = record.delivered.count > 60 ? String(record.delivered.prefix(60)) + "…" : record.delivered
        let marker: String
        switch record.outcome {
        case .inserted: marker = ""
        case .copiedToClipboard: marker = " (copied)"
        case .targetLost: marker = " (focus moved)"
        }
        return "\(preview)\(marker) — \(record.appName)"
    }
}
