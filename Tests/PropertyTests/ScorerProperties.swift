import Testing

@testable import Bakeoff

struct ScorerProperties {
    @Test func numbersUseTheSameUnsignedRangeAsTheRustPort() {
        #expect(Scorer.normalize("0009223372036854775808th") == ["9223372036854775808th"])
        #expect(Scorer.normalize("00018446744073709551615ms") == ["18446744073709551615", "milliseconds"])
        #expect(Scorer.normalize("18446744073709551616") == ["18446744073709551616"])
    }
    @Test func normalizationIsIdempotent() {
        Properties.check(
            seed: 101, generate: { $0.words() },
            property: { words in
                let normal = Scorer.normalize(words.joined(separator: " \t"))
                return Scorer.normalize(normal.joined(separator: " ")) == normal
            })
    }

    @Test func normalizationPreservesConcatenationAcrossWhitespace() {
        Properties.check(
            seed: 102, generate: { $0.words() },
            property: { words in
                let midpoint = words.count / 2
                let left = words.prefix(midpoint).joined(separator: " ")
                let right = words.dropFirst(midpoint).joined(separator: " ")
                return Scorer.normalize(left + "\n\t" + right) == Scorer.normalize(left) + Scorer.normalize(right)
            })
    }

    @Test func normalizedTextHasZeroErrorAndNoWrongDiffSegments() {
        Properties.check(
            seed: 103, generate: { $0.words() },
            property: { words in
                let spoken = words.joined(separator: "\t ")
                let normal = Scorer.normalize(spoken).joined(separator: " ")
                return Scorer.wer(reference: normal, hypothesis: spoken) == 0
                    && Scorer.diff(reference: normal, hypothesis: spoken).allSatisfy { $0.verdict == .match }
            })
    }

    @Test func diffReconstructsHypothesisExactly() {
        Properties.check(
            seed: 104, generate: { $0.words() },
            property: { words in
                let hypothesis = "\n " + words.joined(separator: "\t\n") + " \r\n"
                return Scorer.diff(reference: "send the invoice", hypothesis: hypothesis).map(\.text).joined() == hypothesis
            })
    }

    @Test func editDistanceObeysMetricAndLengthBounds() {
        Properties.check(
            seed: 105, generate: { $0.words() },
            property: { words in
                let a = Scorer.normalize(words.enumerated().filter { $0.offset % 3 == 0 }.map(\.element).joined(separator: " "))
                let b = Scorer.normalize(words.enumerated().filter { $0.offset % 3 == 1 }.map(\.element).joined(separator: " "))
                let c = Scorer.normalize(words.enumerated().filter { $0.offset % 3 == 2 }.map(\.element).joined(separator: " "))
                func distance(_ left: [String], _ right: [String]) -> Int {
                    Scorer.editDistance(left, right)
                }
                let ab = distance(a, b)
                return distance(a, a) == 0 && ab == distance(b, a)
                    && ab >= abs(a.count - b.count) && ab <= max(a.count, b.count)
                    && distance(a, c) <= ab + distance(b, c)
            })
    }

    @Test func wordErrorRateCanExceedOneAndIsDirectional() {
        #expect(Scorer.wer(reference: "invoice", hypothesis: "invoice cache friday") == 2)
        #expect(Scorer.wer(reference: "invoice cache friday", hypothesis: "invoice") == 2.0 / 3.0)
        #expect(Scorer.wer(reference: "", hypothesis: "invoice") == 1)
        #expect(Scorer.wer(reference: "", hypothesis: "...") == 0)
    }

    @Test func deletionsDoNotInventHypothesisSegments() {
        #expect(Scorer.wer(reference: "send the invoice", hypothesis: "send invoice") > 0)
        #expect(Scorer.diff(reference: "send the invoice", hypothesis: "send invoice").allSatisfy { $0.verdict == .match })
    }
}
