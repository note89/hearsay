import AVFoundation
import CoreML
import FluidAudio
import Foundation
import MLX
import MLXAudioSTT

public enum LocalInferenceFailure: LocalizedError {
    case missingAsset(String)
    case missingMetalLibrary
    case unsupportedLanguage(LocalSpeechModel, String)

    public var errorDescription: String? {
        switch self {
        case .missingAsset(let file):
            "This speech model is missing \(file). Download it again in Dictation settings."
        case .missingMetalLibrary:
            "The local speech runtime is incomplete. Install a complete Hearsay app build to use this model."
        case .unsupportedLanguage(let model, let language):
            "\(model.label) does not support \(language). Choose a supported language in Dictation settings."
        }
    }
}

/// A downloaded speech model consumes one utterance and transcribes it entirely on this Mac.
public final class LocalModelTranscriber: Transcriber {
    public let model: LocalSpeechModel
    public let directory: URL
    public let locale: Locale

    public init(model: LocalSpeechModel, directory: URL, locale: Locale) {
        self.model = model
        self.directory = directory
        self.locale = locale
    }

    public func prepare() async throws {
        if model.needsLocale && model.languageCode(for: locale) == nil {
            throw LocalInferenceFailure.unsupportedLanguage(model, locale.identifier)
        }
        try await LocalInferenceRuntime.shared.prepare(model: model, directory: directory)
    }

    public static func releaseModel() async {
        await LocalInferenceRuntime.shared.unload()
    }

    public func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>,
        hints: TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let model = model
        let directory = directory
        let locale = locale
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    var utterance = LocalAudioAccumulator()
                    for await buffer in audio {
                        try Task.checkCancellation()
                        try utterance.append(buffer)
                    }
                    try utterance.finish()
                    try Task.checkCancellation()
                    let text: String
                    if utterance.hasAudibleSamples {
                        text = try await LocalInferenceRuntime.shared.transcribe(
                            model: model, directory: directory, samples: utterance.samples, locale: locale
                        )
                    } else {
                        text = ""
                    }
                    try Task.checkCancellation()
                    continuation.yield(.final(RawTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines))))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct LocalAudioAccumulator {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter = AudioBufferConverter(to: Self.format)
    private(set) var samples: [Float] = []
    private(set) var hasAudibleSamples = false

    mutating func append(_ buffer: AVAudioPCMBuffer) throws {
        if let converted = try converter.convert(buffer) { appendConverted(converted) }
    }

    mutating func finish() throws {
        if let converted = try converter.finish() { appendConverted(converted) }
    }

    private mutating func appendConverted(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        samples.append(contentsOf: chunk)
        if !hasAudibleSamples { hasAudibleSamples = chunk.contains { $0.isFinite && abs($0) > 0.00001 } }
    }
}

/// Every sample belongs to one bounded chunk; cuts prefer quiet moments near the end.
struct LocalAudioChunkPlan {
    let ranges: [Range<Int>]

    init(samples: [Float], secondsPerChunk: Int) {
        let maximumSamples = secondsPerChunk * 16_000
        let searchSamples = 16_000
        let windowSamples = 640
        var ranges: [Range<Int>] = []
        var start = 0
        while start < samples.count {
            var end = min(start + maximumSamples, samples.count)
            if end < samples.count {
                let searchStart = max(start + windowSamples, end - searchSamples)
                var quietestEnergy = Float.infinity
                for center in stride(from: end - windowSamples / 2, through: searchStart, by: -160) {
                    let window = (center - windowSamples / 2)..<(center + windowSamples / 2)
                    let energy = window.reduce(Float(0)) { $0 + samples[$1] * samples[$1] }
                    if energy < quietestEnergy {
                        quietestEnergy = energy
                        end = center
                    }
                }
            }
            ranges.append(start..<end)
            start = end
        }
        self.ranges = ranges
    }
}

