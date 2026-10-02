import AppKit
import Observation
import SwiftUI

public enum OverlayTone: Equatable, Sendable {
    case ok
    case warn
}

public enum OverlayPlacement: Equatable, Sendable {
    case bottom
    /// Leaves room for a rival app's dictation bar during a comparison.
    case raised
}

public enum OverlayState: Equatable, Sendable {
    case hidden
    case listening(partial: String)
    case working(String)
    case settled(String, OverlayTone)
}

enum OverlayContent: Equatable {
    case hidden
    case preview
    case listening(partial: String)
    case working(String)
    case settled(String, OverlayTone)

    init(_ state: OverlayState) {
        switch state {
        case .hidden: self = .hidden
        case .listening(let partial): self = .listening(partial: partial)
        case .working(let label): self = .working(label)
        case .settled(let message, let tone): self = .settled(message, tone)
        }
    }
}

@MainActor @Observable
final class OverlayModel {
    static let barCount = 22

    var content: OverlayContent = .hidden
    var badge: String?
    var levels: [Float] = Array(repeating: 0, count: OverlayModel.barCount)

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level.isFinite ? min(max(level, 0), 1) : 0)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }

    func preparePreview() {
        switch content {
        case .hidden, .preview, .settled:
            content = .preview
            resetLevels()
        case .listening, .working:
            return
        }
    }
}

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A draggable dictation bar that leaves keyboard focus with the app receiving text.
@MainActor
public final class OverlayPanel {
    static let size = NSSize(width: 460, height: 76)
    private static let fadeOut: TimeInterval = 0.22

    private enum Visibility {
        case hidden
        case shown(displayID: CGDirectDisplayID?)
    }

    private struct Drag {
        let pointer: NSPoint
        let origin: NSPoint
    }

    private let panel: NSPanel
    private let model = OverlayModel()
    private let dockStore: OverlayDockStore
    private var dock: OverlayDock
    private var placement: OverlayPlacement = .bottom
    private var visibility = Visibility.hidden
    private var drag: Drag?
    private var screenObserver: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard) {
        dockStore = OverlayDockStore(defaults: defaults)
        dock = dockStore.load()
        panel = DictationPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        let dragActions = OverlayDragActions(
            began: { [weak self] in self?.dragBegan(at: $0) },
            moved: { [weak self] in self?.dragMoved(to: $0) },
            ended: { [weak self] in self?.dragEnded(at: $0) },
            reset: { [weak self] in self?.resetPosition() }
        )
        let host = FirstMouseHostingView(rootView: OverlayView(model: model, dragActions: dragActions))
        host.sizingOptions = []
        panel.contentView = host
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.relayout() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    public func render(_ state: OverlayState) {
        let wasPreview = model.content == .preview
        model.content = OverlayContent(state)
        switch state {
        case .hidden:
            model.resetLevels()
            hide()
        case .listening, .working, .settled:
            if wasPreview { visibility = .hidden }
            show()
        }
    }

    public func meter(_ level: Float) {
        model.push(level: level)
    }

    public func setBadge(_ badge: String?) {
        model.badge = badge
    }

    public func place(_ placement: OverlayPlacement) {
        self.placement = placement
        relayout()
    }

    /// Settings can show the bar for positioning without starting microphone capture.
    public func preview() {
        model.preparePreview()
        guard model.content == .preview else { return }
        placement = .bottom
        show()
    }

    public func endPreview() {
        guard model.content == .preview else { return }
        model.content = .hidden
        hide()
    }

    public func resetPosition() {
        dock = .standard
        dockStore.save(dock)
        drag = nil
        relayout()
    }

    func dragBegan(at pointer: NSPoint) {
        drag = Drag(pointer: pointer, origin: panel.frame.origin)
    }

    func dragMoved(to pointer: NSPoint) {
        guard let drag else { return }
        let origin = NSPoint(
            x: drag.origin.x + pointer.x - drag.pointer.x,
            y: drag.origin.y + pointer.y - drag.pointer.y
        )
        let frame = NSRect(origin: origin, size: Self.size)
        let area = Self.screen(at: pointer)?.visibleFrame
        panel.setFrame(area.map { OverlayGeometry.clamping(frame, to: $0) } ?? frame, display: true)
    }

    func dragEnded(at pointer: NSPoint) {
        guard drag != nil else { return }
        drag = nil
        if let screen = Self.screen(at: pointer) {
            visibility = .shown(displayID: Self.displayID(of: screen))
            dock = OverlayDock.dropping(panel.frame, at: pointer, in: screen.visibleFrame)
            dockStore.save(dock)
        }
        relayout(animated: true)
    }

    private func show() {
        if case .hidden = visibility {
            visibility = .shown(displayID: Self.screen(at: NSEvent.mouseLocation).flatMap(Self.displayID(of:)))
        }
        relayout()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func hide() {
        visibility = .hidden
        drag = nil
        let panel = panel
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = Self.fadeOut
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.model.content == .hidden, case .hidden = self.visibility else { return }
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                }
            })
    }

    private func relayout(animated: Bool = false) {
        guard drag == nil, case .shown(let displayID) = visibility else { return }
        let screen =
            NSScreen.screens.first { Self.displayID(of: $0) == displayID }
            ?? Self.screen(at: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        guard let screen else { return }
        visibility = .shown(displayID: Self.displayID(of: screen))
        let frame = OverlayGeometry.frame(size: Self.size, dock: dock, in: screen.visibleFrame, placement: placement)
        if frame != panel.frame { panel.setFrame(frame, display: true, animate: animated) }
    }

    private static func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.min {
            OverlayGeometry.distanceSquared(from: point, to: $0.frame)
                < OverlayGeometry.distanceSquared(from: point, to: $1.frame)
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
