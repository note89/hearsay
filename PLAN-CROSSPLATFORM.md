# hearsay for Linux & Windows — plan (2026-09-02)

## Decision

One **Rust core** for Linux + Windows with an **egui** skin; the macOS app stays Swift. Rust is where the
deep integration lives (hotkey, audio, inference, insertion) — the UI framework is incidental. egui over
Tauri because it is pure Rust, one binary, no Node toolchain, and its multi-viewport support gives us the
transparent always-on-top overlay for free. Tauri remains a drop-in alternative skin if a web UI is wanted.

Developed and smoke-tested on macOS (all crates build here), **built and tested for real on Linux inside
Docker**, compile-checked for Windows (no Windows machine available — stated, not hidden).

## Concept transfer

The concepts are the product and do not change. Only the mechanisms behind them do.

| Concept | macOS mechanism (Swift) | Linux/Windows mechanism (Rust) | Degradation, stated |
|---|---|---|---|
| utterance | CGEvent tap, fn+shift | `global-hotkey` pressed/released, default Ctrl+Alt+Space (configurable) | fn is not a modifier off-Mac; X11 only on Linux (Wayland unsupported by the crate) |
| transcription | Apple SpeechAnalyzer (streaming) | **whisper.cpp** via `whisper-rs`, local, batch at release, built-in language ID | no live partials (overlay shows level only); cloud engines identical to macOS (OpenRouter, ElevenLabs) |
| language | Apple engine needs a locale | whisper auto-detects → the language picker does not exist here (`needs_locale = false` for every engine) | none — an improvement |
| polish | Apple FoundationModels (on-device) | OpenRouter LLM polish, opt-in, same instructions + guard; local llama.cpp is the planned next engine | default **off** on these platforms: no on-device LLM in v1, so the "never leaves the machine" promise holds for the default path |
| insertion | AX write, verified; paste fallback | clipboard + Ctrl+V via `enigo`/`arboard`, transient marking not portable | evidence is always `posted`; no secure-field detection (no portable focus-role API) — documented |
| field context | AX read around cursor | — | not available; the concept is state of polish and simply stays empty |
| overlay | NSPanel | egui secondary viewport: transparent, always-on-top, non-focusable | — |
| history / dictionary / keys | files in Application Support | **identical formats and file names** under the platform data dir (`directories` crate) | none — data is portable between the two apps |
| comparison (bake-off) | RivalWatch reads the field via AX | the arena is our own egui text buffer, so the rival's inserted text is read directly | stronger than AX, not weaker |
| engine | `Engine` enum, wire keys | same wire keys (`apple-local` absent); new `whisper/<model>` keys | — |

Syncs live only in the session coordinator (a port of the Swift `Coordinator` as a state machine over
backend traits). Concept modules never import each other.

## Data structures (ported, MIRO-clean by construction)

`SessionRules { engine, style, polish, lexicon }` snapshotted at press · `SessionPlan { Dictate(DictationDestination) | Bakeoff { target, expected, run_id } }` ·
`Phase { Idle | Listening(Session) | Finishing(Session, Step) | Settled(Outcome) }` ·
`SessionOutcome { Landed{..}, Compared{..}, NothingHeard, Failed{reason, salvaged, app} }` ·
`InsertionOutcome { Inserted{via, evidence} | CopiedToClipboard(Block) }` · `RivalOutcome` union ·
`Engine { Whisper(WhisperModel) | OpenRouter(OpenRouterModel) | ElevenLabsScribe }` with `wire_key` ⇄ `parse` total inverse ·
provenance-carrying `InsertableText { Polished, Raw, Rewritten{over} }` · `PolishVerdict` + guard constants.

## Crate layout (Parnas: general never depends on specific)

```
crossplatform/
  Cargo.toml                 workspace
  crates/core/               concepts, no platform deps
    scorer.rs lexicon.rs polish.rs (guard + prompt) engine.rs keystore.rs history.rs
    bakeoff.rs (script, store, RunSummary) wav.rs session.rs (state machine over traits)
  crates/backends/           traits + implementations
    audio.rs (cpal)  hotkey.rs (global-hotkey)  insert.rs (enigo + arboard)
  crates/engines/            Transcriber/Polisher impls: whisper (feature local-stt), openrouter, elevenlabs
  crates/app/                eframe binary: overlay viewport, panes (Dictation · Dictionary · Style · Bake-off · History), wiring
```

