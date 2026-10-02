import CryptoKit
import Foundation
import Testing

@testable import Transcription

private enum FixtureDownloadFailure: Error {
    case network
}

private actor FixtureModelTransport: LocalModelDownloadTransport {
    let files: [String: Data]
    let failOnFile: String?
    let pause: Bool
    private(set) var requests: [URL] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    init(files: [String: Data], failOnFile: String? = nil, pause: Bool = false) {
        self.files = files
        self.failOnFile = failOnFile
        self.pause = pause
    }

    func download(from source: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        requests.append(source)
        for waiter in startedWaiters { waiter.resume() }
        startedWaiters.removeAll()
        if pause { try await Task.sleep(for: .seconds(30)) }
        let data = files[source.lastPathComponent] ?? Data()
        if source.lastPathComponent == failOnFile {
            try data.prefix(1).write(to: destination)
            throw FixtureDownloadFailure.network
        }
        try data.write(to: destination)
        progress(Int64(data.count))
    }

    func waitUntilStarted() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
}

private final class ModelProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LocalModelProgress] = []

    func append(_ progress: LocalModelProgress) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(progress)
    }

    var values: [LocalModelProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class LocalModelFixture {
    let directory: URL
    let files: [String: Data] = [
        "config.json": Data("{\"model_type\":\"fixture\"}".utf8),
        "model.safetensors": Data("synthetic model weights".utf8),
    ]

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearsay-model-tests-\(UUID().uuidString)")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var package: LocalModelPackage {
        LocalModelPackage(
            repositoryID: "fixture/speech",
            revision: String(repeating: "a", count: 40),
            artifacts: [
                artifact("config.json", gitBlob: true),
                artifact("model.safetensors", gitBlob: false),
            ]
        )
    }

    func artifact(_ name: String, gitBlob: Bool) -> LocalModelArtifact {
        let data = files[name]!
        let digest: LocalModelDigest
        if gitBlob {
            var hash = Insecure.SHA1()
            hash.update(data: Data("blob \(data.count)\0".utf8))
            hash.update(data: data)
            digest = .gitBlobSHA1(hash.finalize().map { String(format: "%02x", $0) }.joined())
        } else {
            digest = .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        return LocalModelArtifact(relativePath: name, byteCount: Int64(data.count), digest: digest)
    }

    func store(
        transport: FixtureModelTransport,
        package: LocalModelPackage? = nil,
        availableSpace: Int64 = 10_000_000_000
    ) -> LocalModelStore {
        let resolved = package ?? self.package
        return LocalModelStore(
            directory: directory,
            transport: transport,
            packageForModel: { _ in resolved },
            availableSpace: { _ in availableSpace }
        )
    }
}

struct LocalModelStoreTests {
    @Test func completePackagesAreVerifiedPublishedAndReusable() async throws {
        let fixture = LocalModelFixture()
        let transport = FixtureModelTransport(files: fixture.files)
        let store = fixture.store(transport: transport)
        let progress = ModelProgressRecorder()
        #expect(store.installedDirectory(of: .qwen) == nil)

        let target = try await store.download(.qwen, progress: { progress.append($0) })
        #expect(store.installedDirectory(of: .qwen) == target)
        let values = progress.values
        #expect(values.first?.receivedBytes == 0)
        #expect(values.last?.receivedBytes == fixture.package.downloadBytes)
        #expect(values.allSatisfy { $0.totalBytes == fixture.package.downloadBytes })
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.receivedBytes <= $1.receivedBytes })
        #expect(await transport.requests.count == 2)
        #expect(await transport.requests.allSatisfy { $0.path.contains(fixture.package.revision) })

        let sameTarget = try await store.download(.qwen, progress: { _ in })
        #expect(sameTarget == target)
        #expect(await transport.requests.count == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(".partial-qwen").path))
        try await store.remove(.qwen)
        #expect(store.installedDirectory(of: .qwen) == nil)
    }

    @Test func failedTransfersLeaveNothingReadyAndCanBeRetried() async throws {
        let fixture = LocalModelFixture()
        let failing = FixtureModelTransport(files: fixture.files, failOnFile: "model.safetensors")
        let first = fixture.store(transport: failing)
        await #expect(throws: FixtureDownloadFailure.self) { try await first.download(.cohere, progress: { _ in }) }
        #expect(first.installedDirectory(of: .cohere) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)

        let retry = fixture.store(transport: FixtureModelTransport(files: fixture.files))
        let target = try await retry.download(.cohere, progress: { _ in })
        #expect(retry.installedDirectory(of: .cohere) == target)
    }

    @Test func truncatedAndCorruptedArtifactsNeverBecomeReady() async throws {
        let fixture = LocalModelFixture()
        var truncated = fixture.files
        truncated["model.safetensors"] = Data("short".utf8)
        let shortStore = fixture.store(transport: FixtureModelTransport(files: truncated))
        await #expect(throws: LocalModelStoreFailure.artifactSizeMismatch("model.safetensors")) {
            try await shortStore.download(.whisper, progress: { _ in })
        }
        #expect(shortStore.installedDirectory(of: .whisper) == nil)

        var corrupted = fixture.files
        corrupted["model.safetensors"] = Data(repeating: 65, count: fixture.files["model.safetensors"]!.count)
        let corruptStore = fixture.store(transport: FixtureModelTransport(files: corrupted))
        await #expect(throws: LocalModelStoreFailure.artifactDigestMismatch("model.safetensors")) {
            try await corruptStore.download(.whisper, progress: { _ in })
        }
        #expect(corruptStore.installedDirectory(of: .whisper) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @Test func cancellationCleansStagingAndPreventsDuplicateDownloads() async throws {
        let fixture = LocalModelFixture()
        let transport = FixtureModelTransport(files: fixture.files, pause: true)
        let store = fixture.store(transport: transport)
        let download = Task { try await store.download(.redux, progress: { _ in }) }
        await transport.waitUntilStarted()
        await #expect(throws: LocalModelStoreFailure.downloadInProgress) {
            try await store.download(.redux, progress: { _ in })
        }
        await #expect(throws: LocalModelStoreFailure.downloadInProgress) { try await store.remove(.redux) }
        download.cancel()
        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(store.installedDirectory(of: .redux) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @Test func insufficientDiskSpaceMakesNoNetworkRequest() async throws {
        let fixture = LocalModelFixture()
        let transport = FixtureModelTransport(files: fixture.files)
        let store = fixture.store(transport: transport, availableSpace: 1)
        await #expect(throws: LocalModelStoreFailure.self) { try await store.download(.qwen, progress: { _ in }) }
        #expect(await transport.requests.isEmpty)
        #expect(store.installedDirectory(of: .qwen) == nil)
    }

    @Test func interruptedDownloadIsClearedBeforeCheckingSpaceForRetry() async throws {
        let fixture = LocalModelFixture()
        let partial = fixture.directory.appendingPathComponent(".partial-qwen", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("left behind by an interrupted process".utf8).write(to: partial.appendingPathComponent("old-weights"))
        let package = fixture.package
        let store = LocalModelStore(
            directory: fixture.directory,
            transport: FixtureModelTransport(files: fixture.files),
            packageForModel: { _ in package },
            availableSpace: { _ in FileManager.default.fileExists(atPath: partial.path) ? 0 : 10_000_000_000 }
        )
        #expect(store.installedDirectory(of: .qwen) == nil)
        let target = try await store.download(.qwen, progress: { _ in })
        #expect(store.installedDirectory(of: .qwen) == target)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("old-weights").path))
    }

    @Test func installedStateRejectsMissingFilesAndDifferentPinnedRevisions() async throws {
        let fixture = LocalModelFixture()
        let store = fixture.store(transport: FixtureModelTransport(files: fixture.files))
        let target = try await store.download(.qwen, progress: { _ in })
        let changedPackage = LocalModelPackage(
            repositoryID: fixture.package.repositoryID,
            revision: String(repeating: "b", count: 40),
            artifacts: fixture.package.artifacts
        )
        let updated = fixture.store(transport: FixtureModelTransport(files: fixture.files), package: changedPackage)
        #expect(updated.installedDirectory(of: .qwen) == nil)
        try FileManager.default.removeItem(at: target.appendingPathComponent("config.json"))
        #expect(store.installedDirectory(of: .qwen) == nil)
    }

    @Test func everyShippedModelPinsAllWeightsAndTokenizers() {
        for model in LocalSpeechModel.allCases {
            let package = model.package
            #expect(package.revision.count == 40)
            #expect(package.revision.allSatisfy { $0.isHexDigit })
            #expect(model.downloadBytes > 0)
            #expect(!package.artifacts.isEmpty)
            #expect(Set(package.artifacts.map(\.relativePath)).count == package.artifacts.count)
            #expect(package.artifacts.contains { $0.relativePath == "README.md" })
            #expect(package.artifacts.allSatisfy { $0.byteCount > 0 && !$0.relativePath.contains("..") })
        }
        #expect(LocalSpeechModel.cohere.package.artifacts.contains { $0.relativePath == "tokenizer.model" })
        #expect(LocalSpeechModel.qwen.package.artifacts.contains { $0.relativePath == "vocab.json" })
        #expect(LocalSpeechModel.whisper.package.artifacts.contains { $0.relativePath == "tokenizer.json" })
        #expect(LocalSpeechModel.redux.package.artifacts.contains { $0.relativePath == "Encoder.mlmodelc/weights/weight.bin" })
    }
}
