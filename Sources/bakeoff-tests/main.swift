// Scorer test runner — plain executable because the CLT toolchain ships no test framework.
// Run: swift run bakeoff-tests
import Bakeoff
import Foundation

var failures = 0

func expect(_ condition: Bool, _ name: String) {
    print((condition ? "PASS" : "FAIL"), name)
    if !condition { failures += 1 }
}

expect(Scorer.wer(reference: "their deployment won't work there", hypothesis: "their deployment will not work there") == 0, "contraction")
expect(Scorer.wer(reference: "we enabled HTTP/2 today", hypothesis: "we enabled HTTP2 today") == 0, "HTTP/2 vs HTTP2")
expect(Scorer.wer(reference: "the p99 latency spiked", hypothesis: "the p 99 latency spiked") == 0, "letter/digit split")
expect(Scorer.wer(reference: "totals €1,250 plus 23% VAT", hypothesis: "totals 1250 plus 23 percent VAT") == 0, "digit comma + percent")
expect(Scorer.wer(reference: "plus 23% VAT", hypothesis: "plus twenty three percent VAT") == 0, "twenties spelled out")
expect(Scorer.wer(reference: "bring 29 items", hypothesis: "bring twenty nine items") == 0, "29 items")
expect(Scorer.wer(reference: "wait 5ms then retry", hypothesis: "wait five milliseconds then retry") == 0, "5ms unit")
expect(Scorer.wer(reference: "spiked to 250ms after", hypothesis: "spiked to two hundred fifty milliseconds after") == 0, "250ms")
expect(Scorer.wer(reference: "the 2nd option on the 14th", hypothesis: "the second option on the fourteenth") == 0, "ordinals")
expect(Scorer.wer(reference: "the cache is stale", hypothesis: "the cash is stale") > 0, "real error counts")
expect(Scorer.wer(reference: "refactor the parseTranscript function", hypothesis: "refactor the parse transcript function") > 0, "camelCase split penalized")

let styleSegments = Scorer.diff(reference: "wait 5ms for HTTP/2", hypothesis: "wait five milliseconds for HTTP2")
expect(styleSegments.allSatisfy { $0.verdict == .match }, "diff: style variants mark nothing")

let errorSegments = Scorer.diff(reference: "the cache is stale", hypothesis: "the cash is stale")
expect(errorSegments.filter { $0.verdict == .wrong }.map(\.text) == ["cash"], "diff: one real error marks one word")

let listSegments = Scorer.diff(reference: "a list: one two", hypothesis: "a list:\n- one\n- two")
expect(listSegments.map(\.text).joined() == "a list:\n- one\n- two", "diff: newlines preserved")

expect(Scorer.wer(reference: "music from the 90's era", hypothesis: "music from the 90's era") == 0, "digit-apostrophe-letter terminates")
expect(Scorer.diff(reference: "the 90's", hypothesis: "the 90's").allSatisfy { $0.verdict == .match }, "diff survives 90's")
expect(Scorer.wer(reference: "their deployment won't work there", hypothesis: "their deployment won\u{2019}t work there") == 0, "curly apostrophe contraction")
expect(Scorer.wer(reference: "before Thursday's demo", hypothesis: "before Thursday\u{2019}s demo") == 0, "curly possessive")
expect(Scorer.wer(reference: "say hello now", hypothesis: "say 'hello' now") == 0, "single-quote quoting")
expect(Scorer.wer(reference: "hello", hypothesis: "' hello") == 0, "stray apostrophe token dropped")
let pctSegments = Scorer.diff(reference: "fifty", hypothesis: "50%")
expect(pctSegments.filter { $0.verdict == .wrong }.map(\.text) == ["50%"], "diff and wer agree on % insertion")
for (r, h) in [("wait 5ms for HTTP/2", "wait five milliseconds for HTTP2"), ("plus 23% VAT", "plus twenty three percent VAT"), ("the 2nd option", "the second option")] {
    expect(Scorer.wer(reference: r, hypothesis: h) == 0 && Scorer.diff(reference: r, hypothesis: h).allSatisfy { $0.verdict == .match }, "wer==0 implies clean diff: \(r)")
}
expect(Scorer.wer(reference: "the cache is stale", hypothesis: "the cache stale") > 0, "deletion still scores")

if failures > 0 {
    print("\(failures) failing")
    exit(1)
}
print("all scorer tests pass")
