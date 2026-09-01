# hearsay — local push-to-talk dictation for macOS

Working title. Purpose in one sentence: **hold a key, speak, release, and the words land where your cursor was — without the audio leaving the Mac.**

## 0. What Wispr Flow actually is

- Cloud-only. Every utterance is uploaded; no on-device mode at any tier. Requires internet.
- Proprietary models, not Whisper. Subprocessors listed: Baseten, OpenAI, Anthropic, Cerebras, AWS.
- "Context awareness" = surrounding textbox contents + app identity uploaded with every dictation regardless of the toggle; screen OCR/screenshot once per dictation when enabled (AX context defaults on). The widely-blogged "screenshots every few seconds + CTO apology" story traces to competitor marketing — the binary contradicts it.
- Privacy Mode only zeroes server-side retention; audio still leaves the device.

So the friend's claim ("can't build a comparable experience") is really "can't match cloud models locally." That is the bet, and the 2026 on-device stack makes it winnable:

| Engine | Where | Notes |
|---|---|---|
| Apple `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26) | Neural Engine | Streaming partials, ~2× faster than Whisper large-v3-turbo, tops 2026 on-device accuracy benchmarks, auto language detection. Zero dependencies. |
| NVIDIA Parakeet TDT 0.6B v3 via FluidAudio (CoreML) | ANE/CPU | 6.3% WER (vs 7.8% Whisper turbo), ~60–110× realtime on Apple Silicon, 25 European languages incl. sv/pt/en. |
| Apple `FoundationModels` (macOS 26) | On-device ~3B LLM | Free, private, guided generation. Right size for filler removal / punctuation / casing. |

Local open-source apps already doing this: FluidVoice (Swift, GPLv3), VoiceInk (Swift, GPLv3), Handy (Rust/Tauri). We build our own, but their source is the reference for platform mechanics.

## 1. The bet — success criteria

Measured side by side against the installed Wispr Flow, same sentences, same mic:

1. **Latency**: key-up → text visible in the target app ≤ 700 ms for a 10 s utterance.
2. **Offline**: works with Wi-Fi off. (Wispr: cannot.)
3. **Accuracy**: 20-sentence script in English + Swedish (+ Portuguese), count word errors for both.
4. **Privacy**: zero network traffic during dictation (`nettop` / Little Snitch).
5. **Feel**: overlay appears < 100 ms after press; focus never leaves the app you were typing in.

## 2. Concept design

### Concept inventory

| # | Concept | Purpose | Operational principle (compressed) |
|---|---|---|---|
| 1 | utterance [Key] | Bound one spoken thought with a single gesture, eyes on your work | after press, speech is captured; after release, it is delivered as one unit |
| 2 | transcription [Audio] | Turn captured speech into the words that were said | feed audio of "send the invoice" → finish yields "send the invoice" |
| 3 | polish [Text] | Make spoken words read as written text without changing meaning | "um so send the, send the invoice by friday" → "Send the invoice by Friday." |
| 4 | insertion [Target, Text] | Put text where the user was typing, hands never leave the flow | arm while cursor is in app X → insert(t) makes t appear at that cursor |
| 5 | history [Text] | Recover a dictation that didn't land — the *trash* of dictation | after an insertion fails, the text is still retrievable |
| 6 | dictionary [Term] | Get names, jargon, acronyms right | after adding "Enobis", it is transcribed as "Enobis" not "a nobis" |
| 7 | snippet [Trigger, Text] | Insert boilerplate by speaking a trigger | say "insert signature" → signature text lands |

**The overlay is not a concept.** It is the UI *mapping* of `utterance.phase` + `transcription.partial` + the finishing step. One source of truth, rendered — never a parallel "isShowing" flag (that is the Zoom-raised-hand under-sync bug waiting to happen).

### Five-part definitions (the core four)

```
concept    utterance [Key]
purpose    bound one spoken thought with a single gesture, eyes on your work
state      phase: idle | listening(since)
           lock: held | locked                  ← hidden mode → MUST be visible in overlay
actions    press(k)      idle → listening
           release(k)    listening → idle, unless locked
           doubleTap(k)  listening → locked
           press(k)      locked → idle
OP         after press(k), speech is captured; after release(k), the captured
           speech is delivered as one unit
```

```
concept    transcription [Audio]
purpose    turn captured speech into the words that were said
state      engine, localeHint; per utterance: partial (volatile), final
actions    start(utterance); feed(buffer) → partial; finish() → RawTranscript
OP         after feeding audio of someone saying "send the invoice",
           finish() yields "send the invoice"
```

```
concept    polish [Text]
purpose    make spoken words read as written text — punctuation, casing,
           fillers and self-corrections removed — without changing meaning
