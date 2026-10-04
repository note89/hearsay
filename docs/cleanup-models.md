# Cleanup model comparison

GLM 5.3 Flash is the initial OpenRouter choice because it combines low token prices with subsecond median cleanup in this sample. Gemini 3.5 Flash-Lite was faster in the same sample; Gemini 3.8 Flash is also selectable. Apple remains the default provider.

## Measurement

On 4 October 2026, the production OpenRouter polisher processed six published sample transcripts: a self-correction, technical terms, a list, Swedish, Portuguese and a longer request. One sequential request per model and sample, using Full cleanup, temperature zero, transcript and dictionary terms only. Times include the HTTP round trip from this Mac. Presets use their lowest supported reasoning setting and throughput routing within their price cap; the previous Gemini 3.7 request uses its existing provider defaults.

| Model | Median cleanup | Range | Accepted by integrity guard |
|---|---|---|---|
| GLM 5.3 Flash | 0.86 s | 0.46–1.88 s | 6/6 |
| Gemini 3.8 Flash | 1.09 s | 1.00–1.61 s | 6/6 |
| Gemini 3.5 Flash-Lite | 0.52 s | 0.44–0.74 s | 6/6 |
| Gemini 3.7 Flash (previous request settings) | 3.91 s | 1.85–5.61 s | 6/6 |

These are initial samples, not a ranking of transcription accuracy or a guarantee of dictation latency. Guard acceptance checks output integrity, not every cleanup rule. The [responses and timings](cleanup-model-comparison.json) retain the actual outputs for inspection. All four models applied the explicit day correction in the final run. Formatting and phrasing still vary. An earlier GLM run retained the abandoned day; the shared prompt now explicitly removes corrected details and uses time formats appropriate to the original language.

Model prices and supported reasoning settings came from the [OpenRouter model catalog](https://openrouter.ai/api/v1/models). The selectable presets are [GLM 5.3 Flash](https://openrouter.ai/z-ai/glm-5.3-flash), [Gemini 3.8 Flash](https://openrouter.ai/google/gemini-3.8-flash) and [Gemini 3.5 Flash-Lite](https://openrouter.ai/google/gemini-3.5-flash-lite).

## Reproduce

The opt-in probe sends only the repository's published sample transcripts. Set `OPENROUTER_API_KEY`, `HEARSAY_LIVE_CLEANUP=1` and `HEARSAY_CLEANUP_PROBE_OUTPUT` to an output JSON path, then run `scripts/test.sh --filter LiveCleanupProbeTests`. It incurs provider charges.

For Ollama, start the local server and choose an installed instruction model in Style. Local-model speed depends on the model, its quantization and this Mac. Automated protocol tests cover discovery, privacy, request options, and keeping raw text for server failures and incomplete responses. No local inference timing is reported: Ollama was not running during this comparison.
