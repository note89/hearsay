import Foundation

/// The screen edge and normalized position where the dictation bar was dropped.
struct OverlayDock: Equatable {
    enum Edge: String, CaseIterable {
        case bottom
        case left
        case right
    }

    let edge: Edge
    let along: CGFloat

    static let standard = OverlayDock(edge: .bottom, along: 0.5)

    init(edge: Edge, along: CGFloat) {
        self.edge = edge
        self.along = along.isFinite ? min(max(along, 0), 1) : 0.5
    }

    static func dropping(_ bar: CGRect, at pointer: CGPoint, in area: CGRect) -> OverlayDock? {
        guard let edge = OverlayDropZones.edge(at: pointer, in: area) else { return nil }
        let along =
            edge == .bottom
            ? (bar.midX - area.minX) / max(area.width, 1)
            : (bar.midY - area.minY) / max(area.height, 1)
        return OverlayDock(edge: edge, along: along)
    }
}

enum OverlayLayout {
    static let pillSize = CGSize(width: 109, height: 40)
    static let panelSize = CGSize(width: pillSize.width + 24, height: pillSize.height + 26)
}

enum OverlayDropZones {
    static func frame(for edge: OverlayDock.Edge, in area: CGRect) -> CGRect {
        let inset = min(24, min(area.width, area.height) * 0.04)
        switch edge {
        case .bottom:
            let size = CGSize(width: min(320, area.width * 0.4), height: min(104, area.height * 0.18))
            return CGRect(x: area.midX - size.width / 2, y: area.minY + inset, width: size.width, height: size.height)
        case .left, .right:
            let size = CGSize(width: min(156, area.width * 0.2), height: min(280, area.height * 0.5))
            let x = edge == .left ? area.minX + inset : area.maxX - inset - size.width
            return CGRect(x: x, y: area.midY - size.height / 2, width: size.width, height: size.height)
        }
    }

    static func edge(at pointer: CGPoint, in area: CGRect) -> OverlayDock.Edge? {
        OverlayDock.Edge.allCases.first { frame(for: $0, in: area).contains(pointer) }
    }
}

struct OverlayGeometry {
    static let bottomGap: CGFloat = 28
    static let raisedGap: CGFloat = 150
    static let sideGap: CGFloat = 8

    static func frame(size: CGSize, dock: OverlayDock, in area: CGRect, placement: OverlayPlacement) -> CGRect {
        let bottomClearance = placement == .raised ? raisedGap : bottomGap
        let alongX = area.minX + dock.along * area.width - size.width / 2
        let alongY = area.minY + dock.along * area.height - size.height / 2
        let origin: CGPoint
        switch dock.edge {
        case .bottom:
            origin = CGPoint(x: alongX, y: area.minY + bottomClearance)
        case .left:
            origin = CGPoint(x: area.minX + sideGap, y: max(alongY, area.minY + bottomClearance))
        case .right:
            origin = CGPoint(x: area.maxX - size.width - sideGap, y: max(alongY, area.minY + bottomClearance))
        }
        return clamping(CGRect(origin: origin, size: size), to: area)
    }

    static func clamping(_ bar: CGRect, to area: CGRect) -> CGRect {
        let size = CGSize(width: min(bar.width, area.width), height: min(bar.height, area.height))
        let origin = CGPoint(
            x: min(max(bar.minX, area.minX), area.maxX - size.width),
            y: min(max(bar.minY, area.minY), area.maxY - size.height)
        )
        return CGRect(origin: origin, size: size)
    }

    static func distanceSquared(from point: CGPoint, to area: CGRect) -> CGFloat {
        let dx = max(area.minX - point.x, 0, point.x - area.maxX)
        let dy = max(area.minY - point.y, 0, point.y - area.maxY)
        return dx * dx + dy * dy
    }
}

struct OverlayDockStore {
    private enum Key {
        static let edge = "interface.dictationBar.edge"
        static let along = "interface.dictationBar.along"
    }

    let defaults: UserDefaults

    func load() -> OverlayDock {
        guard let rawEdge = defaults.string(forKey: Key.edge),
            let edge = OverlayDock.Edge(rawValue: rawEdge),
            let number = defaults.object(forKey: Key.along) as? NSNumber,
            number.doubleValue.isFinite
        else { return .standard }
        return OverlayDock(edge: edge, along: CGFloat(number.doubleValue))
    }

    func save(_ dock: OverlayDock) {
        defaults.set(dock.edge.rawValue, forKey: Key.edge)
        defaults.set(Double(dock.along), forKey: Key.along)
    }
}
