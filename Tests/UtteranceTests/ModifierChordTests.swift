import CoreGraphics
import Testing

@testable import Utterance

struct ModifierChordTests {
    @Test func everyPresetRequiresBothOfItsModifiers() {
        let modifierFlags: [CGEventFlags] = [.maskSecondaryFn, .maskControl, .maskAlternate, .maskShift]
        for chord in ModifierChord.allCases {
            #expect(chord.isHeld(by: chord.flags), "\(chord.rawValue)")
            #expect(!chord.isHeld(by: []), "\(chord.rawValue)")
            for modifier in modifierFlags where chord.flags.contains(modifier) {
                #expect(!chord.isHeld(by: chord.flags.subtracting(modifier)), "\(chord.rawValue)")
            }
            #expect(chord.isHeld(by: chord.flags.union(.maskAlphaShift)), "\(chord.rawValue)")
        }
    }

    @Test func persistedPresetsRoundTripAndUnknownShortcutIsRejected() {
        for chord in ModifierChord.allCases {
            #expect(ModifierChord(rawValue: chord.rawValue) == chord)
        }
        #expect(ModifierChord(rawValue: "commandOnly") == nil)
        #expect(Set(ModifierChord.allCases.map { $0.flags.rawValue }).count == ModifierChord.allCases.count)
    }

    @Test func onePressAndReleasePerHoldDespiteRepeatedFlagEvents() {
        var state = ModifierHoldState()
        #expect(state.transition(toHeld: false) == nil)
        #expect(state.transition(toHeld: true) == .pressed)
        #expect(state.isHeld)
        #expect(state.transition(toHeld: true) == nil)
        #expect(state.transition(toHeld: false) == .released)
        #expect(!state.isHeld)
        #expect(state.transition(toHeld: false) == nil)
        #expect(state.transition(toHeld: true) == .pressed)
        #expect(state.transition(toHeld: false) == .released)
    }

    @Test func missingReleaseAfterTapInterruptionIsRecoveredFromLiveFlags() {
        var state = ModifierHoldState()
        #expect(state.transition(toHeld: ModifierChord.fnShift.isHeld(by: [.maskSecondaryFn, .maskShift])) == .pressed)
        #expect(state.transition(toHeld: ModifierChord.fnShift.isHeld(by: [.maskShift])) == .released)
        #expect(state.transition(toHeld: ModifierChord.fnShift.isHeld(by: [.maskShift])) == nil)
    }
}
