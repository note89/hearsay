use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use hearsay_core::wav::Accumulator;
use std::sync::{Arc, Mutex};

/// An open microphone. Dropping it stops capture; `stop` hands back the audio.
pub struct Recording {
    _stream: cpal::Stream,
    accumulator: Arc<Mutex<Accumulator>>,
    level: Arc<Mutex<f32>>,
}

#[derive(Debug, thiserror::Error)]
pub enum CaptureFailure {
    #[error("no input device")]
    NoInputDevice,
    #[error("input config: {0}")]
    Config(String),
    #[error("stream: {0}")]
    Stream(String),
}

impl Recording {
    pub fn start() -> Result<Self, CaptureFailure> {
        let host = cpal::default_host();
        let device = host.default_input_device().ok_or(CaptureFailure::NoInputDevice)?;
        let config = device.default_input_config().map_err(|e| CaptureFailure::Config(e.to_string()))?;
        let rate = config.sample_rate().0;
        let channels = config.channels();
        let accumulator = Arc::new(Mutex::new(Accumulator::new(rate, channels)));
        let level = Arc::new(Mutex::new(0.0f32));
        let (acc, lvl) = (accumulator.clone(), level.clone());
        let stream = device
            .build_input_stream(
                &config.into(),
                move |data: &[f32], _| {
                    if let Ok(mut a) = acc.lock() {
                        a.append(data);
                    }
                    if let Ok(mut l) = lvl.lock() {
                        *l = Accumulator::level(data);
                    }
                },
                |e| log::error!("audio stream: {e}"),
                None,
            )
            .map_err(|e| CaptureFailure::Stream(e.to_string()))?;
        stream.play().map_err(|e| CaptureFailure::Stream(e.to_string()))?;
        Ok(Self { _stream: stream, accumulator, level })
    }

    /// Latest input level 0…1 for the overlay meter.
    pub fn level(&self) -> f32 {
        self.level.lock().map(|l| *l).unwrap_or(0.0)
    }

    pub fn seconds(&self) -> f64 {
        self.accumulator.lock().map(|a| a.seconds()).unwrap_or(0.0)
    }

    /// Mono 16 kHz samples that arrived since the last call — the feed for a live engine.
    pub fn take_new(&self) -> Vec<f32> {
        self.accumulator.lock().map(|mut a| a.take_new()).unwrap_or_default()
    }

    /// Ends capture and returns every mono 16 kHz sample of the take.
    pub fn stop(self) -> Vec<f32> {
        drop(self._stream);
        self.accumulator.lock().map(|a| a.mono_16k()).unwrap_or_default()
    }
}
