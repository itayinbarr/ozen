import Foundation
import OzenCore

/// What the job queue needs from a transcriber. The real one wraps OzenCore; DEBUG builds can swap in a fake.
protocol TranscriptionEngine: AnyObject {
    func transcribe(fileURL: URL) -> AsyncThrowingStream<TranscriptionEvent, Error>
    func unload() async
}

/// OzenCore's `Transcriber` over the model bundled under `Model/`.
final class CoreTranscriptionEngine: TranscriptionEngine {
    private let transcriber: Transcriber

    init() {
        let dir = Bundle.main.url(forResource: "Model", withExtension: nil)
            ?? Bundle.main.bundleURL.appendingPathComponent("Model", isDirectory: true)
        transcriber = Transcriber(modelDirectory: dir)
    }

    func transcribe(fileURL: URL) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        transcriber.transcribe(fileURL: fileURL)
    }

    func unload() async {
        await transcriber.unload()
    }
}
