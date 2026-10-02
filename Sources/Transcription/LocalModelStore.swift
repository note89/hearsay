import CryptoKit
import Foundation

public struct LocalModelProgress: Equatable, Sendable {
    public let receivedBytes: Int64
    public let totalBytes: Int64

    public init(receivedBytes: Int64, totalBytes: Int64) {
        precondition(totalBytes > 0 && receivedBytes >= 0 && receivedBytes <= totalBytes)
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double { Double(receivedBytes) / Double(totalBytes) }
}

/// Installs complete, verified model packages; inference reads only completed installations.
public actor LocalModelStore {
    public nonisolated let directory: URL
    private nonisolated let packageForModel: @Sendable (LocalSpeechModel) -> LocalModelPackage
    private let transport: any LocalModelDownloadTransport
    private let availableSpace: @Sendable (URL) throws -> Int64
    private var downloads: Set<LocalSpeechModel> = []

    private static let manifestName = ".hearsay-model.json"
    private static let diskHeadroom: Int64 = 256 * 1_048_576

    public init(directory: URL) {
        self.directory = directory
        packageForModel = { $0.package }
        transport = URLSessionModelDownloadTransport()
        availableSpace = { try Self.freeSpace(at: $0) }
    }

    init(
        directory: URL,
        transport: any LocalModelDownloadTransport,
        packageForModel: @escaping @Sendable (LocalSpeechModel) -> LocalModelPackage,
        availableSpace: @escaping @Sendable (URL) throws -> Int64 = { try LocalModelStore.freeSpace(at: $0) }
    ) {
        self.directory = directory
        self.transport = transport
        self.packageForModel = packageForModel
        self.availableSpace = availableSpace
    }

    /// A completion manifest and every expected file must be present. Partial directories never qualify.
    public nonisolated func installedDirectory(of model: LocalSpeechModel) -> URL? {
        let target = directory.appendingPathComponent(model.rawValue, isDirectory: true)
        let package = packageForModel(model)
        let expected = InstalledLocalModel(model: model, package: package)
        guard
            let data = try? Data(contentsOf: target.appendingPathComponent(Self.manifestName)),
            let manifest = try? JSONDecoder().decode(InstalledLocalModel.self, from: data),
            manifest == expected
        else { return nil }
        for artifact in package.artifacts {
            let path = target.appendingPathComponent(artifact.relativePath)
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                (attributes[.size] as? NSNumber)?.int64Value == artifact.byteCount
            else { return nil }
        }
        return target
    }

    /// Downloads to disk, checks pinned sizes and digests, then publishes the directory atomically.
    public func download(
        _ model: LocalSpeechModel,
        progress: @escaping @Sendable (LocalModelProgress) -> Void
    ) async throws -> URL {
        let package = packageForModel(model)
        if let installed = installedDirectory(of: model) {
            progress(LocalModelProgress(receivedBytes: package.downloadBytes, totalBytes: package.downloadBytes))
            return installed
        }
        guard downloads.insert(model).inserted else { throw LocalModelStoreFailure.downloadInProgress }
        defer { downloads.remove(model) }

        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".partial-\(model.rawValue)", isDirectory: true)
        if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
        let requiredSpace = package.downloadBytes + Self.diskHeadroom
        let freeSpace = try availableSpace(directory)
        guard freeSpace >= requiredSpace else {
            throw LocalModelStoreFailure.insufficientDiskSpace(required: requiredSpace, available: freeSpace)
        }
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }

        progress(LocalModelProgress(receivedBytes: 0, totalBytes: package.downloadBytes))
        var completedBytes: Int64 = 0
        for artifact in package.artifacts {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(artifact.relativePath)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let previousBytes = completedBytes
            try await transport.download(from: package.downloadURL(for: artifact), to: target) { received in
                progress(
                    LocalModelProgress(
                        receivedBytes: previousBytes + min(max(received, 0), artifact.byteCount),
                        totalBytes: package.downloadBytes
                    ))
            }
            try Task.checkCancellation()
            try await Self.verify(target, against: artifact)
            completedBytes += artifact.byteCount
            progress(LocalModelProgress(receivedBytes: completedBytes, totalBytes: package.downloadBytes))
        }
        try Task.checkCancellation()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifest = try encoder.encode(InstalledLocalModel(model: model, package: package))
        try manifest.write(to: staging.appendingPathComponent(Self.manifestName), options: .atomic)

