import XCTest
@testable import OzenCore

/// End-to-end transcripts against spec/golden/golden.json (tools/model/reference.py output).
final class GoldenTests: XCTestCase {
    /// `maxCER` bounds every segment; `maxTotalCER` (if set) bounds the whole transcript.
    private func check(file: String, golden goldenName: String, maxCER: Double, maxTotalCER: Double? = nil,
                       boundaryTolerance: Double) async throws {
        let engine = try Fixtures.engine()
        let golden = try Fixtures.goldenJSON()[goldenName]!
        let x = try await AudioLoader.load16kMono(url: Fixtures.goldenFile(file))

        let before = engine.stats
        let footprintBefore = Fixtures.footprintMB()
        let t0 = DispatchTime.now()
        let box = EventBox()
        try await engine.run(samples: x) { box.append($0) }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        let s = engine.stats
        let windows = s.windows - before.windows
        let steps = s.decoderSteps - before.decoderSteps
        print(String(format: "%@: %.2f s wall for %.1f s audio | %d windows | mel %.1f ms/win | encoder %.0f ms/win | decoder %.1f ms/token (%d tokens) | footprint %.0f -> %.0f MB, peak RSS %.0f MB",
                     file, wall, Double(x.count) / 16000, windows,
                     (s.melSeconds - before.melSeconds) * 1000 / Double(windows),
                     (s.encoderSeconds - before.encoderSeconds) * 1000 / Double(windows),
                     (s.decoderSeconds - before.decoderSeconds) * 1000 / Double(max(1, steps)), steps,
                     footprintBefore, Fixtures.footprintMB(), Fixtures.peakRSSMB()))

        let segments = box.events.compactMap { e -> TranscriptSegment? in
            if case .segment(let s) = e { return s } else { return nil }
        }
        let progress = box.events.compactMap { e -> Double? in
            if case .progress(let p, _) = e { return p } else { return nil }
        }
        XCTAssertEqual(progress.last, 1, file)
        XCTAssertEqual(progress, progress.sorted(), "progress must be monotonic")

        XCTAssertEqual(segments.count, golden.segments.count, "\(file): segment count")
        for (got, want) in zip(segments, golden.segments) {
            let cer = Fixtures.cer(got.text, want.text)
            print(String(format: "  [%6.2f-%6.2f] CER %.3f %@", got.start, got.end, cer, got.text))
            XCTAssertEqual(got.start, Double(want.start) / 16000, accuracy: boundaryTolerance, file)
            XCTAssertEqual(got.end, Double(want.end) / 16000, accuracy: boundaryTolerance, file)
            XCTAssertLessThanOrEqual(cer, maxCER, "\(file): \(got.text) vs \(want.text)")
        }
        let total = Fixtures.cer(segments.map(\.text).joined(separator: " "),
                                 golden.segments.map(\.text).joined(separator: " "))
        print(String(format: "  %@ total CER %.4f", file, total))
        if let maxTotalCER { XCTAssertLessThanOrEqual(total, maxTotalCER, "\(file): total CER") }
    }

    func testSampleWav() async throws {
        try await check(file: "sample-he.wav", golden: "sample-he.wav", maxCER: 0.01, boundaryTolerance: 0.1)
    }

    func testLongWav() async throws {
        try await check(file: "long-he.wav", golden: "long-he.wav", maxCER: 0.01, boundaryTolerance: 0.1)
    }

    // Lossy codecs: the reference pipeline itself (ffmpeg + soxr) transcribes the
    // m4a's 4th paragraph as "חמישי-בנות, שאיין" (4% CER vs the wav golden), so the
    // 3% bound is on the whole transcript and single paragraphs get 10%.
    func testLongM4A() async throws {
        try await check(file: "long-he.m4a", golden: "long-he.wav", maxCER: 0.10, maxTotalCER: 0.03,
                        boundaryTolerance: 0.1)
    }

    func testLongOpus() async throws {
        try await check(file: "long-he.opus", golden: "long-he.wav", maxCER: 0.10, maxTotalCER: 0.03,
                        boundaryTolerance: 0.1)
    }

