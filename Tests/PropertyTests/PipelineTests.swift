import Lexicon
import Polish
import Testing

@testable import Pipeline
@testable import Transcription

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor SuspendedCleanup {
    let started = Gate()
    let released = Gate()
    let returned = Gate()
    private(set) var didStart = false
    private(set) var wasCancelled = false

    func run() async -> PolishVerdict {
        didStart = true
        await started.open()
        await released.wait()  // Deliberately ignores cancellation, like a blocking model call.
        wasCancelled = Task.isCancelled
        await returned.open()
        return PolishGuard.verdict(spoken: "invoice", candidate: "Invoice.")
    }
}

private actor CountingPolisher: Polisher {
    private(set) var calls = 0

    func polish(_ spoken: String, style: WritingStyle, intensity: PolishIntensity, context: PolishContext) async -> PolishVerdict {
        calls += 1
        return PolishGuard.verdict(spoken: spoken, candidate: spoken)
    }
}

struct PipelineTests {
    @Test func rewritesPreserveOriginalTranscriptAtEveryDepth() {
        Properties.check(
            seed: 501, generate: { $0.words() },
            property: { layers in
                let raw = RawTranscript(text: layers.joined(separator: " "))
                var text = InsertableText.raw(raw)
                for layer in layers {
                    text = .rewritten(text: layer, over: text)
                    if text.spoken != raw.text || text.text != layer { return false }
                }
                return text.spoken == raw.text
            })
    }

    @Test(.timeLimit(.minutes(1))) func cancellationReturnsWithoutWaitingForNonCooperativeWork() async {
        let work = SuspendedCleanup()
        let task = Task { await TextPipeline.within(.seconds(60)) { await work.run() } }
        await work.started.wait()
        task.cancel()
        let verdict = await task.value
        guard case .keepRaw(.cancelled) = verdict else {
            await work.released.open()
            Issue.record("cancellation must win before the worker returns")
            return
        }
        await work.released.open()
        await work.returned.wait()
        #expect(await work.wasCancelled)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationBeforeContinuationInstallationSkipsWork() async {
        let gate = Gate()
        let polisher = CountingPolisher()
        let task = Task {
            await gate.wait()
            return await TextPipeline.within(.seconds(60)) {
                await polisher.polish("invoice", style: .plain, intensity: .light, context: .none)
            }
        }
        task.cancel()
        await gate.open()
        guard case .keepRaw(.cancelled) = await task.value else {
            Issue.record("already cancelled callers must receive cancellation")
            return
        }
        #expect(await polisher.calls == 0)
    }

    @Test(.timeLimit(.minutes(1))) func timeoutReturnsWhileNonCooperativeWorkIsStillSuspended() async {
        let work = SuspendedCleanup()
        let task = Task { await TextPipeline.within(.milliseconds(20)) { await work.run() } }
        guard case .keepRaw(.timeout) = await task.value else {
            await work.released.open()
            Issue.record("deadline must return without joining the worker")
            return
        }
        await work.released.open()
        if await work.didStart {
            await work.returned.wait()
            #expect(await work.wasCancelled)
        }
    }

    @Test func workerTimeoutAndCancellationRacesDeliverOnce() async {
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let task = Task {
                        await TextPipeline.within(.zero) {
                            PolishGuard.verdict(spoken: "invoice", candidate: "Invoice.")
                        }
                    }
                    if index.isMultiple(of: 2) { task.cancel() }
                    switch await task.value {
                    case .accept(let text): #expect(text.text == "Invoice.")
                    case .keepRaw(let reason): #expect(reason == .timeout || reason == .cancelled)
                    }
                }
            }
        }
    }

    @Test func emptyTranscriptDoesNotInvokePolisher() async {
        let polisher = CountingPolisher()
        let result = await TextPipeline.finish(
            RawTranscript(text: ""), mode: .full, style: .plain,
            lexicon: .empty, polisher: polisher, fieldContext: nil)
        #expect(result.delivered.text.isEmpty)
        #expect(result.polishDuration == .zero)
        #expect(await polisher.calls == 0)
    }
}
