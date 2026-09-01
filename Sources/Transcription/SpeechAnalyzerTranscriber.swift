import AVFoundation
import Speech

public enum SpeechAnalyzerFailure: Error {
    case localeUnsupported(Locale)
    case noCompatibleAudioFormat
}

/// Apple's on-device recognizers (macOS 26). Prefers the modern SpeechTranscriber model;
/// falls back to DictationTranscriber for locales the modern model lacks (e.g. Swedish).
public final class SpeechAnalyzerTranscriber: Transcriber {
    public let locale: Locale

    public init(locale: Locale) {
        self.locale = locale
    }

    public static func supportedLocales() async -> [Locale] {
        let modern = await SpeechTranscriber.supportedLocales
        let dictation = await DictationTranscriber.supportedLocales
        var seen = Set<String>()
        return (modern + dictation).filter { seen.insert($0.identifier(.bcp47)).inserted }
    }

    private static func modernSupports(_ locale: Locale) async -> Bool {
        await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    private static func dictationSupports(_ locale: Locale) async -> Bool {
        await DictationTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    private static func makeModern(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    private static func makeDictation(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    /// Downloads the on-device model for `locale` when missing. Idempotent.
    public static func ensureModel(for locale: Locale) async throws {
        if await modernSupports(locale) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeModern(locale)]) {
                try await request.downloadAndInstall()
            }
            return
        }
        guard await dictationSupports(locale) else { throw SpeechAnalyzerFailure.localeUnsupported(locale) }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeDictation(locale)]) {
            try await request.downloadAndInstall()
        }
    }

    public func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let locale = self.locale
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    if await Self.modernSupports(locale) {
                        let module = Self.makeModern(locale)
                        try await Self.pump(module: module, results: module.results, audio: audio, emit: continuation) {
                            (String($0.text.characters), $0.isFinal)
                        }
                    } else {
                        let module = Self.makeDictation(locale)
                        try await Self.pump(module: module, results: module.results, audio: audio, emit: continuation) {
                            (String($0.text.characters), $0.isFinal)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func pump<Module: SpeechModule, Results: AsyncSequence>(
        module: Module,
        results: Results,
        audio: AsyncStream<AVAudioPCMBuffer>,
        emit: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation,
        read: @escaping @Sendable (Results.Element) -> (text: String, isFinal: Bool)
    ) async throws {
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw SpeechAnalyzerFailure.noCompatibleAudioFormat
        }
        let (input, feeder) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: input)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var converter = AudioBufferConverter(to: format)
                for await buffer in audio {
                    if let converted = try converter.convert(buffer) {
                        feeder.yield(AnalyzerInput(buffer: converted))
                    }
                }
                feeder.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            group.addTask {
                var finalized = ""
                for try await result in results {
                    let (text, isFinal) = read(result)
                    if isFinal {
                        finalized += text
                        emit.yield(.partial(finalized))
                    } else {
                        emit.yield(.partial(finalized + text))
                    }
                }
                emit.yield(.final(RawTranscript(text: finalized.trimmingCharacters(in: .whitespacesAndNewlines))))
            }
            try await group.waitForAll()
        }
    }
}
