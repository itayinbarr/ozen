import Foundation
import XCTest
@testable import OzenCore

/// Paths to the shared fixtures in spec/ and to the model, valid on macOS and in
/// the iOS simulator (which can read host paths).
enum Fixtures {
    /// Repo root: four levels up from this file's directory.
    static let root: URL = {
        var u = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { u = u.deletingLastPathComponent() }
        return u
    }()

    static let spec = root.appendingPathComponent("spec")
    static let golden = spec.appendingPathComponent("golden")

    static func goldenFile(_ name: String) -> URL { golden.appendingPathComponent(name) }

    static var hostHome: String {
        let env = ProcessInfo.processInfo.environment
        return env["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
    }

    /// The downloaded model (`onnx/` subfolder layout), from OZEN_MODEL_DIR or the default cache.
    static var sourceModelDir: URL {
        if let p = ProcessInfo.processInfo.environment["OZEN_MODEL_DIR"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return URL(fileURLWithPath: hostHome).appendingPathComponent(".cache/ozen/models/82aae03d")
    }

    /// A flat model directory as the app bundles it: symlinks to the cached model
    /// plus spec/mel_filters.bin. Skips the test when the model isn't downloaded.
    static func modelDir() throws -> URL {
        try lock.withLock {
            if let d = flatDir { return d }
            let d = try makeFlatModelDir()
            flatDir = d
            return d
        }
    }

    private static var flatDir: URL?

    private static func makeFlatModelDir() throws -> URL {
        let src = sourceModelDir
        let fm = FileManager.default
        func find(_ name: String) -> URL? {
            for c in [src.appendingPathComponent(name), src.appendingPathComponent("onnx").appendingPathComponent(name)]
            where fm.fileExists(atPath: c.path) { return c }
            return nil
        }
        guard let enc = find(ModelFiles.encoder), let dec = find(ModelFiles.decoder),
              let tok = find(ModelFiles.tokenizer)
        else { throw XCTSkip("model not found at \(src.path); run tools/model/fetch-model.sh or set OZEN_MODEL_DIR") }
        let mel = find(ModelFiles.melFilters) ?? spec.appendingPathComponent(ModelFiles.melFilters)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ozen-model-flat-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, target) in [(ModelFiles.encoder, enc), (ModelFiles.decoder, dec),
                               (ModelFiles.tokenizer, tok), (ModelFiles.melFilters, mel)] {
            try fm.createSymbolicLink(at: dir.appendingPathComponent(name), withDestinationURL: target)
        }
        return dir
    }

    private static var cachedEngine: Engine?
    private static let lock = NSLock()

    /// One engine shared by the model tests (loading the sessions takes a while).
    static func engine() throws -> Engine {
        let dir = try modelDir()
        return try lock.withLock {
            if let e = cachedEngine { return e }
            let e = try Engine(modelDirectory: dir)
            cachedEngine = e
            return e
        }
    }

    // MARK: - golden.json

    struct GoldenSegment: Decodable {
        let start: Int
        let end: Int
        let text: String
    }

    struct GoldenEntry: Decodable {
        let samples: Int
        let window: String
        let segments: [GoldenSegment]
    }

    static func goldenJSON() throws -> [String: GoldenEntry] {
        let data = try Data(contentsOf: goldenFile("golden.json"))
        return try JSONDecoder().decode([String: GoldenEntry].self, from: data)
    }

    // MARK: - helpers

    static func readFloat32LE(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        var out = [Float](repeating: 0, count: data.count / 4)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }

    /// Character error rate: Levenshtein distance over unicode scalars / reference length.
    static func cer(_ hyp: String, _ ref: String) -> Double {
        let a = Array(ref.unicodeScalars), b = Array(hyp.unicodeScalars)
        if a.isEmpty { return b.isEmpty ? 0 : 1 }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            if !b.isEmpty {
                for j in 1...b.count {
                    cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                }
            }
            swap(&prev, &cur)
        }
        return Double(prev[b.count]) / Double(a.count)
    }

    /// Physical footprint (what iOS jetsam counts), in MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Peak resident set size of this process, in MB.
    static func peakRSSMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576  // bytes on Darwin
    }
}

/// Synthetic segmenter signals; mirrors tools/model/golden.py synth()/lcg_noise().
enum Synth {
    struct Piece: Decodable {
        let n: Int
        let tone: Double?
        let hz: Double?
    }

    static func lcgNoise(_ n: Int, amp: Double, seed: UInt32) -> [Double] {
        var out = [Double](repeating: 0, count: n)
        var s = seed
        for i in 0..<n {
            s = s &* 1664525 &+ 1013904223
            out[i] = (Double(s) / 4294967296.0 * 2.0 - 1.0) * amp
        }
        return out
    }

    static func synth(_ pieces: [Piece], seed: UInt32) -> [Float] {
        let total = pieces.reduce(0) { $0 + $1.n }
        var x = lcgNoise(total, amp: 0.002, seed: seed)
        var off = 0
        let sr = 16000.0
        for p in pieces {
            if let tone = p.tone, tone != 0, let hz = p.hz {
                for i in 0..<p.n {
                    let t = Double(i)
                    let env = 0.6 + 0.4 * sin(2 * Double.pi * 4.0 * t / sr)
                    x[off + i] += tone * env * sin(2 * Double.pi * hz * t / sr)
                }
            }
            off += p.n
        }
        return x.map { Float($0) }
    }
}
