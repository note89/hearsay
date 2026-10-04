import Pipeline
import Polish
import SwiftUI
import Transcription

struct CleanupModelPicker: View {
    let coordinator: Coordinator
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { tone(dark: 0xffb454, light: 0xa05a00) }
    private var surface: Color { tone(dark: 0x1d2026, light: 0xffffff) }
    private var border: Color { tone(dark: 0x2f333b, light: 0xdcd8ce) }
    private var foreground: Color { tone(dark: 0xe9e7e2, light: 0x22252b) }
    private var muted: Color { tone(dark: 0xa09d94, light: 0x585d68) }

    private func tone(dark: Int, light: Int) -> Color {
        let rgb = colorScheme == .dark ? dark : light
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    private enum Catalog {
        case idle, loading
        case ready([OllamaModel])
        case unavailable
    }
    @State private var catalog = Catalog.idle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CLEANUP MODEL")
                .font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(1.2).foregroundStyle(muted)
            Picker(
                "Runs with",
                selection: Binding(
                    get: { coordinator.settings.polishEngine }, set: { coordinator.set(polishEngine: $0) }
                )
            ) {
                Text("Apple on-device").tag(PolishEngine.onDevice)
                Text("OpenRouter").tag(PolishEngine.openRouter)
                Text("Ollama").tag(PolishEngine.ollama)
            }.pickerStyle(.segmented)

            switch coordinator.settings.polishEngine {
            case .onDevice:
                Text("Apple's on-device model. Private, free and offline. Field context stays on this Mac.")
                    .font(.caption).foregroundStyle(muted)
            case .openRouter:
                Picker(
                    "Model",
                    selection: Binding(
                        get: { coordinator.settings.cloudCleanupModel }, set: { coordinator.set(cloudCleanupModel: $0) }
                    )
                ) {
                    ForEach(CloudCleanupModel.allCases, id: \.rawValue) { model in
                        Text(model.label + (model == .recommended ? " — fast and cheap" : "")).tag(model)
                    }
                }
                Text(coordinator.settings.cloudCleanupModel.priceLabel + ". Provider prices can change.")
                    .font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(muted)
                Text("Sends your transcript and dictionary terms. Field context stays on this Mac.")
                    .font(.caption).foregroundStyle(muted)
                if !OpenRouterTranscriber.keyAvailable {
                    Text("Add an OpenRouter key in Cloud providers. Until then, cleanup uses Apple's on-device model.")
                        .font(.caption).foregroundStyle(accent)
                }
            case .ollama:
                ollamaControls
                Text(
                    "Uses your Ollama server at localhost:11434. Local models are free and offline; Ollama cloud models use their provider. Field context is never sent."
                )
                .font(.caption).foregroundStyle(muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 1))
        .foregroundStyle(foreground)
        .tint(accent)
        .accentColor(accent)
        .task(id: coordinator.settings.polishEngine) {
            if coordinator.settings.polishEngine == .ollama { await refresh() }
        }
    }

    @ViewBuilder private var ollamaControls: some View {
        HStack {
            switch catalog {
            case .idle, .loading:
                ProgressView().controlSize(.small)
                Text("Looking for Ollama models…").font(.caption)
            case .unavailable:
                Text("Start Ollama, then refresh models. Cleanup keeps the raw transcript while Ollama is unavailable.")
                    .font(.caption).foregroundStyle(muted)
            case .ready(let models):
                if models.isEmpty {
                    Text("No models installed. Add a small instruction model in Ollama, then refresh.")
                        .font(.caption).foregroundStyle(muted)
                } else {
                    Picker(
                        "Model",
                        selection: Binding(
                            get: { coordinator.settings.ollamaModel }, set: { coordinator.set(ollamaModel: $0) }
                        )
                    ) {
                        Text("Choose a model").tag(String?.none)
                        ForEach(models, id: \.name) { model in
                            Text(model.name + " · " + ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))
                                .tag(String?.some(model.name))
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            Button("REFRESH") { Task { await refresh() } }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .disabled(isLoading)
        }
        if case .ready(let models) = catalog, let selected = coordinator.settings.ollamaModel,
            !models.contains(where: { $0.name == selected })
        {
            Text("The saved model \(selected) is unavailable. Choose an installed model to enable cleanup.")
                .font(.caption).foregroundStyle(accent)
        }
    }

    private var isLoading: Bool {
        if case .loading = catalog { return true }
        return false
    }

    @MainActor private func refresh() async {
        catalog = .loading
        do {
            let models = try await OllamaPolisher.models()
            guard !Task.isCancelled else {
                catalog = .idle
                return
            }
            catalog = .ready(models)
        } catch {
            catalog = Task.isCancelled ? .idle : .unavailable
        }
    }
}
