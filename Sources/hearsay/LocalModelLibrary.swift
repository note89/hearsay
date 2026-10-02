import Foundation
import Observation
import Transcription

enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(LocalModelProgress)
    case removing
    case installed(URL)
    case failed(String)
}

/// Download intent and progress belong to the library, independently of the selected engine.
@MainActor @Observable
final class LocalModelLibrary {
    private(set) var states: [LocalSpeechModel: ModelDownloadState] = [:]
    @ObservationIgnored private let store: LocalModelStore
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadToken: UUID?

    init(directory: URL) {
        store = LocalModelStore(directory: directory)
        for model in LocalSpeechModel.allCases {
            states[model] = store.installedDirectory(of: model).map(ModelDownloadState.installed) ?? .notDownloaded
        }
    }

    var isDownloading: Bool { downloadToken != nil }

    var isBusy: Bool {
        isDownloading || states.values.contains(.removing)
    }

    func state(of model: LocalSpeechModel) -> ModelDownloadState {
        states[model] ?? .notDownloaded
    }

    func directory(for model: LocalSpeechModel) -> URL? {
        guard case .installed(let directory) = state(of: model) else { return nil }
        return directory
    }

    func download(_ model: LocalSpeechModel, onInstalled: @escaping @MainActor () -> Void) {
        guard !isBusy, directory(for: model) == nil else { return }
        let token = UUID()
        downloadToken = token
        states[model] = .downloading(LocalModelProgress(receivedBytes: 0, totalBytes: model.downloadBytes))
        downloadTask = Task { [weak self, store] in
            do {
                let directory = try await store.download(model) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.downloadToken == token else { return }
                        self.states[model] = .downloading(progress)
                    }
                }
                guard let self, self.downloadToken == token else { return }
                self.states[model] = .installed(directory)
                self.downloadToken = nil
                self.downloadTask = nil
                onInstalled()
            } catch {
                guard let self, self.downloadToken == token else { return }
                self.states[model] = error is CancellationError ? .notDownloaded : .failed(error.localizedDescription)
                self.downloadToken = nil
                self.downloadTask = nil
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    func remove(_ model: LocalSpeechModel, onRemoved: @escaping @MainActor () -> Void) {
        guard !isBusy else { return }
        states[model] = .removing
        Task { [weak self, store] in
            do {
                try await store.remove(model)
                self?.states[model] = .notDownloaded
                onRemoved()
            } catch {
                self?.states[model] = .failed(error.localizedDescription)
            }
        }
    }

    func stop() { cancelDownload() }
}
