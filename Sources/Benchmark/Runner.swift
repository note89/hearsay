import AVFoundation
import Foundation
import Pipeline
import Polish
import Transcription

public enum BenchmarkRunner {
    public static func run(
        suite: BenchmarkSuite, directory: URL, configuration: BenchmarkConfiguration,
        codeRevision: String, baseline: BenchmarkReport? = nil, progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> BenchmarkReport {
        let fingerprint = try suite.fingerprint(in: directory)
        if let baseline {
            try BenchmarkComparison.checkCompatibility(fingerprint: fingerprint, configuration: configuration, baseline: baseline)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hearsay")
        KeyStore.configure(directory: support)
        let models = LocalModelStore(directory: support.appendingPathComponent("local-models"))
        let residency = ModelResidency()
        let batches = await BenchmarkScheduler.run(configuration.pipelines, execution: configuration.execution) { pipeline in
            var measurements: [BenchmarkMeasurement] = []
            if case .local = pipeline.engine {
                await LocalModelTranscriber.releaseModel()
                await residency.unload()
            }
            for item in suite.cases {
                for repetition in 1...configuration.repetitions {
                    progress("\(pipeline.id) / \(item.id) / \(repetition)")
                    let outcome: BenchmarkOutcome
                    let measurementStarted = ContinuousClock.now
                    do {
                        outcome = .completed(
                            try await measure(
                                item, pipeline: pipeline, suite: suite, directory: directory,
                                pacing: configuration.pacing, models: models, residency: residency
                            ))
                    } catch {
                        outcome = .failed(
                            reason: error.localizedDescription, totalMs: (ContinuousClock.now - measurementStarted).benchmarkMilliseconds)
                    }
                    measurements.append(
                        BenchmarkMeasurement(
                            caseID: item.id, pipelineID: pipeline.id, repetition: repetition, outcome: outcome
                        ))
                }
            }
            return measurements
        }
        var prompts: [String: String] = [:]
        var versions: [String: String] = [:]
        for pipeline in configuration.pipelines {
            if case .local(let model) = pipeline.engine { versions[model.wireKey] = model.repositoryID + "@" + model.revision }
            if pipeline.polish != .off {
                switch pipeline.polishEngine {
                case .onDevice: versions[pipeline.id + "/cleanup"] = "apple-foundation-models"
                case .openRouter: versions[pipeline.id + "/cleanup"] = pipeline.polishModel ?? OpenRouterPolisher.defaultModel
                case .ollama: versions[pipeline.id + "/cleanup"] = "ollama/" + (pipeline.polishModel ?? "")
                }
            }
        }
        for style in Set(suite.cases.map(\.style)) {
            prompts["\(style.rawValue)/light"] = PolishPrompt.instructions(for: style, intensity: .light)
            prompts["\(style.rawValue)/full"] = PolishPrompt.instructions(for: style, intensity: .full)
        }
        return BenchmarkReport(
            schemaVersion: 1, createdAt: Date(), suite: suite, suiteFingerprint: fingerprint,
            configuration: configuration, codeRevision: codeRevision,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            modelVersions: versions,
            cleanupPrompts: prompts, measurements: batches.flatMap { $0 }
        )
    }

    private static func measure(
        _ item: BenchmarkCase, pipeline: BenchmarkPipeline, suite: BenchmarkSuite,
        directory: URL, pacing: ReplayPacing, models: LocalModelStore, residency: ModelResidency
    ) async throws -> BenchmarkOutput {
        let setup = ContinuousClock.now
        let file = try AVAudioFile(forReading: directory.appendingPathComponent(item.audio))
        guard file.length > 0 else { throw BenchmarkError("BenchmarkRunner.measure: empty recording \(item.id)") }
        let audioDuration = Double(file.length) / file.processingFormat.sampleRate
        let modelDirectory: URL?
        if case .local(let model) = pipeline.engine {
            guard let installed = models.installedDirectory(of: model) else {
                throw BenchmarkError("BenchmarkRunner.measure: download \(model.label) in Dictation first")
            }
            modelDirectory = installed
        } else {
            modelDirectory = nil
        }
        guard
            let transcriber = pipeline.engine.makeTranscriber(locale: Locale(identifier: item.locale), localModelDirectory: modelDirectory)
        else {
            throw BenchmarkError("BenchmarkRunner.measure: unavailable engine \(pipeline.engine.wireKey); check its API key")
        }
        if pipeline.engine == .appleLocal { try await SpeechAnalyzerTranscriber.ensureModel(for: Locale(identifier: item.locale)) }
        var startup = ModelStartup.notApplicable
        var modelLoadMs = 0
        if let local = transcriber as? LocalModelTranscriber {
            startup = await residency.state(for: local.model)
            let loadStarted = ContinuousClock.now
            try await local.prepare()
            modelLoadMs = (ContinuousClock.now - loadStarted).benchmarkMilliseconds
            await residency.loaded(local.model)
        }
        let polisher: any Polisher
        switch pipeline.polishEngine {
        case .openRouter where pipeline.polish != .off:
            guard let key = KeyStore.value("OPENROUTER_API_KEY") else {
                throw BenchmarkError("BenchmarkRunner.measure: OPENROUTER_API_KEY missing for cleanup")
            }
            polisher = OpenRouterPolisher(key: key, model: pipeline.polishModel ?? OpenRouterPolisher.defaultModel)
        case .ollama where pipeline.polish != .off:
            guard let model = pipeline.polishModel, !model.isEmpty else {
                throw BenchmarkError("BenchmarkRunner.measure: Ollama cleanup needs polishModel")
            }
            polisher = OllamaPolisher(model: model)
        default:
            polisher = FoundationModelsPolisher()
        }
        let setupMs = (ContinuousClock.now - setup).benchmarkMilliseconds
        let source = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let started = ContinuousClock.now
        let replay = Task { try await feed(file, into: source.continuation, pacing: pacing, started: started) }
        let transcription = Task {
            do {
                var final: RawTranscript?
                var firstPartial: Int?
                for try await event in transcriber.transcribe(
                    source.stream, hints: TranscriptionHints(vocabulary: suite.vocabulary, mode: pipeline.polish.transcriptMode)
                ) {
                    switch event {
                    case .partial(let text):
                        if firstPartial == nil, !text.isEmpty { firstPartial = (ContinuousClock.now - started).benchmarkMilliseconds }
                    case .final(let raw): final = raw
                    }
                }
                guard let final else { throw TranscriptionFailure.endedWithoutFinal }
                return (final, firstPartial, ContinuousClock.now)
            } catch {
                replay.cancel()
                throw error
            }
        }
        defer {
            replay.cancel()
            transcription.cancel()
            source.continuation.finish()
        }
        let ended: ContinuousClock.Instant
        do { ended = try await replay.value } catch {
            if replay.isCancelled { _ = try await transcription.value }
            throw error
        }
        let limit = pipeline.engine.transcriptionLimit(audioDuration: .seconds(audioDuration))
        let (raw, firstPartial, transcribedAt) = try await awaitTranscription(transcription, within: limit)
        let cleanup = await TextPipeline.finish(
            raw, mode: pipeline.polish, style: item.style, lexicon: suite.lexicon, polisher: polisher, fieldContext: item.fieldContext
        )
        let delivered = cleanup.delivered.text
        let finished = ContinuousClock.now
        return BenchmarkOutput(
            raw: raw.text, delivered: delivered,
            rawScore: item.spoken.map { TextScore(reference: $0, hypothesis: raw.text) },
            finalScore: TextScore(reference: item.expected, hypothesis: delivered),
            wisprScore: item.wispr.map { TextScore(reference: item.expected, hypothesis: $0) },
            cleanupRejection: cleanup.rejection?.label,
            audioMs: Int((audioDuration * 1000).rounded()), setupMs: setupMs,
            modelStartup: startup, modelLoadMs: modelLoadMs, firstPartialMs: firstPartial,
            transcriptionMs: (transcribedAt - started).benchmarkMilliseconds,
            afterAudioMs: max(0, (transcribedAt - ended).benchmarkMilliseconds),
            polishMs: cleanup.polishDuration.benchmarkMilliseconds, totalMs: (finished - started).benchmarkMilliseconds,
            finalAfterAudioMs: max(0, (finished - ended).benchmarkMilliseconds)
        )
    }

    private static func feed(
        _ file: AVAudioFile, into continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        pacing: ReplayPacing, started: ContinuousClock.Instant
    ) async throws -> ContinuousClock.Instant {
        defer { continuation.finish() }
        var frames: Int64 = 0
        let clock = ContinuousClock()
        while frames < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048) else {
                throw BenchmarkError("BenchmarkRunner.feed: cannot allocate audio buffer")
            }
            try file.read(into: buffer, frameCount: 2048)
            guard buffer.frameLength > 0 else { throw BenchmarkError("BenchmarkRunner.feed: recording ended early") }
            continuation.yield(buffer)
            frames += Int64(buffer.frameLength)
            if pacing == .realtime {
                try await clock.sleep(until: started + .seconds(Double(frames) / file.processingFormat.sampleRate))
            }
        }
        return clock.now
    }

    private static func awaitTranscription<T: Sendable>(_ task: Task<T, Error>, within limit: Duration) async throws -> T {
        defer { task.cancel() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: limit)
                throw BenchmarkError("BenchmarkRunner.awaitTranscription: timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TranscriptionFailure.endedWithoutFinal }
            return first
        }
    }
}

private actor ModelResidency {
    private var model: LocalSpeechModel?
    func state(for choice: LocalSpeechModel) -> ModelStartup { model == choice ? .resident : .cold }
    func loaded(_ choice: LocalSpeechModel) { model = choice }
    func unload() { model = nil }
}