/// The gate remains held across asynchronous tokenizer/Core ML calls, preventing model overlap.
private actor LocalInferenceRuntime {
    static let shared = LocalInferenceRuntime()

    private struct LoadedModel {
        let model: LocalSpeechModel
        let directory: URL
        let backend: Backend
    }

    private enum Backend {
        case cohere(CohereTranscribeModel)
        case qwen(Qwen3ASRModel)
        case redux(AsrManager)
        case whisper(WhisperModel)
    }

    private var loaded: LoadedModel?
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var metalConfigured = false

    func unload() async {
        await acquire()
        defer { release() }
        loaded = nil
        if metalConfigured { Memory.clearCache() }
    }

    func prepare(model: LocalSpeechModel, directory: URL) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await load(model: model, directory: directory)
        try Task.checkCancellation()
    }

    func transcribe(model: LocalSpeechModel, directory: URL, samples: [Float], locale: Locale) async throws -> String {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await load(model: model, directory: directory)
        guard let loaded else { throw LocalInferenceFailure.missingAsset("model") }
        let languageCode = model.languageCode(for: locale)
        let result: String
        switch loaded.backend {
        case .cohere(let recognizer):
            guard let language = languageCode else {
                throw LocalInferenceFailure.unsupportedLanguage(model, locale.identifier)
            }
            result = try transcribeChunks(samples, secondsPerChunk: 30) { chunk in
                recognizer.generate(
                    audio: chunk,
                    generationParameters: STTGenerateParameters(
                        maxTokens: recognizer.defaultGenerationParameters.maxTokens,
                        language: language
                    )
                ).text
            }
        case .qwen(let recognizer):
            result = try transcribeChunks(samples, secondsPerChunk: 30) { chunk in
                recognizer.generate(audio: chunk, generationParameters: STTGenerateParameters(maxTokens: 1_024)).text
            }
        case .redux(let recognizer):
            var decoder = try TdtDecoderState()
            let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
            let padded =
                samples.count < minimumSamples
                ? samples + Array(repeating: Float(0), count: minimumSamples - samples.count)
                : samples
            result = try await recognizer.transcribe(padded, decoderState: &decoder).text
        case .whisper(let recognizer):
            guard let language = languageCode else {
                throw LocalInferenceFailure.unsupportedLanguage(model, locale.identifier)
            }
            result = try transcribeChunks(samples, secondsPerChunk: 15) { chunk in
                recognizer.generate(
                    audio: chunk,
                    generationParameters: STTGenerateParameters(
                        maxTokens: recognizer.defaultGenerationParameters.maxTokens,
                        language: language
                    )
                ).text
            }
        }
        try Task.checkCancellation()
        return result
    }

    // The SDK's batch calls cannot be interrupted. Hold the gate until the current bounded
    // chunk finishes, then observe cancellation before decoding another chunk or emitting text.
    private func transcribeChunks(
        _ samples: [Float], secondsPerChunk: Int, decode: (MLXArray) -> String
    ) throws -> String {
        let plan = LocalAudioChunkPlan(samples: samples, secondsPerChunk: secondsPerChunk)
        var texts: [String] = []
        for range in plan.ranges {
            try Task.checkCancellation()
            let text = decode(MLXArray(Array(samples[range]))).trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            if !text.isEmpty { texts.append(text) }
            Memory.clearCache()
        }
        return texts.joined(separator: " ")
    }

    private func load(model: LocalSpeechModel, directory: URL) async throws {
        if loaded?.model == model && loaded?.directory == directory { return }
        // Drop the previous weights before constructing the next model on an 18 GB laptop.
        loaded = nil
        if metalConfigured { Memory.clearCache() }
        if model != .redux {
            try configureMetal()
            Memory.cacheLimit = 256 * 1024 * 1024
        }
        let backend: Backend
        switch model {
        case .cohere:
            try require("tokenizer.model", in: directory)
            backend = .cohere(try CohereTranscribeModel.fromDirectory(directory))
        case .qwen:
            try require("tokenizer_config.json", in: directory)
            try require("vocab.json", in: directory)
            try require("merges.txt", in: directory)
            backend = .qwen(try await Qwen3ASRModel.fromModelDirectory(directory))
        case .redux:
            let models = try AsrModels.loadLocal(from: directory, version: .redux, encoderComputeUnits: .cpuAndGPU)
            backend = .redux(AsrManager(models: models))
        case .whisper:
            // Whisper's library loader fetches a fallback tokenizer if this file is absent.
            try require("tokenizer.json", in: directory)
            try require("tokenizer_config.json", in: directory)
            backend = .whisper(try await WhisperModel.fromDirectory(directory))
        }
        try Task.checkCancellation()
        loaded = LoadedModel(model: model, directory: directory, backend: backend)
    }

    private func configureMetal() throws {
        // MLX 0.31.4 looks beside the executable; the app bundles a symlink into Resources.
        guard let library = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mlx.metallib"),
            FileManager.default.fileExists(atPath: library.path)
        else {
            throw LocalInferenceFailure.missingMetalLibrary
        }
        metalConfigured = true
    }

    private func require(_ file: String, in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else {
            throw LocalInferenceFailure.missingAsset(file)
        }
    }

    private func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
