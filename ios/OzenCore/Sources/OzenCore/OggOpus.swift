import AVFoundation
import Foundation

/// Minimal Ogg demuxer (RFC 3533) for a single Opus stream (RFC 7845).
struct OggPacketReader {
    private let data: Data
    private var offset = 0
    private var serial: UInt32?
    private var partial = Data()
    private var queue: [Data] = []
    private(set) var lastGranule: Int64 = -1

    init(data: Data) { self.data = data }

    /// Next complete packet of the first logical stream, or nil at the end.
    mutating func next() throws -> Data? {
        while queue.isEmpty {
            guard try readPage() else { return nil }
        }
        return queue.removeFirst()
    }

    /// Reads one page; false at the end of the data.
    private mutating func readPage() throws -> Bool {
        let n = data.count
        guard offset + 27 <= n else { return false }
        let base = data.startIndex
        func byte(_ i: Int) -> UInt8 { data[base + i] }
        guard byte(offset) == 0x4F, byte(offset + 1) == 0x67, byte(offset + 2) == 0x67, byte(offset + 3) == 0x53 else {
            throw OzenError.unreadableAudio("ogg: bad page")
        }
        var granule: UInt64 = 0
        for i in 0..<8 { granule |= UInt64(byte(offset + 6 + i)) << (8 * UInt64(i)) }
        var pageSerial: UInt32 = 0
        for i in 0..<4 { pageSerial |= UInt32(byte(offset + 14 + i)) << (8 * UInt32(i)) }
        let segments = Int(byte(offset + 26))
        guard offset + 27 + segments <= n else { throw OzenError.unreadableAudio("ogg: truncated") }
        var lacing: [Int] = []
        lacing.reserveCapacity(segments)
        var bodyLength = 0
        for i in 0..<segments {
            let l = Int(byte(offset + 27 + i))
            lacing.append(l)
            bodyLength += l
        }
        var pos = offset + 27 + segments
        guard pos + bodyLength <= n else { throw OzenError.unreadableAudio("ogg: truncated") }
        offset = pos + bodyLength

        if serial == nil { serial = pageSerial }
        guard pageSerial == serial else { return true }  // skip other logical streams
        if granule != UInt64.max { lastGranule = Int64(bitPattern: granule) }

        for l in lacing {
            partial.append(data[(base + pos)..<(base + pos + l)])
            pos += l
            if l < 255 {
                queue.append(partial)
                partial = Data()
            }
        }
        return true
    }
}

/// Ogg Opus decoded with Apple's Opus decoder (AudioToolbox, iOS 11+/macOS 10.13+),
/// for OS versions whose AVAudioFile can't open the Ogg container.
final class OggOpusSource: MonoSource {
    let sampleRate = 48000.0
    private(set) var estimatedFrames: Int

    private var reader: OggPacketReader
    private let channels: Int
    private let converter: AVAudioConverter
    private let opusFormat: AVAudioFormat
    private let outBuf: AVAudioPCMBuffer
    private var skip: Int  // pre-skip still to drop
    private var remaining: Int?  // samples (48 kHz) still allowed by the final granule position
    private var inputDone = false
    private var outputDone = false