## Verification

1. `cargo test` (macOS): scorer (all 24 cases ported), lexicon, guard, session state machine with mock backends, keystore parsing, RunSummary.
2. macOS smoke: `hearsay-rs transcribe sample.wav` (whisper base.en) → text; full loop hotkey→record→transcribe→paste into TextEdit.
3. **Linux, for real**: `docker run rust:1` with cmake/alsa/x11/xdo dev packages → `cargo build --release && cargo test` in the container.
4. Windows: `rustup target add x86_64-pc-windows-msvc` + `cargo check --target … --no-default-features` (everything except the C++ whisper build). Runtime unverified — README says so.

## Build order (each step compiles and is committed)

1. Workspace + core crate with tests green
2. Engines crate: whisper + cloud; CLI smoke `transcribe`
3. Backends crate: audio/hotkey/insert; CLI smoke `listen`
4. App crate: overlay + panes; full macOS loop
5. Linux container build/test; Windows check
6. README section + release notes; both apps share the data-file formats

## Addendum 2026-09-02 — Gemini 3.5 Transcribe Live, OpenRouter 3.x (both apps)

**Concept change.** *transcription* gets a second shape. A batch engine takes the whole utterance at
release; a **live** engine takes audio while the key is held and returns partials, so the wait at
release is only the tail of the stream. Same purpose, same principle (one utterance in, one final
out), different mechanism.

**State of a live take** (MIRO-checked):

| state | meaning |
|---|---|
| `Streaming { committed: [segment], interim }` | key held; server commits segments at pauses, `interim` is its current guess |
| `Draining` | key released, `audioStreamEnd` sent, waiting for the last commit |
| `Done(RawTranscript)` / `Failed(reason)` | final text = committed segments joined; interim never lands unless committed |

Partial shown in the pill = committed + interim. Draining ends on the first of: server `turnComplete`,
socket close, 300 ms of quiet after a post-end commit, 6 s hard cap (interim salvaged if nothing was
committed).

**Syncs** (coordinator only):

- dictionary → transcription: lexicon terms become `customVocabulary` (≤ 1000).
- style → transcription: mode `SMART` iff polish ≠ Off — the model's own filler removal and number
  formatting, zero extra latency. The polisher still runs as configured; the guard is unchanged.
  Off = `VERBATIM`: what was said.
- language: always auto (empty `languageCodes`). Mid-sentence mixing is the reason this engine exists.
- Every engine now receives the same `TranscriptionHints { vocabulary, mode }`; batch engines ignore
  what they cannot use. One door for the dictionary → transcription sync, not a per-engine setter.

**Mechanism.** `wss://…/BidiGenerateContent?key=…`; `setup { model, inputAudioTranscription }`;
`realtimeInput.audio` (pcm16 mono 16 kHz, ~100 ms chunks) then `realtimeInput.audioStreamEnd`;
`serverContent.interimInputTranscription` / `inputTranscription`. macOS: `URLSessionWebSocketTask`
behind the existing `Transcriber` protocol. Rust: `tungstenite` on a session thread (30 ms read
timeout so chunk sends and reads interleave), `LiveTranscriber` / `LiveTranscription` traits in core,
`EngineHandle = Batch | Live` in the app, `Recording::take_new()` drains fresh 16 kHz samples each frame.

Key `GEMINI_API_KEY`. Price ≈ $6 per 100k words ($0.005/min audio in + $0.004/min text out); free
tier while in preview. Wire key `google/gemini-3.5-transcribe-live`.

**OpenRouter.** 2.5 → `google/gemini-3.5-flash-lite` (~$0.70 / 100k words) and `google/gemini-3.7-flash`
(~$1.45); the Rust polisher default follows to 3.5-flash-lite. Old wire keys stop parsing: settings
fall back to the default engine, archived bake-off rows keep their strings.
