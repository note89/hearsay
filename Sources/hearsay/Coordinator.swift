import AppKit
import Audio
import AVFoundation
import Bakeoff
import History
import Insertion
import Lexicon
import Observation
import os
import Overlay
import Polish
import Transcription
import Utterance

/// Text bound for the target, with its provenance. Only the Coordinator unwraps this into the
/// bare String that the Insertion mechanism takes.
enum InsertableText {
    case polished(PolishedText, spoken: RawTranscript)
    case raw(RawTranscript)
    /// Dictionary rewrites applied on top of one of the above.
    case rewritten(text: String, spoken: String)

    var text: String {
        switch self {
        case .polished(let polished, _): return polished.text
        case .raw(let raw): return raw.text
        case .rewritten(let text, _): return text
        }
    }

    var spoken: String {
        switch self {
        case .polished(_, let spoken): return spoken.text
        case .raw(let raw): return raw.text
        case .rewritten(_, let spoken): return spoken
        }
    }
}

/// Normal use inserts; the bake-off pane being front makes a session score instead.
enum AppMode {
    case dictate
    case bakeoff
}

/// The rules a session runs under, snapshotted at press. Later settings changes
/// cannot affect a session in flight.
struct SessionRules {
    let engine: Engine
    let mode: AppMode
    let style: WritingStyle
    let polish: PolishMode
    /// Field text around the cursor, captured at press. Feeds only the on-device polish model.
    let fieldContext: String?
    let lexicon: Lexicon
}

enum BakeoffTarget {
    case watchable(InsertionTarget, baseline: String)
    case unobservable(app: String)
}

enum Run {
    case dictate(ArmResult)
    case bakeoff(BakeoffTarget, expected: String?)
}

enum FinishingStep {
    case transcribing
    case polishing
    case inserting
    case watchingRival

    var label: String {
        switch self {
        case .transcribing: return "transcribing"
        case .polishing: return "polishing"
        case .inserting: return "inserting"
        case .watchingRival: return "watching rival"
        }
    }
}

struct SessionTiming {
    var transcribe: Duration = .zero
    var polish: Duration = .zero
    var insert: Duration = .zero

    var total: Duration { transcribe + polish + insert }
}

enum SessionOutcome {
    case landed(InsertionOutcome, InsertableText, SessionTiming, app: String)
    case compared(InsertableText, ours: Duration, rival: RivalObservation, app: String)
    case nothingHeard
    case blockedSecure
    case failed(reason: String, salvaged: String?)
}

enum EngineStatus: Equatable {
    case preparing
    case downloadingModel(Locale)
    case ready(Locale)
    case failed(String)
}

enum GestureStatus: Equatable {
    case stopped
    case listening
    case denied
}

@MainActor
final class LiveSession {
    let token: UUID
    let rules: SessionRules
    let run: Run
    let transcription: Task<RawTranscript, Error>
    var partial = ""
    var rivalWatch: Task<RivalObservation, Never>?

    init(token: UUID, rules: SessionRules, run: Run, transcription: Task<RawTranscript, Error>) {
        self.token = token
        self.rules = rules
        self.run = run
        self.transcription = transcription
    }

    var appName: String {
        switch run {
        case .dictate(let arm): return Coordinator.appName(of: arm)
        case .bakeoff(.watchable(let target, _), _): return target.app.name
        case .bakeoff(.unobservable(let app), _): return app
        }
    }
}

enum Phase {
    case idle
    case listening(LiveSession)
    case finishing(LiveSession, FinishingStep)
    case settled(SessionOutcome)
}

struct OperationTimeout: Error {}

/// On press, snapshot the rules and where the cursor is, then listen. On release, turn the audio
/// into text, clean it, and put it where the cursor was. If anything fails, keep the text.
/// In bake-off mode the last step is replaced: watch the field for the rival's text and log both.
@MainActor @Observable
final class Coordinator {
    private(set) var phase: Phase = .idle
    private(set) var lastTiming: SessionTiming?
    private(set) var engine: EngineStatus = .preparing
    private(set) var gesture: GestureStatus = .stopped
    private(set) var availableLocales: [Locale] = []

