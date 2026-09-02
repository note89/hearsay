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
indirect enum InsertableText {
    case polished(PolishedText, spoken: RawTranscript)
    case raw(RawTranscript)
    /// Dictionary rewrites applied over a polished or raw base — the base is kept, not flattened.
    case rewritten(text: String, over: InsertableText)

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
        case .rewritten(_, let base): return base.spoken
        }
    }
}

/// The rules a session runs under, snapshotted at press. Later settings changes
/// cannot affect a session in flight.
struct SessionRules {
    let engine: Engine
    let style: WritingStyle
    let polish: PolishMode
    /// Field text around the cursor, captured at press. Feeds only the on-device polish model.
    let fieldContext: String?
    let lexicon: Lexicon
}

/// Where a dictation goes, parsed from the arm result at press — secure fields are refused before this exists.
enum DictationDestination {
    case field(InsertionTarget)
    case clipboardOnly
}

enum BakeoffTarget {
    case watchable(InsertionTarget, baseline: String)
    case unobservable(app: String)
}

/// What a session does with its text: the single representation of "dictate vs bake-off".
/// ("Run" is reserved for the bake-off's multi-take run.)
enum SessionPlan {
    case dictate(DictationDestination)
    case bakeoff(BakeoffTarget, expected: String?, runID: UUID, takeID: UUID)
}

enum FinishingStep {
    case transcribing
    case polishing
    case inserting
    case watchingRival
    case racing(Int)

