// Engine smoke test on a WAV file, the way the app would stream it.
// Run: swift run hearsay-check <file.wav> [smart]
import AVFoundation
import Foundation
import Polish
import Transcription

let arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.first else {
    FileHandle.standardError.write(
        Data(
            "usage: hearsay-check <file.wav> [smart] | polish <file.txt> [light|full] [style] [cloud] | local <cohere|qwen|redux|whisper> <model-directory> <audio-file> [locale] | download <model> <models-root>\n"
                .utf8))
    exit(2)
}

if path == "download" {
    let rest = Array(arguments.dropFirst())
    guard rest.count == 2, let model = LocalSpeechModel(rawValue: rest[0]) else {
        FileHandle.standardError.write(Data("usage: hearsay-check download <cohere|qwen|redux|whisper> <models-root>\n".utf8))
        exit(2)
    }
    let store = LocalModelStore(directory: URL(fileURLWithPath: rest[1], isDirectory: true))
    let completed = DispatchSemaphore(value: 0)
    Task {
        defer { completed.signal() }
        do {
            FileHandle.standardError.write(Data("Downloading \(model.label) (\(model.downloadBytes) bytes)\n".utf8))
            let directory = try await store.download(model) { _ in }
            print(directory.path)
        } catch {
            FileHandle.standardError.write(Data("download failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    completed.wait()
    exit(0)
}

if path == "local" {
    let rest = Array(arguments.dropFirst())
    guard rest.count >= 3, rest.count <= 4, let model = LocalSpeechModel(rawValue: rest[0]) else {
        FileHandle.standardError.write(
            Data("usage: hearsay-check local <cohere|qwen|redux|whisper> <model-directory> <audio-file> [locale]\n".utf8))
        exit(2)
    }
    let transcriber = LocalModelTranscriber(
        model: model,
        directory: URL(fileURLWithPath: rest[1], isDirectory: true),
        locale: Locale(identifier: rest.count == 4 ? rest[3] : "en-US")
    )
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: rest[2]))
    let chunk: AVAudioFrameCount = 2048
    let audio = AsyncStream<AVAudioPCMBuffer> { continuation in
        while let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
            (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0
        {
            continuation.yield(buffer)
        }
        continuation.finish()
    }
    let started = Date()
    let completed = DispatchSemaphore(value: 0)
    Task {
        defer { completed.signal() }
        do {
            try await transcriber.prepare()
            for try await event in transcriber.transcribe(audio, hints: .none) {
                if case .final(let transcript) = event { print(transcript.text) }
            }
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            FileHandle.standardError.write(Data("[\(model.label) · local · \(milliseconds) ms]\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("local transcription failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    completed.wait()
    exit(0)
}

// Cleanup on a transcript file with Apple's on-device model, no timeout: the output and how long it took.
if path == "polish" {
    let rest = Array(arguments.dropFirst())
    guard let file = rest.first, let spoken = try? String(contentsOfFile: file, encoding: .utf8) else {
        FileHandle.standardError.write(Data("usage: hearsay-check polish <file.txt> [light|full] [style]\n".utf8))
        exit(2)
    }
    let intensity: PolishIntensity = rest.dropFirst().first == "light" ? .light : .full
    let style = rest.dropFirst(2).first.flatMap(WritingStyle.init(rawValue:)) ?? .plain
    let polisher: any Polisher
    let engineLabel: String
    if rest.contains("cloud") {
        guard let key = KeyStore.value("OPENROUTER_API_KEY") else {
            FileHandle.standardError.write(Data("OPENROUTER_API_KEY missing\n".utf8))
            exit(1)
        }
        polisher = OpenRouterPolisher(key: key)
        engineLabel = OpenRouterPolisher.defaultModel
    } else {
        let onDevice = FoundationModelsPolisher()
        guard onDevice.isAvailable else {
            FileHandle.standardError.write(Data("on-device model unavailable\n".utf8))
            exit(1)
        }
        polisher = onDevice
        engineLabel = "on-device"
    }
    let started = Date()
    let done = DispatchSemaphore(value: 0)
    Task {
        let verdict = await polisher.polish(
            spoken.trimmingCharacters(in: .whitespacesAndNewlines), style: style, intensity: intensity, context: .none)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch verdict {
        case .accept(let polished):
            print(polished.text)
            FileHandle.standardError.write(Data("[\(engineLabel) · \(intensity) · \(style.rawValue) · accepted · \(ms) ms]\n".utf8))
        case .keepRaw(let rejection): FileHandle.standardError.write(Data("[\(engineLabel) · rejected: \(rejection) · \(ms) ms]\n".utf8))
        }
        done.signal()
    }
    done.wait()
    exit(0)
}
let mode: TranscriptMode = arguments.contains("smart") ? .smart : .verbatim
guard let transcriber = GeminiLiveTranscriber() else {
    FileHandle.standardError.write(Data("GEMINI_API_KEY missing\n".utf8))
    exit(1)
}
let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
let chunk: AVAudioFrameCount = 2048  // the microphone tap's buffer size
let audio = AsyncStream<AVAudioPCMBuffer> { continuation in
    while let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
        (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0
    {
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
            case .partial(let text):
                FileHandle.standardError.write(
                    Data("partial (\(text.count) chars) at \(Int(Date().timeIntervalSince(started) * 1000)) ms\n".utf8))
            case .final(let transcript):
                print(transcript.text)
                FileHandle.standardError.write(
                    Data("[gemini-3.5-transcribe-live · \(mode) · final at \(Int(Date().timeIntervalSince(started) * 1000)) ms]\n".utf8))
            }
        }
    } catch {
        FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
        exit(1)
    }
}
semaphore.wait()
