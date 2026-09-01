import AVFoundation

/// Loudness of one buffer, 0 (silence) … 1 (full scale), on a dB curve so speech reads mid-range.
public struct AudioLevel: Equatable, Sendable {
    public let value: Float

    private static let floorDb: Float = -50

    static func measure(_ buffer: AVAudioPCMBuffer) -> AudioLevel {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return AudioLevel(value: 0) }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames { sum += channel[i] * channel[i] }
        let rms = (sum / Float(frames)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return AudioLevel(value: min(1, max(0, (db - floorDb) / -floorDb)))
    }
}

public enum CaptureFailure: Error {
    case noInputDevice
    case engineStart(Error)
}

public final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    public init() {}

    /// Warms the engine so the first `start()` is fast.
    public func prepare() {
        _ = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
    }

    /// Buffers arrive in the microphone's native format; the consumer converts.
    public func start(onLevel: @escaping (AudioLevel) -> Void) throws -> AsyncStream<AVAudioPCMBuffer> {
        if continuation != nil { stop() }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CaptureFailure.noInputDevice }

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = continuation
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            onLevel(AudioLevel.measure(buffer))
            if let copy = buffer.copied() { continuation.yield(copy) }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            self.continuation = nil
            throw CaptureFailure.engineStart(error)
        }
        return stream
    }

    /// Ends the stream; the consumer sees the end of input.
    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}

private extension AVAudioPCMBuffer {
    /// Tap buffers are owned by the engine; copy before handing them to another task.
    func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            memcpy(to.mData, from.mData, Int(from.mDataByteSize))
        }
        return copy
    }
}