    /// The Ogg demuxer + Apple Opus decoder path (used where AVAudioFile can't open Ogg).
    func testLongOpusFallbackDecoder() async throws {
        let engine = try Fixtures.engine()
        let golden = try Fixtures.goldenJSON()["long-he.wav"]!
        let x = try AudioLoader.loadOggOpus(url: Fixtures.goldenFile("long-he.opus"))
        let box = EventBox()
        try await engine.run(samples: x) { box.append($0) }
        let texts = box.events.compactMap { e -> String? in
            if case .segment(let s) = e { return s.text } else { return nil }
        }
        XCTAssertEqual(texts.count, golden.segments.count)
        let total = Fixtures.cer(texts.joined(separator: " "), golden.segments.map(\.text).joined(separator: " "))
        XCTAssertLessThanOrEqual(total, 0.03)
    }

    /// reference `transcribe_window` on the first 30 s, exact string.
    func testWindowExact() async throws {
        let engine = try Fixtures.engine()
        let golden = try Fixtures.goldenJSON()
        for name in ["sample-he.wav", "long-he.wav"] {
            let x = try await AudioLoader.load16kMono(url: Fixtures.goldenFile(name))
            let text = try engine.transcribeWindow(Array(x.prefix(480_000)))
            XCTAssertEqual(text, golden[name]!.window, name)
        }
    }

    func testTranscriberPublicAPI() async throws {
        let dir = try Fixtures.modelDir()
        let t = Transcriber(modelDirectory: dir)
        try await t.prepare()
        var segments: [TranscriptSegment] = []
        var sawETA = false
        for try await e in t.transcribe(fileURL: Fixtures.goldenFile("sample-he.wav")) {
            switch e {
            case .segment(let s): segments.append(s)
            case .progress(_, let eta): if eta != nil { sawETA = true }
            }
        }
        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(sawETA)
        XCTAssertEqual(segments.first?.start ?? 0, 36960.0 / 16000, accuracy: 1e-9)
        await t.unload()
    }

    func testModelMissing() async {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ozen-empty-model")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        do {
            try await Transcriber(modelDirectory: empty).prepare()
            XCTFail("expected modelMissing")
        } catch {
            XCTAssertEqual(error as? OzenError, .modelMissing(ModelFiles.encoder))
        }
    }

    func testCorruptModelIsReportedMissing() async throws {
        let good = try Fixtures.modelDir()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ozen-corrupt-model")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ModelFiles.all where name != ModelFiles.decoder {
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(name),
                                                       withDestinationURL: good.appendingPathComponent(name).resolvingSymlinksInPath())
        }
        try Data("not an onnx file".utf8).write(to: dir.appendingPathComponent(ModelFiles.decoder))
        do {
            try await Transcriber(modelDirectory: dir).prepare()
            XCTFail("expected modelMissing")
        } catch {
            XCTAssertEqual(error as? OzenError, .modelMissing(ModelFiles.decoder))
        }
    }

    func testCancellation() async throws {
        let engine = try Fixtures.engine()
        let x = try await AudioLoader.load16kMono(url: Fixtures.goldenFile("long-he.wav"))
        let box = EventBox()
        let task = Task {
            try await engine.run(samples: x) { e in
                box.append(e)
            }
        }
        // Cancel once the first paragraph is out.
        while !box.events.contains(where: { if case .segment = $0 { return true } else { return false } }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? OzenError, .cancelled)
        }
        let segs = box.events.filter { if case .segment = $0 { return true } else { return false } }
        XCTAssertLessThan(segs.count, 6)
    }

    func testSilenceProducesNothing() async throws {
        let engine = try Fixtures.engine()
        let box = EventBox()
        try await engine.run(samples: [Float](repeating: 0, count: 16000 * 5)) { box.append($0) }
        XCTAssertEqual(box.events, [.progress(1, eta: 0)])
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TranscriptionEvent] = []
    var events: [TranscriptionEvent] { lock.withLock { _events } }
    func append(_ e: TranscriptionEvent) { lock.withLock { _events.append(e) } }
}