    var label: String {
        switch self {
        case .transcribing: return "transcribing"
        case .racing(let count): return "racing \(count)"
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

/// How a race ended: the first engine with text, and what the rival did.
struct RaceOutcome {
    let fastest: (engine: Engine, ms: Duration)?
    let rival: RivalObservation
    let app: String
}

enum SessionOutcome {
    case landed(InsertionOutcome, InsertableText, SessionTiming, app: String)
    case compared(RaceOutcome)
    case nothingHeard
    case blockedSecure
    case failed(reason: String, salvaged: String?, app: String)
}

enum EngineStatus: Equatable {
    case preparing
    case downloadingModel(Locale)
    case ready
    case failed(String)
}

enum GestureStatus: Equatable {
    case stopped
    case listening
    case denied
}

/// One engine hearing the utterance. A dictation has one; a race has one per engine.
struct Contender {
    let engine: Engine
    let transcription: Task<RawTranscript, Error>
}

@MainActor
final class LiveSession {
    let token: UUID
    let rules: SessionRules
    let plan: SessionPlan
    /// Never empty. A dictation's only contender is the active engine.
    let contenders: [Contender]
    var partial = ""
    var rivalWatch: Task<RivalObservation, Never>?
    /// Key-up: every contender's clock starts here.
    var releasedAt: ContinuousClock.Instant?

    init(token: UUID, rules: SessionRules, plan: SessionPlan, contenders: [Contender]) {
        self.token = token
        self.rules = rules
        self.plan = plan
        self.contenders = contenders
    }

    var appName: String {
        switch plan {
        case .dictate(.field(let target)): return target.app.name
        case .dictate(.clipboardOnly): return "—"
        case .bakeoff(.watchable(let target, _), _, _, _): return target.app.name
        case .bakeoff(.unobservable(let app), _, _, _): return app
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
    /// The engine sessions actually run on: the chosen one when its key is present, else Apple.
    /// The user's choice in Settings is never overwritten by availability.
    private(set) var activeEngine: Engine = .appleLocal

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

    private static let settleDisplay: Duration = .milliseconds(700)
    private static let warningDisplay: Duration = .milliseconds(2200)
    private static let bakeoffDisplay: Duration = .seconds(4)
    private static let transcriptionTimeout: Duration = .seconds(15)
    private static let polishTimeout: Duration = .seconds(8)
    private static let rivalTimeout: Duration = .seconds(8)
    private static let gestureRetry: Duration = .seconds(3)
    /// Field text handed to the on-device polish model as terminology reference; bounded for its context window.
    private static let fieldContextMaxChars = 600

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
        KeyStore.configure(directory: support)
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
        activateEngine()
    }

    func select(engine chosen: Engine) {
        settings.engine = chosen
        activateEngine()
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

    /// Resolves the chosen engine to the one sessions run on (Apple when a key is missing) and (re)builds its transcriber.
    private func activateEngine() {
        let chosen = settings.engine
        var resolved = chosen
        if !chosen.isAvailable {
            log.notice("activateEngine: \(chosen.wireKey, privacy: .public) needs an API key — running on Apple until it is added")
            resolved = .appleLocal
        }
        if let built = resolved.makeTranscriber(locale: settings.locale) {
            transcriber = built
        } else {
            resolved = .appleLocal
            transcriber = SpeechAnalyzerTranscriber(locale: settings.locale)
        }
        activeEngine = resolved
        switch resolved {
        case .appleLocal:
            reloadAppleModel()
        case .openRouter, .elevenLabsScribe, .geminiTranscribeLive:
            loadModelTask?.cancel()
            engine = .ready
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
                guard !Task.isCancelled, locale == self.settings.locale, self.activeEngine == .appleLocal else { return }
                self.engine = .ready
                self.log.notice("loadModel: ready \(locale.identifier, privacy: .public)")
            } catch {
                guard !Task.isCancelled, locale == self.settings.locale, self.activeEngine == .appleLocal else { return }
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
            settle(.failed(reason: "engine not ready", salvaged: nil, app: "—"))
            return
        }

        let target = Arming.arm()
        if case .secureField = target {
            log.notice("pressed: secure field focused — dictation blocked")
            settle(.blockedSecure)
            return
        }
        let armedTarget: InsertionTarget? = { if case .armed(let armed) = target { return armed }; return nil }()
        let polish = settings.polish
        let fieldContext = (settings.fieldContextEnabled && polish != .off) ? armedTarget?.contextAroundCursor(maxChars: Self.fieldContextMaxChars) : nil
        let rules = SessionRules(
            engine: activeEngine,
            style: StyleInference.style(for: target),
            polish: polish,
            fieldContext: fieldContext,
            lexicon: Lexicon.load(from: dictionaryURL)
        )
        // Bake-off iff the text would land in our own pane: same arm() snapshot the session uses,
        // so activation state and view lifecycle cannot disagree with it.
        let plan: SessionPlan
        if let armed = armedTarget, armed.app.pid == ProcessInfo.processInfo.processIdentifier,
           case .textElement = armed.focused, bakeoffPaneVisible {
            let position = bakeoff.takes.count
            let expected = position < BakeoffScript.sentences.count ? BakeoffScript.sentences[position].text : nil
            if let baseline = armed.currentText() {
                plan = .bakeoff(.watchable(armed, baseline: baseline), expected: expected, runID: bakeoff.runID, takeID: UUID())
            } else {
                plan = .bakeoff(.unobservable(app: armed.app.name), expected: expected, runID: bakeoff.runID, takeID: UUID())
            }
        } else if let armed = armedTarget {
            plan = .dictate(.field(armed))
        } else {
            plan = .dictate(.clipboardOnly)
        }
        let lineup: [(engine: Engine, transcriber: any Transcriber)]
        if case .bakeoff = plan {
            lineup = racingLineup()
        } else {
            lineup = [(activeEngine, transcriber)]
        }
        overlay.place(Self.placement(for: plan))
        overlay.setBadge(lineup.count > 1 ? "racing \(lineup.count)" : Self.badge(for: rules.engine))
        let audio: AsyncStream<AVAudioPCMBuffer>
        do {
            audio = try capture.start { [weak self] level in
                Task { @MainActor in self?.meter(level) }
            }
        } catch {
            log.error("pressed: microphone failed: \(String(describing: error))")
            settle(.failed(reason: "microphone failed", salvaged: nil, app: "—"))
            return
        }

        let token = UUID()
        // dictionary → transcription and style → transcription, in one object every engine receives.
        let hints = TranscriptionHints(vocabulary: rules.lexicon.terms, mode: rules.polish == .off ? .verbatim : .smart)
        // The pill follows one streaming engine; the others race silently.
        let pillEngine = lineup.first { $0.engine.deliversPartials }?.engine
        let contenders = zip(lineup, Self.fanOut(audio, count: lineup.count)).map { entry, stream in
            let (engine, engineTranscriber) = entry
            let reportsPartials = engine == pillEngine
            return Contender(engine: engine, transcription: Task { [weak self] () throws -> RawTranscript in
                var final: RawTranscript?
                for try await event in engineTranscriber.transcribe(stream, hints: hints) {
                    switch event {
                    case .partial(let text): if reportsPartials { self?.partial(text, token: token) }
                    case .final(let transcript): final = transcript
                    }
                }
                guard let final else { throw TranscriptionFailure.endedWithoutFinal }
                return final
            })
        }
        phase = .listening(LiveSession(token: token, rules: rules, plan: plan, contenders: contenders))
        overlay.render(.listening(partial: ""))
    }

    func released() {
        guard case .listening(let session) = phase else {
            log.notice("released: ignored, no session listening")
            return
        }
        capture.stop()
        session.releasedAt = clock.now
        if case .bakeoff(.watchable(let target, let baseline), _, _, _) = session.plan {
            let since = clock.now
            session.rivalWatch = Task {
                await RivalWatch.observe(read: { target.currentText() }, baseline: baseline, since: since, timeout: Self.rivalTimeout)
            }
        }
        let step: FinishingStep = session.contenders.count > 1 ? .racing(session.contenders.count) : .transcribing
        phase = .finishing(session, step)
        overlay.render(.working(step.label))
        log.notice("released: partial length \(session.partial.count)")
        Task { await finish(session) }
    }

    /// The engines a take races: the user's selection minus any without a key. Never empty.
    private func racingLineup() -> [(engine: Engine, transcriber: any Transcriber)] {
        let chosen = Engine.all.filter { $0.isAvailable && settings.isRacing($0) }
        let lineup: [(engine: Engine, transcriber: any Transcriber)] = chosen.compactMap { engine in
            if engine == activeEngine { return (engine, transcriber) }
            return engine.makeTranscriber(locale: settings.locale).map { (engine, $0) }
        }
        return lineup.isEmpty ? [(activeEngine, transcriber)] : lineup
    }

    /// One microphone, several listeners: every buffer reaches every stream, and no listener can
    /// slow another. Buffers are shared, not copied, and a stream holds at most one take's worth,
    /// so the buffering is unbounded on purpose — dropping audio for a slower engine would be a
    /// wrong measurement. One listener gets the source itself.
    private static func fanOut(_ source: AsyncStream<AVAudioPCMBuffer>, count: Int) -> [AsyncStream<AVAudioPCMBuffer>] {
        guard count > 1 else { return [source] }
        let copies = (0..<count).map { _ in AsyncStream<AVAudioPCMBuffer>.makeStream() }
        Task.detached {
            for await buffer in source {
                for copy in copies { copy.continuation.yield(buffer) }
            }
            for copy in copies { copy.continuation.finish() }
        }
        return copies.map(\.stream)
    }

    private func meter(_ level: AudioLevel) {
        guard case .listening = phase else { return }
        overlay.meter(level.value)
    }

    private func partial(_ text: String, token: UUID) {
        switch phase {
        case .listening(let session) where session.token == token:
            session.partial = text
            overlay.render(.listening(partial: text))
        case .finishing(let session, _) where session.token == token:
            session.partial = text   // salvage must see text finalized after release
        default:
            break
        }
    }

    private func finish(_ session: LiveSession) async {
        switch session.plan {
        case .dictate(let destination): await finishDictation(session, into: destination)
        case .bakeoff(let target, let expected, let runID, let takeID): await finishRace(session, target: target, expected: expected, runID: runID, takeID: takeID)
        }
    }

    private func finishDictation(_ session: LiveSession, into destination: DictationDestination) async {
        var timing = SessionTiming()

        let transcribeStart = clock.now
        let raw: RawTranscript
        do {
            raw = try await Self.value(of: session.contenders[0].transcription, within: Self.transcriptionTimeout)
        } catch {
            session.rivalWatch?.cancel()
            log.error("finish: transcription failed: \(String(describing: error))")
            var salvaged: String?
            if case .dictate = session.plan, !session.partial.isEmpty {
                salvaged = session.partial
                Inserter.copyToClipboard(session.partial)
            }
            settle(.failed(reason: "transcription failed", salvaged: salvaged, app: session.appName))
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
            case .keepRaw(let rejection): log.notice("finish: kept raw (\(rejection.label, privacy: .public))")
            }
            timing.polish = clock.now - polishStart
        }
        if let rewritten = session.rules.lexicon.rewriteResult(of: delivered.text) {
            delivered = .rewritten(text: rewritten, over: delivered)
        }

        phase = .finishing(session, .inserting)
        overlay.render(.working(FinishingStep.inserting.label))
        let insertStart = clock.now
        let outcome: InsertionOutcome
        switch destination {
        case .field(let target): outcome = await Inserter.insert(delivered.text, into: target)
        case .clipboardOnly: outcome = Inserter.copyToClipboard(delivered.text, because: .noFrontmostApp)
        }
        timing.insert = clock.now - insertStart
        lastTiming = timing
        log.notice("session: transcribe \(timing.transcribe.milliseconds) ms · polish \(timing.polish.milliseconds) ms · insert \(timing.insert.milliseconds) ms · \(Self.summary(of: outcome), privacy: .public)")
        settle(.landed(outcome, delivered, timing, app: session.appName))
    }

    /// Every contender is scored on its raw text, each on its own clock from key-up; the rival on
    /// the same clock. One take, every row.
    private func finishRace(_ session: LiveSession, target: BakeoffTarget, expected: String?, runID: UUID, takeID: UUID) async {
        let releasedAt = session.releasedAt ?? clock.now
        let clock = self.clock
        var results: [(index: Int, result: EngineResult)] = []
        await withTaskGroup(of: (Int, EngineResult).self) { group in
            for (index, contender) in session.contenders.enumerated() {
                let key = contender.engine.wireKey
                group.addTask {
                    do {
                        let raw = try await Self.value(of: contender.transcription, within: Self.transcriptionTimeout)
                        let ms = (clock.now - releasedAt).milliseconds
                        let outcome: EngineOutcome = raw.text.isEmpty ? .failed(reason: "nothing heard") : .scored(spoken: raw.text, ours: raw.text, ms: ms)
                        return (index, EngineResult(engine: key, outcome: outcome))
                    } catch {
                        return (index, EngineResult(engine: key, outcome: .failed(reason: error is OperationTimeout ? "timed out" : "failed")))
                    }
                }
            }
            for await entry in group { results.append((entry.0, entry.1)) }
        }
        results.sort { $0.index < $1.index }

        phase = .finishing(session, .watchingRival)
        overlay.render(.working(FinishingStep.watchingRival.label))
        let rival: RivalObservation
        switch target {
        case .watchable: rival = await session.rivalWatch?.value ?? .unobservable
        case .unobservable: rival = .unobservable
        }
        let take = Take(id: takeID.uuidString, app: session.appName, expected: expected, rival: RivalOutcome(rival), results: results.map(\.result))
        if runID == bakeoff.runID {
            bakeoff.append(take)
        } else {
            log.notice("finish: bake-off run was reset during the take — take dropped")
        }
        let fastest = take.results.compactMap { result -> (engine: Engine, ms: Duration)? in
            guard case .scored(_, _, let ms) = result.outcome, let engine = Engine(wireKey: result.engine) else { return nil }
            return (engine, .milliseconds(ms))
        }.min { $0.ms < $1.ms }
        log.notice("bakeoff: raced \(take.results.count) · fastest \(fastest?.ms.milliseconds ?? -1) ms · rival \(Self.summary(of: rival), privacy: .public)")
        settle(.compared(RaceOutcome(fastest: fastest, rival: rival, app: session.appName)))
    }

    private func settle(_ outcome: SessionOutcome) {
        phase = .settled(outcome)
        let state = Self.overlayState(for: outcome)
        overlay.render(state)
        if settings.historyEnabled, let entry = Self.historyEntry(for: outcome) { history.record(entry) }
        let display = Self.display(for: outcome, shownAs: state)
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: display)
            guard !Task.isCancelled, let self, case .settled = self.phase else { return }
            self.phase = .idle
            self.overlay.render(.hidden)
        }
    }

    // MARK: - Projections (content-free where logged)

    /// How long the settled pill stays: good news is a glance, a warning must be readable, a bake-off verdict has two numbers.
    private static func display(for outcome: SessionOutcome, shownAs state: OverlayState) -> Duration {
        if case .compared = outcome { return bakeoffDisplay }
        if case .settled(_, .warn) = state { return warningDisplay }
        return settleDisplay
    }

    private static func overlayState(for outcome: SessionOutcome) -> OverlayState {
        switch outcome {
        case .landed(.inserted(_, .verified), _, let timing, _): return .settled("inserted · \(timing.total.milliseconds) ms", .ok)
        case .landed(.inserted(_, .posted), _, let timing, _): return .settled("sent · \(timing.total.milliseconds) ms", .ok)
        case .landed(.copiedToClipboard(let block), _, _, _): return .settled(copiedMessage(block), .warn)
        case .compared(let race):
            let ours = race.fastest.map { "\($0.engine.shortLabel) \($0.ms.milliseconds) ms" } ?? "no engine answered"
            switch race.rival {
            case .landed(_, let latency): return .settled("\(ours) · rival \(latency.milliseconds) ms", race.fastest == nil ? .warn : .ok)
            case .unobservable: return .settled("\(ours) · rival unobservable — use TextEdit or Notes", .warn)
            case .timedOut: return .settled("\(ours) · rival: nothing landed", .warn)
            case .abandoned: return .settled("\(ours) · rival watch abandoned", .warn)
            }
        case .nothingHeard: return .settled("nothing heard", .warn)
        case .blockedSecure: return .settled("secure field — dictation blocked", .warn)
        case .failed(let reason, let salvaged, _): return .settled(salvaged != nil ? "\(reason) — draft copied" : reason, .warn)
        }
    }

    private static func copiedMessage(_ block: InsertionBlock) -> String {
        switch block {
        case .accessibilityDenied: return "copied — grant Accessibility"
        case .allStrategiesFailed: return "copied — could not insert"
        case .noFrontmostApp: return "copied"
        case .targetLost: return "copied — focus moved"
        }
    }

    private static func historyEntry(for outcome: SessionOutcome) -> DictationRecord? {
        switch outcome {
        case .landed(let insertion, let text, _, let app):
            let recorded: RecordedOutcome
            switch insertion {
            case .inserted: recorded = .inserted
            case .copiedToClipboard(.targetLost): recorded = .targetLost
            case .copiedToClipboard: recorded = .copiedToClipboard
            }
            return DictationRecord(spoken: text.spoken, delivered: text.text, appName: app, outcome: recorded)
        case .failed(_, let salvaged, let app):
            guard let salvaged else { return nil }
            return DictationRecord(spoken: salvaged, delivered: salvaged, appName: app, outcome: .copiedToClipboard)
        case .compared, .nothingHeard, .blockedSecure:
            return nil
        }
    }

    private static func summary(of outcome: InsertionOutcome) -> String {
        switch outcome {
        case .inserted(let via, .verified): return "inserted(\(via.rawValue), verified)"
        case .inserted(let via, .posted): return "inserted(\(via.rawValue), posted)"
        case .copiedToClipboard(let block): return "copied(\(block))"
        }
    }

    private static func summary(of observation: RivalObservation) -> String {
        switch observation {
        case .landed(_, let latency): return "landed \(latency.milliseconds) ms"
        case .unobservable: return "unobservable"
        case .timedOut(let after): return "nothing after \(after.milliseconds) ms"
        case .abandoned: return "abandoned"
        }
    }

    private static func placement(for plan: SessionPlan) -> OverlayPlacement {
        switch plan {
        case .dictate: return .bottom
        case .bakeoff: return .raised
        }
    }

    private static func badge(for engine: Engine) -> String? {
        switch engine.privacyClass {
        case .onDevice: return nil
        case .cloud: return "cloud"
        }
    }

    // MARK: - Bootstrap & bridge

    private func bootstrap() async {
        polisher.prewarm()
        startGesture()
        activateEngine()
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

    /// Runs non-throwing work against a deadline; nil on timeout. Returns at the deadline even if the
    /// loser ignores cancellation (the on-device model is only cooperatively cancellable).
    private static func race<T: Sendable>(timeout: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        let once = OnceResume<T?>()
        return await withCheckedContinuation { continuation in
            let worker = Task { let value = await work(); once.resume(continuation, with: value) }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(continuation, with: nil)
                worker.cancel()
            }
        }
    }
}

/// Resumes a continuation exactly once across racing tasks.
final class OnceResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ continuation: CheckedContinuation<T, Never>, with value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(returning: value)
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