        let destination = directory.appendingPathComponent(model.rawValue, isDirectory: true)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.moveItem(at: staging, to: destination)
        return destination
    }

    public func remove(_ model: LocalSpeechModel) throws {
        guard !downloads.contains(model) else { throw LocalModelStoreFailure.downloadInProgress }
        let target = directory.appendingPathComponent(model.rawValue, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }

    private static func freeSpace(at directory: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let bytes = attributes[.systemFreeSize] as? NSNumber else {
            throw LocalModelStoreFailure.diskSpaceUnavailable
        }
        return bytes.int64Value
    }

    private static func verify(_ file: URL, against artifact: LocalModelArtifact) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let received = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard received == artifact.byteCount else {
            throw LocalModelStoreFailure.artifactSizeMismatch(artifact.relativePath)
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha256 = SHA256()
        var gitSHA1 = Insecure.SHA1()
        if case .gitBlobSHA1 = artifact.digest {
            gitSHA1.update(data: Data("blob \(artifact.byteCount)\0".utf8))
        }
        var chunksRead = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            switch artifact.digest {
            case .sha256: sha256.update(data: chunk)
            case .gitBlobSHA1: gitSHA1.update(data: chunk)
            }
            chunksRead += 1
            if chunksRead.isMultiple(of: 64) { await Task.yield() }
        }
        let actual: String
        let expected: String
        switch artifact.digest {
        case .sha256(let digest):
            actual = sha256.finalize().map { String(format: "%02x", $0) }.joined()
            expected = digest
        case .gitBlobSHA1(let digest):
            actual = gitSHA1.finalize().map { String(format: "%02x", $0) }.joined()
            expected = digest
        }
        guard actual == expected else { throw LocalModelStoreFailure.artifactDigestMismatch(artifact.relativePath) }
    }
}

private struct InstalledLocalModel: Codable, Equatable {
    let formatVersion: Int
    let model: String
    let repositoryID: String
    let revision: String
    let artifacts: [LocalModelArtifact]

    init(model: LocalSpeechModel, package: LocalModelPackage) {
        formatVersion = 1
        self.model = model.rawValue
        repositoryID = package.repositoryID
        revision = package.revision
        artifacts = package.artifacts
    }
}

enum LocalModelStoreFailure: Error, LocalizedError, Equatable {
    case downloadInProgress
    case diskSpaceUnavailable
    case insufficientDiskSpace(required: Int64, available: Int64)
    case invalidHTTPResponse
    case httpStatus(Int)
    case artifactSizeMismatch(String)
    case artifactDigestMismatch(String)

    var errorDescription: String? {
        switch self {
        case .downloadInProgress: return "This model is already downloading."
        case .diskSpaceUnavailable: return "Could not check available disk space."
        case .insufficientDiskSpace(let required, let available):
            let need = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "The download needs \(need) of free disk space; \(free) is available."
        case .invalidHTTPResponse: return "The model server returned an invalid response."
        case .httpStatus(let status): return "The model server returned HTTP \(status). Try downloading again."
        case .artifactSizeMismatch(let path): return "The download of \(path) was incomplete. Try downloading again."
        case .artifactDigestMismatch(let path): return "The download of \(path) failed its integrity check. Try downloading again."
        }
    }
}

protocol LocalModelDownloadTransport: Sendable {
    func download(from source: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
}

private struct URLSessionModelDownloadTransport: LocalModelDownloadTransport {
    func download(from source: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = ModelFileDownload(destination: destination, progress: progress)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(from: source, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// URLSession downloads directly into its temporary file; even large weights stay out of app memory.
private final class ModelFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var wasCancelled = false

    init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func start(from source: URL, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if wasCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 6 * 60 * 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: source)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw LocalModelStoreFailure.invalidHTTPResponse
            }
            guard response.statusCode == 200 else { throw LocalModelStoreFailure.httpStatus(response.statusCode) }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            finish(.failure(cancelled ? CancellationError() : error))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        let session = session
        self.continuation = nil
        self.session = nil
        task = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
