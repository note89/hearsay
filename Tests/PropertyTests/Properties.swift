import Foundation
import Testing

/// Reproducible generated cases with deletion shrinking; failures print the seed and reduced case.
enum Properties {
    struct Generator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func integer(_ range: Range<Int>) -> Int {
            Int.random(in: range, using: &self)
        }

        mutating func words() -> [String] {
            let tokens = [
                "invoice", "cache", "FRIDAY", "åäö", "ação", "你好", "e\u{301}",
                "won't", "we’re", "90's", "HTTP2", "p99", "5ms", "23%", "1,250,000",
                "14th", "...", "'", "🙂", "$1", "\\path", "um", "uh", "",
            ]
            return (0..<integer(0..<13)).map { _ in
                integer(0..<4) == 0 ? String(integer(0..<10000)) : tokens[integer(tokens.indices)]
            }
        }
    }

    static func check<Element>(
        seed defaultSeed: UInt64, cases: Int = 300,
        generate: (inout Generator) -> [Element],
        property: ([Element]) -> Bool
    ) {
        let seed = ProcessInfo.processInfo.environment["HEARSAY_PROPERTY_SEED"].flatMap(UInt64.init) ?? defaultSeed
        var generator = Generator(state: seed)
        for index in 0..<cases {
            var witness = generate(&generator)
            guard !property(witness) else { continue }
            var changed = true
            while changed {
                changed = false
                for position in witness.indices {
                    var smaller = witness
                    smaller.remove(at: position)
                    if !property(smaller) {
                        witness = smaller
                        changed = true
                        break
                    }
                }
            }
            Issue.record("Property failed: seed=\(seed), case=\(index), shrunk input=\(String(reflecting: witness))")
            return
        }
    }
}
