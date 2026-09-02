/// Collects microphone samples at any rate and keeps them as 16 kHz mono, resampled as they arrive:
/// `f32` for local engines, `take_new` for streaming engines, 16-bit WAV bytes for cloud engines.
pub struct Accumulator {
    mono_16k: Vec<f32>,
    input_rate: u32,
    channels: u16,
    frames_seen: u64,
    /// Position, in input frames, of the next output sample.
    next_out_pos: f64,
    last_frame: f32,
    drained: usize,
}

pub const TARGET_RATE: u32 = 16_000;

impl Accumulator {
    pub fn new(input_rate: u32, channels: u16) -> Self {
        Self { mono_16k: Vec::new(), input_rate, channels: channels.max(1), frames_seen: 0, next_out_pos: 0.0, last_frame: 0.0, drained: 0 }
    }

    /// Interleaved frames as delivered by the capture backend. Downmixed, then linearly resampled
    /// across chunk boundaries (fine for speech at 44.1/48 kHz inputs).
    pub fn append(&mut self, interleaved: &[f32]) {
        let channels = self.channels as usize;
        let frames: Vec<f32> = interleaved.chunks(channels).map(|frame| frame.iter().sum::<f32>() / channels as f32).collect();
        if frames.is_empty() {
            return;
        }
        if self.input_rate == TARGET_RATE {
            self.mono_16k.extend_from_slice(&frames);
        } else {
            let ratio = self.input_rate as f64 / TARGET_RATE as f64;
            let base = self.frames_seen as f64;
            let end = base + frames.len() as f64;
            while self.next_out_pos < end - 1.0 {
                let index = self.next_out_pos.floor();
                let frac = (self.next_out_pos - index) as f32;
                let i = (index - base) as i64;
                let a = if i < 0 { self.last_frame } else { frames[i as usize] };
                let b = frames[(i + 1) as usize];
                self.mono_16k.push(a + (b - a) * frac);
                self.next_out_pos += ratio;
            }
        }
        self.last_frame = *frames.last().expect("non-empty");
        self.frames_seen += frames.len() as u64;
    }

    pub fn seconds(&self) -> f64 {
        self.frames_seen as f64 / self.input_rate as f64
    }

    /// Everything so far, mono 16 kHz.
    pub fn mono_16k(&self) -> Vec<f32> {
        self.mono_16k.clone()
    }

    /// Only what arrived since the last call — the feed for a streaming engine.
    pub fn take_new(&mut self) -> Vec<f32> {
        let fresh = self.mono_16k[self.drained..].to_vec();
        self.drained = self.mono_16k.len();
        fresh
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
