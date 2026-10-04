import AVFoundation
import AppKit
import Audio
import Bakeoff
import History
import Insertion
import Lexicon
import Observation
import Overlay
import Pipeline
import Polish
import Sessions
import Transcription
import Utterance
import os

/// The rules a session runs under, snapshotted at press. Later settings changes
/// cannot affect a session in flight.
struct SessionRules {
    let engine: Engine
    let style: WritingStyle
    let polish: PolishMode
    /// Model and credentials are snapshotted at press, along with the cleanup mode.
    let polisher: any Polisher
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
    case needsDownload(LocalSpeechModel)
    case loadingLocalModel(LocalSpeechModel)
    case ready
    case failed(String)
}

enum GestureStatus: Equatable {
    case stopped
    case listening
    case denied
    case failed
}

/// One engine hearing the utterance. A dictation has one; a race has one per engine.
struct Contender {
    let engine: Engine
    let transcription: Task<RawTranscript, Error>
}

@MainActor
final class LiveSession: SessionIdentity {
    let token: UUID
    let rules: SessionRules
    let plan: SessionPlan
    /// Never empty. A dictation's only contender is the active engine.
    let contenders: [Contender]
    var partial = ""
    var rivalWatch: Task<RivalObservation, Never>?
    /// Key-up: every contender's clock starts here.
    var releasedAt: ContinuousClock.Instant?
    let pressedAt = ContinuousClock.now

    var transcriptionLimit: Duration {
        guard let releasedAt else { return .seconds(15) }
        // Local decoders need time proportional to the recording; a long dictation is not a failed model.
        return max(.seconds(15), min(.seconds(300), releasedAt - pressedAt))
    }

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

typealias Phase = SessionPhase<LiveSession, FinishingStep, SessionOutcome>

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
    private(set) var permissionReport = Permissions.check()
    private(set) var requestingPermission: PermissionPane?
    private(set) var barPreviewVisible = false
    private(set) var keyStatuses: [APIKeyProvider: APIKeyStatus] = [:]
    let launchAtLogin = LaunchAtLogin()
    let updater = Updater()
    let localModels: LocalModelLibrary
    private(set) var availableLocales: [Locale] = []
    /// The engine sessions actually run on: the chosen one when its key is present, else Apple.
    /// The user's choice in Settings is never overwritten by availability.
    private(set) var activeEngine: Engine = .appleLocal

    /// One entry per language: the variant matching the user's region when the model list has it,
    /// else a canonical default. Regional model variants are mechanism, not a user choice.
    var languageChoices: [Locale] {
        let model: LocalSpeechModel?
        if case .local(let selected) = settings.engine { model = selected } else { model = nil }
        return SpeechLanguages.choices(for: model, availableLocales: availableLocales, userRegion: Locale.current.region?.identifier)
    }
    /// Set by the Bake-off pane's appear/disappear. Being in the pane IS bake-off mode.
    var bakeoffPaneVisible = false
    let settings: Settings
    let history: HistoryStore
    let bakeoff: BakeoffStore
    @ObservationIgnored private var dictionaryURL: URL!

    private static let settleDisplay: Duration = .milliseconds(700)
    private static let warningDisplay: Duration = .milliseconds(2200)
    private static let bakeoffDisplay: Duration = .seconds(4)
    private static let rivalTimeout: Duration = .seconds(8)
    private static let gestureRetry: Duration = .seconds(3)
    /// Field text handed to the on-device polish model as terminology reference; bounded for its context window.
    private static let fieldContextMaxChars = 600

