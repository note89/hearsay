# hearsay v0.2.0 — Linux & Windows, the race, mixed languages

hearsay now runs on all three desktops. `hearsay.app` is the Mac app; `hearsay-rs` is the Rust port with
the same concepts, the same data files and the same bake-off lab.

**New**
- `hearsay-rs` for Linux and Windows: hold Ctrl+Alt+Space, speak, release. whisper.cpp on-device (`base.en`
  or `large-v3-turbo`, downloaded from the Dictation pane with progress). Wayland sessions supported: the
  chord is read from the keyboard devices, the text goes to the clipboard.
- Engines: ElevenLabs Scribe v2, Gemini 3.5 Transcribe Live (streaming, partials in the pill on every
  platform), Gemini 3.7 Flash via OpenRouter. Mixed-language dictation (svengelska) works on all three.
- API keys are found automatically (environment, `keys.env`, shell profile) and can be pasted in the app.
- The bake-off is a race: one take feeds every ticked engine, a leaderboard by WER and latency, each
  engine's record against the rival, failures counted. Ten-sentence script with Swedish, svengelska and
  Portuguese. Both apps.
- Every engine receives dictionary terms as vocabulary hints.
- Overlay: good news is a glance (700 ms, fading), warnings stay readable.

**Known limits on Linux/Windows** (deliberate, see PLAN-CROSSPLATFORM.md)
- Local whisper is batch: no live partials (Gemini 3.5 Transcribe streams).
- Paste-only insertion; no field context, per-app tone or secure-field detection.
- Cleanup (Light/Full) uses OpenRouter, opt-in. Off is fully local.
- Prebuilt binaries run whisper on the CPU; GPU back ends are build-from-source features.

**Verified**: macOS build and bake-off tests; Linux x86_64, Windows x86_64 and macOS built and tested by
GitHub Actions, Linux window smoke-tested under Xvfb; Windows with whisper compiled on MSVC.

**Assets**: `hearsay-0.2.0.zip` (macOS app, local certificate — right-click → Open), `hearsay-rs-linux-x86_64.zip`,
`hearsay-rs-windows-x86_64.zip`, `hearsay-rs-macos-arm64.zip` (the Rust app on a Mac, for comparison runs).
