# Design verification

TLA+ checks asynchronous design, Lean proves token-scoring rules, and generated tests exercise
the production code and compare the Swift and Rust ports.
The `*-before.cfg` configurations deliberately restore the original bugs. The check script
requires those configurations to violate the named invariant, and the repaired configurations
to pass. Syntax errors or unrelated checker failures do not count as a reproduced bug.

## Run

Requires Java 11 or later and the official [TLA+ command-line tools](https://github.com/tlaplus/tlaplus).
The checked version is TLC 2.19 from the stable v1.7.4 release. Download it once:

```sh
mkdir -p .build/formal
curl --fail --location https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar \
  --output .build/formal/tla2tools.jar
printf '%s  %s\n' 936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88 \
  .build/formal/tla2tools.jar | shasum -a 256 -c -
bash scripts/check-models.sh
```

An existing installation works with `TLA2TOOLS_JAR=/absolute/path/tla2tools.jar`.
The runner removes its temporary state graphs on exit. To inspect a pre-fix trace directly:

```sh
java -XX:+UseParallelGC -cp .build/formal/tla2tools.jar tlc2.TLC \
  -metadir .build/formal/trace \
  -config formal/DictationSession-before.cfg formal/DictationSession.tla
```

TLC exits unsuccessfully for that last command by design. Its trace output stays under `.build/`.

## Models and implementation correspondence

| Model action | Implementation |
|---|---|
| `CleanupDeadline.Install` | `CleanupCompletion.install`, including cancellation before continuation setup |
| `Start`, `Track` | Creating and registering the worker and deadline tasks |
| `Arrive(worker/timer/cancel)` | `resolve`, called by worker, timer, or cancellation handler |
| `DictationSession.Press`, `Release` | `Coordinator.pressed`, `released`; press-time rules and run snapshot |
| Active session ownership | `Sessions.SessionPhase`; the coordinator uses its release, advance and completion transitions |
| `ChangeSettings` | `requestEngineRefresh`; engine activation deferred while a session is in flight |
| `Stop`, `Restart` | `Coordinator.stop`, `start`; cancellation belongs to the old task even after restarting |
| `BeginInsertion`, `InsertionReturned` | The `await Inserter.insert` boundary and its subsequent cancellation check |
| `ResetRun`, `Compare` | Resetting bake-off and rejecting a take whose captured run ID no longer matches |

`CleanupDeadline` explores continuation installation, task registration, deadline expiry,
worker completion, and caller cancellation in every ordering. Worker completion remains allowed
after cancellation to represent a model call that ignores cancellation. It checks:

- At most one continuation delivery, and delivery once a result and continuation both exist.
- Cancellation wins when it arrives before any result.
- Every registered task is cancelled once a winner is chosen, including late registrations.
- Eventual delivery, assuming installation and the timer get scheduled (weak fairness).

The checked graph has **76 distinct states**. The pre-fix trace is `Init → Arrive(cancel)`:
the caller cancels, but no result is selected. The original unstructured worker and timer had
no caller cancellation handler. The repaired implementation stores the winner even when
cancellation precedes continuation installation and cancels both tasks on completion.

`DictationSession` explores two distinct session IDs, two engine classes, one run reset, focus
changes, and stop/restart. It checks that an old cancelled insertion cannot settle the UI,
the selected engine stays stable during a session, a stopped app has no active session,
and a take from a reset run cannot enter the current run. The checked graph has
**4,960 distinct states**. The pre-fix trace is:

```text
Press(1, dictate) → Release → BeginInsertion → Stop → Restart → InsertionReturned(1)
```

The original code checked cancellation before insertion, then awaited the paste delay.
`settle` checked only whether the app was running. Restarting during the await let that old
task overwrite the current phase. Every asynchronous completion now checks the active session
token, cancellation, and running state through `SessionPhase.canComplete`; settlement itself
uses `SessionPhase.complete`. Stop resets that same phase to idle. A late gesture cannot start
a session while the coordinator is stopped.
This prevents stale settlement and history writes; it does not retract an already posted paste.

These are bounded models of the stated transitions, not proofs of the Swift code. They abstract
audio, network protocols, model loading, accessibility behavior, and clipboard contents.
Only cleanup has a liveness claim: the session model checks safety and assumes nothing about
whether external speech engines terminate. Keep actions and this correspondence table aligned
when changing the coordinator or cleanup lifetime.

## Algebraic and unit tests

```sh
scripts/test.sh --filter PropertyTests
cargo test --manifest-path crossplatform/Cargo.toml -p hearsay-core
```

Swift's generated cases use a small test-only SplitMix64 generator and deletion shrinking.
Failures report the seed, case index, and reduced input. Reproduce or vary a run with
`HEARSAY_PROPERTY_SEED=123 scripts/test.sh --filter PropertyTests`.
Rust uses [proptest](https://proptest-rs.github.io/proptest/), automatic shrinking, and persisted
regression seeds; use `PROPTEST_RNG_SEED=123` to replay a seed. Both default to 300 generated cases
per property (the Swift disk round-trip property uses 80).

The laws check normalization idempotence and concatenation across whitespace, edit-distance
identity/symmetry/triangle inequality/length bounds, exact reconstruction of diff text, independent
dictionary rewrite commutativity and idempotence, empty-dictionary identity, and preservation of
original speech through nested rewrites. Swift also checks gesture edge conservation and duplicate
event idempotence; Rust checks disabled-cleanup identity through `deliver`.

The preconditions matter: WER is directional and may exceed one, although edit distance is a metric.
Diff cannot mark a deleted word absent from the hypothesis. Dictionary rules can chain, so arbitrary
rewrites are neither commutative nor idempotent. Disk round trips generate entries representable by
the line-based dictionary format. Focused unit examples document those boundaries, literal replacement
strings, empty cleanup, and timeout/cancellation with a worker that ignores cancellation.

Guard regression tests caught a third issue in both ports: if either side had no content words,
the guard accepted anything. Filler-only speech could accept invented text; meaningful speech could
be replaced by punctuation or fillers alone. Both guards now keep the raw transcript in those cases.

## Production boundaries and cross-port agreement

`SessionProperties` generates 500 sequences of start/stop, press/release, settings changes,
step advancement and delayed completions against the same phase type the coordinator uses.
Focused tests reject an old completion after stop/restart, canceled work, and duplicate settlement.
The native coordinator also has a test for a press received while stopped. These tests do not
simulate real accessibility or prove that an already posted paste can be undone.

`CloudTranscriptionTests` checks cancellation before the cloud request and after a request that
ignores cancellation, one request/one final, trimming, and error propagation. Cancellation of an
audio stream can look like normal end of input; the production boundary now checks cancellation
explicitly. WAV partition tests generate 20 random bufferings at each of 16 kHz and 48 kHz, compare
the exact payload with a single buffer, and check repeated finish. The cloud path now flushes the
resampler's delayed tail before encoding.

Run the synthetic, offline cross-port corpus on macOS with Swift, Rust and Python 3:

```sh
bash scripts/check-differential.sh
HEARSAY_DIFFERENTIAL_SEED=123 bash scripts/check-differential.sh --cases 1000
```

The adapters compile the actual production scorer, dictionary and cleanup guard; they exchange
JSON lines. The default corpus has 13 saved cases plus 1,000 generated pairs. Comparison includes
normalized tokens, integer edit distance, WER, every diff segment and verdict, dictionary output,
and cleanup acceptance/rejection. Inputs include Unicode accents, multiple scripts, mixed whitespace,
contractions, units, ordinals, literal replacements and chained rules. Failures report the seed and
case index, then shrink text and rules by deletion. Add the reduced case to
`formal/differential/regressions.json` after investigating it.

This found two additional production differences:

- Swift parsed numbers as signed `Int`, while Rust used `u64`. Large ordinals could count as two
  tokens on Swift and one on Rust. Swift now uses `UInt64`, and both ports test the range boundary.
- Swift compared accented graphemes canonically, while Rust split decomposed marks into separate
  content words. Both cleanup guards now apply NFC after lowercasing before extracting content.

## Lean scorer pilot

`formal/lean/Scorer.lean` has a recursive Levenshtein specification, `distance`, and a separately
implemented rolling-row algorithm, `rowDistance`. The row algorithm caches suffix distances
instead of recomputing the specification's three recursive edit choices. The kernel checks:

- Every cached row equals the specification's corresponding suffix distances.
- `rowDistance xs ys = distance xs ys` for arbitrary token types with decidable equality.
- Zero distance if and only if the token lists are equal.
- Symmetry, and `abs(length xs - length ys) ≤ distance ≤ max(length xs, length ys)`.

These are universal statements, with no input-length bound. The specification uses natural numbers;
the bridge does not prove machine-integer overflow safety. Triangle inequality remains a generated
property in both production ports, rather than a theorem in this pilot. WER retains its documented
empty-reference convention and is directional; the Lean laws concern token edit distance.

The proof has no `sorry`, custom axioms, `native_decide`, mathlib, or external solver. The runner audits
the key theorems' dependencies and permits only Lean's standard `propext`, `Quot.sound` and
`Classical.choice` foundations. A missing theorem, unfinished proof, warning or new axiom fails the run.

Lean 4.24.0 is pinned in `formal/lean/lean-toolchain`. Use an existing installation with `LEAN`, or
fetch the official checksum-pinned compiler into the normal build cache (requires `zstd`):

```sh
LEAN="$(bash scripts/fetch-lean.sh)" bash scripts/check-lean.sh
```

That checks the proofs, runs the executable Lean row algorithm over both ports' normalized token
lists, and compares its distances for the same corpus. The production implementations scan prefixes
left to right; Lean scans suffixes right to left. The universal proof covers the Lean algorithm.
The Swift/Rust bridge is empirical differential testing, not a proof of those compiled programs,
normalization, diff backtracking or Unicode behavior. The GitHub design-verification workflow runs
TLC and the proof/differential bridge when relevant sources change.

Further useful work: clipboard restoration with concurrent external changes, crash recovery during
model publication, and generated traces over full coordinator effects using injected audio/insertion
services. Those boundaries are outside the current proof. Direct proof of Rust code via
[Aeneas](https://github.com/AeneasVerif/aeneas) would be a separate project involving extraction and
a supported pure subset; it is not needed to use this executable Lean reference today.
