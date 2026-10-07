import Foundation

// STUB — replaced by the real implementation (mel, tokenizer, ONNX loop, segmenter).
final class Engine: @unchecked Sendable {
    init(modelDirectory: URL) throws {}

    func run(samples: [Float], emit: @Sendable (TranscriptionEvent) -> Void) async throws {
        emit(.progress(1, eta: 0))
    }
}