state      style per context (chat | email | code | plain), engine
actions    polish(raw, context) → polished | unchanged
OP         "um so send the, send the invoice by friday" → "Send the invoice by Friday."
misfits    (imported from every LLM-cleanup product ever)
           - model ANSWERS the dictated question instead of cleaning it
           - over-formalizes chat, drops swearing, "fixes" code identifiers
           - hallucinates a sentence when audio was silence
mitigation guided generation (typed output), bounded edit-distance guard,
           raw fallback on any doubt, style keyed to app
```

```
concept    insertion [Target, Text]
purpose    put the text where the user was typing, hands never leave the flow
state      armed target: (app bundle id, AX focused element, clipboard snapshot)
actions    arm() → Target | noTextTarget          ← captured at PRESS, not at release
           insert(text, target) → inserted(via) | targetLost | unsupported(reason)
OP         after arm() while the cursor is in app X, insert(t) makes t appear
           at that cursor in X
misfits    Electron/Chromium/Terminal/JetBrains reject or lie about AX writes;
           secure fields block everything; paste clobbers clipboard;
           focus moves during a long utterance
```

### Dependence diagram

```
utterance                       ← root: the gesture. No product without it.
└── transcription               ← needs something to transcribe
    ├── insertion               ← needs text to land
    ├── polish                  ← needs raw text to clean
    ├── history                 ← needs transcripts to keep
    ├── dictionary              ← needs transcription to bias/correct
    └── snippet                 ← needs a transcript to match triggers
```

Downward-closed subsets = shippable products:

- **{utterance, transcription, insertion}** — the MVP and the whole bet.
- **+ polish** — Wispr parity on the core loop.
- **+ history** — safety net; cheap; makes every insertion failure survivable.
- **+ dictionary, snippet** — taste. Later.
- **command mode** (edit selected text by voice) is a *different* concept with a different purpose. Deliberately out of scope; not a missing concept for v1.

### Compositions (syncs live in one coordinator, never inside a concept)

| Sync | Kind | Why |
|---|---|---|
| utterance.press → insertion.arm ∧ transcription.start | bookkeeping | target must be captured *before* focus can move; audio must start at the same instant |
| utterance.release → transcription.finish → polish → insertion.insert | staging | the pipeline |
| polish = unchanged/failed → insertion gets raw | mitigation | never lose words to a cleanup model |
| insertion.insert (any outcome) → history.record | logging | free undo |
| insertion = noTextTarget/unsupported → clipboard + overlay "copied" | mitigation | still useful when no field is focused |

Deliberately **not** synced:

- partial transcript → insertion (no live typing into the target: flicker, undo pollution, focus risk). Partials go to the overlay.
- user correction → dictionary (Wispr's inference sync; surprising entries). Adding to dictionary is explicit.

### Findings vs Wispr Flow's design

- **Screenshot context**: purpose (style per app) is served by a much cheaper concept — frontmost bundle id + AX role of the focused field. Same outcome, no screenshots, no upload.
- **Auto-dictionary from corrections**: over-synchronization by inference; users cannot predict what got learned. We make it an action.
- **Cloud transcription + cloud polish**: not a concept problem, a deployment choice. Every concept above is engine-agnostic.

## 3. Architecture (Mirdin best practices applied)

Native Swift. Everything load-bearing is Swift-only: `SpeechAnalyzer`, `FoundationModels`, `AXUIElement`, `NSPanel`, `CGEvent`. Tauri/Electron would put a bridge between us and every one of those.

### One concept, one module

```
Package.swift
Sources/
  Hearsay/          app entry, MenuBarExtra, Coordinator (ALL syncs live here)
  Utterance/        hotkey gesture → press / release / lock events
  Transcription/    Transcriber protocol; SpeechAnalyzerTranscriber (ParakeetTranscriber later)
  Polish/           Polisher protocol; FoundationModelsPolisher (ClaudePolisher later, opt-in)
  Insertion/        InsertionTarget, InsertionStrategy, strategies
  History/
  Overlay/          NSPanel + SwiftUI, renders SessionPhase — nothing else
scripts/bundle.sh   wraps the executable into hearsay.app, Info.plist, codesign
```

Parnas check: `Transcription` is not more complex for not knowing `Overlay`. `Insertion` is not more complex for not knowing `Transcription`. A useful subset (CLI transcriber) exists with `Transcription` but not `Utterance`. Only `Coordinator` knows everything; that is its one job.

### Types — MIRO, Parse-don't-validate, no booleans

```swift
// The single state that drives overlay, menu bar and pipeline.
enum SessionPhase {
    case idle
    case listening(Utterance, InsertionTarget, lock: HoldLock)
    case finishing(Utterance, InsertionTarget, step: FinishingStep)
    case settled(InsertionOutcome)          // shown ~1 s, then idle
}
enum HoldLock { case held, locked }
enum FinishingStep { case transcribing, polishing, inserting }

