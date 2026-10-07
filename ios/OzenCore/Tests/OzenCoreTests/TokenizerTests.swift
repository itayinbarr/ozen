import XCTest
@testable import OzenCore

final class TokenizerTests: XCTestCase {
    func testByteDecoderIsBijective() {
        let d = Tokenizer.byteDecoder()
        XCTAssertEqual(d.count, 256)
        XCTAssertEqual(Set(d.values).count, 256)
        XCTAssertEqual(d[UInt32(("Ġ" as Unicode.Scalar).value)], 0x20)
        XCTAssertEqual(d[UInt32(("!" as Unicode.Scalar).value)], 0x21)
    }

    func testDecode() throws {
        let dir = try Fixtures.modelDir()
        let t = try Tokenizer(url: dir.appendingPathComponent(ModelFiles.tokenizer))
        XCTAssertEqual(t.vocabSize, 8192)
        // Vectors from tokenizers.Tokenizer.encode + reference.Tokenizer.decode.
        XCTAssertEqual(t.decode([1, 6197, 14, 4193, 2358, 4127, 3898, 2752, 434, 906, 4910, 288, 16, 2]),
                       "שלום, וברוכים הבאים לפגישת הצוות השבועית.")
        XCTAssertEqual(t.decode([223, 763, 8012, 1747, 7854, 33, 8012]), "מה החברה עושה?")
        XCTAssertEqual(t.decode([42, 7448, 81, 223, 89, 1393, 78, 70, 343, 1493]), "Hello world 123")
        // 8191 is an ordinary word piece, not a special token.
        XCTAssertEqual(t.decode([8191, 8190, 5]), "קומפ77#")
        XCTAssertEqual(t.decode([0, 1, 2]), "")
    }

    func testDegenerate() {
        XCTAssertFalse(isDegenerate("שלום עולם"))
        XCTAssertTrue(isDegenerate(Array(repeating: "לא", count: 12).joined(separator: " ")))
        XCTAssertTrue(isDegenerate(Array(repeating: "אני לא יודע", count: 6).joined(separator: " ")))
        let varied = (0..<30).map { "מילה\($0)" }.joined(separator: " ")
        XCTAssertFalse(isDegenerate(varied))
        // Same word > 60% of > 20 words, not at the start.
        let mostly = (["א", "ב", "ג"] + Array(repeating: "כן", count: 19)).joined(separator: " ")
        XCTAssertTrue(isDegenerate(mostly))
    }
}