    static func isOgg(url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let magic = (try? h.read(upToCount: 4)) ?? Data()
        return magic == Data("OggS".utf8)
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        reader = OggPacketReader(data: data)
        guard let head = try reader.next(), head.count >= 19,
              head.prefix(8) == Data("OpusHead".utf8)
        else { throw OzenError.unreadableAudio(url.lastPathComponent) }
        let h = [UInt8](head)
        channels = Int(h[9])
        let preSkip = Int(h[10]) | (Int(h[11]) << 8)
        let mapping = h[18]
        guard channels >= 1, channels <= 2, mapping == 0 else {
            throw OzenError.unreadableAudio("\(url.lastPathComponent): unsupported Opus channel mapping")
        }
        guard let tags = try reader.next(), tags.prefix(8) == Data("OpusTags".utf8) else {
            throw OzenError.unreadableAudio(url.lastPathComponent)
        }
        skip = preSkip

        // Total length from the last page's granule position (sample count at 48 kHz incl. pre-skip).
        var scan = OggPacketReader(data: data)
        while try scan.next() != nil {}
        if scan.lastGranule > Int64(preSkip) {
            remaining = Int(scan.lastGranule) - preSkip
            estimatedFrames = Int(scan.lastGranule) - preSkip
        } else {
            estimatedFrames = 0
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &asbd),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                      channels: AVAudioChannelCount(channels), interleaved: false),
              let conv = AVAudioConverter(from: opus, to: pcm),
              let buf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 48000)
        else { throw OzenError.unreadableAudio("\(url.lastPathComponent): no Opus decoder") }
        opusFormat = opus
        converter = conv
        outBuf = buf

        // Apple's decoder already drops some leading samples (120 = Opus' 2.5 ms
        // lookahead on macOS 26 / iOS 26). Measure it on the first packet so the
        // total trim is exactly the stream's pre-skip.
        var peek = reader
        if let first = try peek.next() {
            let n = Self.samplesInPacket(first)
            let decoded = Self.decodedLength(first, format: opus, channels: channels)
            if let decoded, decoded <= n {
                skip = max(0, preSkip - (n - decoded))
            }
        }
    }

    /// How many samples Apple's decoder emits for `packet` decoded on its own.
    private static func decodedLength(_ packet: Data, format: AVAudioFormat, channels: Int) -> Int? {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                      channels: AVAudioChannelCount(channels), interleaved: false),
              let conv = AVAudioConverter(from: format, to: pcm),
              let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 5760 * 2)
        else { return nil }
        var fed = false
        var total = 0
        for _ in 0..<4 {
            out.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, inputStatus in
                if fed {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                let b = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: packet.count)
                packet.copyBytes(to: b.data.assumingMemoryBound(to: UInt8.self), count: packet.count)
                b.packetDescriptions![0] = AudioStreamPacketDescription(
                    mStartOffset: 0, mVariableFramesInPacket: UInt32(samplesInPacket(packet)),
                    mDataByteSize: UInt32(packet.count))
                b.packetCount = 1
                b.byteLength = UInt32(packet.count)
                inputStatus.pointee = .haveData
                return b
            }
            total += Int(out.frameLength)
            if status != .haveData { break }
        }
        return total
    }

    /// Samples per channel at 48 kHz in an Opus packet (RFC 6716 §3.1).
    static func samplesInPacket(_ p: Data) -> Int {
        guard let toc = p.first else { return 0 }
        let config = Int(toc >> 3)
        let frameSize: Int
        if config < 12 {
            frameSize = [480, 960, 1920, 2880][config & 3]
        } else if config < 16 {
            frameSize = (config & 1) == 0 ? 480 : 960
        } else {
            frameSize = [120, 240, 480, 960][(config - 16) & 3]
        }
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: frames = p.count > 1 ? Int(p[p.startIndex + 1] & 0x3F) : 0
        }
        return frameSize * frames
    }

    func nextChunk() throws -> [Float]? {
        while !outputDone {
            if Task.isCancelled { throw OzenError.cancelled }
            outBuf.frameLength = 0
            var readError: Error?
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { [self] requested, inputStatus in
                if inputDone {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                var packets: [Data] = []
                let want = max(1, min(Int(requested), 64))
                do {
                    while packets.count < want, let p = try reader.next() {
                        if !p.isEmpty { packets.append(p) }
                    }
                } catch {
                    readError = error
                }
                if packets.isEmpty {
                    inputDone = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let maxSize = packets.map(\.count).max()!
                let buffer = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: AVAudioPacketCount(packets.count),
                                                     maximumPacketSize: maxSize)
                var byteOffset = 0
                for (i, p) in packets.enumerated() {
                    p.copyBytes(to: buffer.data.advanced(by: byteOffset).assumingMemoryBound(to: UInt8.self),
                                count: p.count)
                    buffer.packetDescriptions![i] = AudioStreamPacketDescription(
                        mStartOffset: Int64(byteOffset),
                        mVariableFramesInPacket: UInt32(Self.samplesInPacket(p)),
                        mDataByteSize: UInt32(p.count))
                    byteOffset += p.count
                }
                buffer.packetCount = AVAudioPacketCount(packets.count)
                buffer.byteLength = UInt32(byteOffset)
                inputStatus.pointee = .haveData
                return buffer
            }
            if let readError { throw readError }
            if status == .error { throw convError ?? OzenError.unreadableAudio("opus decode") }
            if status == .endOfStream { outputDone = true }

            var start = 0
            var count = Int(outBuf.frameLength)
            let drop = min(skip, count)
            skip -= drop
            start += drop
            count -= drop
            if let r = remaining {
                count = min(count, r)
                remaining = r - count
                if remaining == 0 { outputDone = true }
            }
            if count > 0 {
                let ch = outBuf.floatChannelData!
                if channels == 1 { return Array(UnsafeBufferPointer(start: ch[0] + start, count: count)) }
                var out = [Float](repeating: 0, count: count)
                for c in 0..<channels {
                    for i in 0..<count { out[i] += ch[c][start + i] }
                }
                for i in 0..<count { out[i] /= Float(channels) }
                return out
            }
        }
        return nil
    }

}
