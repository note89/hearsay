import AVFoundation

enum AudioConversionFailure: Error {
    case conversionFailed
}

/// Resamples audio buffers into a target format, keeping converter state across buffers.
struct AudioBufferConverter {
    /// The resampler can emit a few frames beyond the length ratio; headroom avoids a short read.
    private static let slackFrames: AVAudioFrameCount = 32

    private let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to target: AVAudioFormat) {
        self.target = target
    }

    mutating func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + Self.slackFrames
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var handedOver = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
            if handedOver {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw conversionError ?? AudioConversionFailure.conversionFailed }
        return out.frameLength > 0 ? out : nil
    }
}
