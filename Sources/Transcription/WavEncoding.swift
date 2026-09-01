import AVFoundation

/// Collects microphone buffers and emits 16 kHz mono 16-bit WAV. Shared by the cloud engines.
struct WavAccumulator {
    private static let sampleRate = 16000.0
    private static let pcmFormatTag: UInt16 = 1
    private static let channelCount: UInt16 = 1
    private static let bitsPerSample: UInt16 = 16
    private static let bytesPerFrame = UInt32(channelCount) * UInt32(bitsPerSample) / 8
    private static let riffChunkHeaderBytes: UInt32 = 36

    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: WavAccumulator.sampleRate, channels: 1, interleaved: true)!
    private var converter: AudioBufferConverter?

    private var samples = Data()

    mutating func append(_ buffer: AVAudioPCMBuffer) throws {
        if converter == nil { converter = AudioBufferConverter(to: target) }
        guard let out = try converter?.convert(buffer) else { return }
        if out.frameLength > 0, let channel = out.int16ChannelData?[0] {
            samples.append(Data(bytes: channel, count: Int(out.frameLength) * Int(Self.bytesPerFrame)))
        }
    }

    func wavData() -> Data {
        func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let byteRate = UInt32(Self.sampleRate) * Self.bytesPerFrame
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(le32(Self.riffChunkHeaderBytes + UInt32(samples.count)))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(le32(16))                                   // fmt chunk size
        data.append(le16(Self.pcmFormatTag))
        data.append(le16(Self.channelCount))
        data.append(le32(UInt32(Self.sampleRate)))
        data.append(le32(byteRate))
        data.append(le16(UInt16(Self.bytesPerFrame)))           // block align
        data.append(le16(Self.bitsPerSample))
        data.append("data".data(using: .ascii)!)
        data.append(le32(UInt32(samples.count)))
        data.append(samples)
        return data
    }
}
