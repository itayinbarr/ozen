import XCTest
@testable import OzenCore

final class SegmenterTests: XCTestCase {
    struct Vectors: Decodable {
        struct Case: Decodable {
            let name: String
            let seed: UInt32
            let pieces: [Synth.Piece]
            let samples: Int
            let expected: [[Int]]
        }
        let cases: [Case]
    }

    func testVectors() throws {
        let data = try Data(contentsOf: Fixtures.spec.appendingPathComponent("segmenter-vectors.json"))
        let vectors = try JSONDecoder().decode(Vectors.self, from: data)
        XCTAssertGreaterThanOrEqual(vectors.cases.count, 10)
        for c in vectors.cases {
            let x = Synth.synth(c.pieces, seed: c.seed)
            XCTAssertEqual(x.count, c.samples, c.name)
            let got = Segmenter.segment(x).map { [$0.lowerBound, $0.upperBound] }
            XCTAssertEqual(got, c.expected, c.name)
        }
    }

    func testEmpty() {
        XCTAssertEqual(Segmenter.segment([]), [])
    }

    func testGoldenAudioCuts() async throws {
        let golden = try Fixtures.goldenJSON()
        for name in ["sample-he.wav", "long-he.wav"] {
            let x = try await AudioLoader.load16kMono(url: Fixtures.goldenFile(name))
            XCTAssertEqual(x.count, golden[name]!.samples, name)
            // golden.json only lists non-empty paragraphs; every one must be a segmenter cut.
            let cuts = Segmenter.segment(x)
            for s in golden[name]!.segments {
                XCTAssertTrue(cuts.contains(s.start..<s.end), "\(name): \(s.start)..<\(s.end) not in \(cuts)")
            }
        }
    }
}
