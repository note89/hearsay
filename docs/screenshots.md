# macOS screenshots

Run `scripts/screenshots.sh` on a Mac to refresh the README images. The opt-in capture test uses the production SwiftUI views in native AppKit windows, captured at 2× resolution with ScreenCaptureKit. Existing Screen Recording access is required for this development command; it never requests a new permission. Hearsay itself does not need Screen Recording access.

Dictionary and history examples come from a temporary sample data folder that is removed after capture. The command does not read the user's dictionary, history or comparison results, and does not start microphone capture, model downloads or transcription. The docking image demonstrates the real overlay over a sample settings window; the waveform uses sample levels.

The Linux screenshots remain available as `linux-*.png` for the cross-platform documentation.