    /// One entry per language: the variant matching the user's region when the model list has it,
    /// else a canonical default. Regional model variants are mechanism, not a user choice.
    var languageChoices: [Locale] {
        var byLanguage: [String: [Locale]] = [:]
        for locale in availableLocales {
            byLanguage[locale.language.languageCode?.identifier ?? locale.identifier, default: []].append(locale)
        }
        let userRegion = Locale.current.region?.identifier
        let preferred = ["en": "en_US", "pt": "pt_PT", "sv": "sv_SE", "de": "de_DE", "fr": "fr_FR", "es": "es_ES", "it": "it_IT", "nl": "nl_NL", "zh": "zh_CN"]
        return byLanguage.map { language, variants in
            if let regional = variants.first(where: { $0.region?.identifier == userRegion }) { return regional }
            if let canonical = preferred[language], let match = variants.first(where: { $0.identifier == canonical }) { return match }
            return variants.sorted { $0.identifier < $1.identifier }[0]
        }
        .sorted { $0.languageDisplayName < $1.languageDisplayName }
    }
    /// Set by the Bake-off pane's appear/disappear. Being in the pane IS bake-off mode.
    var bakeoffPaneVisible = false
    let settings = Settings()
    let history: HistoryStore
    let bakeoff: BakeoffStore
    @ObservationIgnored private var dictionaryURL: URL!

    private static let settleDisplay: Duration = .milliseconds(1400)
    private static let bakeoffDisplay: Duration = .seconds(4)
    private static let transcriptionTimeout: Duration = .seconds(15)
    private static let polishTimeout: Duration = .seconds(8)
    private static let rivalTimeout: Duration = .seconds(8)
    private static let gestureRetry: Duration = .seconds(3)

