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

// RunSummary: aggregation and verdict over records
let winTake = BakeoffRecord(app: "T", engine: "apple-local", expected: "the cache is stale", spoken: "the cache is stale", ours: "the cache is stale", oursMs: 300, rival: .landed(text: "the cash is stale", latency: .milliseconds(900)))
let lossTake = BakeoffRecord(app: "T", engine: "apple-local", expected: "send the invoice", spoken: "send the invoice", ours: "send the voice", oursMs: 200, rival: .landed(text: "send the invoice", latency: .milliseconds(700)))
let unscoredTake = BakeoffRecord(app: "T", engine: "apple-local", expected: "hello there", spoken: "hello there", ours: "hello there", oursMs: 100, rival: .timedOut(after: .seconds(8)))
let legacyTake = BakeoffRecord(app: "T", engine: "apple-local", expected: nil, spoken: "x", ours: "x", oursMs: 1, rival: .unobservable)
let summary = RunSummary(records: [winTake, lossTake, unscoredTake, legacyTake])
expect(summary.takes.count == 3, "summary: takes without expected are skipped")
expect(summary.wins == 1 && summary.losses == 1 && summary.ties == 0, "summary: verdict counts")
expect(summary.engines.count == 1 && summary.engines[0].takes == 2, "summary: engine group over landed takes only")
expect(summary.engines[0].meanOursMs == 250 && summary.engines[0].meanRivalMs == 800, "summary: latency means")
expect(summary.takes[2].rivalWer == nil, "summary: timed-out rival is unscored")

// BakeoffRecord: illegal on-disk states are dropped at decode
let illegal = Data(#"{"at":0,"app":"T","engine":"apple-local","spoken":"x","ours":"x","oursMs":1,"rivalStatus":"landed"}"#.utf8)
expect((try? JSONDecoder().decode(BakeoffRecord.self, from: illegal)) == nil, "record: landed without text is illegal")
let roundTrip = try! JSONDecoder().decode(BakeoffRecord.self, from: try! JSONEncoder().encode(winTake))
expect(roundTrip.rival == .landed(text: "the cash is stale", ms: 900), "record: encode/decode round-trips the union")

if failures > 0 {
    print("\(failures) failing")
    exit(1)
}
print("all scorer tests pass")
