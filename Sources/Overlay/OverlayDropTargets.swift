import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class OverlayDropTargetModel {
    let screenFrame: CGRect
    let visibleFrame: CGRect
    var highlighted: OverlayDock.Edge?

    init(screenFrame: CGRect, visibleFrame: CGRect) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
    }

    func localFrame(for edge: OverlayDock.Edge) -> CGRect {
        let frame = OverlayDropZones.frame(for: edge, in: visibleFrame)
        return CGRect(
            x: frame.minX - screenFrame.minX, y: screenFrame.maxY - frame.maxY,
            width: frame.width, height: frame.height)
    }
}

struct OverlayDropTargetView: View {
    let model: OverlayDropTargetModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.3)
            VStack(spacing: 8) {
                Text("Move your dictation bar").font(.system(size: 22, weight: .semibold))
                Text("Drop on an edge · Esc to cancel").font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .frame(width: model.screenFrame.width)
            .offset(y: max(32, model.screenFrame.height * 0.12))

            ForEach(OverlayDock.Edge.allCases, id: \.self) { edge in
                let frame = model.localFrame(for: edge)
                target(edge)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .frame(width: model.screenFrame.width, height: model.screenFrame.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drop the dictation bar at the bottom, left or right. Press Escape to cancel.")
    }

    private func target(_ edge: OverlayDock.Edge) -> some View {
        let selected = model.highlighted == edge
        return VStack(spacing: 14) {
            Image(
                systemName: edge == .bottom
                    ? "rectangle.bottomhalf.inset.filled"
                    : edge == .left ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled"
            )
            .font(.system(size: 24, weight: .medium))
            Text(edge.rawValue.capitalized).font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(selected ? 1 : 0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial.opacity(selected ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 24))
        .background(Color.white.opacity(selected ? 0.18 : 0.03), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(
                    .white.opacity(selected ? 0.9 : 0.3), style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [6, 5]))
        }
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

private final class DropTargetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayDropTargets {
    private struct Display {
        let panel: NSPanel
        let model: OverlayDropTargetModel
    }

    private var displays: [Display] = []

    func show(at pointer: NSPoint) {
        hide()
        displays = NSScreen.screens.map { screen in
            let model = OverlayDropTargetModel(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
            let panel = DropTargetPanel(
                contentRect: screen.frame, styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = true
            let host = NSHostingView(rootView: OverlayDropTargetView(model: model))
            host.sizingOptions = []
            panel.contentView = host
            panel.orderFrontRegardless()
            return Display(panel: panel, model: model)
        }
        update(at: pointer)
    }

    func update(at pointer: NSPoint) {
        for display in displays {
            display.model.highlighted = OverlayDropZones.edge(at: pointer, in: display.model.visibleFrame)
        }
    }

    func hide() {
        for display in displays { display.panel.orderOut(nil) }
        displays.removeAll()
    }
}