    @ObservationIgnored private lazy var overlay = OverlayPanel()
    @ObservationIgnored private let capture = MicrophoneCapture()
    @ObservationIgnored private let polisher = FoundationModelsPolisher()
    @ObservationIgnored private var transcriber: any Transcriber
    @ObservationIgnored private var gestureMonitor: HoldGestureMonitor?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var loadModelTask: Task<Void, Never>?
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "hearsay", category: "session")

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hearsay")
        history = HistoryStore(directory: support)
        dictionaryURL = support.appendingPathComponent("dictionary.txt")
        bakeoff = BakeoffStore(directory: support)
        transcriber = SpeechAnalyzerTranscriber(locale: settings.locale)   // placeholder; bootstrap rebuilds from the persisted engine
    }

    func start() {
        Task { await bootstrap() }
    }

    // MARK: - Intents

    func select(locale: Locale) {
        settings.locale = locale
        rebuildTranscriber()
    }

    func select(engine chosen: Engine) {
        settings.engine = chosen
        rebuildTranscriber()
    }

    func set(polish: PolishMode) {
        settings.polish = polish
    }

    func set(historyEnabled: Bool) {
        settings.historyEnabled = historyEnabled
    }

    func clearHistory() {
        history.clear()
    }

    func deleteHistory(record: DictationRecord) {
        history.delete(id: record.id)
    }

    func copy(record: DictationRecord) {
        Inserter.copyToClipboard(record.delivered)
    }

    func set(fieldContextEnabled: Bool) {
        settings.fieldContextEnabled = fieldContextEnabled
    }

    func openDictionary() {
        NSWorkspace.shared.open(Lexicon.ensureFile(at: dictionaryURL))
    }

    func loadDictionaryEntries() -> [LexiconEntry] {
        Lexicon.entries(from: Lexicon.ensureFile(at: dictionaryURL))
    }

    func saveDictionaryEntries(_ entries: [LexiconEntry]) {
        Lexicon.save(entries, to: dictionaryURL)
    }

    // MARK: - Engine

    private func rebuildTranscriber() {
        var chosen = settings.engine
        if !chosen.isAvailable {
            log.error("rebuildTranscriber: \(chosen.wireKey, privacy: .public) needs an API key — falling back to Apple")
            chosen = .appleLocal
            settings.engine = chosen
        }
        if let built = chosen.makeTranscriber(locale: settings.locale) {
            transcriber = built
        } else {
            chosen = .appleLocal
            settings.engine = chosen
            transcriber = SpeechAnalyzerTranscriber(locale: settings.locale)
        }
        switch chosen {
        case .appleLocal: reloadAppleModel()
        case .openRouter, .elevenLabsScribe: engine = .ready(settings.locale)
        }
    }

    private func reloadAppleModel() {
        loadModelTask?.cancel()
        let locale = settings.locale
        engine = .downloadingModel(locale)
        loadModelTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await SpeechAnalyzerTranscriber.ensureModel(for: locale)
                guard !Task.isCancelled, locale == self.settings.locale, case .appleLocal = self.settings.engine else { return }
                self.engine = .ready(locale)
                self.log.notice("loadModel: ready \(locale.identifier, privacy: .public)")
            } catch {
                guard !Task.isCancelled else { return }
                self.log.error("loadModel: \(String(describing: error))")
                self.engine = .failed("model download failed")
            }
        }
    }

    // MARK: - Gesture → pipeline

    func pressed() {
        switch phase {
        case .listening, .finishing:
            log.notice("pressed: ignored, session in flight")
            return
        case .idle, .settled: break
        }
        settleTask?.cancel()
        guard case .ready = engine else {
            log.error("pressed: engine not ready")
            settle(.failed(reason: "engine not ready", salvaged: nil))
            return
        }

        let target = Arming.arm()
        if case .secureField = target {
            log.notice("pressed: secure field focused — dictation blocked")
            settle(.blockedSecure)
            return
        }
        let armedTarget: InsertionTarget? = { if case .armed(let armed) = target { return armed }; return nil }()
        let fieldContext = settings.fieldContextEnabled ? armedTarget?.contextAroundCursor(maxChars: 600) : nil
        let mode: AppMode = (bakeoffPaneVisible && NSApp.isActive) ? .bakeoff : .dictate
        let rules = SessionRules(
            engine: settings.engine,
            mode: mode,
            style: StyleInference.style(for: target),
            polish: settings.polish,
            fieldContext: fieldContext,
            lexicon: Lexicon.load(from: dictionaryURL)
        )
        let run: Run
        if rules.mode == .bakeoff {
            let position = bakeoff.records.count
            let expected = position < BakeoffScript.sentences.count ? BakeoffScript.sentences[position].text : nil
            if case .armed(let armed) = target, let baseline = armed.currentText() {
                run = .bakeoff(.watchable(armed, baseline: baseline), expected: expected)
            } else {
                run = .bakeoff(.unobservable(app: Self.appName(of: target)), expected: expected)
            }
        } else {
            run = .dictate(target)
        }

        overlay.place(Self.placement(for: rules.mode))
        let audio: AsyncStream<AVAudioPCMBuffer>
        do {
            audio = try capture.start { [weak self] level in
                Task { @MainActor in self?.meter(level) }
            }
        } catch {
            log.error("pressed: microphone failed: \(String(describing: error))")
            settle(.failed(reason: "microphone failed", salvaged: nil))
            return
        }

        let token = UUID()
        let events = transcriber.transcribe(audio)
        let transcription = Task { [weak self] () throws -> RawTranscript in
            var final: RawTranscript?
            for try await event in events {
                switch event {
                case .partial(let text): self?.partial(text, token: token)
                case .final(let transcript): final = transcript
                }
            }
            guard let final else { throw TranscriptionFailure.endedWithoutFinal }
            return final
        }
        phase = .listening(LiveSession(token: token, rules: rules, run: run, transcription: transcription))
        overlay.render(.listening(partial: ""))
    }

    func released() {
        guard case .listening(let session) = phase else {
            log.notice("released: ignored, no session listening")
            return
        }
        capture.stop()
        if case .bakeoff(.watchable(let target, let baseline), _) = session.run {
            let since = clock.now
            session.rivalWatch = Task {
                await RivalWatch.observe(target, baseline: baseline, since: since, timeout: Self.rivalTimeout)
            }
        }
        phase = .finishing(session, .transcribing)
        overlay.render(.working(FinishingStep.transcribing.label))
        log.notice("released: partial length \(session.partial.count)")
        Task { await finish(session) }
    }

    private func meter(_ level: AudioLevel) {
        guard case .listening = phase else { return }
        overlay.meter(level.value)
    }

    private func partial(_ text: String, token: UUID) {
        guard case .listening(let session) = phase, session.token == token else { return }
        session.partial = text
        overlay.render(.listening(partial: text))
    }

    private func finish(_ session: LiveSession) async {
        var timing = SessionTiming()

        let transcribeStart = clock.now
        let raw: RawTranscript
        do {
            raw = try await Self.value(of: session.transcription, within: Self.transcriptionTimeout)
        } catch {
            session.rivalWatch?.cancel()
            log.error("finish: transcription failed: \(String(describing: error))")
            let salvaged = session.partial.isEmpty ? nil : session.partial
            if let salvaged { Inserter.copyToClipboard(salvaged) }
            settle(.failed(reason: "transcription failed", salvaged: salvaged))
            return
        }
        timing.transcribe = clock.now - transcribeStart
        guard !raw.text.isEmpty else {
            session.rivalWatch?.cancel()
            settle(.nothingHeard)
            return
        }

        var delivered = InsertableText.raw(raw)
        if session.rules.polish != .off {
            phase = .finishing(session, .polishing)
            overlay.render(.working(FinishingStep.polishing.label))
            let polishStart = clock.now
            let polisher = self.polisher
            let style = session.rules.style
            let text = raw.text
            let context = PolishContext(fieldText: session.rules.fieldContext, terms: session.rules.lexicon.terms)
            let intensity: PolishIntensity = session.rules.polish == .light ? .light : .full
            let verdict: PolishVerdict = await Self.race(timeout: Self.polishTimeout) { () -> PolishVerdict in
                await polisher.polish(text, style: style, intensity: intensity, context: context)
            } ?? PolishVerdict.keepRaw(.timeout)
            switch verdict {
            case .accept(let polished): delivered = .polished(polished, spoken: raw)
            case .keepRaw(let rejection): log.notice("finish: kept raw (\(String(describing: rejection), privacy: .public))")
            }
            timing.polish = clock.now - polishStart
        }
        if let rewritten = session.rules.lexicon.rewriteResult(of: delivered.text) {
            delivered = .rewritten(text: rewritten, spoken: delivered.spoken)
        }

        switch session.run {
        case .dictate(let target):
            phase = .finishing(session, .inserting)
            overlay.render(.working(FinishingStep.inserting.label))
            let insertStart = clock.now
            let outcome: InsertionOutcome
            switch target {
            case .armed(let armed): outcome = await Inserter.insert(delivered.text, into: armed)
            case .secureField: outcome = .blocked(.secureField)   // unreachable: blocked at press; kept total
            case .noFrontmostApp: outcome = Inserter.copyToClipboard(delivered.text, because: .noFrontmostApp)
            }
            timing.insert = clock.now - insertStart
            lastTiming = timing
            log.notice("session: transcribe \(timing.transcribe.milliseconds) ms · polish \(timing.polish.milliseconds) ms · insert \(timing.insert.milliseconds) ms · \(Self.summary(of: outcome), privacy: .public)")
            settle(.landed(outcome, delivered, timing, app: session.appName))

        case .bakeoff(let bakeoffTarget, let expected):
            phase = .finishing(session, .watchingRival)
            overlay.render(.working(FinishingStep.watchingRival.label))
            let ours = timing.transcribe + timing.polish
            let rival: RivalObservation
            switch bakeoffTarget {
            case .watchable: rival = await session.rivalWatch?.value ?? .unobservable
            case .unobservable: rival = .unobservable
            }
            lastTiming = timing
            bakeoff.append(BakeoffRecord(app: session.appName, engine: session.rules.engine.wireKey, expected: expected, spoken: delivered.spoken, ours: delivered.text, oursMs: ours.milliseconds, rival: rival))
            log.notice("bakeoff: ours \(ours.milliseconds) ms · rival \(Self.summary(of: rival), privacy: .public)")
            settle(.compared(delivered, ours: ours, rival: rival, app: session.appName))
        }
    }

    private func settle(_ outcome: SessionOutcome) {
        phase = .settled(outcome)
        overlay.render(Self.overlayState(for: outcome))
        if settings.historyEnabled, let record = Self.record(outcome) { history.record(record) }
        let display: Duration
        if case .compared = outcome { display = Self.bakeoffDisplay } else { display = Self.settleDisplay }
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: display)
            guard !Task.isCancelled, let self, case .settled = self.phase else { return }
            self.phase = .idle
            self.overlay.render(.hidden)
        }
    }

    // MARK: - Projections (content-free where logged)

    private static func overlayState(for outcome: SessionOutcome) -> OverlayState {
        switch outcome {
        case .landed(.inserted(_, .verified), _, let timing, _): return .settled("inserted · \(timing.total.milliseconds) ms", .ok)
        case .landed(.inserted(_, .posted), _, let timing, _): return .settled("sent · \(timing.total.milliseconds) ms", .ok)
        case .landed(.copiedToClipboard(let block), _, _, _): return .settled(copiedMessage(block), .warn)
        case .landed(.blocked, _, _, _): return .settled("blocked — secure field", .warn)
        case .compared(_, let ours, .landed(_, let latency), _): return .settled("ours \(ours.milliseconds) ms · rival \(latency.milliseconds) ms", .ok)
        case .compared(_, let ours, .unobservable, _): return .settled("ours \(ours.milliseconds) ms · rival unobservable — use TextEdit or Notes", .warn)
        case .compared(_, let ours, .timedOut, _): return .settled("ours \(ours.milliseconds) ms · rival: nothing landed", .warn)
        case .nothingHeard: return .settled("nothing heard", .warn)
        case .blockedSecure: return .settled("secure field — dictation blocked", .warn)
        case .failed(let reason, let salvaged): return .settled(salvaged != nil ? "\(reason) — draft copied" : reason, .warn)
        }
    }

    private static func copiedMessage(_ block: InsertionBlock) -> String {
        switch block {
        case .secureField: return "copied — secure field"
        case .accessibilityDenied: return "copied — grant Accessibility"
        case .allStrategiesFailed: return "copied — could not insert"
        case .noFrontmostApp: return "copied"
        case .targetLost: return "copied — focus moved"
        }
    }

    private static func record(_ outcome: SessionOutcome) -> DictationRecord? {
        switch outcome {
        case .landed(let insertion, let text, _, let app):
            let recorded: RecordedOutcome
            switch insertion {
            case .inserted: recorded = .inserted
            case .copiedToClipboard(.targetLost): recorded = .targetLost
            case .copiedToClipboard: recorded = .copiedToClipboard
            case .blocked: return nil
            }
            return DictationRecord(spoken: text.spoken, delivered: text.text, appName: app, outcome: recorded)
        case .failed(_, let salvaged):
            guard let salvaged else { return nil }
            return DictationRecord(spoken: salvaged, delivered: salvaged, appName: "—", outcome: .copiedToClipboard)
        case .compared, .nothingHeard, .blockedSecure:
            return nil
        }
    }

    static func appName(of target: ArmResult) -> String {
        switch target {
        case .armed(let armed): return armed.app.name
        case .secureField(let app): return app.name
        case .noFrontmostApp: return "—"
        }
    }

    private static func summary(of outcome: InsertionOutcome) -> String {
        switch outcome {
        case .inserted(let via, .verified): return "inserted(\(via.rawValue), verified)"
        case .inserted(let via, .posted): return "inserted(\(via.rawValue), posted)"
        case .copiedToClipboard(let block): return "copied(\(block))"
        case .blocked(let block): return "blocked(\(block))"
        }
    }

    private static func summary(of observation: RivalObservation) -> String {
        switch observation {
        case .landed(_, let latency): return "landed \(latency.milliseconds) ms"
        case .unobservable: return "unobservable"
        case .timedOut(let after): return "nothing after \(after.milliseconds) ms"
        }
    }

    private static func placement(for mode: AppMode) -> OverlayPlacement {
        switch mode {
        case .dictate: return .bottom
        case .bakeoff: return .raised
        }
    }

    // MARK: - Bootstrap & bridge

    private func bootstrap() async {
        polisher.prewarm()
        startGesture()
        rebuildTranscriber()
        Task {
            availableLocales = await SpeechAnalyzerTranscriber.supportedLocales()
                .sorted { $0.displayName < $1.displayName }
        }
        let granted = await Permissions.request()
        log.notice("bootstrap: microphone=\(granted.microphone) accessibility=\(granted.accessibility) inputMonitoring=\(granted.inputMonitoring)")
        capture.prepare()
    }

    private func startGesture() {
        let monitor = HoldGestureMonitor(chord: .fnShift) { [weak self] event in
            MainActor.assumeIsolated {
                switch event {
                case .pressed: self?.pressed()
                case .released: self?.released()
                }
            }
        }
        do {
            try monitor.start()
            gestureMonitor = monitor
            gesture = .listening
            log.notice("startGesture: listening for fn+shift")
        } catch {
            if gesture != .denied {
                log.error("startGesture: \(String(describing: error), privacy: .public) — retrying every \(Self.gestureRetry.milliseconds) ms until granted")
            }
            gesture = .denied
            Task { [weak self] in
                try? await Task.sleep(for: Self.gestureRetry)
                self?.startGesture()
            }
        }
    }

    // MARK: - Async helpers

    /// Awaits the task's value, cancelling the task itself when the limit passes — the timeout is real.
    private static func value<T: Sendable>(of task: Task<T, Error>, within limit: Duration) async throws -> T {
        do {
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
                    throw OperationTimeout()
                }
                guard let first = try await group.next() else { throw OperationTimeout() }
                group.cancelAll()
                return first
            }
        } catch {
            task.cancel()
            throw error
        }
    }

    /// Runs non-throwing work against a deadline; nil on timeout.
    private static func race<T: Sendable>(timeout: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

extension Duration {
    var milliseconds: Int {
        Int(components.seconds * 1000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}

extension Locale {
    var displayName: String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    var languageDisplayName: String {
        guard let code = language.languageCode?.identifier else { return displayName }
        return Locale.current.localizedString(forLanguageCode: code) ?? displayName
    }
}
