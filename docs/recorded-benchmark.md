# Recorded dictation benchmark

Record your voice once, correct the references, and replay those exact files after each pipeline change. The runner uses the app's engines, transcription hints, cleanup prompt, meaning guard, cleanup deadline, and dictionary rewrites. It does not insert text into another app.

## Make your corpus

```sh
scripts/benchmark.sh init "$HOME/Library/Application Support/hearsay/benchmark"
scripts/benchmark.sh record "$HOME/Library/Application Support/hearsay/benchmark"
```

The starter has nine editable prompts covering numbers, jargon, corrections, chat, lists, email, Swedish, mixed Swedish/English, Portuguese, and a longer request. Return starts recording; Return stops it. Existing recordings are skipped. To redo a take, give it a new audio filename in `suite.json`; keep the original take for reproducibility.

Edit `suite.json`:

- `spoken`: exactly what you actually said, including false starts and fillers. Optional; without it, raw transcription is unscored.
- `expected`: the written text you wanted, including punctuation, capitalization, paragraphs, lists and identifiers. This is the final-output target.
- `wispr`: optionally paste Wispr Flow's output **from the same recording**. The runner compares it with your ideal output. It does not control Wispr Flow or generate a rival result.
- `locale`, `style`, optional `fieldContext`: the conditions you want to test. Cloud cleanup strips field context, as it does in the app.
- `vocabulary` and `rewrites`: a frozen dictionary for the corpus, independent of your current app dictionary.

You can also supply existing WAV, M4A or other files AVFoundation can read using paths relative to the corpus. Keep this personal corpus outside Git. Templates have no recordings or captured rival output.

## Race every model

```sh
scripts/benchmark.sh run "$HOME/Library/Application Support/hearsay/benchmark" \
  --all-models --execution hybrid
```

`--all-models` selects every registered transcription engine with Full on-device cleanup. Download local models in Dictation first and configure the keys for cloud engines. Missing models/keys produce failed rows; the runner never silently substitutes another engine. `hearsay-benchmark engines` lists wire keys for custom configurations.

Choose execution:

| Mode | Scheduling | Use |
|---|---|---|
| `sequential` | Every pipeline in configuration order, one at a time | Isolated timing for everything |
| `hybrid` (default) | Cloud pipelines run together; after they finish, local pipelines run one at a time | Compare many models and measure local startup without competing runs |
| `parallel` | Apple/cloud pipelines run together and overlap a serial lane of downloaded models | Fastest compatible scheduling; timing includes contention |

Downloaded models share one resident-model runtime, so running different downloaded models concurrently would replace each other's weights. They stay sequential in every mode. Each model finishes its entire corpus before the next is loaded. The runner releases downloaded weights before each local pipeline. Startup is marked **cold** for the first load and **resident** on subsequent takes. Cold does not mean the OS disk cache was cleared. Apple model provisioning is recorded as setup; the API does not expose a separate Apple weight-loading duration.

Edit `pipelines.json` to compare selected engines, raw/light/full cleanup or cloud cleanup, and set `repetitions` (1–100). Each pipeline has a stable `id`, `engine` wire key, `polish` (`off`, `light`, `full`), `polishEngine` (`onDevice`, `openRouter`), and optional `polishModel` for a different OpenRouter cleanup model. The starter's normal run compares Apple raw/light/full; `--all-models` replaces that selection. Cloud entries explicitly send audio and/or transcripts to the selected provider. The default configuration is on-device.

`pacing: "realtime"` feeds 2048-frame buffers at the original speaking speed, matching the app's streaming path. `"immediate"` feeds them as fast as possible for throughput experiments. Reports retain pacing and execution mode; baseline comparisons reject different modes.

## Save a baseline and rerun automatically

```sh
CORPUS="$HOME/Library/Application Support/hearsay/benchmark"
scripts/benchmark.sh run "$CORPUS" --all-models --execution hybrid \
  --output "$CORPUS/baseline.json"

# After changing the pipeline, rerun the same command against the baseline:
scripts/benchmark.sh run "$CORPUS" --all-models --execution hybrid \
  --baseline "$CORPUS/baseline.json" --fail-on-regression
```

The second command can be used in a local build hook or scheduler without further input. It saves a timestamped JSON report and readable Markdown report, then exits nonzero on an engine failure or quality regression. Keep cloud runs out of public CI unless you deliberately provide keys and a shareable corpus. No recurring schedule is created by this feature.

Compare existing reports without model calls:

```sh
scripts/benchmark.sh compare "$CORPUS/baseline.json" "$CORPUS/runs/current.json" --fail-on-regression
```

Reports contain every raw and delivered transcript, failures and cleanup fallbacks, setup and model load time, first partial, transcription tail, cleanup time, total time including setup, and final readiness after audio. The table shows p50/p95 readiness and cold model loading separately. Setup is excluded from readiness but included in total time.

Raw WER uses `spoken`; final WER uses `expected`. The existing WER normalizer tolerates equivalent number/unit spellings and ignores punctuation. Character error rate (CER) and exact matches preserve punctuation, case, identifiers and line breaks. Similarity to one reference cannot judge whether an alternative rewrite preserves intent; inspect the per-case output when tuning Full cleanup. Wispr is a saved comparison, not the ground truth.

Regressions are checked per case and pipeline across repetitions: more failures, more cleanup fallbacks, worse final WER/CER, or fewer exact matches. Timings are reported without a latency pass/fail threshold. A SHA-256 fingerprint includes the corpus, references, dictionary and audio bytes; changing them requires a new baseline. The wrapper records the Git revision, source hash and build mode, and reports snapshot the exact cleanup prompts and pinned local-model revisions.

`scripts/benchmark.sh` builds optimized release binaries and installs the existing MLX Metal resource. For runner development, set `HEARSAY_BENCHMARK_BUILD=debug`. Reports and recordings are written with private file permissions. Microphone recording needs your terminal's microphone permission; replay needs no microphone, hotkey, or Accessibility permission.
