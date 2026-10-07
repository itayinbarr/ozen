import COzenORT
import Foundation

/// Ozen-v1 inference: segmenter -> log-mel -> Whisper encoder -> greedy merged
/// decoder -> tokenizer, one paragraph window at a time. Mirrors
/// tools/model/reference.py `Model.transcribe`.
final class Engine: @unchecked Sendable {
    struct Options: Sendable {
        /// Intra-op threads for ORT (both sessions).
        var intraOpThreads: Int
        /// Execution provider for the encoder (the decoder always runs on the CPU EP).
        var encoderProvider: Provider
        var coreMLComputeUnits: String = "ALL"
        /// Where CoreML caches the compiled encoder (only used with CoreML).
        var coreMLCacheDirectory: URL?
        /// Per-session ORT memory settings; see `OzenOrtOptions`. The encoder runs once
        /// per window with ~300 MB of activations (the fp16 graph runs as fp32 with Casts
        /// on the CPU EP), so it gets neither the arena nor a memory pattern: that cut peak
        /// footprint on long-he from ~830 MB to ~690 MB on macOS at no measurable cost.
        /// The decoder runs ~200 small steps per window and keeps both.
        var encoderMemory = Memory(arena: false, prepacking: true, memPattern: false)
        var decoderMemory = Memory(arena: true, prepacking: true, memPattern: true)

        struct Memory: Sendable {
            var arena: Bool
            var prepacking: Bool
            var memPattern: Bool
        }

        enum Provider: Int32, Sendable { case cpu = 0, coreMLProgram = 1, coreMLNeuralNetwork = 2 }

