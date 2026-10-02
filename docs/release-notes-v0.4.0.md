Hearsay 0.4.0 adds more on-device speech engines and a smaller native Mac dictation bar.

- Download and use Cohere Transcribe 2B, Qwen3-ASR 1.7B, Parakeet Redux or Whisper large-v3-turbo from Dictation. Downloads include progress, cancellation, retry and checksum verification. Recognition runs offline after installation; no account, API key or Python setup is required.
- Compare the local models' download sizes, measured first-run timings and supported languages. Use Bake-off to compare engines on your own speech, or run a recorded corpus with the new benchmark command for repeatable accuracy and latency reports.
- The listening bar is one quarter of its previous width and 20% shorter. A microphone and level meter show listening; cloud and comparison sessions retain their indicators. Hover for transcript or processing details, and click a result to read its full message.
- Drag the bar's grip to dim the displays and reveal bottom, left and right drop zones. The target under the pointer highlights. Release inside a zone to dock; release elsewhere or press Escape to restore the saved position. Docking preserves the typing app's keyboard focus.
- Documentation now shows the native macOS app, including the compact listening bar and docking overlay.

Install or upgrade on **Apple Silicon with macOS 26 or newer**:

```sh
brew install --cask note89/tap/hearsay
# Existing installation:
brew update
brew upgrade --cask note89/tap/hearsay
```

Or download `hearsay-0.4.0.zip`, unzip it, and move `hearsay.app` to `/Applications`. The Mac app is Developer ID signed, notarized and stapled. Apple dictation remains the default. Optional downloaded models and cloud engines are selected in Dictation.

Linux and Windows archives remain available with the existing cross-platform dictation features.
