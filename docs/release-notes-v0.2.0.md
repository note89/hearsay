# hearsay v0.2.0 — Linux & Windows

hearsay now runs on all three desktops. The Mac app is unchanged; `hearsay-rs` is a Rust port with
the same concepts, the same data files and the same bake-off lab.

**New**
- `hearsay-rs` for Linux and Windows: hold Ctrl+Alt+Space, speak, release, text lands at the caret.
- whisper.cpp on-device engine (`base.en`, downloaded from the Dictation pane; `large-v3-turbo` selectable).
- OpenRouter (Gemini 2.5 Flash Lite / Flash) and ElevenLabs Scribe engines, keys via `keys.env` or env vars.
- The five panes — Dictation · Dictionary · Style · Bake-off · History — as an egui window, plus the overlay pill.
- Bake-off lab scores hearsay against any rival dictation tool on identical audio, same as on Mac.

**Known limits on Linux/Windows** (deliberate, see PLAN-CROSSPLATFORM.md)
- Batch transcription: no live partials.
- Paste-only insertion; no field context, per-app tone or secure-field detection.
- Cleanup (Light/Full) uses OpenRouter, opt-in. Off is fully local.
- Linux hotkeys need X11 or XWayland.

**Verified**: macOS GUI smoke (engine ready, hotkey registered), Linux build + tests + whisper inference
in a `rust:1` container, Windows `cargo check` of the MSVC target.
