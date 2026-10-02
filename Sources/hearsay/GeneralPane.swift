import AppKit
import SwiftUI
import Transcription
import Utterance

struct GeneralPane: View {
    let coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(title: "General", subtitle: "A little room for your voice, in every app.")

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Hold to dictate", systemImage: "keyboard")
                    Spacer()
                    Picker(
                        "Hold shortcut",
                        selection: Binding(
                            get: { coordinator.settings.shortcut },
                            set: { coordinator.select(shortcut: $0) }
                        )
                    ) {
                        ForEach(ModifierChord.allCases) { shortcut in
                            Text(shortcut.label).tag(shortcut)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
                Text(
                    "Hold \(coordinator.settings.shortcut.label), speak, then release. Choose a combination that your other apps do not use."
                )
                .font(.caption).foregroundStyle(.secondary)
                if coordinator.shortcutChangePending {
                    Label("The new shortcut applies when you release the current one.", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Toggle(
                    "Pause dictation",
                    isOn: Binding(
                        get: { coordinator.settings.dictationPaused },
                        set: { coordinator.set(dictationPaused: $0) }
                    ))
                Text("Pausing stops the global shortcut. A recording in progress is released and finished.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { coordinator.launchAtLogin.isEnabled },
                        set: { coordinator.launchAtLogin.setEnabled($0) }
                    )
                )
                .disabled(coordinator.launchAtLogin.status == .unavailable)
                if coordinator.launchAtLogin.status == .needsApproval {
                    HStack {
                        Label("Allow Hearsay in Login Items to finish enabling this.", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { coordinator.launchAtLogin.openSettings() }
                    }
                }
                if coordinator.launchAtLogin.status == .unavailable {
                    Text("Launch at login is available when Hearsay is installed as an app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = coordinator.launchAtLogin.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(18)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 12) {
                Label("Floating bar", systemImage: "rectangle.bottomhalf.inset.filled").font(.headline)
                Text(
                    "Drag the grip to reveal the bottom, left and right drop zones. Drop into a zone to dock the bar, or press Esc to cancel. "
                        + "Its position is remembered, including in full-screen apps."
                )
                .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(coordinator.barPreviewVisible ? "Done positioning" : "Show bar preview") {
                        if coordinator.barPreviewVisible { coordinator.endBarPreview() } else { coordinator.previewBar() }
                    }
                    Button("Reset position") { coordinator.resetBarPosition() }
                }
                .disabled(coordinator.sessionInFlight)
            }
            .padding(18)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        coordinator.permissionReport.allGranted ? "Ready to dictate" : "Set up this Mac",
                        systemImage: coordinator.permissionReport.allGranted ? "checkmark.circle" : "hand.raised"
                    )
                    .font(.headline)
                    Spacer()
                    Button("Refresh") { coordinator.refreshPermissions() }
                }
                Text("Enable each permission below. Hearsay checks again when you return from System Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                PermissionsRows(coordinator: coordinator)
                if !coordinator.permissionReport.inputMonitoring || !coordinator.permissionReport.accessibility {
                    Text("If macOS asks you to quit after granting a permission, use Relaunch from Hearsay’s menu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
        .onAppear { coordinator.refreshPermissions() }
        .onDisappear { coordinator.endBarPreview() }
    }
}

struct PermissionsRows: View {
    let coordinator: Coordinator

    var body: some View {
        VStack(spacing: 14) {
            ForEach(PermissionPane.allCases) { pane in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: coordinator.permissionReport.isGranted(pane) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(coordinator.permissionReport.isGranted(pane) ? Color.green : Color.secondary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pane.title).fontWeight(.medium)
                        Text(pane.detail).font(.caption).foregroundStyle(.secondary)
                        if pane == .microphone, coordinator.permissionReport.microphonePermission == .restricted {
                            Text("Restricted by this Mac’s policy.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !coordinator.permissionReport.isGranted(pane) {
                        Button(actionTitle(for: pane)) {
                            Task { await coordinator.requestPermission(pane) }
                        }
                        .disabled(
                            coordinator.requestingPermission != nil
                                || (pane == .microphone && coordinator.permissionReport.microphonePermission == .restricted))
                    }
                }
            }
        }
    }

    private func actionTitle(for pane: PermissionPane) -> String {
        if coordinator.requestingPermission == pane { return "Waiting…" }
        if pane == .microphone, coordinator.permissionReport.microphonePermission == .denied { return "Open Settings" }
        return "Enable"
    }
}

struct ProvidersPane: View {
    let coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Cloud providers", subtitle: "Optional engines, using your own provider accounts.")
            Text(
                "Apple on-device dictation works without a key or an account. Cloud engines send audio to the selected provider; cloud cleanup sends the transcript and dictionary terms. Your field context stays on this Mac."
            )
            .font(.callout).foregroundStyle(.secondary)
            ForEach(APIKeyProvider.allCases) { provider in
                ProviderKeyCard(provider: provider, coordinator: coordinator)
            }
            Text(
                "New keys are saved in this Mac’s Keychain. Existing environment, keys.env and shell-profile keys still work. Removing a saved key may reveal one of those existing keys."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ProviderKeyCard: View {
    let provider: APIKeyProvider
    let coordinator: Coordinator
    @State private var enteredKey = ""
    @State private var message: String?
    @State private var failed = false

    private var status: APIKeyStatus { coordinator.keyStatuses[provider] ?? .missing }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.label).font(.headline)
                    Label(status.label, systemImage: status == .missing ? "key" : "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Link("Get a key ↗", destination: provider.keysURL).font(.callout)
            }
            HStack {
                SecureField("Paste an API key", text: $enteredKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                Button("Save") { save() }.disabled(enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if status.hasSavedKey {
                    Button("Remove", role: .destructive) { remove() }
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .onDisappear { enteredKey = "" }
    }

    private func save() {
        do {
            try KeyStore.save(enteredKey, for: provider)
            enteredKey = ""
            message = "Saved in Keychain. The provider checks the key when you next use its engine."
            failed = false
            coordinator.refreshKeys()
        } catch {
            message = error.localizedDescription
            failed = true
        }
    }

    private func remove() {
        do {
            try KeyStore.remove(provider)
            enteredKey = ""
            coordinator.refreshKeys()
            message = status == .missing ? "Saved key removed." : "Saved key removed. \(status.label)."
            failed = false
        } catch {
            message = error.localizedDescription
            failed = true
        }
    }
}

struct AboutPane: View {
    let coordinator: Coordinator
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 54)).foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hearsay").font(.largeTitle.bold())
                    Text("Version \(version)\(build.isEmpty ? "" : " · build \(build)")")
                        .foregroundStyle(.secondary)
                    Text("Your voice, at your cursor.").font(.callout)
                }
            }
            Divider()
            UpdateControls(updater: coordinator.updater)
            VStack(alignment: .leading, spacing: 9) {
                Text("Made for this Mac").font(.headline)
                Text(
                    "Apple dictation runs on-device. Optional cloud providers use keys you manage. History and your dictionary are stored locally; turn history off or clear it in History."
                )
                .foregroundStyle(.secondary)
                Text("Requires Apple Silicon and macOS 26 or later. On-device cleanup also requires Apple Intelligence to be enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                Link("Source & documentation", destination: URL(string: "https://github.com/note89/hearsay")!)
                Link("Report an issue", destination: URL(string: "https://github.com/note89/hearsay/issues")!)
                Link("Releases", destination: URL(string: "https://github.com/note89/hearsay/releases")!)
            }
        }
    }
}
