import XCTest
@testable import OzenCore

/// Run alone (`swift test --filter MemoryTests`) for meaningful numbers.
/// OZEN_MEM_VARIANT: comma list of encArena, encNoPrepack, encMemPattern, decNoArena,
/// decNoPrepack, decNoMemPattern, coreml, coremlANE, coremlCPU, coremlNN, t1, t2 (applied on top of the defaults).
final class MemoryTests: XCTestCase {
    func testFootprintLongWav() async throws {
        let dir = try Fixtures.modelDir()
        let x = try await AudioLoader.load16kMono(url: Fixtures.goldenFile("long-he.wav"))
        let variant = ProcessInfo.processInfo.environment["OZEN_MEM_VARIANT"] ?? "default"
        var o = Engine.Options.default
        for v in variant.split(separator: ",") {
            switch v {
            case "encArena": o.encoderMemory.arena = true
            case "encNoPrepack": o.encoderMemory.prepacking = false
            case "encMemPattern": o.encoderMemory.memPattern = true
            case "decNoArena": o.decoderMemory.arena = false
            case "decNoPrepack": o.decoderMemory.prepacking = false
            case "decNoMemPattern": o.decoderMemory.memPattern = false
            case "coreml": o.encoderProvider = .coreMLProgram
            case "coremlANE": o.encoderProvider = .coreMLProgram; o.coreMLComputeUnits = "CPUAndNeuralEngine"
            case "coremlCPU": o.encoderProvider = .coreMLProgram; o.coreMLComputeUnits = "CPUOnly"
            case "coremlNN": o.encoderProvider = .coreMLNeuralNetwork
            case "t1": o.intraOpThreads = 1
            case "t2": o.intraOpThreads = 2
            default: break
            }
        }
        let sampler = PeakSampler()
        let base = Fixtures.footprintMB()
        let t0 = DispatchTime.now()
        let engine = try Engine(modelDirectory: dir, options: o)
        let loadS = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        let loaded = Fixtures.footprintMB()
        let peakLoad = sampler.takePeak()
        let box = EventBox()
        try await engine.run(samples: x) { e in box.append(e) }
        let peakRun = sampler.takePeak()
        sampler.stop()
        let s = engine.stats
        print(String(format: "MEMORY [%@] load %.1f s | footprint: before %.0f, peak during load %.0f, loaded %.0f, peak during run %.0f, after %.0f MB | encoder %.0f ms/win (thread CPU %.0f), decoder %.1f ms/token (thread CPU %.1f), mel %.1f ms/win",
                     variant, loadS, base, peakLoad, loaded, peakRun, Fixtures.footprintMB(),
                     s.encoderSeconds * 1000 / Double(s.windows), s.encoderThreadCPU * 1000 / Double(s.windows),
                     s.decoderSeconds * 1000 / Double(s.decoderSteps), s.decoderThreadCPU * 1000 / Double(s.decoderSteps),
                     s.melSeconds * 1000 / Double(s.windows)))
        let texts = box.events.compactMap { e -> String? in if case .segment(let t) = e { return t.text } else { return nil } }
        XCTAssertEqual(texts, try Fixtures.goldenJSON()["long-he.wav"]!.segments.map(\.text))
    }
}

/// Samples the physical footprint every 5 ms on a background thread.
final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0.0
    private var running = true

    init() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let f = Fixtures.footprintMB()
                lock.withLock { peak = max(peak, f) }
                usleep(5000)
            }
        }
    }

    func takePeak() -> Double {
        lock.withLock {
            let p = max(peak, Fixtures.footprintMB())
            peak = 0
            return p
        }
    }

    func stop() { lock.withLock { running = false } }
}
