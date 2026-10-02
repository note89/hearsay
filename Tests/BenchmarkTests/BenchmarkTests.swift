import Foundation
import Lexicon
import Pipeline
import Polish
import Testing

@testable import Benchmark
@testable import Transcription

@Test func formattingErrorsRemainVisibleWhenWordsMatch() {
    let score = TextScore(reference: "Buy:\n- Bread\n- Milk", hypothesis: "buy bread milk")
    #expect(score.wer == 0)
    #expect(score.characterErrorRate > 0)
    #expect(!score.exact)
    #expect(TextScore(reference: "hello\r\nworld", hypothesis: "hello\nworld").exact)
    #expect(TextScore(reference: "", hypothesis: "invented").characterErrorRate > 0)
}

private actor TestPolisher: Polisher {
    private(set) var calls = 0
    let verdict: PolishVerdict
    init(_ verdict: PolishVerdict) { self.verdict = verdict }
    func polish(_ spoken: String, style: WritingStyle, intensity: PolishIntensity, context: PolishContext) async -> PolishVerdict {
        calls += 1
        return verdict
    }
}

@Test func actualCleanupAppliesDictionaryAfterPolishAndPreservesProvenance() async {
    let raw = RawTranscript(text: "um send mprox invoice")
    let polisher = TestPolisher(PolishGuard.verdict(spoken: raw.text, candidate: "Send mprox invoice"))
    let result = await TextPipeline.finish(
        raw, mode: .full, style: .chat,
        lexicon: Lexicon(entries: [.rewrite(from: "mprox", to: "mprocs")]), polisher: polisher, fieldContext: nil
    )
    #expect(result.delivered.text == "Send mprocs invoice")
    #expect(result.delivered.spoken == raw.text)
    #expect(result.rejection == nil)
    #expect(await polisher.calls == 1)
}

@Test func cleanupOffAndRejectedCleanupStillApplyRewrites() async {
    let raw = RawTranscript(text: "mprox")
    let polisher = TestPolisher(.keepRaw(.meaningDrift))
    let dictionary = Lexicon(entries: [.rewrite(from: "mprox", to: "mprocs")])
    let off = await TextPipeline.finish(raw, mode: .off, style: .plain, lexicon: dictionary, polisher: polisher, fieldContext: nil)
    #expect(off.delivered.text == "mprocs")
    #expect(off.polishDuration == .zero)
    #expect(await polisher.calls == 0)
    let rejected = await TextPipeline.finish(raw, mode: .full, style: .plain, lexicon: dictionary, polisher: polisher, fieldContext: nil)
    #expect(rejected.delivered.text == "mprocs")
    #expect(rejected.rejection == .meaningDrift)
}

private func pipeline(_ id: String = "apple", engine: Engine = .appleLocal) -> BenchmarkPipeline {
    BenchmarkPipeline(id: id, engine: engine, polish: .off, polishEngine: .onDevice, polishModel: nil)
}

private func report(hypothesis: String, fingerprint: String = "same-audio", failure: String? = nil) -> BenchmarkReport {
    let item = BenchmarkCase(
        id: "one", audio: "audio/one.wav", locale: "en-US", style: .plain,
        spoken: "hello world", expected: "Hello, world!", wispr: nil, fieldContext: nil)
    let suite = BenchmarkSuite(schemaVersion: 1, name: "Test", vocabulary: [], rewrites: [], cases: [item])
    let output = BenchmarkOutput(
        raw: "hello world", delivered: hypothesis, rawScore: nil, finalScore: TextScore(reference: item.expected, hypothesis: hypothesis),
        wisprScore: nil, cleanupRejection: nil, audioMs: 100, setupMs: 20, modelStartup: .cold, modelLoadMs: 20,
        firstPartialMs: nil, transcriptionMs: 150, afterAudioMs: 50, polishMs: 0, totalMs: 150, finalAfterAudioMs: 50
    )
    return BenchmarkReport(
        schemaVersion: 1, createdAt: Date(), suite: suite, suiteFingerprint: fingerprint,
        configuration: BenchmarkConfiguration(
            schemaVersion: 1, repetitions: 1, pacing: .realtime, execution: .hybrid, pipelines: [pipeline()]),
        codeRevision: "test", operatingSystem: "test", modelVersions: [:], cleanupPrompts: [:],
        measurements: [
            BenchmarkMeasurement(
                caseID: item.id, pipelineID: "apple", repetition: 1,
                outcome: failure.map { .failed(reason: $0, totalMs: 150) } ?? .completed(output))
        ]
    )
}

@Test func baselineDetectsFormattingRegressionAndCountsFailure() throws {
    let baseline = report(hypothesis: "Hello, world!")
    #expect(try BenchmarkComparison.regressions(current: baseline, baseline: baseline).isEmpty)
    let regressions = try BenchmarkComparison.regressions(current: report(hypothesis: "hello world"), baseline: baseline)
    #expect(regressions.count == 1)
    #expect(regressions[0].contains("character errors"))
    #expect(
        try BenchmarkComparison.regressions(current: report(hypothesis: "", failure: "timeout"), baseline: baseline)[0].contains("failures")
    )
    #expect(throws: BenchmarkError.self) {
        try BenchmarkComparison.regressions(current: report(hypothesis: "Hello, world!", fingerprint: "changed-audio"), baseline: baseline)
    }
}

