// Runs against the SERVED page script — catches template-literal escape rot.
// Usage: node scripts/arena-tests.js /tmp/arena-page.js   (check-arena.sh passes the path)
const fs = require("fs");
const pagePath = process.argv[2];
if (!pagePath) {
  console.error("usage: node scripts/arena-tests.js <extracted-page.js>");
  process.exit(2);
}
var document = { getElementById: () => ({ style: {} }), querySelectorAll: () => [] };
var fetch = async () => ({ json: async () => ({ sentences: [], records: [], refs: [], skipped: 0, status: null }) });
var setInterval = () => {};
eval(fs.readFileSync(pagePath, "utf8"));

const marks = html => (html.match(/class="bad"/g) || []).length;
const cases = [
  ["wer: contraction", wer("their deployment won't work there", "their deployment will not work there"), 0],
  ["wer: HTTP/2 vs HTTP2", wer("we enabled HTTP/2 today", "we enabled HTTP2 today"), 0],
  ["wer: p99 split", wer("the p99 latency spiked", "the p 99 latency spiked"), 0],
  ["wer: digit comma + percent", wer("totals €1,250 plus 23% VAT", "totals 1250 plus 23 percent VAT"), 0],
  ["wer: twenties spelled out", wer("plus 23% VAT", "plus twenty three percent VAT"), 0],
  ["wer: 29 items", wer("bring 29 items", "bring twenty nine items"), 0],
  ["wer: 5ms unit", wer("wait 5ms then retry", "wait five milliseconds then retry"), 0],
  ["wer: 250ms", wer("spiked to 250ms after", "spiked to two hundred fifty milliseconds after"), 0],
  ["wer: real error counts", wer("the cache is stale", "the cash is stale") > 0, true],
  ["wer: camelCase split penalized", wer("refactor the parseTranscript function", "refactor the parse transcript function") > 0, true],
  ["diff: identical marks nothing", marks(diffMark("Quick update before the demo: done", "Quick update before the demo. Done")), 0],
  ["diff: style variants mark nothing", marks(diffMark("wait 5ms for HTTP/2", "wait five milliseconds for HTTP2")), 0],
  ["diff: one real error marks one word", marks(diffMark("the cache is stale", "the cash is stale")), 1],
  ["diff: list newlines preserved", diffMark("a list: one two", "a list:\n- one\n- two").includes("\n"), true],
  ["esc: escapes angle and quote", esc('<img src="x">') === "&lt;img src=&quot;x&quot;&gt;", true],
];
let fails = 0;
for (const [name, got, want] of cases) {
  const ok = got === want;
  if (!ok) fails++;
  console.log((ok ? "PASS" : "FAIL got=" + got), name);
}
process.exit(fails);