    @ObservationIgnored private lazy var overlay = OverlayPanel()
    @ObservationIgnored private let capture = MicrophoneCapture()
    @ObservationIgnored private let onDevicePolisher = FoundationModelsPolisher()
    @ObservationIgnored private var transcriber: any Transcriber
    @ObservationIgnored private var gestureMonitor: HoldGestureMonitor?
    @ObservationIgnored private var gestureGeneration: UUID?
    @ObservationIgnored private var gestureRetryTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var microphonePrepared = false
    @ObservationIgnored private var pendingEngineRefresh = false
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var loadModelTask: Task<Void, Never>?
    @ObservationIgnored private var loadModelToken: UUID?
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "hearsay", category: "session")

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        settings = Settings(defaults: defaults)
        let support =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hearsay")
        KeyStore.configure(directory: support)
        history = HistoryStore(directory: support)
        dictionaryURL = support.appendingPathComponent("dictionary.txt")
        bakeoff = BakeoffStore(directory: support)
        localModels = LocalModelLibrary(directory: support.appendingPathComponent("local-models", isDirectory: true))
        transcriber = SpeechAnalyzerTranscriber(locale: settings.locale)  // placeholder; bootstrap rebuilds from the persisted engine
    }

    func start() {
        guard bootstrapTask == nil else { return }
        isRunning = true
        bootstrapTask = Task { await bootstrap() }
    }

    func stop() {
        isRunning = false
        bootstrapTask?.cancel()
        bootstrapTask = nil
        gestureRetryTask?.cancel()
        gestureRetryTask = nil
        switch phase {
        case .listening(let session):
            capture.stop()
            for contender in session.contenders { contender.transcription.cancel() }
            session.rivalWatch?.cancel()
        case .finishing(let session, _):
            for contender in session.contenders { contender.transcription.cancel() }
            session.rivalWatch?.cancel()
        case .idle, .settled: break
        }
        finishTask?.cancel()
        finishTask = nil
        phase = .idle
        stopGesture()
        loadModelTask?.cancel()
        loadModelToken = nil
        localModels.stop()
        settleTask?.cancel()
        endBarPreview()
        overlay.render(.hidden)
    }

    func refreshPermissions() {
        permissionReport = Permissions.check()
        launchAtLogin.refresh()
        if !permissionReport.microphone { microphonePrepared = false }
        if permissionReport.microphone, !microphonePrepared {
            capture.prepare()
            microphonePrepared = true
        }
        guard isRunning else { return }
        if !permissionReport.inputMonitoring {
            stopGesture()
            if !settings.dictationPaused { gesture = .denied }
            scheduleGestureRetry()
        } else if !settings.dictationPaused {
            startGesture()
        }
    }

    func requestPermission(_ pane: PermissionPane) async {
        guard requestingPermission == nil else { return }
        requestingPermission = pane
        _ = await Permissions.request(pane)
        requestingPermission = nil
        refreshPermissions()
    }

    func select(shortcut: ModifierChord) {
        settings.shortcut = shortcut
        guard gestureMonitor?.isHeld != true else { return }
        startGesture()
    }

    func set(dictationPaused: Bool) {
        settings.dictationPaused = dictationPaused
        if dictationPaused {
            gestureRetryTask?.cancel()
            gestureRetryTask = nil
            stopGesture()
        } else {
            refreshPermissions()
        }
    }

    func refreshKeys() {
        keyStatuses = Dictionary(uniqueKeysWithValues: APIKeyProvider.allCases.map { ($0, KeyStore.status($0)) })
        requestEngineRefresh()
    }

    private func requestEngineRefresh() {
        if sessionInFlight { pendingEngineRefresh = true } else { activateEngine() }
    }

    func previewBar() {
        guard !sessionInFlight else { return }
        settleTask?.cancel()
        phase = .idle
        barPreviewVisible = true
        overlay.preview()
    }

    func endBarPreview() {
        guard barPreviewVisible else { return }
        barPreviewVisible = false
        overlay.endPreview()
    }

    func resetBarPosition() { overlay.resetPosition() }

    var sessionInFlight: Bool {
        phase.isInFlight
    }

    var shortcutChangePending: Bool {
        gestureMonitor.map { $0.chord != settings.shortcut } ?? false
    }

    // MARK: - Intents

    func select(locale: Locale) {
        settings.locale = locale
        requestEngineRefresh()
    }

    func select(engine chosen: Engine) {
        if case .local(let model) = chosen, model.needsLocale,
            model.languageCode(for: settings.locale) == nil
        {
            settings.locale = Locale(identifier: "en-US")
        }
        settings.engine = chosen
        requestEngineRefresh()
    }

    func download(model: LocalSpeechModel) {
        localModels.download(model) { [weak self] in
            guard let self, self.isRunning, self.settings.engine == .local(model) else { return }
            self.requestEngineRefresh()
        }
    }

    func remove(model: LocalSpeechModel) {
        guard !sessionInFlight, !localModels.isBusy else { return }
        if case .loadingLocalModel = engine { return }
        if settings.engine == .local(model) { engine = .needsDownload(model) }
        localModels.remove(model) { [weak self] in
            guard let self, self.isRunning, self.settings.engine == .local(model) else { return }
            self.requestEngineRefresh()
        }
    }

    func canSelect(_ choice: Engine) -> Bool {
        if case .local(let model) = choice { return localModels.directory(for: model) != nil }
        return choice.isAvailable
    }

    /// Keep one downloaded model resident; cloud and Apple contenders can still race it.
    func canRace(_ choice: Engine) -> Bool {
        if case .local = choice { return choice == activeEngine && canSelect(choice) && engine == .ready }
        return choice.isAvailable
    }

    func set(polishEngine: PolishEngine) {
        settings.polishEngine = polishEngine
    }

    func set(cloudCleanupModel: CloudCleanupModel) {
        settings.cloudCleanupModel = cloudCleanupModel
    }

    func set(ollamaModel: String?) {
        settings.ollamaModel = ollamaModel
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
        loadModelTask?.cancel()
        loadModelToken = UUID()
        let chosen = settings.engine
        var resolved = chosen
        if !chosen.isAvailable {
            log.notice("activateEngine: \(chosen.wireKey, privacy: .public) needs an API key — running on Apple until it is added")
            resolved = .appleLocal
        }
        if resolved == .appleLocal { normalizeAppleLocale() }
        if case .local = activeEngine {
            if case .local = resolved {
                // Loading the next model releases the previous weights under the inference gate.
            } else {
                Task { await LocalModelTranscriber.releaseModel() }
            }
        }
        let directory: URL?
        if case .local(let model) = resolved {
            directory = localModels.directory(for: model)
            guard directory != nil else {
                activeEngine = resolved
                engine = .needsDownload(model)
                return
            }
        } else {
            directory = nil
        }
        if let built = resolved.makeTranscriber(locale: settings.locale, localModelDirectory: directory) {
            transcriber = built
        } else {
            resolved = .appleLocal
            transcriber = SpeechAnalyzerTranscriber(locale: settings.locale)
        }
        activeEngine = resolved
        switch resolved {
        case .appleLocal:
            reloadAppleModel()
        case .local(let model):
            guard let local = transcriber as? LocalModelTranscriber else { return }
            let token = loadModelToken
            engine = .loadingLocalModel(model)
            loadModelTask = Task { [weak self] in
                do {
                    try await local.prepare()
                    guard let self, !Task.isCancelled, self.loadModelToken == token else { return }
                    self.engine = .ready
                } catch {
                    guard let self, !Task.isCancelled, self.loadModelToken == token else { return }
                    self.engine = .failed(error.localizedDescription)
                }
            }
        case .openRouter, .elevenLabsScribe, .geminiTranscribeLive:
            loadModelTask?.cancel()
            engine = .ready
        }
    }

    private func normalizeAppleLocale() {
        guard !availableLocales.isEmpty else { return }
        let current = settings.locale.identifier(.bcp47)
        guard !availableLocales.contains(where: { $0.identifier(.bcp47) == current }) else { return }
        let choices = SpeechLanguages.choices(for: nil, availableLocales: availableLocales, userRegion: Locale.current.region?.identifier)
        let language = settings.locale.language.languageCode?.identifier
        if let choice = choices.first(where: { $0.language.languageCode?.identifier == language })
            ?? choices.first(where: { $0.language.languageCode?.identifier == "en" }) ?? choices.first
        {
            settings.locale = choice
        }
    }

    private func reloadAppleModel() {
        loadModelTask?.cancel()
        let token = loadModelToken
        let locale = settings.locale
        engine = .downloadingModel(locale)
        loadModelTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await SpeechAnalyzerTranscriber.ensureModel(for: locale)
                guard !Task.isCancelled, self.loadModelToken == token, self.activeEngine == .appleLocal else { return }
                self.engine = .ready
                self.log.notice("loadModel: ready \(locale.identifier, privacy: .public)")
            } catch {
                guard !Task.isCancelled, self.loadModelToken == token, self.activeEngine == .appleLocal else { return }
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
        guard isRunning, !settings.dictationPaused else { return }
        refreshPermissions()
        guard permissionReport.microphone else {
            settle(.failed(reason: "allow microphone in Hearsay settings", salvaged: nil, app: "—"))
            return
        }
        endBarPreview()
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
        let armedTarget: InsertionTarget? = {
            if case .armed(let armed) = target { return armed }
            return nil
        }()
        let polish = settings.polish
        let polishEngine: PolishEngine =
            settings.polishEngine == .openRouter && KeyStore.value("OPENROUTER_API_KEY") == nil ? .onDevice : settings.polishEngine
        let polisher: any Polisher
        switch polishEngine {
        case .onDevice: polisher = onDevicePolisher
        case .openRouter:
            polisher = OpenRouterPolisher(
                key: KeyStore.value("OPENROUTER_API_KEY") ?? "", model: settings.cloudCleanupModel.rawValue)
        case .ollama: polisher = OllamaPolisher(model: settings.ollamaModel ?? "")
        }
        // Field context is read only when the on-device model will use it: it never leaves the Mac.
        let fieldContext =
            (settings.fieldContextEnabled && polish != .off && polishEngine == .onDevice)
            ? armedTarget?.contextAroundCursor(maxChars: Self.fieldContextMaxChars) : nil
        let rules = SessionRules(
            engine: activeEngine,
            style: StyleInference.style(for: target),
            polish: polish,
            polisher: polisher,
            fieldContext: fieldContext,
            lexicon: Lexicon.load(from: dictionaryURL)
        )
        // Bake-off iff the text would land in our own pane: same arm() snapshot the session uses,
        // so activation state and view lifecycle cannot disagree with it.
        let plan: SessionPlan
        if let armed = armedTarget, armed.app.pid == ProcessInfo.processInfo.processIdentifier,
            case .textElement = armed.focused, bakeoffPaneVisible
        {
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
        let hints = TranscriptionHints(vocabulary: rules.lexicon.terms, mode: rules.polish.transcriptMode)
        // The pill follows one streaming engine; the others race silently.
        let pillEngine = lineup.first { $0.engine.deliversPartials }?.engine
        let contenders = zip(lineup, Self.fanOut(audio, count: lineup.count)).map { entry, stream in
            let (engine, engineTranscriber) = entry
            let reportsPartials = engine == pillEngine
            return Contender(
                engine: engine,
                transcription: Task { [weak self] () throws -> RawTranscript in
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
            applyPendingShortcut()
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
        guard phase.release(to: step) != nil else { return }
        overlay.render(.working(step.label))
        log.notice("released: partial length \(session.partial.count)")
        finishTask = Task { await finish(session) }
        applyPendingShortcut()
    }

    /// The engines a take races: the user's selection minus any without a key. Never empty.
    private func racingLineup() -> [(engine: Engine, transcriber: any Transcriber)] {
        let chosen = Engine.all.filter { canRace($0) && settings.isRacing($0) }
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
            session.partial = text  // salvage must see text finalized after release
        default:
            break
        }
    }

    private func finish(_ session: LiveSession) async {
        guard phase.canComplete(session.token, running: isRunning, cancelled: Task.isCancelled) else { return }
        switch session.plan {
        case .dictate(let destination): await finishDictation(session, into: destination)
        case .bakeoff(let target, let expected, let runID, let takeID):
            await finishRace(session, target: target, expected: expected, runID: runID, takeID: takeID)
        }
    }

    private func finishDictation(_ session: LiveSession, into destination: DictationDestination) async {
        var timing = SessionTiming()

        let transcribeStart = clock.now
        let raw: RawTranscript
        do {
            let limit = session.rules.engine.transcriptionLimit(audioDuration: session.transcriptionLimit)
            raw = try await Self.value(of: session.contenders[0].transcription, within: limit)
        } catch {
            guard phase.canComplete(session.token, running: isRunning, cancelled: Task.isCancelled) else { return }
            session.rivalWatch?.cancel()
            log.error("finish: transcription failed: \(String(describing: error))")
            var salvaged: String?
            if case .dictate = session.plan, !session.partial.isEmpty {
                salvaged = session.partial
                Inserter.copyToClipboard(session.partial)
            }
            settle(.failed(reason: "transcription failed", salvaged: salvaged, app: session.appName), from: session.token)
            return
        }
        guard phase.canComplete(session.token, running: isRunning, cancelled: Task.isCancelled) else { return }
        timing.transcribe = clock.now - transcribeStart
        guard !raw.text.isEmpty else {
            session.rivalWatch?.cancel()
            settle(.nothingHeard, from: session.token)
            return
        }

        if session.rules.polish != .off {
            guard phase.advance(session.token, to: .polishing) else { return }
            overlay.render(.working(FinishingStep.polishing.label))
        }
        let cleanup = await TextPipeline.finish(
            raw, mode: session.rules.polish, style: session.rules.style,
            lexicon: session.rules.lexicon, polisher: session.rules.polisher, fieldContext: session.rules.fieldContext
        )
        let delivered = cleanup.delivered
        timing.polish = cleanup.polishDuration
        if let rejection = cleanup.rejection {
            log.notice("finish: kept raw (\(rejection.label, privacy: .public))")
        }
        guard phase.canComplete(session.token, running: isRunning, cancelled: Task.isCancelled) else { return }

        guard phase.advance(session.token, to: .inserting) else { return }
        overlay.render(.working(FinishingStep.inserting.label))
        let insertStart = clock.now
        let outcome: InsertionOutcome
        switch destination {
        case .field(let target): outcome = await Inserter.insert(delivered.text, into: target)
        case .clipboardOnly: outcome = Inserter.copyToClipboard(delivered.text, because: .noFrontmostApp)
        }
        guard phase.canComplete(session.token, running: isRunning, cancelled: Task.isCancelled) else { return }
        timing.insert = clock.now - insertStart
        lastTiming = timing
        log.notice(
            "session: transcribe \(timing.transcribe.milliseconds) ms · polish \(timing.polish.milliseconds) ms · insert \(timing.insert.milliseconds) ms · \(Self.summary(of: outcome), privacy: .public)"
        )
        settle(.landed(outcome, delivered, timing, app: session.appName), from: session.token)
    }

    /// Every contender is scored on its raw text, each on its own clock from key-up; the rival on
    /// the same clock. One take, every row.
    private func finishRace(_ session: LiveSession, target: BakeoffTarget, expected: String?, runID: UUID, takeID: UUID) async {
        let releasedAt = session.releasedAt ?? clock.now
        let audioDuration = session.transcriptionLimit
        let clock = self.clock
        var results: [(index: Int, result: EngineResult)] = []
        await withTaskGroup(of: (Int, EngineResult).self) { group in
            for (index, contender) in session.contenders.enumerated() {
                let key = contender.engine.wireKey
                group.addTask {
                    do {
                        let limit = contender.engine.transcriptionLimit(audioDuration: audioDuration)
                        let raw = try await Self.value(of: contender.transcription, within: limit)
                        let ms = (clock.now - releasedAt).milliseconds
                        let outcome: EngineOutcome =
                            raw.text.isEmpty ? .failed(reason: "nothing heard") : .scored(spoken: raw.text, ours: raw.text, ms: ms)
                        return (index, EngineResult(engine: key, outcome: outcome))
                    } catch {
                        return (
                            index, EngineResult(engine: key, outcome: .failed(reason: error is OperationTimeout ? "timed out" : "failed"))
                        )
                    }
                }
            }
            for await entry in group { results.append((entry.0, entry.1)) }
        }
        guard phase.canComplete(session.token, running: isRunning, cancelled: Task.isCancelled) else { return }
        results.sort { $0.index < $1.index }

        guard phase.advance(session.token, to: .watchingRival) else { return }
        overlay.render(.working(FinishingStep.watchingRival.label))
        let rival: RivalObservation
        switch target {
        case .watchable: rival = await session.rivalWatch?.value ?? .unobservable
        case .unobservable: rival = .unobservable
        }
        guard phase.canComplete(session.token, running: isRunning, cancelled: Task.isCancelled) else { return }
        let take = Take(
            id: takeID.uuidString, app: session.appName, expected: expected, rival: RivalOutcome(rival), results: results.map(\.result))
        if runID == bakeoff.runID {
            bakeoff.append(take)
        } else {
            log.notice("finish: bake-off run was reset during the take — take dropped")
        }
        let fastest = take.results.compactMap { result -> (engine: Engine, ms: Duration)? in
            guard case .scored(_, _, let ms) = result.outcome, let engine = Engine(wireKey: result.engine) else { return nil }
            return (engine, .milliseconds(ms))
        }.min { $0.ms < $1.ms }
        log.notice(
            "bakeoff: raced \(take.results.count) · fastest \(fastest?.ms.milliseconds ?? -1) ms · rival \(Self.summary(of: rival), privacy: .public)"
        )
        settle(.compared(RaceOutcome(fastest: fastest, rival: rival, app: session.appName)), from: session.token)
    }

    private func settle(_ outcome: SessionOutcome, from token: UUID) {
        guard phase.complete(token, with: outcome, running: isRunning, cancelled: Task.isCancelled) else { return }
        showSettlement(outcome)
    }

    private func settle(_ outcome: SessionOutcome) {
        guard isRunning else { return }
        phase = .settled(outcome)
        showSettlement(outcome)
    }

    private func showSettlement(_ outcome: SessionOutcome) {
        if pendingEngineRefresh {
            pendingEngineRefresh = false
            activateEngine()
        }
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
        onDevicePolisher.prewarm()
        refreshPermissions()
        availableLocales = await SpeechAnalyzerTranscriber.supportedLocales()
            .sorted { $0.displayName < $1.displayName }
        guard !Task.isCancelled, isRunning else { return }
        refreshKeys()
    }

    private func startGesture() {
        guard isRunning, !settings.dictationPaused else { return }
        guard gestureMonitor?.chord != settings.shortcut else { return }
        guard gestureMonitor?.isHeld != true else { return }
        gestureRetryTask?.cancel()
        gestureRetryTask = nil
        stopGesture()
        let generation = UUID()
        let monitor = HoldGestureMonitor(chord: settings.shortcut) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.gestureGeneration == generation else { return }
                switch event {
                case .pressed: self.pressed()
                case .released: self.released()
                }
            }
        }
        do {
            try monitor.start()
            gestureGeneration = generation
            gestureMonitor = monitor
            gesture = .listening
            log.notice("startGesture: listening for \(self.settings.shortcut.label, privacy: .public)")
        } catch {
            gesture = (error as? GestureMonitorFailure) == .inputMonitoringDenied ? .denied : .failed
            scheduleGestureRetry()
        }
    }

    private func stopGesture() {
        let previous = gestureMonitor
        gestureMonitor = nil
        gestureGeneration = nil
        previous?.stop()
        if case .listening = phase { released() }
        gesture = .stopped
    }

    private func applyPendingShortcut() {
        if shortcutChangePending { startGesture() }
    }

    private func scheduleGestureRetry() {
        guard isRunning, !settings.dictationPaused, gestureRetryTask == nil else { return }
        gestureRetryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.gestureRetry)
            guard !Task.isCancelled, let self else { return }
            self.gestureRetryTask = nil
            self.refreshPermissions()
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