@Test func reportRoundTripIncludesFailuresAndPrivatePermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("report.json")
    let original = report(hypothesis: "", failure: "timeout")
    try original.save(to: file)
    let decoded = try BenchmarkReport.load(at: file)
    #expect(decoded.suiteFingerprint == original.suiteFingerprint)
    if case .failed(let reason, let totalMs) = decoded.measurements[0].outcome {
        #expect(totalMs == 150)
        #expect(reason == "timeout")
    } else {
        Issue.record("failure was dropped")
    }
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    #expect(BenchmarkRendering.markdown(decoded).contains("1"))
}

@Test func starterCorpusCannotOverwriteRecordingsAndFingerprintIncludesAudio() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try BenchmarkStarter.create(at: directory)
    let suite = try BenchmarkSuite.load(at: directory)
    let config = try BenchmarkConfiguration.load(at: directory.appendingPathComponent("pipelines.json"))
    #expect(suite.cases.count == 9)
    #expect(config.execution == .hybrid)
    #expect(throws: BenchmarkError.self) { try BenchmarkStarter.create(at: directory) }
    for item in suite.cases { try Data("first".utf8).write(to: directory.appendingPathComponent(item.audio)) }
    let before = try suite.fingerprint(in: directory)
    try Data("new recording".utf8).write(to: directory.appendingPathComponent(suite.cases[0].audio))
    #expect(try suite.fingerprint(in: directory) != before)
}

@Test func malformedCorpusAndUnknownEngineFailBeforeExecution() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try BenchmarkStarter.create(at: directory)
    let suiteURL = directory.appendingPathComponent("suite.json")
    let original = try String(contentsOf: suiteURL, encoding: .utf8)
    try original.replacingOccurrences(of: "audio/numbers.wav", with: "../outside.wav").write(
        to: suiteURL, atomically: true, encoding: .utf8)
    #expect(throws: BenchmarkError.self) { try BenchmarkSuite.load(at: directory) }
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Engine.self, from: Data("\"unknown-model\"".utf8)) }
}

@Test func allModelSelectionRetainsExecutionModeAndUsesValidUniqueIDs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try BenchmarkStarter.create(at: directory)
    let url = directory.appendingPathComponent("pipelines.json")
    let original = try BenchmarkConfiguration.load(at: url)
    let all = original.includingAllModels().selecting(execution: .sequential)
    try JSONEncoder().encode(all).write(to: url)
    let decoded = try BenchmarkConfiguration.load(at: url)
    #expect(decoded.execution == .sequential)
    #expect(decoded.pipelines.map(\.engine) == Engine.all)
    #expect(decoded.pipelines.allSatisfy { $0.polish == .full })
}

@Test func incompleteBaselineAndDifferentExecutionModesCannotPass() throws {
    let original = report(hypothesis: "Hello, world!")
    let incomplete = BenchmarkReport(
        schemaVersion: 1, createdAt: original.createdAt, suite: original.suite, suiteFingerprint: original.suiteFingerprint,
        configuration: original.configuration, codeRevision: "test", operatingSystem: "test", modelVersions: [:], cleanupPrompts: [:],
        measurements: []
    )
    #expect(throws: BenchmarkError.self) { try BenchmarkComparison.regressions(current: original, baseline: incomplete) }
    #expect(throws: BenchmarkError.self) {
        try BenchmarkComparison.checkCompatibility(
            fingerprint: original.suiteFingerprint,
            configuration: original.configuration.selecting(execution: .parallel), baseline: original)
    }
}

private actor ConcurrencyProbe {
    var active = 0
    var peak = 0
    var diskActive = 0
    var diskPeak = 0
    var cloudActive = 0
    var cloudPeak = 0
    var hybridOverlap = false
    func start(_ engine: Engine) {
        active += 1
        peak = max(peak, active)
        if case .local = engine {
            diskActive += 1
            diskPeak = max(diskPeak, diskActive)
        }
        if engine.privacyClass == .cloud {
            cloudActive += 1
            cloudPeak = max(cloudPeak, cloudActive)
        }
        if diskActive > 0 && cloudActive > 0 { hybridOverlap = true }
    }
    func end(_ engine: Engine) {
        active -= 1
        if case .local = engine { diskActive -= 1 }
        if engine.privacyClass == .cloud { cloudActive -= 1 }
    }
}

@Test(arguments: [BenchmarkExecution.sequential, .hybrid, .parallel])
func schedulerKeepsDiskModelsSerialAndReturnsConfigurationOrder(_ mode: BenchmarkExecution) async {
    let jobs = [
        pipeline("disk-a", engine: .local(.cohere)), pipeline("cloud-a", engine: .elevenLabsScribe),
        pipeline("disk-b", engine: .local(.qwen)), pipeline("cloud-b", engine: .geminiTranscribeLive),
    ]
    let probe = ConcurrencyProbe()
    let results = await BenchmarkScheduler.run(jobs, execution: mode) { job in
        await probe.start(job.engine)
        try? await Task.sleep(for: .milliseconds(60))
        await probe.end(job.engine)
        return job.id
    }
    #expect(results == jobs.map(\.id))
    #expect(await probe.diskPeak == 1)
    if mode == .sequential { #expect(await probe.peak == 1) } else { #expect(await probe.cloudPeak == 2) }
    if mode == .hybrid { #expect(await probe.hybridOverlap == false) }
    if mode == .parallel { #expect(await probe.hybridOverlap) }
}
