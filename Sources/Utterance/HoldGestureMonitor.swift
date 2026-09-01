import CoreGraphics
import Foundation
import os

public enum GestureEvent {
    case pressed
    case released
}

public struct ModifierChord: Equatable {
    public let flags: CGEventFlags

    public init(flags: CGEventFlags) {
        self.flags = flags
    }

    public static let fnShift = ModifierChord(flags: [.maskSecondaryFn, .maskShift])
}

public enum GestureMonitorFailure: Error {
    case inputMonitoringDenied
    case tapCreationFailed
}

private enum ChordState {
    case up
    case down
}

/// Reports `.pressed` the moment the whole chord is held and `.released` the moment any key of it lifts.
public final class HoldGestureMonitor {
    private let chord: ModifierChord
    private let onEvent: (GestureEvent) -> Void
    private var state: ChordState = .up
    private var tap: CFMachPort?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "hearsay", category: "gesture")

    public init(chord: ModifierChord, onEvent: @escaping (GestureEvent) -> Void) {
        self.chord = chord
        self.onEvent = onEvent
    }

    public func start() throws {
        guard tap == nil else { return }
        guard CGPreflightListenEventAccess() else { throw GestureMonitorFailure.inputMonitoringDenied }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                Unmanaged<HoldGestureMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw GestureMonitorFailure.tapCreationFailed }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        stop()
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let held = event.flags.contains(chord.flags)
            log.debug("flagsChanged: flags=0x\(String(event.flags.rawValue, radix: 16), privacy: .public) key=\(event.getIntegerValueField(.keyboardEventKeycode)) chordHeld=\(held)")
            transition(chordHeld: held)
        default:
            break
        }
    }

    private func transition(chordHeld: Bool) {
        switch (state, chordHeld) {
        case (.up, true):
            state = .down
            onEvent(.pressed)
        case (.down, false):
            state = .up
            onEvent(.released)
        case (.up, false), (.down, true):
            break
        }
    }
}
