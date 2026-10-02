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
    @State private var showingDetails = false

    private var pillOpacity: Double {
        if case .settled(_, .ok) = model.content { return 0.72 }
        return 0.9
    }

    var body: some View {
        HStack(spacing: 6) {
            DragGrip(actions: dragActions)
                .frame(width: 14, height: 28)
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1, height: 16)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .padding(.horizontal, 10)
        .frame(width: OverlayLayout.pillSize.width, height: OverlayLayout.pillSize.height)
        .background(Capsule().fill(Color.black.opacity(pillOpacity)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.content) { showingDetails = false }
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .hidden:
            EmptyView()
        case .preview:
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.white.opacity(0.8))
                Text("Move").foregroundStyle(.white.opacity(0.7))
            }
            .help("Drag the grip to the bottom, left or right drop zone. Press Escape to cancel.")
        case .listening(let partial):
            HStack(spacing: 5) {
                sessionIcon
                Waveform(levels: model.levels)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Listening\(model.badge.map { ", \($0)" } ?? "")\(partial.isEmpty ? "" : ": \(partial)")")
            .help(partial.isEmpty ? "Listening\(model.badge.map { " · \($0)" } ?? "")" : partial)
        case .working(let label):
            HStack(spacing: 6) {
                sessionIcon
                ProgressView().controlSize(.mini).tint(.white)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .help(label)
        case .settled(let message, let tone):
            Button {
                showingDetails.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: tone == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(tone == .ok ? Color.green : Color.orange)
                    Text(tone == .ok ? "Done" : message.contains("copied") ? "Copy" : "Issue")
                        .foregroundStyle(.white.opacity(tone == .ok ? 0.9 : 1))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(message)
            .help(message)
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                Text(message).font(.callout).padding(16).frame(maxWidth: 280)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sessionIcon: some View {
        Image(systemName: model.badge == nil ? "mic.fill" : model.badge?.hasPrefix("racing") == true ? "flag.checkered" : "cloud.fill")
            .font(.system(size: 12))
            .foregroundStyle(model.badge == nil ? Color.white.opacity(0.85) : Color.orange)
            .help(model.badge ?? "On-device dictation")
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
    private static let barHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2.5, height: max(3, CGFloat(levels[index]) * Self.barHeight))
            }
        }
        .frame(height: Self.barHeight)
        .animation(.linear(duration: 0.04), value: levels)
        .accessibilityLabel("Microphone level")
    }
}
