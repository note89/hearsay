import CoreGraphics
import Foundation

public enum GestureEvent: Equatable, Sendable {
    case pressed
    case released
}

/// Supported hold shortcuts all use two modifiers, so ordinary typing never starts a recording.
public enum ModifierChord: String, CaseIterable, Identifiable, Sendable {
    case fnShift
    case fnControl
    case fnOption
    case controlShift
    case optionShift

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fnShift: return "Fn + Shift"
        case .fnControl: return "Fn + Control"
        case .fnOption: return "Fn + Option"
        case .controlShift: return "Control + Shift"
        case .optionShift: return "Option + Shift"
        }
    }

    public var flags: CGEventFlags {
        switch self {
        case .fnShift: return [.maskSecondaryFn, .maskShift]
        case .fnControl: return [.maskSecondaryFn, .maskControl]
        case .fnOption: return [.maskSecondaryFn, .maskAlternate]
        case .controlShift: return [.maskControl, .maskShift]
        case .optionShift: return [.maskAlternate, .maskShift]
        }
    }

    public func isHeld(by flags: CGEventFlags) -> Bool { flags.contains(self.flags) }
}

public enum GestureMonitorFailure: Error, Equatable {
    case inputMonitoringDenied
    case tapCreationFailed
}

struct ModifierHoldState {
    private(set) var isHeld = false

    mutating func transition(toHeld held: Bool) -> GestureEvent? {
        guard isHeld != held else { return nil }
        isHeld = held
        return held ? .pressed : .released
    }
}

/// Reports a press when the whole chord is held and a release when any of its keys lifts.
/// Start and stop on the main thread, where the event tap is installed.
public final class HoldGestureMonitor {
    public let chord: ModifierChord
    public var isHeld: Bool { state.isHeld }

    private let onEvent: (GestureEvent) -> Void
    private var state = ModifierHoldState()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

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
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else { throw GestureMonitorFailure.tapCreationFailed }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw GestureMonitorFailure.tapCreationFailed
        }

        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit { stop() }

    public func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
            self.source = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        transition(chordHeld: false)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            transition(chordHeld: chord.isHeld(by: CGEventSource.flagsState(.combinedSessionState)))
        case .flagsChanged:
            transition(chordHeld: chord.isHeld(by: event.flags))
        default:
            break
        }
    }

    private func transition(chordHeld: Bool) {
        if let event = state.transition(toHeld: chordHeld) { onEvent(event) }
    }
}
