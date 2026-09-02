/// Collects microphone samples at any rate and hands out 16 kHz mono: `f32` for local engines,
/// 16-bit WAV bytes for cloud engines.
pub struct Accumulator {
    samples: Vec<f32>,
    input_rate: u32,
    channels: u16,
}

pub const TARGET_RATE: u32 = 16_000;

impl Accumulator {
    pub fn new(input_rate: u32, channels: u16) -> Self {
        Self { samples: Vec::new(), input_rate, channels: channels.max(1) }
    }

    /// Interleaved frames as delivered by the capture backend.
    pub fn append(&mut self, interleaved: &[f32]) {
        let channels = self.channels as usize;
        self.samples.extend(interleaved.chunks(channels).map(|frame| frame.iter().sum::<f32>() / channels as f32));
    }

    pub fn seconds(&self) -> f64 {
        self.samples.len() as f64 / self.input_rate as f64
    }

    /// Mono 16 kHz, linear resampling (fine for speech at 44.1/48 kHz inputs).
    pub fn mono_16k(&self) -> Vec<f32> {
        if self.input_rate == TARGET_RATE {
            return self.samples.clone();
        }
        let ratio = self.input_rate as f64 / TARGET_RATE as f64;
        let out_len = (self.samples.len() as f64 / ratio) as usize;
        (0..out_len)
            .map(|i| {
                let pos = i as f64 * ratio;
                let index = pos as usize;
                let frac = (pos - index as f64) as f32;
                let a = self.samples.get(index).copied().unwrap_or(0.0);
                let b = self.samples.get(index + 1).copied().unwrap_or(a);
                a + (b - a) * frac
            })
            .collect()
    }

    pub fn wav_data(&self) -> Vec<u8> {
        let pcm = self.mono_16k();
        let byte_rate = TARGET_RATE * 2;
        let data_len = (pcm.len() * 2) as u32;
        let mut out = Vec::with_capacity(44 + data_len as usize);
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_len).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes()); // PCM
        out.extend_from_slice(&1u16.to_le_bytes()); // mono
        out.extend_from_slice(&TARGET_RATE.to_le_bytes());
        out.extend_from_slice(&byte_rate.to_le_bytes());
        out.extend_from_slice(&2u16.to_le_bytes()); // block align
        out.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_len.to_le_bytes());
        for sample in pcm {
            out.extend_from_slice(&((sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16).to_le_bytes());
        }
        out
    }

    /// RMS on a dB curve, 0…1, for the overlay meter.
    pub fn level(interleaved: &[f32]) -> f32 {
        if interleaved.is_empty() {
            return 0.0;
        }
        let rms = (interleaved.iter().map(|s| s * s).sum::<f32>() / interleaved.len() as f32).sqrt();
        let db = 20.0 * rms.max(1e-7).log10();
        ((db + 50.0) / 50.0).clamp(0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resamples_to_16k_and_encodes_wav() {
        let mut acc = Accumulator::new(48_000, 2);
        acc.append(&vec![0.5f32; 48_000 * 2]); // one second, stereo
        let mono = acc.mono_16k();
        assert!((mono.len() as i64 - 16_000).abs() <= 1);
        let wav = acc.wav_data();
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(wav.len(), 44 + mono.len() * 2);
    }
}
