// Engine smoke test on a WAV file, the way the app would stream it.
// Run: swift run hearsay-check <file.wav> [smart]
import AVFoundation
import Foundation
import Transcription

let arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.first else {
    FileHandle.standardError.write(Data("usage: hearsay-check <file.wav> [smart]\n".utf8))
    exit(2)
}
let mode: TranscriptMode = arguments.contains("smart") ? .smart : .verbatim
guard let transcriber = GeminiLiveTranscriber() else {
    FileHandle.standardError.write(Data("GEMINI_API_KEY missing\n".utf8))
    exit(1)
}
let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
let chunk: AVAudioFrameCount = 2048 // the microphone tap's buffer size
let audio = AsyncStream<AVAudioPCMBuffer> { continuation in
    while let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk), (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 {
        continuation.yield(buffer)
    }
    continuation.finish()
}
let started = Date()
let semaphore = DispatchSemaphore(value: 0)
Task {
    defer { semaphore.signal() }
    do {
        for try await event in transcriber.transcribe(audio, hints: TranscriptionHints(vocabulary: [], mode: mode)) {
            switch event {
            case .partial(let text): FileHandle.standardError.write(Data("partial (\(text.count) chars) at \(Int(Date().timeIntervalSince(started) * 1000)) ms\n".utf8))
            case .final(let transcript):
                print(transcript.text)
                FileHandle.standardError.write(Data("[gemini-3.5-transcribe-live · \(mode) · final at \(Int(Date().timeIntervalSince(started) * 1000)) ms]\n".utf8))
            }
        }
    } catch {
        FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
        exit(1)
    }
}
semaphore.wait()
