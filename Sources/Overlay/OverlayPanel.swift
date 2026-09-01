import AppKit
import Observation
import SwiftUI

public enum OverlayTone: Equatable, Sendable {
    case ok
    case warn
}

public enum OverlayPlacement: Equatable, Sendable {
    case bottom
    /// Higher up, so a rival app's pill at the bottom stays visible too.
    case raised
}

public enum OverlayState: Equatable, Sendable {
    case hidden
    case listening(partial: String)
    case working(String)
    case settled(String, OverlayTone)
}

@MainActor @Observable
final class OverlayModel {
    static let barCount = 28

    var state: OverlayState = .hidden
    var levels: [Float] = Array(repeating: 0, count: OverlayModel.barCount)

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

/// A non-activating floating pill at the bottom of the screen. Never takes focus — the target app keeps it.
@MainActor
public final class OverlayPanel {
    static let size = NSSize(width: 400, height: 64)
    private static let bottomMargin: CGFloat = 28
    private static let raisedMargin: CGFloat = 150

    private let panel: NSPanel
    private let model = OverlayModel()
    private var placement: OverlayPlacement = .bottom

    public init() {
        panel = NSPanel(
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
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    public func render(_ state: OverlayState) {
        model.state = state
        switch state {
        case .hidden:
            model.resetLevels()
            panel.orderOut(nil)
        case .listening, .working, .settled:
            show()
        }
    }

    public func meter(_ level: Float) {
        model.push(level: level)
    }

    public func place(_ placement: OverlayPlacement) {
        self.placement = placement
    }

    private func show() {
        guard !panel.isVisible else { return }
        panel.setFrameOrigin(Self.origin(on: Self.screenUnderMouse(), placement: placement))
        panel.orderFrontRegardless()
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private static func origin(on screen: NSScreen?, placement: OverlayPlacement) -> NSPoint {
        guard let frame = screen?.visibleFrame else { return .zero }
        let margin = placement == .bottom ? bottomMargin : raisedMargin
        return NSPoint(x: frame.midX - size.width / 2, y: frame.minY + margin)
    }
}
