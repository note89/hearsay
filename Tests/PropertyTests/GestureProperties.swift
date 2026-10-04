import CoreGraphics
import Testing

@testable import Utterance

struct GestureProperties {
    @Test func repeatedStatesAreIdempotentAndEdgesConserveHolds() {
        Properties.check(
            seed: 401,
            generate: { random in
                (0..<random.integer(0..<100)).map { _ in random.integer(0..<2) == 1 }
            },
            property: { heldStates in
                var state = ModifierHoldState()
                var balance = 0
                for held in heldStates {
                    let prior = state.isHeld
                    let event = state.transition(toHeld: held)
                    if (event == nil) != (prior == held) { return false }
                    if let event { balance += event == .pressed ? 1 : -1 }
                    if balance != (held ? 1 : 0) || state.transition(toHeld: held) != nil { return false }
                }
                return true
            })
    }

    @Test func addingModifiersIsMonotone() {
        let flags: [CGEventFlags] = [.maskSecondaryFn, .maskControl, .maskAlternate, .maskShift, .maskCommand, .maskAlphaShift]
        for chord in ModifierChord.allCases {
            for subset in 0..<(1 << flags.count) {
                let extra = flags.enumerated().filter { subset & (1 << $0.offset) != 0 }.reduce(CGEventFlags()) { $0.union($1.element) }
                #expect(chord.isHeld(by: chord.flags.union(extra)))
            }
        }
    }
}
