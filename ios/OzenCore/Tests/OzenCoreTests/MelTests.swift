import XCTest
@testable import OzenCore

final class MelTests: XCTestCase {
    func testMatchesReference() async throws {
        let x = try await AudioLoader.load16kMono(url: Fixtures.goldenFile("sample-he.wav"))
        let expected = try Fixtures.readFloat32LE(Fixtures.goldenFile("sample-he.mel.bin"))
        XCTAssertEqual(expected.count, 80 * 3000)

        let mel = try MelSpectrogram(filtersURL: Fixtures.spec.appendingPathComponent("mel_filters.bin"))
        var out = [Float](repeating: 0, count: 80 * 3000)
        x.withUnsafeBufferPointer { xs in out.withUnsafeMutableBufferPointer { mel.compute(xs, into: $0) } }

        var maxDiff: Float = 0
        for i in 0..<out.count { maxDiff = max(maxDiff, abs(out[i] - expected[i])) }
        print("mel max abs diff: \(maxDiff)")
        XCTAssertLessThan(maxDiff, 2e-3)

        // Speed: one 30 s window.
        let t0 = DispatchTime.now()
        let reps = 10
        for _ in 0..<reps {
            x.withUnsafeBufferPointer { xs in out.withUnsafeMutableBufferPointer { mel.compute(xs, into: $0) } }
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6 / Double(reps)
        print(String(format: "mel: %.1f ms per 30 s window", ms))
    }

    func testFullWindowAndEmpty() throws {
        let mel = try MelSpectrogram(filtersURL: Fixtures.spec.appendingPathComponent("mel_filters.bin"))
        var out = [Float](repeating: .nan, count: 80 * 3000)
        // Longer than 30 s is trimmed; silence gives a constant (0 power -> floor).
        let silence = [Float](repeating: 0, count: 600_000)
        silence.withUnsafeBufferPointer { xs in out.withUnsafeMutableBufferPointer { mel.compute(xs, into: $0) } }
        XCTAssertTrue(out.allSatisfy { $0 == out[0] && $0.isFinite })
        XCTAssertEqual(out[0], (-10 + 4) / 4, accuracy: 1e-6)
    }
}
