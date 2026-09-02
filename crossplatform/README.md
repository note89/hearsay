# hearsay-rs — Linux & Windows

The Rust port of hearsay. User-facing install notes live in the top-level README; this file is for
people building it.

## Crates

| crate | role | depends on |
|---|---|---|
| `core` | the concepts: session, polish guard, scorer, lexicon, history, bake-off, key store, paths, wav | nothing platform-specific |
| `engines` | transcribers and polishers: whisper.cpp (`local-stt` feature), OpenRouter, ElevenLabs | core |
| `backends` | the OS: microphone (cpal), hold-gesture (global-hotkey), paste insertion (enigo + arboard) | core |
| `app` | `hearsay-rs`: eframe/egui window, overlay pill, five panes, the coordinator that syncs the concepts | all three |

Syncs between concepts happen only in `app/src/app.rs`. Panes in `app/src/panes.rs` are mappings, not logic.

## Verify

```sh
cargo test --workspace                                   # core: scorer, session, bake-off, keystore, lexicon
cargo build -p hearsay-rs && ./target/debug/hearsay-rs   # opens the window; RUST_LOG=info for engine status
./target/debug/hearsay-rs transcribe some.wav            # engine smoke test on a file
cargo check -p hearsay-rs --target x86_64-pc-windows-msvc --no-default-features   # Windows, from any host
```

Real Linux build + tests + whisper inference from a Mac, in Docker:

```sh
docker run --rm -v "$PWD":/work -v hearsay-linux-target:/target -w /work rust:1 bash -c '
  apt-get update -qq && apt-get install -y -qq cmake clang libclang-dev pkg-config libasound2-dev \
    libx11-dev libxi-dev libxtst-dev libxdo-dev libxkbcommon-dev libwayland-dev libgl1-mesa-dev &&
  CARGO_TARGET_DIR=/target cargo test --workspace && CARGO_TARGET_DIR=/target cargo build -p hearsay-rs'
```

## Data

`~/.local/share/hearsay` (Linux), `%APPDATA%\hearsay\data` (Windows), `~/Library/Application Support/hearsay`
(macOS — shared with the Swift app). Files: `settings.json`, `history.jsonl`, `dictionary.txt`,
`bakeoff.jsonl`, `keys.env` (0600), `models/ggml-*.bin`.
