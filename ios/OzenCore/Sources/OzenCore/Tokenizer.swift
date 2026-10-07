import Foundation

/// Decode-only byte-level BPE tokenizer (GPT-2 / Whisper style), matching
/// `reference.Tokenizer.decode`: specials skipped, bytes UTF-8 decoded lossily,
/// whitespace collapsed and trimmed.
struct Tokenizer: Sendable {
    /// Bytes of each token id; nil for ids outside the vocab.
    private let bytes: [[UInt8]?]
    private let special: Set<Int>

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? [String: Any],
              let vocab = model["vocab"] as? [String: Int]
        else {
            throw OzenError.modelMissing(ModelFiles.tokenizer)
        }
        var special = Set<Int>()
        for added in json["added_tokens"] as? [[String: Any]] ?? [] {
            if let id = added["id"] as? Int { special.insert(id) }
        }
        let decoder = Self.byteDecoder()
        let maxID = vocab.values.max() ?? -1
        var table = [[UInt8]?](repeating: nil, count: maxID + 1)
        for (token, id) in vocab where id >= 0 {
            var out: [UInt8] = []
            out.reserveCapacity(token.unicodeScalars.count)
            for scalar in token.unicodeScalars {
                guard let b = decoder[scalar.value] else {
                    throw OzenError.modelMissing(ModelFiles.tokenizer)
                }
                out.append(b)
            }
            table[id] = out
        }
        self.bytes = table
        self.special = special
    }

    var vocabSize: Int { bytes.count }

    func decode(_ ids: [Int]) -> String {
        var out: [UInt8] = []
        for id in ids where !special.contains(id) {
            guard id >= 0, id < bytes.count, let b = bytes[id] else { continue }
            out.append(contentsOf: b)
        }
        let text = String(decoding: out, as: UTF8.self)
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Inverse of GPT-2's `bytes_to_unicode`: unicode scalar value -> byte.
    static func byteDecoder() -> [UInt32: UInt8] {
        var bs: [Int] = Array(0x21...0x7E) + Array(0xA1...0xAC) + Array(0xAE...0xFF)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var map: [UInt32: UInt8] = [:]
        for (b, c) in zip(bs, cs) { map[UInt32(c)] = UInt8(b) }
        return map
    }
}

/// Port of free-transcribe's repetition-loop guard (`reference.is_degenerate`).
func isDegenerate(_ text: String) -> Bool {
    let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if words.count < 12 { return false }
    for size in 1...4 {
        if words.count < size * 6 { continue }
        let phrase = Array(words[0..<size])
        var repeats = 0
        var i = 0
        while i <= words.count - size {
            if Array(words[i..<(i + size)]) == phrase {
                repeats += 1
            } else {
                break
            }
            i += size
        }
        if Double(repeats * size) > Double(words.count) * 0.7 { return true }
    }
    var counts: [String: Int] = [:]
    for w in words { counts[w, default: 0] += 1 }
    return Double(counts.values.max() ?? 0) > Double(words.count) * 0.6 && words.count > 20
}