        static var `default`: Options {
            Options(intraOpThreads: min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)),
                    encoderProvider: .cpu)
        }
    }

    /// Wall-clock timings, for tests and benchmarking.
    struct Stats: Sendable {
        var windows = 0
        var melSeconds = 0.0
        var encoderSeconds = 0.0
        var decoderSeconds = 0.0
        var decoderSteps = 0
        /// CPU time of the calling thread (meaningful with intraOpThreads == 1).
        var encoderThreadCPU = 0.0
        var decoderThreadCPU = 0.0
    }

    static let bos = 1
    static let eos = 2
    static let maxNewTokens = 220

    private let ort: OpaquePointer
    private let tokenizer: Tokenizer
    private let mel: MelSpectrogram
    private let lock = NSLock()
    private var _stats = Stats()
    var stats: Stats { lock.withLock { _stats } }

    convenience init(modelDirectory: URL) throws {
        try self.init(modelDirectory: modelDirectory, options: .default)
    }

    init(modelDirectory: URL, options: Options) throws {
        for name in ModelFiles.all {
            let path = modelDirectory.appendingPathComponent(name).path
            if !FileManager.default.fileExists(atPath: path) {
                throw OzenError.modelMissing(name)
            }
        }
        tokenizer = try Tokenizer(url: modelDirectory.appendingPathComponent(ModelFiles.tokenizer))
        mel = try MelSpectrogram(filtersURL: modelDirectory.appendingPathComponent(ModelFiles.melFilters))

        let encoderPath = modelDirectory.appendingPathComponent(ModelFiles.encoder).path
        let decoderPath = modelDirectory.appendingPathComponent(ModelFiles.decoder).path
        var err = [CChar](repeating: 0, count: 1024)
        let units = options.coreMLComputeUnits
        let cacheDir = options.coreMLCacheDirectory?.path ?? ""
        if let dir = options.coreMLCacheDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let handle: OpaquePointer? = units.withCString { unitsPtr in
            cacheDir.withCString { cachePtr in
                let o = OzenOrtOptions(intraOpThreads: Int32(options.intraOpThreads),
                                       encoderProvider: options.encoderProvider.rawValue,
                                       coreMLComputeUnits: unitsPtr,
                                       coreMLCacheDirectory: cacheDir.isEmpty ? nil : cachePtr,
                                       arena: (options.encoderMemory.arena ? 1 : 0, options.decoderMemory.arena ? 1 : 0),
                                       prepacking: (options.encoderMemory.prepacking ? 1 : 0,
                                                    options.decoderMemory.prepacking ? 1 : 0),
                                       memPattern: (options.encoderMemory.memPattern ? 1 : 0,
                                                    options.decoderMemory.memPattern ? 1 : 0))
                return ozen_ort_create(encoderPath, decoderPath, o, &err, err.count)
            }
        }
        guard let handle else {
            // A model file that exists but won't load (truncated download, wrong file)
            // is reported like a missing one, so the app re-fetches it.
            let message = String(cString: err)
            NSLog("OzenCore: ONNX Runtime could not load the model: %@", message)
            throw OzenError.modelMissing(message.hasPrefix("decoder:") ? ModelFiles.decoder : ModelFiles.encoder)
        }
        ort = handle
    }

    deinit {
        ozen_ort_destroy(ort)
    }

    // MARK: - One window

    /// Greedy token ids (without BOS/EOS) for one window of features [80][3000].
    /// Call with `lock` held.
    private func tokens(features: UnsafeBufferPointer<Float>) throws -> [Int] {
        precondition(features.count == MelSpectrogram.nMels * MelSpectrogram.nFrames)
        var err = [CChar](repeating: 0, count: 1024)
        defer { ozen_ort_end_window(ort) }

        let c0 = Self.threadCPU()
        let t0 = DispatchTime.now()
        guard ozen_ort_encode(ort, features.baseAddress!, &err, err.count) == 0 else {
            throw EngineError.onnx(String(cString: err))
        }
        let t1 = DispatchTime.now()
        let c1 = Self.threadCPU()

        var ids = [Self.bos]
        var steps = 0
        for _ in 0..<Self.maxNewTokens {
            if Task.isCancelled { throw OzenError.cancelled }
            var next: Int32 = 0
            guard ozen_ort_step(ort, Int64(ids[ids.count - 1]), &next, &err, err.count) == 0 else {
                throw EngineError.onnx(String(cString: err))
            }
            steps += 1
            if Int(next) == Self.eos { break }
            ids.append(Int(next))
        }
        let t2 = DispatchTime.now()
        _stats.windows += 1
        _stats.encoderSeconds += Self.seconds(t0, t1)
        _stats.decoderSeconds += Self.seconds(t1, t2)
        _stats.decoderSteps += steps
        _stats.encoderThreadCPU += c1 - c0
        _stats.decoderThreadCPU += Self.threadCPU() - c1
        return Array(ids.dropFirst())
    }

    /// Transcribes up to 30 s of audio (reference `transcribe_window`).
    func transcribeWindow(_ x: UnsafeBufferPointer<Float>, scratch: UnsafeMutableBufferPointer<Float>) throws -> String {
        try lock.withLock {
            let t0 = DispatchTime.now()
            mel.compute(x, into: scratch)
            _stats.melSeconds += Self.seconds(t0, DispatchTime.now())
            return tokenizer.decode(try tokens(features: UnsafeBufferPointer(scratch)))
        }
    }

    func transcribeWindow(_ x: [Float]) throws -> String {
        var scratch = [Float](repeating: 0, count: MelSpectrogram.nMels * MelSpectrogram.nFrames)
        return try x.withUnsafeBufferPointer { xs in
            try scratch.withUnsafeMutableBufferPointer { try transcribeWindow(xs, scratch: $0) }
        }
    }


    // MARK: - Whole recording

    func run(samples: [Float], emit: @Sendable (TranscriptionEvent) -> Void) async throws {
        let segments = Segmenter.segment(samples)
        let total = samples.count
        guard total > 0, !segments.isEmpty else {
            emit(.progress(1, eta: 0))
            return
        }
        emit(.progress(0, eta: nil))

        let totalWork = segments.reduce(0) { $0 + $1.count }
        var doneWork = 0
        var lastProgress = 0.0
        let start = DispatchTime.now()
        var scratch = [Float](repeating: 0, count: MelSpectrogram.nMels * MelSpectrogram.nFrames)

        for seg in segments {
            if Task.isCancelled { throw OzenError.cancelled }
            let text = try samples.withUnsafeBufferPointer { all in
                try scratch.withUnsafeMutableBufferPointer { s in
                    try transcribeWindow(UnsafeBufferPointer(rebasing: all[seg]), scratch: s)
                }
            }
            if !text.isEmpty && !isDegenerate(text) {
                let sr = Double(MelSpectrogram.sampleRate)
                emit(.segment(TranscriptSegment(start: Double(seg.lowerBound) / sr,
                                                end: Double(seg.upperBound) / sr,
                                                text: text)))
            }
            doneWork += seg.count
            let elapsed = Self.seconds(start, DispatchTime.now())
            let eta = elapsed / Double(doneWork) * Double(totalWork - doneWork)
            lastProgress = doneWork == totalWork ? 1 : Double(seg.upperBound) / Double(total)
            emit(.progress(lastProgress, eta: eta))
            await Task.yield()
        }
        if lastProgress < 1 { emit(.progress(1, eta: 0)) }
    }

    private static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    private static func seconds(_ a: DispatchTime, _ b: DispatchTime) -> Double {
        Double(b.uptimeNanoseconds - a.uptimeNanoseconds) / 1e9
    }
}

enum EngineError: Error, CustomStringConvertible {
    case onnx(String)
    var description: String {
        switch self {
        case .onnx(let m): return "ONNX Runtime: \(m)"
        }
    }
}
