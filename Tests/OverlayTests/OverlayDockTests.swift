import Foundation
import Testing

@testable import Overlay

struct OverlayDockTests {
    private let size = CGSize(width: 460, height: 76)
    private let area = CGRect(x: -1920, y: 30, width: 1920, height: 1050)

    @Test
    func testBottomDockUsesDisplayOriginAndNormalizedCenter() {
        let frame = OverlayGeometry.frame(size: size, dock: .standard, in: area, placement: .bottom)
        #expect(frame.midX == area.midX)
        #expect(frame.minY == area.minY + OverlayGeometry.bottomGap)
        #expect(area.contains(frame))
    }

    @Test
    func testSideDocksStayInsideVisibleDisplayAtBothEnds() {
        for edge in [OverlayDock.Edge.left, .right] {
            for along in [CGFloat(0), 1] {
                let frame = OverlayGeometry.frame(size: size, dock: OverlayDock(edge: edge, along: along), in: area, placement: .bottom)
                #expect(area.contains(frame), "\(edge) at \(along) escaped the display")
            }
        }
    }

    @Test
    func testRaisedPlacementLeavesSpaceForTheOtherBarWithoutChangingDock() {
        for edge in [OverlayDock.Edge.bottom, .left, .right] {
            let dock = OverlayDock(edge: edge, along: 0)
            let frame = OverlayGeometry.frame(size: size, dock: dock, in: area, placement: .raised)
            #expect(frame.minY == area.minY + OverlayGeometry.raisedGap)
            #expect(dock.edge == edge)
        }
    }

    @Test
    func testClampingHandlesDisplaysSmallerThanTheBar() {
        let smallArea = CGRect(x: 500, y: 200, width: 300, height: 50)
        let frame = OverlayGeometry.frame(size: size, dock: .standard, in: smallArea, placement: .raised)
        #expect(frame == smallArea)
    }

    @Test
    func testClampingHandlesDragAcrossDisplaysWithDifferentOrigins() {
        let secondary = CGRect(x: 1728, y: -200, width: 1440, height: 900)
        let dragged = CGRect(x: 3120, y: -260, width: size.width, height: size.height)
        let frame = OverlayGeometry.clamping(dragged, to: secondary)
        #expect(frame.maxX == secondary.maxX)
        #expect(frame.minY == secondary.minY)
        #expect(secondary.contains(frame))
    }

    @Test
    func testDropSnapsUsingPointerButRemembersTheBarCenter() {
        let bar = CGRect(x: area.minX + 20, y: area.midY - size.height / 2, width: size.width, height: size.height)
        let pointer = CGPoint(x: area.minX + 25, y: area.midY)
        let dock = OverlayDock.dropping(bar, at: pointer, in: area)
        #expect(dock.edge == .left)
        #expect(dock.along == 0.5)
    }

    @Test
    func testDropAtBottomRemembersCenterRatherThanGripOffset() {
        let bar = CGRect(x: area.midX - size.width / 2, y: area.minY + 20, width: size.width, height: size.height)
        let pointer = CGPoint(x: bar.minX + 20, y: area.minY + 25)
        let dock = OverlayDock.dropping(bar, at: pointer, in: area)
        #expect(dock == .standard)
    }

    @Test
    func testNormalizedPositionAdaptsWhenDisplaySizeChanges() {
        let dock = OverlayDock(edge: .right, along: 0.75)
        let resized = CGRect(x: -1200, y: -300, width: 1200, height: 1600)
        let frame = OverlayGeometry.frame(size: size, dock: dock, in: resized, placement: .bottom)
        #expect(frame.midY == resized.minY + resized.height * 0.75)
        #expect(frame.maxX == resized.maxX - OverlayGeometry.sideGap)
    }

    @Test
    func testNormalizedPositionsClampAndInvalidNumbersUseCenter() {
        #expect(OverlayDock(edge: .bottom, along: -2).along == 0)
        #expect(OverlayDock(edge: .bottom, along: 4).along == 1)
        #expect(OverlayDock(edge: .bottom, along: .nan).along == 0.5)
        #expect(OverlayDock(edge: .bottom, along: .infinity).along == 0.5)
    }

    @Test
    func testDistanceSelectsTheClosestDisplayEvenBetweenScreens() {
        #expect(OverlayGeometry.distanceSquared(from: CGPoint(x: 0, y: 100), to: area) == 0)
        #expect(OverlayGeometry.distanceSquared(from: CGPoint(x: 50, y: 100), to: area) == 2500)
        #expect(OverlayGeometry.distanceSquared(from: CGPoint(x: 50, y: 0), to: area) == 3400)
    }

    @Test
    func testDockPersistsAcrossStoreInstances() throws {
        let suite = "OverlayDockTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = OverlayDock(edge: .right, along: 0.72)
        OverlayDockStore(defaults: defaults).save(original)
        let reloaded = OverlayDockStore(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reloaded.load() == original)
    }

    @Test
    func testIncompleteOrCorruptPreferenceFallsBackToStandard() throws {
        let suite = "OverlayDockTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OverlayDockStore(defaults: defaults)
        #expect(store.load() == .standard)
        defaults.set("left", forKey: "interface.dictationBar.edge")
        #expect(store.load() == .standard)
        defaults.set(Double.nan, forKey: "interface.dictationBar.along")
        #expect(store.load() == .standard)
        defaults.set("top", forKey: "interface.dictationBar.edge")
        defaults.set(0.3, forKey: "interface.dictationBar.along")
        #expect(store.load() == .standard)
    }
}
