import AppKit
import History
import Lexicon
import SwiftUI
import Transcription

enum SettingsSection: String, CaseIterable, Identifiable {
    case dictation = "Dictation"
    case dictionary = "Dictionary"
    case style = "Style"
    case bakeoff = "Bake-off"
    case history = "History"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dictation: return "mic"
        case .dictionary: return "character.book.closed"
        case .style: return "textformat"
        case .bakeoff: return "flag.checkered"
        case .history: return "clock"
        }
    }
}

struct SettingsWindowView: View {
    let coordinator: Coordinator
    @State private var section: SettingsSection? = .dictation

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            ScrollView {
                Group {
                    switch section ?? .dictation {
                    case .dictation: DictationPane(coordinator: coordinator)
                    case .dictionary: DictionaryPane(coordinator: coordinator)
                    case .style: StylePane(coordinator: coordinator)
                    case .bakeoff: BakeoffPane(coordinator: coordinator)
                    case .history: HistoryPane(coordinator: coordinator)
                    }
                }
                .padding(28)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 780, minHeight: 540)
        .navigationTitle("hearsay")
    }
}

struct PaneHeaderShared: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Dictation

private struct DictationPane: View {
    let coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeaderShared(title: "Dictation", subtitle: "Hold fn+shift anywhere. Release, and the words land at your cursor.")

            Text("ENGINE").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Engine.all, id: \.wireKey) { engineOption in
                EngineCard(
                    engine: engineOption,
                    selected: coordinator.settings.engine == engineOption,
                    select: { coordinator.select(engine: engineOption) }
                )
            }
            HStack {
                Button("API Keys…") { NSWorkspace.shared.open(KeyStore.ensureFile()) }
                Text("Cloud engines unlock when their key is present.").font(.caption).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 4)

            HStack {
                Text("Language")
                Spacer()
                Picker("", selection: Binding(
                    get: { coordinator.settings.locale.identifier },
                    set: { identifier in coordinator.select(locale: Locale(identifier: identifier)) }
                )) {
                    ForEach(coordinator.availableLocales, id: \.identifier) { locale in
                        Text(locale.displayName).tag(locale.identifier)
                    }
                }
                .frame(width: 260)
            }
            Toggle(isOn: Binding(
                get: { coordinator.settings.fieldContextEnabled },
                set: { coordinator.set(fieldContextEnabled: $0) }
            )) {
                VStack(alignment: .leading) {
                    Text("Field context")
                    Text("Reads the text around your cursor as terminology reference. On-device only — never uploaded, never stored.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider().padding(.vertical, 4)

            Text("PERMISSIONS").font(.caption.bold()).foregroundStyle(.secondary)
            PermissionsRows()
        }
    }
}

private struct EngineCard: View {
    let engine: Engine
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(engine.label).fontWeight(.semibold)
                        if case .onDevice = engine.privacyClass {
                            Tag(text: "private", tone: .green)
                        } else {
                            Tag(text: "cloud", tone: .orange)
                        }
                        if !engine.isAvailable { Tag(text: "needs key", tone: .secondary) }
                    }
                    Text(engine.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(!engine.isAvailable)
        .opacity(engine.isAvailable ? 1 : 0.5)
    }
}

private struct Tag: View {
    enum Tone { case green, orange, secondary }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch tone {
        case .green: return .green
        case .orange: return .orange
        case .secondary: return .secondary
        }
    }
}

private struct PermissionsRows: View {
    @State private var report = Permissions.check()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Microphone", granted: report.microphone, pane: .microphone)
            row("Accessibility", granted: report.accessibility, pane: .accessibility)
            row("Input Monitoring", granted: report.inputMonitoring, pane: .inputMonitoring)
        }
        .onAppear { report = Permissions.check() }
    }

    private func row(_ name: String, granted: Bool, pane: PermissionPane) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(name)
            Spacer()
            if !granted { Button("Open Settings") { Permissions.openSettings(pane) } }
        }
    }
}

// MARK: - Dictionary

private struct DictionaryPane: View {
    let coordinator: Coordinator
    @State private var entries: [LexiconEntry] = []
    @State private var search = ""
    @State private var newFrom = ""
    @State private var newTo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeaderShared(title: "Dictionary", subtitle: "Names and jargon, spelled your way. Entries are only ever added by you.")