// Provenance carried in the type, not in a comment.
struct RawTranscript  { let text: String }   // only Transcription can mint
struct PolishedText   { let text: String }   // only Polish can mint
enum InsertableText   { case polished(PolishedText), raw(RawTranscript) }
// Insertion accepts InsertableText, never String — you cannot insert
// something whose origin is unknown.

enum ArmResult      { case armed(InsertionTarget), noTextTarget, secureField }
enum InsertionStrategy { case accessibility, paste, keystrokes }
enum InsertionOutcome  { case inserted(via: InsertionStrategy), targetLost, unsupported(String), copiedToClipboard }
enum PolishVerdict     { case accept(PolishedText), keepRaw(reason: PolishRejection) }
enum PolishRejection   { case tooDifferent, lengthRatio, modelUnavailable, timeout }

protocol Transcriber { func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptionEvent, Error> }
enum TranscriptionEvent { case partial(String), final(RawTranscript) }

protocol Polisher { func polish(_ raw: RawTranscript, style: WritingStyle) async -> PolishVerdict }
enum WritingStyle { case chat, email, code, plain }
```

Plain-English test for the whole app: *"On press, remember where the cursor is and start listening. On release, turn the audio into text, clean it, and put it where the cursor was. If anything fails, keep the text."* The `Coordinator` should read like that sentence.

## 4. Platform mechanics and known gotchas

**Toolchain.** This machine has only Command Line Tools (SDK 14.4, Swift 5.10). `SpeechAnalyzer` and `FoundationModels` need the macOS 26 SDK → install Xcode 26 from the App Store, `sudo xcode-select -s /Applications/Xcode.app`. Runtime frameworks are already present (`/System/Library/Frameworks/{Speech,FoundationModels}.framework`); Apple Intelligence is opted in.

**Hotkey.** Modifier-only keys (fn, right ⌥) cannot be Carbon hotkeys; use a `CGEvent` tap (`.listenOnly`, `flagsChanged` + `keyDown/keyUp`) — requires *Input Monitoring*. `fn` is currently bound to **Change Input Source** (Swedish ↔ ABC) on this Mac → decision needed (see §6).

**Overlay.** `NSPanel` with `[.nonactivatingPanel, .borderless]`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, `ignoresMouseEvents = true`, `hidesOnDeactivate = false`. It must never become key — if it does, insertion targets the overlay. Bottom-center of the screen containing the cursor.

**Audio.** `AVAudioEngine` input tap → `AVAudioConverter` to the analyzer's preferred format → `AsyncStream<AnalyzerInput>`. `SpeechTranscriber(locale:, transcriptionOptions:, reportingOptions: [.volatileResults], attributeOptions:)`. Model assets are downloaded once via `AssetInventory.assetInstallationRequest(supporting:)`. RMS from the same tap drives the overlay waveform.

**Insertion strategies**, tried in order until one reports success:
1. `accessibility` — set `kAXSelectedTextAttribute` on the armed element. Native Cocoa text views only.
2. `paste` — snapshot `NSPasteboard` (all types), write text, post ⌘V via `CGEvent` (requires *Accessibility*), wait ~80 ms, restore snapshot. Works almost everywhere.
3. `keystrokes` — `CGEventKeyboardSetUnicodeString` in chunks. Universal but ~1–2 ms/char.
Secure text fields (`kAXSecureTextField`) → refuse, `copiedToClipboard`, overlay says so.

**Polish.** `SystemLanguageModel.default` → check `.availability` → `LanguageModelSession(instructions:)` → `respond(to:, generating: CleanedDictation.self)` with a `@Generable` struct. 4096-token context is plenty for dictation. Optional `ClaudePolisher` (`claude-haiku-4-5-20251001`) behind an explicit toggle; cloud, so off by default — the whole point.

**Permissions.** Microphone (`NSMicrophoneUsageDescription`), Accessibility (CGEvent posting + AX), Input Monitoring (event tap). Verify in M1 whether `SpeechAnalyzer` needs `SFSpeechRecognizer` authorization (believed not for on-device).

**Code signing / TCC trap.** Accessibility permission is keyed to the code signature. Ad-hoc signatures change every build → re-grant after every build. Fix once: free Apple Development certificate (Xcode → Settings → Accounts → Manage Certificates), sign with it in `scripts/bundle.sh`, stable bundle id.

**App shape.** `LSUIElement = true` (no Dock icon), `MenuBarExtra` for settings/history/quit.

## 5. Milestones — built along the dependence diagram

Each milestone is a working product.

| # | Deliverable | Exit criterion | Effort |
|---|---|---|---|
| M0 | Xcode 26, dev cert, fn-key decision, `fn` → Do Nothing or alt key, permissions granted | `swift build` against SDK 26 succeeds | 1 h |
| M1 | **Engine spike**: `hearsay-spike` CLI — record 5 s from mic, print transcript + timing via `SpeechAnalyzer`; test en/sv/pt | key-up → final ≤ 500 ms for 10 s speech. If not, swap in Parakeet via FluidAudio behind the same `Transcriber` protocol | 2–3 h |
| M2 | **The bet**: hotkey + overlay + insertion, raw text. Menu bar app | hold key in Slack, Cursor, Terminal, Mail, Chrome → text lands. Side-by-side with Wispr on the §1 script | 1–2 days |
| M3 | Polish via `FoundationModels`, style by app, guard + raw fallback; partials shown in overlay | fillers gone, meaning intact, no "answering" | ½ day |
| M4 | History (menu + reinsert/copy), clipboard fallback, secure-field refusal, locale picker | every failed insertion recoverable | ½ day |
| M5 | Dictionary, snippets, Parakeet engine, Claude polish opt-in, sounds | taste | later |

## 6. Decisions that are yours (they shape the product; each is ~10 lines of code)

1. **Gesture semantics + key.** Hold-only, or hold + double-tap-to-lock? And which key, given `fn` currently switches Swedish/ABC: (a) `fn` → Do Nothing and switch layouts with ⌃Space, (b) right ⌥, (c) `fn` with tap-vs-hold discrimination (tap still switches input source, hold ≥ 150 ms talks). You write the gesture reducer: `(keyDown/keyUp timestamps) → press | release | lock`.
2. **Insertion policy.** Fixed fallback order, or a per-app table (Terminal → keystrokes, Electron → paste, native → AX)? You write `strategies(for: InsertionTarget) -> [InsertionStrategy]`.
3. **Polish guard.** What counts as "the model changed my meaning"? Edit-distance ratio, length ratio, forbidden transformations? You write `verdict(raw:, polished:) -> PolishVerdict`.

## Sources

- Wispr Flow is cloud-only, no local mode: https://www.parakeety.com/resources/does-wispr-flow-run-locally
- Wispr Flow subprocessors / Privacy Mode: https://metawhisp.com/blog/is-wispr-flow-safe/ , https://www.getvoibe.com/resources/wispr-flow-review/
- Wispr Flow screenshot / privacy incident: https://modelpiper.com/blog/wispr-flow-privacy-incident
- Wispr Flow doesn't use Whisper: https://www.getvoibe.com/resources/openai-whisper-vs-wispr-flow/
- Wispr Flow features: https://wisprflow.ai/features
- SpeechAnalyzer (WWDC25): https://developer.apple.com/videos/play/wwdc2025/277/
- SpeechAnalyzer benchmark vs Whisper: https://get-inscribe.com/blog/apple-speech-api-benchmark.html , https://www.forasoft.com/blog/article/speech-recognition-with-neural-networks-on-ios-1621
- Parakeet v3 vs Whisper turbo WER: https://loronote.com/en/blog/parakeet-v3-vs-whisper-large-v3
- FluidAudio (Parakeet CoreML, Swift): https://github.com/FluidInference/FluidAudio
- FluidVoice (open-source local Wispr alternative): https://github.com/altic-dev/FluidVoice

## Status — 2026-08-26

- M0 done: Command Line Tools 26.6 installed via `softwareupdate` (no Xcode, no sudo needed). `@Generable` macro is Xcode-only → polish uses plain text responses + `PolishGuard`.
- M1–M4 code written and compiling (≈1500 lines, 7 modules). Hotkey fixed to **fn+shift** (Nils' Wispr binding).
- App launches, model `en-US` ready on-device, gesture monitor polling for Input Monitoring grant.
- Blocked on first-run permission clicks (Microphone, Accessibility, Input Monitoring) — see README.
- Signing is ad-hoc until `hearsay-dev` cert is trusted (README) — permissions must be re-granted after each rebuild until then.
- fal.ai: cloud STT, same category as Wispr. Fits behind `Transcriber` as an optional second engine for the accuracy bake-off — M5.
- Bake-off mode added (same hotkey for both apps; hearsay observes instead of inserting; `RivalWatch` + `bakeoff.jsonl` + `scripts/bakeoff-report.py` for WER/latency).

## Status — 2026-09-01

- Full pre-release pass done: 7-agent code review (~90 findings) → DESIGN-REVIEW.md (concept + data-structure blueprint) → refactor executed. Engine reified, sessions atomic under press-time rules, secure fields block capture, logs content-free, arena localhost-only with validated control and pinned scoring refs. All builds green; 15 arena scoring tests pass; permission grants survive rebuilds via hearsay-dev cert.
- Remaining before public release: Developer ID + hardened runtime + notarization (bundle.sh warns), Parakeet engine (one Engine case + FluidAudio), dictionary concept for jargon accuracy.
