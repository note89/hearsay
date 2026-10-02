import SwiftUI

struct UpdateControls: View {
    let updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Updates").font(.headline)
                Spacer()
                Button("Check for updates") { Task { await updater.check() } }
                    .disabled(updater.state == .checking)
            }
            switch updater.state {
            case .idle:
                Text("Check GitHub for a new release when you choose.")
                    .foregroundStyle(.secondary)
            case .checking:
                ProgressView("Checking GitHub…").controlSize(.small)
            case .upToDate:
                Label("You're using the latest version.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case .available(let release):
                Label("hearsay \(release.version.description) is available", systemImage: "arrow.down.circle")
                HStack {
                    Link("Release notes", destination: release.pageURL)
                    Link("Download for macOS", destination: release.downloadURL)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("Installed with Homebrew? Run:")
                .font(.caption).foregroundStyle(.secondary)
            Text("brew upgrade --cask note89/tap/hearsay")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text("Update checks send your IP address and app version to GitHub.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