            HStack(spacing: 8) {
                TextField("word or phrase", text: $newFrom).textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("rewrite to (optional)", text: $newTo).textFieldStyle(.roundedBorder)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFrom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Leave the right side empty for a term (exact spelling). Fill it for an automatic rewrite.")
                .font(.caption).foregroundStyle(.secondary)

            TextField("search", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)

            VStack(spacing: 0) {
                if filtered.isEmpty {
                    Text(entries.isEmpty ? "No entries yet." : "No matches.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(20)
                }
                ForEach(filtered, id: \.offset) { item in
                    HStack {
                        switch item.element {
                        case .term(let term):
                            Text(term)
                        case .rewrite(let from, let to):
                            Text(from).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text(to)
                        }
                        Spacer()
                        Button {
                            entries.remove(at: item.offset)
                            save()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    Divider()
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))

            Button("Open dictionary file…") { coordinator.openDictionary() }
                .font(.caption)
        }
        .onAppear { entries = coordinator.loadDictionaryEntries() }
    }

    private var filtered: [(offset: Int, element: LexiconEntry)] {
        let all = Array(entries.enumerated())
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return all.map { (offset: $0.offset, element: $0.element) } }
        return all.compactMap { pair in
            let matches: Bool
            switch pair.element {
            case .term(let term): matches = term.lowercased().contains(query)
            case .rewrite(let from, let to): matches = from.lowercased().contains(query) || to.lowercased().contains(query)
            }
            return matches ? (offset: pair.offset, element: pair.element) : nil
        }
    }

    private func add() {
        let from = newFrom.trimmingCharacters(in: .whitespaces)
        let to = newTo.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty else { return }
        entries.append(to.isEmpty ? .term(from) : .rewrite(from: from, to: to))
        newFrom = ""
        newTo = ""
        save()
    }

    private func save() {
        coordinator.saveDictionaryEntries(entries)
    }
}

// MARK: - Style

private struct StylePane: View {
    let coordinator: Coordinator

    private static let sample = "hey um so send the, send the invoice by friday and uh maybe cc sara"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeaderShared(title: "Style", subtitle: "How much cleanup every dictation gets. All of it runs on this Mac.")

            HStack(alignment: .top, spacing: 12) {
                CleanupCard(
                    title: "Off",
                    blurb: "Exactly what the engine heard, mistakes included.",
                    example: Self.sample,
                    selected: coordinator.settings.polish == .off
                ) { coordinator.set(polish: .off) }
                CleanupCard(
                    title: "Light",
                    blurb: "Punctuation, casing, fillers and self-corrections. Your wording, kept.",
                    example: "Hey, so send the invoice by Friday and maybe cc Sara.",
                    selected: coordinator.settings.polish == .light
                ) { coordinator.set(polish: .light) }
                CleanupCard(
                    title: "Full",
                    blurb: "What you meant, dense and structured. Fixes mishearings from context.",
                    example: "Send the invoice by Friday; cc Sara.",
                    selected: coordinator.settings.polish == .full
                ) { coordinator.set(polish: .full) }
            }

            Divider().padding(.vertical, 4)

            Text("TONE FOLLOWS THE APP").font(.caption.bold()).foregroundStyle(.secondary)
            // Display table for StyleInference — update both together.
            VStack(alignment: .leading, spacing: 6) {
                styleRow("Chat", "Slack, Messages, WhatsApp, Discord, Telegram, Signal", "casual, no trailing period")
                styleRow("Email", "Mail, Outlook, Spark, Superhuman", "complete sentences, paragraphs")
                styleRow("Code", "Cursor, VS Code, Xcode, terminals, Zed, JetBrains", "identifiers verbatim, straight quotes")
                styleRow("Markdown", "Obsidian, Notion, Bear, Craft", "- lists, # headings, `code`")
                styleRow("Plain", "everything else", "neutral written prose")
            }
        }
    }

    private func styleRow(_ name: String, _ apps: String, _ effect: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).fontWeight(.medium).frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(apps).font(.caption)
                Text(effect).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CleanupCard: View {
    let title: String
    let blurb: String
    let example: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.bold())
                Text(blurb).font(.caption).foregroundStyle(.secondary).frame(minHeight: 44, alignment: .top)
                Text(example)
                    .font(.caption)
                    .italic()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .quaternarySystemFill)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - History

private struct HistoryPane: View {
    let coordinator: Coordinator

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeaderShared(title: "History", subtitle: "The trash of dictation — whatever didn't land is still here. Plain file, local, yours.")

            HStack {
                Toggle("Keep history", isOn: Binding(
                    get: { coordinator.settings.historyEnabled },
                    set: { coordinator.set(historyEnabled: $0) }
                ))
                Spacer()
                Button("Clear all", role: .destructive) { coordinator.clearHistory() }
                    .disabled(coordinator.history.records.isEmpty)
            }

            VStack(spacing: 0) {
                if coordinator.history.records.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(20)
                }
                ForEach(coordinator.history.records) { record in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.delivered).lineLimit(3)
                            Text("\(Self.timestamp.string(from: record.at)) · \(record.appName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { coordinator.copy(record: record) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        Button { coordinator.deleteHistory(record: record) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    Divider()
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
        }
    }
}
