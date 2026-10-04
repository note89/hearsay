import AVFoundation
import Foundation
import Testing

@testable import Transcription

private actor RequestGate {
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

private actor Requests {
    private(set) var payloads: [Data] = []
    private(set) var wasCancelled = false

    func record(_ payload: Data) { payloads.append(payload) }
    func recordCancellation(_ cancelled: Bool) { wasCancelled = cancelled }
}

struct CloudTranscriptionTests {
    @Test(.timeLimit(.minutes(1))) func cancellingConsumerCancelsItsRequestTask() async {
        let requests = Requests()
        let started = RequestGate()
        let released = RequestGate()
        let returned = RequestGate()
        let audio = AsyncStream<AVAudioPCMBuffer> { $0.finish() }
        let events = oneShotWavTranscription(audio) { _ in
            await started.open()
            await released.wait()
            await requests.recordCancellation(Task.isCancelled)
            await returned.open()
            return "late result"
        }
        let consumer = Task {
            var finals = 0
            do {
                for try await event in events {
                    if case .final = event { finals += 1 }
                }
            } catch is CancellationError {
            } catch { Issue.record("Unexpected stream error: \(error)") }
            return finals
        }
        await started.wait()
        consumer.cancel()
        #expect(await consumer.value == 0)
        await released.open()
        await returned.wait()
        #expect(await requests.wasCancelled)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledAudioCannotStartACloudRequest() async {
        let requests = Requests()
        let audio = AsyncStream<AVAudioPCMBuffer> { _ in }
        let task = Task {
            try await wavTranscript(audio) { wav in
                await requests.record(wav)
                return "should never be requested"
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled audio must throw before starting a request")
        } catch is CancellationError {
        } catch { Issue.record("Unexpected cancellation error: \(error)") }
        #expect(await requests.payloads.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledRequestCannotReturnATranscript() async {
        let started = RequestGate()
        let released = RequestGate()
        let audio = AsyncStream<AVAudioPCMBuffer> { $0.finish() }
        let task = Task {
            try await wavTranscript(audio) { _ in
                await started.open()
                await released.wait()  // Deliberately noncooperative request.
                return "late result"
            }
        }
        await started.wait()
        task.cancel()
        await released.open()
        do {
            _ = try await task.value
            Issue.record("A late request result must be rejected after cancellation")
        } catch is CancellationError {
        } catch { Issue.record("Unexpected cancellation error: \(error)") }
    }

    @Test func completedAudioMakesOneRequestAndOneTrimmedFinal() async throws {
        let requests = Requests()
        let buffer = try inputBuffer(rate: 16_000, start: 0, count: 1_600)
        let audio = AsyncStream<AVAudioPCMBuffer> {
            $0.yield(buffer)
            $0.finish()
        }
        var finals: [String] = []
        for try await event in oneShotWavTranscription(
            audio,
            request: { wav in
                await requests.record(wav)
                return " \nInvoice.\t "
            })
        {
            switch event {
            case .final(let transcript): finals.append(transcript.text)
            case .partial: Issue.record("One-shot transcriber emitted a partial")
            }
        }
        #expect(finals == ["Invoice."])
        let payloads = await requests.payloads
        #expect(payloads.count == 1)
        let wav = try #require(payloads.first)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(wav.count == 44 + 1_600 * 2)
    }

    @Test func requestFailureEmitsNoFinal() async {
        struct Failure: Error {}
        let audio = AsyncStream<AVAudioPCMBuffer> { $0.finish() }
        var finals = 0
        do {
            for try await event in oneShotWavTranscription(audio, request: { _ in throw Failure() }) {
                if case .final = event { finals += 1 }
            }
            Issue.record("Request error must reach the caller")
        } catch is Failure {
        } catch { Issue.record("Unexpected request error: \(error)") }
        #expect(finals == 0)
    }

    @Test func wavEncodingIsIndependentOfAudioPartitionAndFinishIsIdempotent() throws {
        var generator = Properties.Generator(state: 702)
        for rate in [16_000.0, 48_000.0] {
            let count = Int(rate) / 5 + 37
            var whole = WavAccumulator()
            try whole.append(inputBuffer(rate: rate, start: 0, count: count))
            try whole.finish()
            let expected = whole.wavData()
            let expectedFrames = Int((Double(count) * 16_000 / rate).rounded())
            #expect(abs((expected.count - 44) / 2 - expectedFrames) <= 1, "resampler lost the utterance tail")
            for _ in 0..<20 {
                var chunked = WavAccumulator()
                var start = 0
                while start < count {
                    let size = min(generator.integer(1..<997), count - start)
                    try chunked.append(inputBuffer(rate: rate, start: start, count: size))
                    start += size
                }
                try chunked.finish()
                #expect(chunked.wavData() == expected, "partition changed PCM at \(rate) Hz")
                try chunked.finish()
                #expect(chunked.wavData() == expected)
            }
        }
    }

    private func inputBuffer(rate: Double, start: Int, count: Int) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<count { samples[index] = Float(sin(Double(start + index) * 440 * 2 * .pi / rate) * 0.3) }
        return buffer
    }
}
