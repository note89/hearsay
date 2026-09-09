# hearsay v0.2.2 — cleanup that runs, and a cloud cleanup model on the Mac

A 290-word dictation came out raw because the cleanup step hit its 8 s timeout and the app kept the
transcript. Fixed, and the ceiling of the on-device model on long rewrites is now something you can
choose around.

**New**
- **Cleanup model choice on macOS** (Style pane): on this Mac (private, free) or Gemini 3.7 Flash via
  OpenRouter. The cloud model receives the transcript and dictionary terms only; field context is not even
  read when it is selected.
- **Cleanup timeout scales with length**: 6 s plus 70 ms per word, capped at 40 s, instead of a flat 8 s.
- **Cleanup rules tightened** (both apps): keep every request and the sign-off, keep the point of view,
  standard spelling for product names ("key cloak" → Keycloak), lists for enumerated options.
- OpenRouter errors say what the server said ("no credits", with the top-up link) instead of "failed".
- `hearsay-check polish file.txt [light|full] [style] [cloud]` and `hearsay-rs polish file.txt [model]`
  run cleanup on a transcript file and time it.
- Linux/Windows cleanup default is Gemini 3.7 Flash, the same model as the Mac cloud option.
