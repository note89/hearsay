Hearsay 0.3.0 makes the native macOS app ready for everyday installation and use.

- Drag the floating dictation bar into place. Its position is remembered, stays within the display, and keeps your typing app focused. General options include a preview and position reset.
- Choose a dictation shortcut, pause dictation, and enable launch at login. Permission status refreshes when you return from System Settings.
- Enter optional API keys in Cloud providers and save them in the macOS login Keychain. On-device dictation remains the default and requires no account or API key.
- Check for updates from About and open the latest release. Homebrew installations update with `brew upgrade --cask note89/tap/hearsay`.
- The macOS app now uses an Apple Developer ID, hardened runtime, secure signing timestamp, Apple notarization and a stapled ticket. Its bundle identifier stays `computer.borrowed.hearsay`.
- Native macOS CI tests the Swift modules and bake-off scorer and verifies the hardened runtime bundle. Crossplatform releases attach their archives only after the build and NixOS checks pass.

Install on **Apple Silicon with macOS 26 or newer**:

```sh
brew install --cask note89/tap/hearsay
```

Or download `hearsay-0.3.0.zip`, unzip it, and move `hearsay.app` to `/Applications`. Grant Microphone, Accessibility and Input Monitoring on first launch. An upgrade from an older self-signed build may ask you to grant permissions once again.

The existing Linux and Windows app remains available through its platform archives. macOS Keychain entries stay on the Mac; history, dictionary and bake-off files retain their existing formats.
