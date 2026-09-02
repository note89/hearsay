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

// RunSummary: every engine scored per take, leaderboard, record against the rival
let win = Take(id: "t1", app: "T", expected: "the cache is stale", rival: .landed(text: "the cash is stale", ms: 900), results: [
    EngineResult(engine: "apple-local", outcome: .scored(spoken: "the cache is stale", ours: "the cache is stale", ms: 300)),
    EngineResult(engine: "elevenlabs/scribe_v2", outcome: .failed(reason: "timed out")),
])
let loss = Take(id: "t2", app: "T", expected: "send the invoice", rival: .landed(text: "send the invoice", ms: 700), results: [
    EngineResult(engine: "apple-local", outcome: .scored(spoken: "send the invoice", ours: "send the voice", ms: 200)),
    EngineResult(engine: "elevenlabs/scribe_v2", outcome: .scored(spoken: "send the invoice", ours: "send the invoice", ms: 500)),
])
let unscored = Take(id: "t3", app: "T", expected: "hello there", rival: .timedOut, results: [
    EngineResult(engine: "apple-local", outcome: .scored(spoken: "hello there", ours: "hello there", ms: 100)),
])
let legacy = Take(id: "t4", app: "T", expected: nil, rival: .unobservable, results: [
    EngineResult(engine: "apple-local", outcome: .scored(spoken: "x", ours: "x", ms: 1)),
])
let summary = RunSummary(takes: [win, loss, unscored, legacy])
expect(summary.takes.count == 3, "summary: takes without expected are skipped")
let apple = summary.leaderboard.first { $0.engineKey == "apple-local" }!
let scribe = summary.leaderboard.first { $0.engineKey == "elevenlabs/scribe_v2" }!
expect(apple.scored == 3 && apple.failed == 0 && scribe.scored == 1 && scribe.failed == 1, "summary: scored and failed counts per engine")
expect(apple.wins == 1 && apple.losses == 1 && apple.ties == 0, "summary: record against the rival")
expect(apple.meanOursMs == 200 && apple.meanRivalMs == 800, "summary: own mean over all scored, rival mean over decided")
expect(scribe.ties == 1 && scribe.decided == 1, "summary: a perfect tie counts as a tie")
expect(summary.leaderboard.map(\.engineKey) == ["elevenlabs/scribe_v2", "apple-local"], "summary: leaderboard by WER (scribe 0% on its one take)")
expect(summary.takes[2].rivalWer == nil, "summary: timed-out rival is unscored")
expect(summary.takes[0].results.count == 2, "summary: a failed engine is still a row in the take")

// Codec: rows regroup into takes, legacy rows stand alone, illegal rows are dropped
let roundTrip = BakeoffCodec.takes(fromJSONL: String(decoding: BakeoffCodec.jsonl(for: win) + BakeoffCodec.jsonl(for: loss), as: UTF8.self))
expect(roundTrip == [win, loss], "codec: takes round-trip through jsonl, rows regrouped by take id")
let legacyLine = #"{"at":1000,"app":"T","engine":"apple-local","expected":"a","spoken":"a","ours":"a","oursMs":1,"rivalStatus":"landed","rival":"b","rivalMs":5}"#
let legacyTakes = BakeoffCodec.takes(fromJSONL: legacyLine + "\n" + legacyLine.replacingOccurrences(of: "1000", with: "2000"))
expect(legacyTakes.count == 2 && legacyTakes[0].results.count == 1 && legacyTakes[0].rival == .landed(text: "b", ms: 5), "codec: pre-race rows become one take each")
let illegal = #"{"at":0,"app":"T","engine":"apple-local","spoken":"x","ours":"x","oursMs":1,"rivalStatus":"landed"}"#
expect(BakeoffCodec.takes(fromJSONL: illegal).isEmpty, "codec: landed without text is illegal")
let halfFailed = #"{"at":0,"take":"z","app":"T","engine":"e","oursStatus":"failed","spoken":"x","rivalStatus":"timedOut"}"#
expect(BakeoffCodec.takes(fromJSONL: halfFailed).isEmpty, "codec: failed with spoken text is illegal")

if failures > 0 {
    print("\(failures) failing")
    exit(1)
}
print("all bake-off tests pass")
