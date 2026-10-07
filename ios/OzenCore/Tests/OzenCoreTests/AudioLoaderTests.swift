import XCTest
@testable import OzenCore

final class AudioLoaderTests: XCTestCase {
    func testWavIsExact() async throws {
        let x = try await AudioLoader.load16kMono(url: Fixtures.goldenFile("sample-he.wav"))
        XCTAssertEqual(x.count, 192_000)
        XCTAssertGreaterThan(x.map(abs).max()!, 0.05)
    }

    func testCompressedFormats() async throws {
        // name -> expected length in samples (16 kHz), from the matching wav.
        let cases: [(String, Int)] = [
            ("sample-he.m4a", 192_000), ("sample-he.mp3", 192_000), ("sample-he.ogg", 192_000),
            ("long-he.m4a", 815_532), ("long-he.opus", 815_532),
        ]
        for (name, n) in cases {
            let x = try await AudioLoader.load16kMono(url: Fixtures.goldenFile(name))
            print("\(name): \(x.count) samples (wav \(n))")
            XCTAssertEqual(Double(x.count), Double(n), accuracy: 16000 * 0.1, name)
            XCTAssertGreaterThan(x.map(abs).max()!, 0.05, name)
        }
    }

    /// Whether this OS's AVAudioFile opens Ogg Opus natively (informational).
    func testReportNativeOggSupport() throws {
        for name in ["long-he.opus", "sample-he.ogg"] {
            do {
                let s = try AVAudioFileSource(url: Fixtures.goldenFile(name))
                print("AVAudioFile opens \(name): yes (\(s.sampleRate) Hz, \(s.estimatedFrames) frames)")
            } catch {
                print("AVAudioFile opens \(name): no (\(error))")
            }
        }
    }

    /// The fallback Ogg demuxer + Apple Opus decoder agrees with the wav it was encoded from.
    func testOggOpusFallbackPath() async throws {
        let wav = try await AudioLoader.load16kMono(url: Fixtures.goldenFile("long-he.wav"))
        for name in ["long-he.opus", "sample-he.ogg"] {
            let x = try AudioLoader.loadOggOpus(url: Fixtures.goldenFile(name))
            let ref = name.hasPrefix("long") ? wav : try await AudioLoader.load16kMono(url: Fixtures.goldenFile("sample-he.wav"))
            print("ogg fallback \(name): \(x.count) samples (wav \(ref.count))")
            XCTAssertEqual(Double(x.count), Double(ref.count), accuracy: 160, name)
            // Aligned (pre-skip applied): best lag within ±5 ms should be ~0.
            let lag = bestLag(x, ref, maxLag: 80)
            print("ogg fallback \(name): best lag \(lag) samples")
            XCTAssertLessThanOrEqual(abs(lag), 2, name)
        }
    }

    func testUnreadable() async {
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("not-audio.m4a")
        try? Data("hello".utf8).write(to: bogus)
        do {
            _ = try await AudioLoader.load16kMono(url: bogus)
            XCTFail("expected unreadableAudio")
        } catch {
            XCTAssertEqual(error as? OzenError, .unreadableAudio("not-audio.m4a"))
        }
        let missing = URL(fileURLWithPath: "/nonexistent/x.wav")
        do {
            _ = try await AudioLoader.load16kMono(url: missing)
            XCTFail("expected unreadableAudio")
        } catch {
            XCTAssertEqual(error as? OzenError, .unreadableAudio("x.wav"))
        }
    }

    private func bestLag(_ a: [Float], _ b: [Float], maxLag: Int) -> Int {
        let n = min(a.count, b.count) - 2 * maxLag
        var best = 0
        var bestScore = -Double.infinity
        for lag in -maxLag...maxLag {
            var s = 0.0
            var i = maxLag
            while i < maxLag + n {
                s += Double(a[i + lag]) * Double(b[i])
                i += 4
            }
            if s > bestScore { bestScore = s; best = lag }
        }
        return best
    }
}
