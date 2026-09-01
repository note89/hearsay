# hearsay

Hold **fn+shift**, speak, release. The words land where your cursor was. Nothing leaves the Mac.

- Speech → text: Apple `SpeechAnalyzer` (macOS 26, on-device, Neural Engine)
- Cleanup: Apple `FoundationModels` (on-device ~3B LLM), guarded so it can't change your meaning
- Insert: accessibility API → clipboard-paste fallback; failures land in History (menu bar) and on the clipboard

See `PLAN.md` for the concept design and the bet against Wispr Flow.

## Run

```sh
scripts/run.sh          # build → build/hearsay.app → launch (waveform icon in menu bar)
scripts/logs.sh         # live timings: transcribe / polish / insert in ms
```

Requires Command Line Tools 26+ (`softwareupdate -i "Command Line Tools for Xcode 26.6-26.6"`). No Xcode needed.

## First launch — three permissions

macOS asks once per app signature:

1. **Microphone** — click Allow on the prompt.
2. **Accessibility** — System Settings → Privacy & Security → Accessibility → enable *hearsay*.
3. **Input Monitoring** — same place → Input Monitoring → enable *hearsay*.

Then menu bar → **Relaunch**. Status line should read "hold fn+shift to dictate".

## Stable signature (do once, or you re-grant after every rebuild)

Ad-hoc signatures change on every build, and macOS keys permissions to the signature. Create and trust a local self-signed certificate (one command does both, asks for your password once):

```sh
scripts/fix-permissions.sh
```

Next `scripts/run.sh` signs with it; the first time, macOS asks whether `codesign` may use the key — choose **Always Allow**.
Re-grant the three permissions one last time after that.

## Bake-off against Wispr Flow (same audio, same key-up, one clock)

Menu bar → Open hearsay… → **Bake-off**. Both apps listen for fn+shift and share the microphone, so one
hold feeds identical audio to both. In bake-off mode hearsay never inserts — it watches the pane's text
box (a normal field, which Wispr types into), captures the rival's text and latency on the same clock,
and scores both against the on-screen script sentence. Each record stores the sentence it was a take of,
so retakes can't shift the scoring. Word error rate is computed over normalized tokens — numeral style,
units, ordinals and contractions never count as errors ("5ms" ≡ "five milliseconds"). Records live in
`~/Library/Application Support/hearsay/bakeoff.jsonl`; **Reset run** archives them.

## Cloud comparison engines & API keys

The default engine is Apple, fully on-device, no key, no network. The optional comparison engines need keys:

| Engine | Key | Get it |
|---|---|---|
| OpenRouter · Gemini Flash-Lite / Flash | `OPENROUTER_API_KEY` | https://openrouter.ai/keys |
| ElevenLabs · Scribe | `ELEVEN_LABS_API_KEY` | https://elevenlabs.io |

Menu bar → Engine → **API Keys…** opens `~/Library/Application Support/hearsay/keys.env` (created with a template,
chmod 600). Environment variables and an `export` line in `~/.zshrc` also work. Engines without a key show
"needs key" in the menu and stay disabled. Note: ElevenLabs is *not* reachable via OpenRouter — separate key.

## The hearsay window

Menu bar → **Open hearsay…** for the full UI: engine cards (privacy-tagged, key-aware), language,
field-context toggle and permission status under **Dictation**; a searchable add/delete **Dictionary**
list (the plain text file stays the source of truth — both stay in sync); **Style** with three cleanup
levels shown as example outputs — Off / Light (punctuation and fillers, your wording kept) / Full
(intent-dense, the default) — plus the app→tone table; and **History** with per-record copy/delete.
The menu bar menu keeps the quick controls.

## Field context & dictionary

- **Field context** (menu toggle, default on): at press, hearsay reads ~600 chars around your cursor via
  accessibility and hands them to the *on-device* polish model as terminology reference. Because polish always
  runs locally, this context never leaves the Mac — even when a cloud transcription engine is selected. It is
  never logged and never stored.
- **Dictionary** (menu → Dictionary…): a plain text file, one entry per line. `mprocs` = prefer this exact
  spelling; `mprox -> mprocs` = deterministic rewrite applied after polish (works even with polish off).
  Entries are only ever added by you — hearsay never learns words behind your back.

## Where the decisions live

- `Sources/Insertion/Inserter.swift` → `Inserter.strategies(for:)` — which insertion strategies, in which order, per target (`DECISION_INSERTION_POLICY`)
- `Sources/Polish/Polisher.swift` → `PolishGuard.verdict(spoken:candidate:)` — when the cleanup model "changed your meaning" and we keep the raw transcript (`DECISION_POLISH_GUARD`)
- `Sources/hearsay/StyleInference.swift` — which apps get chat / email / code style
- `Sources/Utterance/HoldGestureMonitor.swift` → `ModifierChord.fnShift` — the hotkey

## License

GPLv3 — see [LICENSE](LICENSE). © 2026 Nils Eriksson.
