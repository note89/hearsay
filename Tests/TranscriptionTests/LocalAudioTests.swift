import AVFoundation
import Foundation
import Testing

@testable import Transcription

struct LocalAudioTests {
    @Test func longUtteranceChunksCoverEverySampleIncludingTail() {
        let count = 16_000 * 97 + 83
        var samples = Array(repeating: Float(0.2), count: count)
        samples[count - 1] = 0.9
        let plan = LocalAudioChunkPlan(samples: samples, secondsPerChunk: 30)
        #expect(plan.ranges.count == 4)
        #expect(plan.ranges.first?.lowerBound == 0)
        #expect(plan.ranges.last?.upperBound == count)
        #expect(plan.ranges.allSatisfy { !$0.isEmpty && $0.count <= 16_000 * 30 })
        for pair in zip(plan.ranges, plan.ranges.dropFirst()) {
            #expect(pair.0.upperBound == pair.1.lowerBound)
        }
        #expect(plan.ranges.reduce(0) { $0 + $1.count } == count)
        #expect(samples[plan.ranges.last!.last!] == 0.9)
    }

    @Test func stereoAudioIsResampledToMono16kHz() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        input.frameLength = 4_800
        let channels = try #require(input.floatChannelData)
        for frame in 0..<4_800 {
            channels[0][frame] = 0.2
            channels[1][frame] = 0.4
        }
        var audio = LocalAudioAccumulator()
        try audio.append(input)
        try audio.finish()
        #expect(audio.hasAudibleSamples)
        #expect(abs(audio.samples.count - 1_600) <= 32)
        #expect(abs(audio.samples[audio.samples.count / 2] - 0.3) < 0.01)
    }

    @Test func silenceReturnsOneEmptyFinalWithoutLoadingAModel() async throws {
        let input = try #require(AVAudioPCMBuffer(pcmFormat: LocalAudioAccumulator.format, frameCapacity: 1_600))
        input.frameLength = 1_600
        let channel = try #require(input.floatChannelData?[0])
        channel.initialize(repeating: 0, count: 1_600)
        let audio = AsyncStream<AVAudioPCMBuffer> { continuation in
            continuation.yield(input)
            continuation.finish()
        }
        let transcriber = LocalModelTranscriber(
            model: .whisper, directory: URL(fileURLWithPath: "/nonexistent-model"), locale: Locale(identifier: "en-US"))
        var finals: [String] = []
        for try await event in transcriber.transcribe(audio, hints: .none) {
            if case .final(let transcript) = event { finals.append(transcript.text) }
            if case .partial = event { Issue.record("Batch transcriber emitted a partial") }
        }
        #expect(finals == [""])
    }

    @Test func cancellingUnfinishedAudioProducesNoFinal() async {
        let audio = AsyncStream<AVAudioPCMBuffer> { _ in }
        let transcriber = LocalModelTranscriber(
            model: .whisper, directory: URL(fileURLWithPath: "/nonexistent-model"), locale: Locale(identifier: "en-US"))
        let task = Task {
            var finals = 0
            do {
                for try await event in transcriber.transcribe(audio, hints: .none) {
                    if case .final = event { finals += 1 }
                }
            } catch is CancellationError {
            } catch {
                Issue.record("Unexpected cancellation error: \(error)")
            }
            return finals
        }
        task.cancel()
        #expect(await task.value == 0)
    }
}
