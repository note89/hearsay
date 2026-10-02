import AppKit
import SwiftUI

struct OverlayDragActions {
    let began: (NSPoint) -> Void
    let moved: (NSPoint) -> Void
    let ended: (NSPoint) -> Void
    let reset: () -> Void
}

struct OverlayView: View {
    let model: OverlayModel
    let dragActions: OverlayDragActions

    private static let pillHeight: CGFloat = 50

    private var pillOpacity: Double {
        if case .settled(_, .ok) = model.content { return 0.72 }
        return 0.9
    }

    var body: some View {
        HStack(spacing: 10) {
            DragGrip(actions: dragActions)
                .frame(width: 22, height: 30)
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1, height: 20)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .padding(.horizontal, 14)
        .frame(height: Self.pillHeight)
        .frame(maxWidth: OverlayPanel.size.width - 24)
        .background(Capsule().fill(Color.black.opacity(pillOpacity)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .hidden:
            EmptyView()
        case .preview:
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move your dictation bar").foregroundStyle(.white)
                    Text("Drag the grip to a screen edge")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        case .listening(let partial):
            HStack(spacing: 10) {
                privacyBadge
                Waveform(levels: model.levels)
                Text(partial.isEmpty ? "Listening…" : partial)
                    .foregroundStyle(partial.isEmpty ? Color.white.opacity(0.6) : Color.white)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .working(let label):
            HStack(spacing: 10) {
                privacyBadge
                ProgressView().controlSize(.small).tint(.white)
                Text(label)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        case .settled(let message, let tone):
            HStack(spacing: 10) {
                Image(systemName: tone == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tone == .ok ? Color.green : Color.orange)
                Text(message)
                    .foregroundStyle(.white.opacity(tone == .ok ? 0.9 : 1))
                    .lineLimit(tone == .ok ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var privacyBadge: some View {
        if let badge = model.badge {
            Text(badge)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.6), lineWidth: 1))
                .fixedSize()
                .accessibilityLabel("Session mode: \(badge)")
        }
    }
}

private struct DragGrip: NSViewRepresentable {
    let actions: OverlayDragActions

    func makeNSView(context: Context) -> DragGripView {
        DragGripView(actions: actions)
    }

    func updateNSView(_ view: DragGripView, context: Context) {
        view.actions = actions
    }
}

private final class DragGripView: NSView {
    var actions: OverlayDragActions
    private var isDragging = false

    init(actions: OverlayDragActions) {
        self.actions = actions
        super.init(frame: .zero)
        toolTip = "Drag to the bottom, left or right screen edge. Double-click to reset."
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Move dictation bar")
        setAccessibilityHelp("Drag to a screen edge. Activate or double-click to reset the position.")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.45).setFill()
        for column in [-3.0, 3.0] {
            for row in [-6.0, 0.0, 6.0] {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX + column - 1.2, y: bounds.midY + row - 1.2, width: 2.4, height: 2.4)).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            actions.reset()
            return
        }
        isDragging = true
        NSCursor.closedHand.set()
        actions.began(screenPoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        actions.moved(screenPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.openHand.set()
        actions.ended(screenPoint(for: event))
    }

    override func accessibilityPerformPress() -> Bool {
        actions.reset()
        return true
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
}

private struct Waveform: View {
    let levels: [Float]
    private static let barHeight: CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: max(3, CGFloat(levels[index]) * Self.barHeight))
            }
        }
        .frame(height: Self.barHeight)
        .animation(.linear(duration: 0.04), value: levels)
        .accessibilityLabel("Microphone level")
    }
}
