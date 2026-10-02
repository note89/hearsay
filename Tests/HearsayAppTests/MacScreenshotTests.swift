import AppKit
import History
import Lexicon
import ScreenCaptureKit
import SwiftUI
import Testing

@testable import Overlay
@testable import hearsay

/// Opt-in documentation captures of the production views, with an isolated sample data folder.
struct MacScreenshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEARSAY_SCREENSHOT_DIR"] != nil))
    @MainActor func captureMacScreenshots() async throws {
        let destination = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HEARSAY_SCREENSHOT_DIR"]))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearsay-screenshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = Coordinator(directory: directory)
        defer { coordinator.stop() }
        Lexicon.save(
            [.term("Hearsay"), .term("SwiftUI"), .term("mprocs"), .rewrite(from: "mprox", to: "mprocs")],
            to: directory.appendingPathComponent("dictionary.txt"))
        coordinator.history.record(
            DictationRecord(
                spoken: "hey um can you send the updated design by friday",
                delivered: "Can you send the updated design by Friday?", appName: "TextEdit", outcome: .inserted))

        _ = NSApplication.shared
        try #require(CGPreflightScreenCaptureAccess(), "Native documentation captures need existing Screen Recording access.")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try checkDockingLifecycle()
        for section in [SettingsSection.general, .dictation, .style, .dictionary, .bakeoff, .history] {
            let view = SettingsWindowView(coordinator: coordinator, initialSection: section)
            try await capture(
                view, size: CGSize(width: 1020, height: section == .dictation ? 1160 : 820),
                titled: true,
                to: destination.appendingPathComponent("macos-\(section.rawValue.lowercased().replacingOccurrences(of: "-", with: "")).png")
            )
        }

        let model = OverlayModel()
        model.content = .listening(partial: "")
        let levels: [Float] = [0.2, 0.45, 0.8, 0.5, 0.9, 0.65, 0.35, 0.15]
        for level in levels { model.push(level: level) }
        let actions = OverlayDragActions(began: { _ in }, moved: { _ in }, ended: { _ in }, reset: {})
        try await capture(
            OverlayView(model: model, dragActions: actions), size: OverlayLayout.panelSize,
            titled: false, to: destination.appendingPathComponent("macos-pill.png"))

        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let targets = OverlayDropTargetModel(screenFrame: frame, visibleFrame: frame.insetBy(dx: 0, dy: 24))
        targets.highlighted = .bottom
        let docking = ZStack {
            Color(nsColor: .windowBackgroundColor)
            SettingsWindowView(coordinator: coordinator, initialSection: .general)
                .frame(width: 920, height: 740)
            OverlayDropTargetView(model: targets)
        }
        try await capture(docking, size: frame.size, titled: false, to: destination.appendingPathComponent("macos-docking.png"))
    }

    @MainActor private func checkDockingLifecycle() throws {
        let screen = try #require(NSScreen.screens.first)
        let suite = "MacScreenshotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = OverlayDock(edge: .right, along: 0.65)
        let store = OverlayDockStore(defaults: defaults)
        store.save(original)
        let previousKeyWindow = NSApp.keyWindow
        let overlay = OverlayPanel(defaults: defaults)
        defer { overlay.endPreview() }
        overlay.preview()
        let start = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        overlay.dragBegan(at: start)
        let targets = NSApp.windows.filter { $0.isVisible && $0.ignoresMouseEvents && $0.level == .statusBar }
        #expect(targets.count == NSScreen.screens.count)
        #expect(targets.allSatisfy { !$0.canBecomeKey && !$0.canBecomeMain })
        #expect(NSApp.keyWindow === previousKeyWindow)

        overlay.dragMoved(to: start)
        overlay.dragEnded(at: start)
        #expect(store.load() == original)
        #expect(targets.allSatisfy { !$0.isVisible })

        let zone = OverlayDropZones.frame(for: .bottom, in: screen.visibleFrame)
        let destination = CGPoint(x: zone.midX, y: zone.midY)
        overlay.dragBegan(at: start)
        overlay.dragMoved(to: destination)
        overlay.dragEnded(at: destination)
        #expect(store.load().edge == .bottom)

        overlay.dragBegan(at: start)
        overlay.endPreview()
        #expect(!NSApp.windows.contains { $0.isVisible && $0.ignoresMouseEvents && $0.level == .statusBar })
        #expect(NSApp.keyWindow === previousKeyWindow)
    }

    @MainActor private func capture<Content: View>(_ content: Content, size: CGSize, titled: Bool, to url: URL) async throws {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: titled ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless],
            backing: .buffered, defer: false)
        window.title = "Hearsay"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = titled
        window.backgroundColor = titled ? .windowBackgroundColor : .clear
        let host = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
        host.sizingOptions = []
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        window.center()
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let capturedWindow = try #require(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = titled
        print("Capturing \(url.lastPathComponent)")
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: capturedWindow), configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
