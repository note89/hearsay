# Portable whisper.cpp for binaries that run on machines other than the one that built them.
# whisper-rs-sys drives ggml's cmake and leaves GGML_NATIVE at its default (ON = -march=native), which
# would tune a release binary to the build runner's CPU. With native off, ggml's own defaults apply:
# AVX/AVX2/FMA/F16C on x86-64 (every CPU since 2013), no AVX-512; generic flags on arm64.
# Loaded through CMAKE_TOOLCHAIN_FILE by CI and the Nix package; a local `cargo build` stays native.
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
