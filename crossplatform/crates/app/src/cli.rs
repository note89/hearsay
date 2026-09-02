use hearsay_core::engine::Engine;
use hearsay_core::keystore::KeyStore;
use hearsay_core::paths::support_dir;
use std::time::Instant;

pub fn engines() {
    let keys = KeyStore::new(&support_dir());
    for engine in Engine::all() {
        println!("{:<32} {:<10} {}", engine.wire_key(), if engine.is_available(&keys) { "available" } else { "needs key" }, engine.detail());
    }
}

pub fn transcribe(path: Option<&str>, engine_key: Option<&str>) {
    let Some(path) = path else {
        eprintln!("usage: hearsay-rs transcribe <file.wav> [engine wire key, see `hearsay-rs engines`]");
        std::process::exit(2);
    };
    let engine = match engine_key {
        None => Engine::default_engine(),
        Some(key) => match Engine::parse(key) {
            Some(engine) => engine,
            None => {
                eprintln!("unknown engine {key}; see `hearsay-rs engines`");
                std::process::exit(2);
            }
        },
    };
    let samples = match read_wav_16k(path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("cannot read {path}: {e}");
            std::process::exit(1);
        }
    };
    let dir = support_dir();
    let keys = KeyStore::new(&dir);
    let started = Instant::now();
    let transcriber = match hearsay_engines::make_engine(engine, &keys, &dir.join("models")) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("{}: {e}", engine.wire_key());
            std::process::exit(1);
        }
    };
    let load_ms = started.elapsed().as_millis();
    let started = Instant::now();
    match transcriber.transcribe(&samples, &hearsay_core::session::TranscriptionHints::default()) {
        Ok(text) if text.text().is_empty() => {
            eprintln!("nothing transcribed");
            std::process::exit(1);
        }
        Ok(text) => {
            println!("{}", text.text());
            eprintln!("[{} · {:.1}s audio · load {load_ms} ms · transcribe {} ms]", engine.wire_key(), samples.len() as f64 / 16_000.0, started.elapsed().as_millis());
        }
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}

fn read_wav_16k(path: &str) -> Result<Vec<f32>, String> {
    let mut reader = hound::WavReader::open(path).map_err(|e| e.to_string())?;
    let spec = reader.spec();
    let mut acc = hearsay_core::wav::Accumulator::new(spec.sample_rate, spec.channels);
    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => reader.samples::<f32>().filter_map(Result::ok).collect(),
        hound::SampleFormat::Int => {
            let max = (1u64 << (spec.bits_per_sample - 1)) as f32;
            reader.samples::<i32>().filter_map(Result::ok).map(|s| s as f32 / max).collect()
        }
    };
    acc.append(&samples);
    Ok(acc.mono_16k())
}
