# hearsay — concept & data-structure review (pre-refactor)

Date: 2026-09-01. Inputs: the 7-agent code review (~90 findings), The Essence of Software review
checklists, the data-structures decision procedure. This document is the blueprint the refactor follows.

## Part 1 — Concept review

### Inventory, as built

| # | Concept | Purpose | Health |
|---|---------|---------|--------|
| 1 | utterance | bound one spoken thought with a single gesture | ✅ healthy (lock action cut by YAGNI — fine) |
| 2 | transcription | turn captured speech into the words said | ⚠️ generic concept leaking engine-specific errors |
| 3 | polish | turn what was said into what the speaker meant to write | ✅ coherent (see F4) |
| 4 | insertion | put the text where the user was typing | ⚠️ OP not honored by paste path |
| 5 | history | recover a dictation that didn't land | ⚠️ incomplete mapping, privacy misfit |
| 6 | comparison (bake-off) | measure ours vs a rival on identical audio | ⚠️ alignment invariant is a ghost |
| 7 | **engine** | choose who turns audio into text, at what cost and privacy | ❌ **missing concept** — exists in users' heads, homeless in code |
| 8 | api-key | unlock a cloud engine | ✅ mechanism under engine |

### Findings (Essence-of-Software vocabulary, ordered by user impact)

**F1 · engine: missing concept.** The picker exists in the UI; the code smears identity across
`EngineChoice`+`cloudModel` (a tandem pair), wire keys in two files, labels, `keyAvailable` checks, and a
TS dict. Consequence already observed: relaunch dictates with Apple while records claim Gemini.
*Repair:* reify `Engine` (Part 2, T1). One concept, one type, one table.

**F2 · arena-control: over-synchronization → integrity violation.** control.json applies mid-utterance;
a bake-off session ("never inserts") can insert. A session must be an atomic execution of the rules in
force at press. *Repair:* session snapshots its rules at press (T2); control application deferred
unless phase is idle/settled.

**F3 · secure-field: suppression sync that leaks.** Refusal suppresses typing only; clipboard (unconcealed),
history (plaintext), and the system log still receive content. A suppression concept must suppress every
effluent. *Repair:* sensitivity parsed at arm time into the session rules (T2); every downstream sync
(history, clipboard marking, logging) consults it.

**F4 · polish: coherence check — passes.** Four purposes (written form, densify, format, retro-correct)
reformulate without "and" as: *turn what was said into what the speaker meant to write.* Same stakeholder,
no conflict scenario (the faithful-vs-dense conflict was resolved by decision: intent-faithful IS the purpose).
Keep as one concept; the guard is its integrity protector and stays.

**F5 · history: incomplete mapping + inherited misfit.** The trash concept's known misfits include "needs an
empty action". No clear/disable action is reachable; file is 0644. *Repair:* add Clear History + History-off,
0600, and (per F3) secure sessions never recorded.

**F6 · insertion: operational principle violated.** OP: "insert(t) makes t appear at that cursor." The paste
strategy reports `inserted` on posting ⌘V, unverified — the overlay's "inserted ✓" is sometimes a lie, and
`.targetLost` hides that text went to the clipboard. *Repair:* verify where the target is readable; encode
confidence in the outcome type (T5); fold targetLost into the copied family.

**F7 · comparison: the alignment invariant is a ghost.** "record k ↔ sentence k" lives in no artifact;
retakes silently corrupt every later score; overflow rows score hearsay against itself. *Repair:* the arena
server stamps the expected sentence into a record sidecar at observation time — alignment becomes data,
not reconstruction.

**F8 · transcription: genericity violation.** Contract breaches surface as `SpeechAnalyzerFailure` for any
engine, and the shared WAV encoder throws `OpenRouterFailure`. *Repair:* concept-owned
`TranscriptionFailure` / `WavEncodingFailure` (T6).

## Part 2 — Data-structure redesign (decision procedure applied)

**T1 · `Engine` — the reified concept.** Replaces the `EngineChoice`+`cloudModel` tandem, wire-key strings,
labels, and availability checks:

