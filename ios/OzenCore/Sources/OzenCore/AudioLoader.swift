import AVFoundation
import Foundation

/// Decodes audio files to 16 kHz mono Float32.
///
/// Everything AVFoundation can open (m4a/aac, wav, mp3, caf, aiff, and Ogg Opus
/// where the OS supports it) goes through `AVAudioFile`. Ogg Opus (WhatsApp voice
/// notes) that AVAudioFile refuses is demuxed by `OggOpusSource` and decoded with
/// Apple's built-in Opus decoder. Audio is read in chunks, downmixed to mono at the
/// source rate (mean of channels, like librosa) and resampled to 16 kHz as it
/// streams, so the original-rate PCM is never held in full.
public enum AudioLoader {
    static let targetRate = 16000.0
    static let chunkFrames: AVAudioFrameCount = 65536

    /// Decodes any supported audio file to 16 kHz mono Float32.
    public static func load16kMono(url: URL) async throws -> [Float] {
        do {
            return try decode(url: url)
        } catch OzenError.cancelled {
            throw OzenError.cancelled
        } catch {
            throw OzenError.unreadableAudio(url.lastPathComponent)
        }
    }

    static func decode(url: URL) throws -> [Float] {
        let avError: Error
        do {
            let source = try AVAudioFileSource(url: url)
            return try resample(source)
        } catch let e as OzenError where e == .cancelled {
            throw e
        } catch {
            avError = error
        }
        if OggOpusSource.isOgg(url: url) {
            return try loadOggOpus(url: url)
        }
        throw avError
    }

    /// The Ogg Opus path on its own (used when AVAudioFile can't open the file).
    static func loadOggOpus(url: URL) throws -> [Float] {
        let source = try OggOpusSource(url: url)
        return try resample(source)
    }

    /// Pulls mono chunks from `source` and resamples them to 16 kHz.
    static func resample(_ source: MonoSource) throws -> [Float] {
        var out: [Float] = []
        let expected = Int((Double(source.estimatedFrames) * targetRate / source.sampleRate).rounded(.up))
        out.reserveCapacity(expected + 1024)

        if source.sampleRate == targetRate {
            while let chunk = try source.nextChunk() {
                if Task.isCancelled { throw OzenError.cancelled }
                out.append(contentsOf: chunk)
            }
            return out
        }

        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate,
                                           channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw OzenError.unreadableAudio("converter") }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let outCapacity: AVAudioFrameCount = 32768
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw OzenError.unreadableAudio("buffer")
        }
        var sourceError: Error?
        var finished = false
        while true {
            if Task.isCancelled { throw OzenError.cancelled }
            outBuf.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, inputStatus in
                if finished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    guard let chunk = try source.nextChunk(), !chunk.isEmpty,
                          let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(chunk.count))
                    else {
                        finished = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    chunk.withUnsafeBufferPointer {
                        buf.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count)
                    }
                    buf.frameLength = AVAudioFrameCount(chunk.count)
                    inputStatus.pointee = .haveData
                    return buf
                } catch {
                    sourceError = error
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let sourceError { throw sourceError }
            if status == .error { throw convError ?? OzenError.unreadableAudio("convert") }
            let n = Int(outBuf.frameLength)
            if n > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n))
            }
            if status == .endOfStream || (finished && n == 0) { break }
        }
        return out
    }
}

/// A stream of mono Float32 chunks at `sampleRate`.
protocol MonoSource: AnyObject {
    var sampleRate: Double { get }
    var estimatedFrames: Int { get }
    /// Next chunk, or nil at the end.
    func nextChunk() throws -> [Float]?
}

/// Averages `channels` deinterleaved channels into one.
private func downmix(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, frames: Int) -> [Float] {
    if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: frames)) }
    var out = [Float](repeating: 0, count: frames)
    for c in 0..<channels {
        let ch = data[c]
        for i in 0..<frames { out[i] += ch[i] }
    }
    let scale = 1 / Float(channels)
    for i in 0..<frames { out[i] *= scale }
    return out
}

final class AVAudioFileSource: MonoSource {
    let file: AVAudioFile
    let buffer: AVAudioPCMBuffer
    let channels: Int
    var sampleRate: Double { file.processingFormat.sampleRate }
    var estimatedFrames: Int { Int(max(0, file.length)) }

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate > 0,
              let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AudioLoader.chunkFrames)
        else { throw OzenError.unreadableAudio(url.lastPathComponent) }
        buffer = b
    }

    func nextChunk() throws -> [Float]? {
        if file.framePosition >= file.length { return nil }
        buffer.frameLength = 0
        try file.read(into: buffer, frameCount: AudioLoader.chunkFrames)
        let n = Int(buffer.frameLength)
        if n == 0 { return nil }
        return downmix(buffer.floatChannelData!, channels: channels, frames: n)
    }
}
