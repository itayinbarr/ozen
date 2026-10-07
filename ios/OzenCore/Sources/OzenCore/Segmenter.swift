import Foundation

/// Paragraph segmenter. Implements spec/segmenter.md exactly (64-bit energies);
/// must agree with tools/model/reference.py and web/src/engine/segmenter.ts on
/// spec/segmenter-vectors.json.
enum Segmenter {
    static let frame = 480
    static let bridge = 17
    static let pad = 5
    static let minSpeech = 7
    static let targetMax = 667
    static let hardMax = 933
    static let splitFrom = 500
    static let paraGap = 50
    static let minSeg = 67

    /// Per-frame energy in dB: `10*log10(mean(x²) + 1e-10)`, last frame partial.
    static func frameDB(_ x: UnsafeBufferPointer<Float>) -> [Double] {
        let n = (x.count + frame - 1) / frame
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = i * frame
            let b = min(a + frame, x.count)
            var sum = 0.0
            for j in a..<b {
                let v = Double(x[j])
                sum += v * v
            }
            out[i] = 10 * log10(sum / Double(b - a) + 1e-10)
        }
        return out
    }

    /// Paragraph cut points as half-open sample ranges.
    static func segment(_ samples: [Float]) -> [Range<Int>] {
        samples.withUnsafeBufferPointer { segment($0) }
    }

    static func segment(_ x: UnsafeBufferPointer<Float>) -> [Range<Int>] {
        if x.isEmpty { return [] }
        let db = frameDB(x)
        let n = db.count
        let sorted = db.sorted()
        let noise = sorted[Int((0.1 * Double(n - 1)).rounded(.down))]
        let peak = sorted[Int((0.95 * Double(n - 1)).rounded(.down))]
        if peak < -55 { return [] }
        let thr = noise + max(6.0, 0.35 * (peak - noise))

        // Runs of voiced frames, [s, e).
        var runs: [(s: Int, e: Int)] = []
        var i = 0
        while i < n {
            if db[i] > thr {
                var j = i
                while j < n && db[j] > thr { j += 1 }
                runs.append((i, j))
                i = j
            } else {
                i += 1
            }
        }

        var bridged: [(s: Int, e: Int)] = []
        for r in runs {
            if let last = bridged.last, r.s - last.e < bridge {
                bridged[bridged.count - 1].e = r.e
            } else {
                bridged.append(r)
            }
        }

        let kept = bridged.filter { $0.e - $0.s >= minSpeech }

        var padded: [(s: Int, e: Int)] = []
        for r in kept {
            let a = max(0, r.s - pad), b = min(n, r.e + pad)
            if let last = padded.last, a <= last.e {
                padded[padded.count - 1].e = max(last.e, b)
            } else {
                padded.append((a, b))
            }
        }

        var split: [(s: Int, e: Int)] = []
        for r in padded {
            var a = r.s
            let b = r.e
            while b - a > hardMax {
                let lo = a + splitFrom, hi = a + hardMax
                var k = lo
                for j in lo..<hi where db[j] < db[k] { k = j }
                split.append((a, k))
                a = k
            }
            split.append((a, b))
        }

        var paras: [(s: Int, e: Int)] = []
        for r in split {
            guard let cur = paras.last else {
                paras.append(r)
                continue
            }
            if r.s - cur.e < paraGap && r.e - cur.s <= targetMax {
                paras[paras.count - 1].e = r.e
            } else {
                paras.append(r)
            }
        }

        var changed = true
        while changed {
            changed = false
            for idx in paras.indices {
                let p = paras[idx]
                if p.e - p.s >= minSeg { continue }
                if idx > 0 && p.e - paras[idx - 1].s <= hardMax {
                    paras[idx - 1].e = p.e
                    paras.remove(at: idx)
                    changed = true
                    break
                }
                if idx + 1 < paras.count && paras[idx + 1].e - p.s <= hardMax {
                    paras[idx + 1].s = p.s
                    paras.remove(at: idx)
                    changed = true
                    break
                }
            }
        }

        return paras.map { ($0.s * frame)..<min($0.e * frame, x.count) }
    }
}