```swift
enum Engine: Equatable {
    case appleLocal
    case openRouter(model: String)
    case elevenLabsScribe
}
extension Engine {
    var wireKey: String                    // total inverse pair, same file:
    init?(wireKey: String)                 // rejects garbage at the boundary (parse, don't validate)
    var label: String
    var requiredKey: String?               // "OPENROUTER_API_KEY" / "ELEVEN_LABS_API_KEY" / nil
    var isAvailable: Bool                  // requiredKey == nil || KeyStore has it
    var privacyClass: PrivacyClass         // .onDevice | .cloud(provider:) → honest UI + mic-string
    func makeTranscriber(locale: Locale) -> (any Transcriber)?
    static let all: [Engine]               // menu + arena derive from this; Parakeet = one new case
}
```
MIRO: kills illegal `(.appleLocal, model)`; kills the three redundant encodings. Settings persists
`wireKey`, parsed at load with `.appleLocal` fallback — fixing the relaunch bug by construction.

**T2 · `SessionRules` — press-time snapshot (fixes F2, F3, mislabeled records):**

```swift
struct SessionRules {
    let engine: Engine
    let mode: AppMode
    let style: WritingStyle
    let sensitivity: Sensitivity           // .normal | .secure — parsed from arm()
}
```
`LiveSession` carries `rules`; release/finish read only the snapshot. `applyPendingControl()` defers
while a session is in flight.

**T3 · `Run` union — kills LiveSession's illegal states:**

```swift
enum Run {
    case dictate(target: ArmResult)
    case bakeoff(target: InsertionTarget, baseline: String)   // armed-by-construction
}
```
A baseline-less bake-off or a rival-watched dictation becomes unrepresentable; the scattered
`if mode == .bakeoff, let target, let baseline` guards collapse into a switch.

**T4 · `SessionOutcome` carries its own data (kills the `lastTiming`/`appName` side channels):**

```swift
enum SessionOutcome {
    case landed(InsertionOutcome, InsertableText, SessionTiming, app: String)
    case compared(InsertableText, ours: Duration, rival: RivalObservation, app: String)
    case nothingHeard
    case failed(reason: String, salvaged: RawTranscript?)     // partial text preserved (M7)
}
```

**T5 · `InsertionOutcome` algebra:**

```swift
enum InsertionOutcome {
    case inserted(via: InsertionStrategy, evidence: InsertionEvidence)  // .verified | .posted
    case copiedToClipboard(InsertionBlock)   // InsertionBlock gains .targetLost
}
```

**T6 · Concept-owned errors:** `TranscriptionFailure { endedWithoutFinal, timeout }` in Transcriber.swift;
`WavEncodingFailure.conversionFailed` in the shared encoder; `SpeechAnalyzerFailure.audioConversionFailed`
split from `noCompatibleAudioFormat`. Engines keep provider-specific HTTP errors.

**T7 · Bridge boundary:** `ArenaControl.engine` parsed via `Engine(wireKey:)` — reject, log, never adopt
garbage. `polish` crosses as `rawValue` string like `mode` (information preservation).

## Part 3 — Refactor order (each step builds and ships)

1. **T1 Engine** — foundation; rewires Settings, Coordinator, ArenaBridge, MenuView, BakeoffRecord.
2. **T2+T3 SessionRules/Run** — session atomicity; control deferral.
3. **T4+T5 outcomes** — side channels out, evidence in; salvage partial on failure.
4. **T6+T7 errors & boundary parsing.**
5. **P0 mechanicals** (type-independent): log privacy, localhost bind + /control validation, honest mic
   string, scorer TENS[2], bundle.sh stale-binary, secure-field effluents, keys.env perms.
6. **P1 mechanicals**: timeout/cancellation cluster, RivalWatch cancellability + AX timeout, gesture
   delivery synchronous, URLSession timeouts, polish timeout, capture/tap re-entry guards.
7. **F7 arena sidecar** + arena perf/robustness fixes; delete bakeoff-report.py.
