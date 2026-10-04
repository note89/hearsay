Hearsay 0.5.0 adds Ollama cleanup and a choice of low-cost cloud cleanup models.

- In Style, choose Apple on-device, OpenRouter or Ollama. Ollama discovers models from your local server; select an installed instruction model. Missing models and unavailable servers keep the original transcript.
- OpenRouter cleanup offers GLM 5.3 Flash, Gemini 3.8 Flash and Gemini 3.5 Flash-Lite, with current token prices shown in the app. GLM is the initial cloud choice. Requests use the lowest supported reasoning setting and route within the displayed price limits.
- The model and provider selected when dictation begins stay with that dictation. External cleanup receives only the transcript and dictionary terms; text around the cursor stays on this Mac. Apple on-device remains the default provider.
- The recorded benchmark command can also use an explicitly selected Ollama model.
- Native macOS documentation screenshots have transparent window corners and a subtle framed background.

Install or upgrade on **Apple Silicon with macOS 26 or newer**:

```sh
brew install --cask note89/tap/hearsay
# Existing installation:
brew update
brew upgrade --cask note89/tap/hearsay
```

Or download `hearsay-0.5.0.zip`, unzip it, and move `hearsay.app` to `/Applications`. The Mac app is Developer ID signed, notarized and stapled.

Linux and Windows retain the existing dictation features and now use GLM 5.3 Flash for cloud cleanup. Ollama selection is available in the native macOS app.
