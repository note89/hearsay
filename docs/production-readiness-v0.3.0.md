# Full-Cycle Implementation Report

**Feature:** ScreenSnap-style production treatment for Hearsay: movable bar, native options, Apple signing and notarization, publication, and Homebrew installation.
**Date:** 2026-10-02
**Iterations:** 3
**Exit reason:** clean

## Plan summary

Keep the native macOS app and its offline default. Add remembered, focus-preserving bar placement and native setup/preferences; retain the existing Linux/Windows application. Reuse the working ScreenSnap Developer ID and notarization setup. Stage a release draft, require successful native and crossplatform checks, and publish the signed app through the existing Homebrew tap. “Sign-in” was interpreted as Apple code signing based on the ScreenSnap reference; no account service was added.

## Slices implemented

- Overlay agent: movable bottom/left/right docking, display clamping, retained session display, preview/reset, first-click drag grip, and geometry/preview tests.
- Application options agent: shortcut presets, pause/resume, launch at login, explicit permission setup, local Keychain key entry, General/Cloud providers/About panes, lifecycle cleanup, and synthetic credential/shortcut tests.
- Planning/release agent: hardened runtime/audio entitlement, Developer ID preference, strict release verification, notarization/stapling/checksum scripts, native CI, draft-only platform uploads, and release documentation.
- Root: manual update checks with canonical repository/asset parsing, Homebrew distribution, version consistency, Command Line Tools-compatible Swift Testing support, formatting/lint, integration verification, and publication.

## Review history

| Iteration | Confirmed issues | Warnings remaining | Result |
|---|---:|---:|---|
| 1 | 3 | 3 | Fixed workflow selection, published-asset replacement, and narrow-display cropping. |
| 2 | 0 | 0 | Independent final validation clean. |
| 3 | 1 | 0 | CI caught combined ad-hoc/runtime flags; the verifier now checks the runtime bit and independent review is clean. |

Release CI selection now includes the exact commit and creation time after the tag push starts. Platform uploads require a draft containing the expected native archive and checksum. The overlay accepts its hosting panel's size. Review also checked microphone denial, pause/release, deferred engine changes, shortcut retry/replacement, shutdown cancellation, credential fallback, and preview/fade behavior.

## Verification

- 27 Swift Testing tests passed: docking/preview, modifier holds, credential parsing/storage boundaries, and release/version parsing.
- 37 bake-off scorer/codec/summary checks passed.
- 18 Rust workspace tests passed; the updated Cargo lock file is valid with `--locked`.
- All 22 changed Swift files passed strict formatter lint; shell syntax, plist lint, workflow YAML parsing, and whitespace checks passed.
- Optimized arm64 app compiled with the hardened runtime and microphone entitlement, without compiler warnings.
- Release verification accepts Developer ID and ad-hoc hardened signatures and rejects signatures without the runtime bit. GitHub's first native CI run exposed the combined-flag parsing issue; this was corrected before publication.
- Apple notarization accepted submission `08a3a3bc-20e6-49f5-b7d7-9ac19d38ffb4`; ticket stapling and validation succeeded. Gatekeeper reported `Notarized Developer ID`.
- Native process smoke reached the main event loop and prepared the English on-device model. Computer-use automation could not attach to the accessory app, so physical dragging and live microphone-to-caret dictation were not automated.

## Distribution contract

The native app requires Apple Silicon and macOS 26 or newer. Its identifier remains `computer.borrowed.hearsay`. Keys entered in Settings stay in this Mac's Keychain; legacy key files remain readable. History/dictionary/bake-off formats are unchanged. Update checks contact GitHub only when requested. Homebrew upgrades use `brew upgrade --cask note89/tap/hearsay`.

Future publication uses `scripts/release.sh VERSION --publish`; any failed CI leaves the release in draft. The separate tap cask must receive the published archive's exact version and SHA-256. Linux/Windows archives retain their existing functionality.
