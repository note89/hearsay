// hearsay bake-off arena — local benchmark site: teleprompter + dictation box + live scoreboard.
// Run: bun scripts/bakeoff-arena.ts   → http://localhost:4141
import { readFileSync, existsSync, renameSync, writeFileSync, statSync, appendFileSync } from "fs";
import { homedir } from "os";

const LOG = `${homedir()}/Library/Application Support/hearsay/bakeoff.jsonl`;
const SENTENCES = new URL("./bakeoff-sentences.txt", import.meta.url).pathname;
const STATUS = LOG.replace("bakeoff.jsonl", "status.json");
const CONTROL = LOG.replace("bakeoff.jsonl", "control.json");
const REFS = LOG.replace("bakeoff.jsonl", "bakeoff-refs.jsonl");
const MODES = ["dictate", "bakeoff"];
// ARENA_ENGINE_KEYS: must match Engine.wireKey values in Sources/hearsay/Engine.swift
const ENGINE_KEYS = ["apple-local", "elevenlabs/scribe_v1", "google/gemini-2.5-flash-lite", "google/gemini-2.5-flash"];
const PORT = 4141;

type Sentence = { text: string; lang: string };

let sentencesCache: { mtimeMs: number; list: Sentence[] } | null = null;
function sentences(): Sentence[] {
  const mtimeMs = statSync(SENTENCES).mtimeMs;
  if (sentencesCache && sentencesCache.mtimeMs === mtimeMs) return sentencesCache.list;
  const out: Sentence[] = [];
  let lang = "en-US";
  for (const raw of readFileSync(SENTENCES, "utf8").split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    const marker = line.match(/^# --- .*\(([^)]+)\)/);
    if (marker) { lang = marker[1]; continue; }
    if (line.startsWith("#")) continue;
    out.push({ text: line, lang });
  }
  sentencesCache = { mtimeMs, list: out };
  return out;
}

function parseJsonl(path: string): { rows: any[]; skipped: number } {
  if (!existsSync(path)) return { rows: [], skipped: 0 };
  let skipped = 0;
  const rows = readFileSync(path, "utf8").split("\n").filter(Boolean).flatMap((line) => {
    try { return [JSON.parse(line)]; } catch { skipped++; return []; }
  });
  return { rows, skipped };
}

// The reference each record was a take of, pinned at the moment the server first sees the record —
// alignment is data, not reconstruction, so retakes cannot shift later scores.
function pinnedRefs(recordCount: number): (string | null)[] {
  const existing = parseJsonl(REFS).rows.map((r) => (typeof r.sentence === "string" ? r.sentence : null));
  if (existing.length < recordCount) {
    const list = sentences();
    let out = "";
    for (let k = existing.length; k < recordCount; k++) {
      const sentence = list[k] ? list[k].text : null;
      existing.push(sentence);
      out += JSON.stringify({ sentence }) + "\n";
    }
    appendFileSync(REFS, out);
  }
  return existing;
}

Bun.serve({
  port: PORT,
  hostname: "127.0.0.1",
  async fetch(req) {
    const url = new URL(req.url);
    const host = req.headers.get("host") || "";
    if (host !== `localhost:${PORT}` && host !== `127.0.0.1:${PORT}`) {
      return new Response("forbidden", { status: 403 });
    }
    const { pathname } = url;
    if (pathname === "/data") {
      let status = null;
let lastRenderKey = "";
let tickGen = 0;
      try { status = JSON.parse(readFileSync(STATUS, "utf8")); } catch {}
      const { rows, skipped } = parseJsonl(LOG);
      return Response.json({ sentences: sentences(), records: rows, refs: pinnedRefs(rows.length), skipped, status });
    }
    if (pathname === "/control" && req.method === "POST") {
      const raw = await req.text();
      if (raw.length > 1024) return new Response("too large", { status: 413 });
      let body: any;
      try { body = JSON.parse(raw); } catch { return new Response("bad json", { status: 400 }); }
      const control: { engine?: string; mode?: string } = {};
      if (typeof body.engine === "string") {
        if (!ENGINE_KEYS.includes(body.engine)) return new Response("unknown engine", { status: 400 });
        control.engine = body.engine;
      }
      if (typeof body.mode === "string") {
        if (!MODES.includes(body.mode)) return new Response("unknown mode", { status: 400 });
        control.mode = body.mode;
      }
      writeFileSync(CONTROL + ".tmp", JSON.stringify(control));
      renameSync(CONTROL + ".tmp", CONTROL);
      return Response.json({ ok: true });
    }
    if (pathname === "/reset" && req.method === "POST") {
      const stamp = Date.now();
      if (existsSync(LOG)) renameSync(LOG, LOG.replace(".jsonl", `-${stamp}.jsonl`));
      if (existsSync(REFS)) renameSync(REFS, REFS.replace(".jsonl", `-${stamp}.jsonl`));
      return Response.json({ ok: true });
    }
    return new Response(PAGE, { headers: { "content-type": "text/html; charset=utf-8" } });
  },
});
console.log(`bake-off arena → http://localhost:${PORT}`);

const PAGE = `<!doctype html>
<meta charset="utf-8">
<title>hearsay × wispr — bake-off</title>
<style>
  :root { --bg:#0c0c0e; --card:#17171a; --line:#26262b; --fg:#f2f2f4; --dim:#8b8b93; --ours:#7ee787; --rival:#ffa657; }
  * { box-sizing:border-box; margin:0 }
  body { background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system,system-ui; padding:32px; max-width:880px; margin:0 auto }
  h1 { font-size:15px; font-weight:600; letter-spacing:.04em; color:var(--dim); display:flex; align-items:center; gap:10px }
  h1 b.o { color:var(--ours) } h1 b.r { color:var(--rival) }
  .prompt { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:28px 32px; margin:20px 0 14px }
  .prompt .idx { color:var(--dim); font-size:13px; margin-bottom:8px }
  .prompt .text { font-size:30px; font-weight:650; line-height:1.3 }
  .banner { background:#2b2410; border:1px solid #5c4a12; color:#ffd66b; border-radius:10px; padding:10px 14px; margin:0 0 14px; font-size:14px; display:none }
  textarea { width:100%; height:110px; background:var(--card); border:1px solid var(--line); border-radius:14px; color:var(--fg);
             font:17px/1.5 -apple-system,system-ui; padding:16px; resize:none; outline:none }
  textarea:focus { border-color:#4a4a52 }
  .hint { color:var(--dim); font-size:13px; margin:10px 2px 26px }
  .summary { display:flex; gap:12px; margin-bottom:14px }
  .stat { flex:1; background:var(--card); border:1px solid var(--line); border-radius:14px; padding:14px 18px }
  .stat .who { font-size:12px; letter-spacing:.05em; color:var(--dim) }
  .stat .nums { font-size:20px; font-weight:700; margin-top:4px }
  .stat.o .nums { color:var(--ours) } .stat.r .nums { color:var(--rival) }
  .rsub { color:var(--rival); font-size:12.5px; margin-top:3px }
  .sub2 { color:var(--dim); font-size:10.5px }
  .verdict { text-align:center; font-size:17px; font-weight:650; padding:14px; display:none;
             background:var(--card); border:1px solid var(--line); border-radius:14px; margin-bottom:14px }
  table { width:100%; border-collapse:collapse; font-size:13.5px }
  th { text-align:left; color:var(--dim); font-weight:500; padding:6px 10px; border-bottom:1px solid var(--line) }
  td { padding:8px 10px; border-bottom:1px solid var(--line); vertical-align:top }
  td.o { color:var(--ours) } td.r { color:var(--rival) }
  .win { font-weight:700 }
  .miss { color:var(--dim); font-style:italic }
  .sub { color:var(--dim); font-size:12px; margin-top:3px; white-space:pre-wrap; line-height:1.55 }
  .sub .bad { color:#ff7b72; text-decoration:underline; text-decoration-color:rgba(255,123,114,.45); text-underline-offset:2px }
  .chip { font-size:10.5px; border:1px solid var(--line); border-radius:99px; padding:1px 7px; color:var(--dim); margin-left:6px }
  button { background:none; border:1px solid var(--line); color:var(--dim); border-radius:8px; padding:6px 12px; font-size:13px; cursor:pointer; margin-left:auto }
  button:hover { color:var(--fg) }
  .enginebar { display:flex; align-items:center; gap:12px; margin:18px 0 10px; flex-wrap:wrap }
  .enginebar .lbl { font-size:11px; letter-spacing:.08em; color:var(--dim); font-weight:700 }
  .seg { display:flex; background:var(--card); border:1px solid var(--line); border-radius:10px; padding:3px; gap:2px }
  .seg button { border:none; border-radius:7px; padding:6px 12px; color:var(--dim); font-size:13px; margin:0 }
  .seg button:hover { color:var(--fg) }
  .seg button.on { background:#22301f; color:var(--ours); font-weight:700 }
  .enginebar .state { font-size:12px; color:var(--dim); margin-left:auto }
  .matchcard { background:var(--card); border:1px solid var(--line); border-radius:14px; margin-bottom:16px; overflow:hidden }
  table.matchup { width:100%; border-collapse:collapse; font-size:13.5px }
  .matchup th, .matchup td { padding:9px 16px; border-bottom:1px solid var(--line); text-align:left; vertical-align:top }
  .matchup tr:last-child th, .matchup tr:last-child td { border-bottom:none }
  .matchup td.lbl { color:var(--dim); font-size:11px; letter-spacing:.05em; width:84px; padding-top:11px }
  .matchup th.o { color:var(--ours) }
  .matchup th.r { color:var(--rival) }
  .matchup td.oc { border-right:1px solid var(--line) }
  .matchup th.o { border-right:1px solid var(--line) }
</style>
<h1><b class="o">hearsay</b> × <b class="r">wispr flow</b> — same audio, same key-up, one clock
  <button onclick="resetLog()">reset run</button></h1>
<div class="enginebar">
  <span class="lbl">HEARSAY ENGINE</span>
  <div class="seg" id="enginePick"></div>
  <span class="state" id="engineState"></span>
</div>
<div class="matchcard"><table class="matchup">
  <tr><td class="lbl"></td><th class="o">HEARSAY</th><th class="r">WISPR FLOW</th></tr>
  <tr><td class="lbl">MODEL</td><td class="oc" id="m-model"></td><td>proprietary cloud STT + LLM</td></tr>
  <tr><td class="lbl">RUNS ON</td><td class="oc" id="m-runs"></td><td>Baseten · OpenAI · Anthropic · Cerebras · AWS</td></tr>
  <tr><td class="lbl">PRICE</td><td class="oc" id="m-price"></td><td>$144/yr · ≈ $1.32 per 1k words spoken</td></tr>
  <tr><td class="lbl">PRIVACY</td><td class="oc" id="m-privacy"></td><td>audio + window screenshots uploaded</td></tr>
</table></div>
<div class="banner" id="modeBanner"></div>\n<div class="banner" id="banner"></div>
<div class="prompt"><div class="idx" id="idx"></div><div class="text" id="sentence">loading…</div></div>
<textarea id="arena" placeholder="click here, hold fn+shift, read the sentence, release" spellcheck="false"></textarea>
<div class="hint">bake-off mode must be ON in hearsay's menu · wispr runs as normal · row appears ~1 s after release</div>
<div class="verdict" id="verdict"></div>
<div class="summary" id="summary"></div>
<table><thead><tr><th>#</th><th>sentence</th><th>hearsay · ms to text ready</th><th>wispr · ms to text visible</th></tr></thead><tbody id="rows"></tbody></table>
<script>
const ONES = ["zero","one","two","three","four","five","six","seven","eight","nine","ten","eleven","twelve","thirteen","fourteen","fifteen","sixteen","seventeen","eighteen","nineteen","twenty"];
const TENS = {2:"twenty",3:"thirty",4:"forty",5:"fifty",6:"sixty",7:"seventy",8:"eighty",9:"ninety"};
const ORD = {one:"first",two:"second",three:"third",five:"fifth",eight:"eighth",nine:"ninth",twelve:"twelfth",twenty:"twentieth"};
function numWords(n) {
  if (n <= 20) return ONES[n];
  if (n < 100) { const t = TENS[Math.floor(n/10)], r = n % 10; return r ? t + " " + ONES[r] : t; }
  if (n < 1000) { const h = Math.floor(n/100), r = n % 100; return ONES[h] + " hundred" + (r ? " " + numWords(r) : ""); }
  return String(n);
}
function ordWords(n) {
  const w = numWords(n), parts = w.split(" "), last = parts.pop();
  const o = ORD[last] || (last.endsWith("y") ? last.slice(0,-1) + "ieth" : last + "th");
  return [...parts, o].join(" ");
}
// "700" scores as "seven hundred", "2nd" as "second" — numeral style is formatting, not accuracy.
const CONTRACTIONS = { "won't":"will not","can't":"can not","don't":"do not","doesn't":"does not","didn't":"did not","isn't":"is not","aren't":"are not","wasn't":"was not","weren't":"were not","haven't":"have not","hasn't":"has not","hadn't":"had not","wouldn't":"would not","shouldn't":"should not","couldn't":"could not","i'm":"i am","i've":"i have","i'll":"i will","i'd":"i would","you're":"you are","you've":"you have","you'll":"you will","they're":"they are","they've":"they have","they'll":"they will","we're":"we are","we've":"we have","we'll":"we will","it's":"it is","that's":"that is","there's":"there is","let's":"let us","what's":"what is","who's":"who is","he's":"he is","she's":"she is","here's":"here is" };
const UNITS = {ms:"milliseconds",s:"seconds",min:"minutes",h:"hours",km:"kilometers",kg:"kilograms",gb:"gigabytes",mb:"megabytes",kb:"kilobytes",hz:"hertz",khz:"kilohertz",mhz:"megahertz",ghz:"gigahertz",pm:"pm",am:"am","%":"percent"};
const normToken = t => {
  let m;
  if (CONTRACTIONS[t]) return CONTRACTIONS[t].split(" ");
  if (/^\\d+$/.test(t)) return numWords(+t).split(" ");
  if ((m = t.match(/^(\\d+)(st|nd|rd|th)$/))) return ordWords(+m[1]).split(" ");
  if ((m = t.match(/^(\\d+)([a-z%]+)$/)) && UNITS[m[2]]) return [...numWords(+m[1]).split(" "), UNITS[m[2]]];
  if (UNITS[t]) return [UNITS[t]];
  if (/[a-z]/.test(t) && /\\d/.test(t)) return t.split(/(?<=[a-z])(?=\\d)|(?<=\\d)(?=[a-z])/).flatMap(normToken);
  return [t];
};
const norm = t => t.toLowerCase().replace(/(\\d),(?=\\d)/g, "$1").replace(/%/g, " percent ").replace(/[^\\p{L}\\p{N}\\s']/gu, " ").split(/\\s+/).filter(Boolean).flatMap(normToken);
function wer(ref, hyp) {
  const a = norm(ref), b = norm(hyp);
  let prev = Array.from({length: b.length + 1}, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++)
      cur.push(Math.min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + (a[i-1] === b[j-1] ? 0 : 1)));
    prev = cur;
  }
  return prev[b.length] / Math.max(a.length, 1);
}
const pct = x => Math.round(x * 100) + "%";
function esc(t) { return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }
// Marks hypothesis words that differ from the reference, aligned on normalized tokens so
// numeral/unit style ("700" vs "seven hundred") never lights up.
function diffMark(ref, hyp) {
  const refN = norm(ref);
  const parts = hyp.split(/(\\s+)/);
  const hypN = [], srcIdx = [];
  parts.forEach((part, i) => {
    if (/^\\s*$/.test(part)) return;
    for (const t of norm(part)) { hypN.push(t); srcIdx.push(i); }
  });
  const n = refN.length, m = hypN.length;
  const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = 0; i <= n; i++) dp[i][0] = i;
  for (let j = 0; j <= m; j++) dp[0][j] = j;
  for (let i = 1; i <= n; i++)
    for (let j = 1; j <= m; j++)
      dp[i][j] = Math.min(dp[i-1][j] + 1, dp[i][j-1] + 1, dp[i-1][j-1] + (refN[i-1] === hypN[j-1] ? 0 : 1));
  const bad = new Set();
  let i = n, j = m;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && dp[i][j] === dp[i-1][j-1] + (refN[i-1] === hypN[j-1] ? 0 : 1)) {
      if (refN[i-1] !== hypN[j-1]) bad.add(srcIdx[j-1]);
      i--; j--;
    } else if (j > 0 && dp[i][j] === dp[i][j-1] + 1) {
      bad.add(srcIdx[j-1]); j--;
    } else {
      i--;
    }
  }
  return parts.map((part, k) => /^\\s*$/.test(part) ? part : (bad.has(k) ? '<span class="bad">' + esc(part) + "</span>" : esc(part))).join("");
}
let status = null;
const ENGINES = {
  "apple-local": { name: "Apple local", model: "SpeechAnalyzer → on-device ~3B LLM polish", runs: "this Mac — Neural Engine, works offline", price: "$0", privacy: "audio never leaves the Mac" },
  "elevenlabs/scribe_v1": { name: "ElevenLabs Scribe", model: "Scribe (scribe_v1, dedicated ASR) → on-device polish", runs: "ElevenLabs cloud", price: "~$2.80 per 100k words", privacy: "audio uploaded to ElevenLabs" },
  "google/gemini-2.5-flash-lite": { name: "Gemini Flash-Lite", model: "Gemini 2.5 Flash-Lite (audio LLM) → on-device polish", runs: "Google, via OpenRouter", price: "~$0.50 per 100k words", privacy: "audio uploaded to Google" },
  "google/gemini-2.5-flash": { name: "Gemini Flash", model: "Gemini 2.5 Flash (audio LLM) → on-device polish", runs: "Google, via OpenRouter", price: "~$1.85 per 100k words", privacy: "audio uploaded to Google" },
};
async function setControl(patch) {
  status = Object.assign({}, status, patch);
  lastRenderKey = "";
  renderCard();
  await fetch("/control", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(patch) });
}
function renderCard() {
  const key = status ? status.engine : "apple-local";
  const e = ENGINES[key] || { name: key, model: key, runs: "cloud", price: "?", privacy: "audio uploaded" };
  document.getElementById("engineState").textContent = status
    ? status.locale + " · polish " + (status.polish === "off" ? "off" : "on") + " · " + (status.mode === "bakeoff" ? "bake-off" : "⚠ dictate mode")
    : "app not running?";
  document.getElementById("m-model").textContent = e.model;
  document.getElementById("m-runs").textContent = e.runs;
  document.getElementById("m-price").textContent = e.price;
  document.getElementById("m-privacy").textContent = e.privacy;
  document.getElementById("enginePick").innerHTML = Object.keys(ENGINES).map(k =>
    '<button class="' + (k === key ? "on" : "") + '" data-engine="' + k + '">' + ENGINES[k].name + "</button>").join("");
  document.querySelectorAll("#enginePick button").forEach(b => { b.onclick = () => setControl({ engine: b.dataset.engine }); });
  const banner = document.getElementById("modeBanner");
  if (status && status.mode !== "bakeoff") {
    banner.style.display = "block";
    banner.innerHTML = '⚠ bake-off mode is OFF — hearsay will insert into the box. <button id="modeOn">turn on</button>';
    document.getElementById("modeOn").onclick = () => setControl({ mode: "bakeoff" });
  } else {
    banner.style.display = "none";
  }
}

let lastCount = -1;
async function tick() {
  const gen = ++tickGen;
  let payload;
  try {
    payload = await (await fetch("/data")).json();
  } catch {
    document.getElementById("engineState").textContent = "arena server unreachable";
    return;
  }
  if (gen !== tickGen) return;
  const { sentences, records, refs = [], skipped = 0, status: liveStatus } = payload;
  status = liveStatus;
  const renderKey = JSON.stringify(liveStatus) + "|" + records.length + "|" + skipped + "|" + sentences.length;
  if (renderKey === lastRenderKey) return;
  lastRenderKey = renderKey;
  renderCard();
  const i = records.length;
  document.getElementById("idx").textContent = i < sentences.length
    ? "sentence " + (i + 1) + " of " + sentences.length + " · " + sentences[i].lang : "done";
  document.getElementById("sentence").textContent = i < sentences.length ? sentences[i].text : "🏁 run complete";
  const banner = document.getElementById("banner");
  const langSwitch = i > 0 && i < sentences.length && sentences[i].lang !== sentences[i - 1].lang;
  banner.style.display = langSwitch ? "block" : "none";
  if (langSwitch) banner.textContent = "⚠ switch hearsay: menu bar → Language → " + sentences[i].lang + " (wispr auto-detects)";
  if (i !== lastCount) { document.getElementById("arena").value = ""; lastCount = i; }

  const groups = {};
  let oWins = 0, rWins = 0, ties = 0, scored = 0, unaligned = 0, rows = "";
  records.forEach((rec, k) => {
    const ref = k < refs.length && refs[k] ? refs[k] : null;
    const chip = rec.engine && rec.engine !== "apple-local" ? '<span class="chip">⚡' + esc(rec.engine.split("/").pop()) + "</span>" : "";
    if (ref === null) {
      unaligned++;
      rows = "<tr><td>" + (k + 1) + '</td><td class="miss">unaligned — extra take, not scored</td>'
        + '<td class="o">' + chip + '<div class="sub">' + esc(rec.ours) + "</div></td>"
        + '<td class="r"><div class="sub">' + (rec.rivalStatus === "landed" ? esc(rec.rival) : esc(rec.rivalStatus)) + "</div></td></tr>" + rows;
      return;
    }
    const ow = wer(ref, rec.ours);
    let rivalCell = '<span class="miss">' + esc(rec.rivalStatus) + "</span>";
    let rw = null;
    if (rec.rivalStatus === "landed") {
      rw = wer(ref, rec.rival);
      const key = rec.engine || "apple-local";
      const g = groups[key] || (groups[key] = { n: 0, oW: 0, oM: 0, rW: 0, rM: 0 });
      g.n++; g.oW += ow; g.oM += Number(rec.oursMs) || 0; g.rW += rw; g.rM += Number(rec.rivalMs) || 0;
      scored++;
      if (ow < rw) oWins++; else if (rw < ow) rWins++; else ties++;
      rivalCell = '<span class="' + (rw <= ow ? "win" : "") + '">' + pct(rw) + " · " + (Number(rec.rivalMs) || 0) + ' ms</span><div class="sub">' + diffMark(ref, rec.rival) + "</div>";
    }
    rows = "<tr><td>" + (k + 1) + "</td><td>" + esc(ref) + "</td>"
      + '<td class="o"><span class="' + (rw === null || ow <= rw ? "win" : "") + '">' + pct(ow) + " · " + (Number(rec.oursMs) || 0) + " ms</span>" + chip
      + '<div class="sub">' + diffMark(ref, rec.ours) + "</div></td>"
      + '<td class="r">' + rivalCell + "</td></tr>" + rows;
  });

  document.getElementById("summary").innerHTML = Object.keys(groups).map(k => {
    const g = groups[k];
    const name = (ENGINES[k] || { name: k }).name;
    return '<div class="stat o"><div class="who">' + esc(name.toUpperCase()) + " — " + g.n + ' scored rows</div>'
      + '<div class="nums">' + pct(g.oW / g.n) + " · " + Math.round(g.oM / g.n) + ' ms <span class="sub2">to text ready</span></div>'
      + '<div class="rsub">wispr, same rows: ' + pct(g.rW / g.n) + " · " + Math.round(g.rM / g.n) + ' ms <span class="sub2">to text visible</span></div></div>';
  }).join("");

  const unscored = records.length - scored - unaligned;
  const v = document.getElementById("verdict");
  if (scored >= 3) {
    v.style.display = "block";
    v.textContent = (oWins >= rWins ? "🏆 hearsay wins " + oWins + " · wispr " + rWins : "wispr leads " + rWins + " · hearsay " + oWins)
      + (ties ? " · ties " + ties : "") + (unscored ? " · " + unscored + " unscored" : "")
      + (unaligned ? " · " + unaligned + " unaligned" : "") + (skipped ? " · " + skipped + " corrupt lines skipped" : "") + " — by WER only";
  } else {
    v.style.display = "none";
  }
  document.getElementById("rows").innerHTML = rows;
}
async function resetLog() { await fetch("/reset", { method: "POST" }); lastCount = -1; lastRenderKey = ""; tick(); }
setInterval(tick, 800); tick();
</script>`;
