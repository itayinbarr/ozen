import Accelerate
import Foundation

/// Whisper log-mel features, identical to `reference.log_mel`:
/// 30 s window (zero-padded / trimmed), reflect pad 200, periodic Hann 400,
/// hop 160, 3000 frames, power spectrum (201 bins) x slaney filters, log10,
/// clamp to max-8, (x+4)/4. Output is [80][3000] row-major Float32.
///
/// n_fft = 400 is not a length vDSP's FFT supports, so the windowed real DFT is
/// one matrix product: frames (3000x400) x [cos | sin] (400x402).
final class MelSpectrogram {
    static let sampleRate = 16000
    static let nFFT = 400
    static let hop = 160
    static let nMels = 80
    static let nSamples = 30 * 16000
    static let nFrames = 3000
    static let nBins = nFFT / 2 + 1  // 201

    /// (201, 80) row-major [freq][mel].
    private let filters: [Float]
    /// Hann-windowed DFT basis, (400, 402) row-major: columns 0..<201 cos, 201..<402 sin.
    private let basis: [Float]

    // Scratch, reused across windows (one window at a time).
    private var padded: [Float]
    private var frames: [Float]
    private var spectrum: [Float]
    private var power: [Float]
    private var mel: [Float]

    init(filtersURL: URL) throws {
        let data = try Data(contentsOf: filtersURL)
        let count = Self.nBins * Self.nMels
        guard data.count == count * 4 else {
            throw OzenError.modelMissing(ModelFiles.melFilters)
        }
        var f = [Float](repeating: 0, count: count)
        _ = f.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        // File is little-endian, as is every Apple platform we run on.
        filters = f
        basis = Self.makeBasis()
        padded = [Float](repeating: 0, count: Self.nSamples + Self.nFFT)
        frames = [Float](repeating: 0, count: Self.nFrames * Self.nFFT)
        spectrum = [Float](repeating: 0, count: Self.nFrames * 2 * Self.nBins)
        power = [Float](repeating: 0, count: Self.nFrames * Self.nBins)
        mel = [Float](repeating: 0, count: Self.nFrames * Self.nMels)
    }

    private static func makeBasis() -> [Float] {
        let n = nFFT, bins = nBins, cols = 2 * nBins
        var b = [Float](repeating: 0, count: n * cols)
        for t in 0..<n {
            // np.hanning(401)[:-1]
            let w = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(t) / Double(n))
            for k in 0..<bins {
                // Reduce the angle exactly before the trig call.
                let phase = 2.0 * Double.pi * Double((t * k) % n) / Double(n)
                b[t * cols + k] = Float(w * cos(phase))
                b[t * cols + bins + k] = Float(-w * sin(phase))
            }
        }
        return b
    }

    /// Computes features for up to 30 s of 16 kHz audio into `out` (80*3000 floats).
    func compute(_ x: UnsafeBufferPointer<Float>, into out: UnsafeMutableBufferPointer<Float>) {
        precondition(out.count == Self.nMels * Self.nFrames)
        let N = Self.nSamples, P = Self.nFFT / 2
        let m = min(x.count, N)

        padded.withUnsafeMutableBufferPointer { pad in
            // pad[P + i] = audio[i]; audio is x zero-padded to N.
            pad.update(repeating: 0)
            if m > 0 { pad.baseAddress!.advanced(by: P).update(from: x.baseAddress!, count: m) }
            // Reflect (no edge repeat): pad[P - j] = audio[j], pad[P + N - 1 + j] = audio[N - 1 - j].
            for j in 1...P {
                pad[P - j] = pad[P + j]
                pad[P + N - 1 + j] = pad[P + N - 1 - j]
            }
        }

        let nFrames = Self.nFrames, nFFT = Self.nFFT, hop = Self.hop
        padded.withUnsafeBufferPointer { pad in
            frames.withUnsafeMutableBufferPointer { fr in
                for f in 0..<nFrames {
                    fr.baseAddress!.advanced(by: f * nFFT).update(from: pad.baseAddress!.advanced(by: f * hop), count: nFFT)
                }
            }
        }

        let cols = 2 * Self.nBins
        // spectrum (3000x402) = frames (3000x400) x basis (400x402)
        frames.withUnsafeBufferPointer { fr in
            basis.withUnsafeBufferPointer { bs in
                spectrum.withUnsafeMutableBufferPointer { sp in
                    vDSP_mmul(fr.baseAddress!, 1, bs.baseAddress!, 1, sp.baseAddress!, 1,
                              vDSP_Length(nFrames), vDSP_Length(cols), vDSP_Length(nFFT))
                }
            }
        }

        // power = re^2 + im^2
        let bins = Self.nBins
        spectrum.withUnsafeMutableBufferPointer { sp in
            power.withUnsafeMutableBufferPointer { pw in
                for f in 0..<nFrames {
                    let re = sp.baseAddress!.advanced(by: f * cols)
                    var split = DSPSplitComplex(realp: re, imagp: re.advanced(by: bins))
                    vDSP_zvmags(&split, 1, pw.baseAddress!.advanced(by: f * bins), 1, vDSP_Length(bins))
                }
            }
        }

        // mel (3000x80) = power (3000x201) x filters (201x80)
        let nMels = Self.nMels
        power.withUnsafeBufferPointer { pw in
            filters.withUnsafeBufferPointer { fl in
                mel.withUnsafeMutableBufferPointer { ml in
                    vDSP_mmul(pw.baseAddress!, 1, fl.baseAddress!, 1, ml.baseAddress!, 1,
                              vDSP_Length(nFrames), vDSP_Length(nMels), vDSP_Length(bins))
                }
            }
        }

        let total = nFrames * nMels
        mel.withUnsafeMutableBufferPointer { ml in
            let p = ml.baseAddress!
            var n = Int32(total)
            var floor: Float = 1e-10
            vDSP_vthr(p, 1, &floor, p, 1, vDSP_Length(total))
            vvlog10f(p, p, &n)
            var mx: Float = 0
            vDSP_maxv(p, 1, &mx, vDSP_Length(total))
            var lo = mx - 8
            vDSP_vthr(p, 1, &lo, p, 1, vDSP_Length(total))
            var scale: Float = 0.25, offset: Float = 1
            vDSP_vsmsa(p, 1, &scale, &offset, p, 1, vDSP_Length(total))
            // (3000x80) -> (80x3000)
            vDSP_mtrans(p, 1, out.baseAddress!, 1, vDSP_Length(nMels), vDSP_Length(nFrames))
        }
    }
}
