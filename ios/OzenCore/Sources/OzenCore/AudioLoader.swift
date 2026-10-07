import Foundation

// STUB — replaced by the real AVFoundation (+ Ogg Opus) decoder.
public enum AudioLoader {
    /// Decodes any supported audio file to 16 kHz mono Float32.
    public static func load16kMono(url: URL) async throws -> [Float] {
        throw OzenError.unreadableAudio(url.lastPathComponent)
    }
}
