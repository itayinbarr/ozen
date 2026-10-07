import Foundation

// Public surface of OzenCore. The app target codes against exactly this; the
// implementation behind it lives in the other files of this module.

/// One paragraph of a transcript, cut at a pause. Times are in seconds from the
/// start of the audio.
public struct TranscriptSegment: Sendable, Codable, Equatable, Hashable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// What a running transcription reports, in order. `progress` is 0...1 of audio
/// processed; `eta` is seconds remaining once there is enough timing to guess.
public enum TranscriptionEvent: Sendable, Equatable {
    case progress(Double, eta: Double?)
    case segment(TranscriptSegment)
}

public enum OzenError: Error, Sendable, Equatable {
    case modelMissing(String)
    case unreadableAudio(String)
    case cancelled
}

/// The files a model directory must contain. The app bundles them under
/// `Model/`; tests point at `~/.cache/ozen/models/<rev>` plus `spec/mel_filters.bin`.
public enum ModelFiles {
    public static let encoder = "encoder_model_fp16.onnx"
    public static let decoder = "decoder_model_merged.onnx"
    public static let tokenizer = "tokenizer.json"
    public static let melFilters = "mel_filters.bin"
    public static let all = [encoder, decoder, tokenizer, melFilters]
}

/// Loads and runs Ozen-v1. One instance per process; sessions load lazily on
/// first use and are released by `unload()` (call it on memory warnings).
public actor Transcriber {
    public let modelDirectory: URL

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    /// Loads the ONNX sessions now, so the first transcription starts at once.
    public func prepare() async throws {
        try await engine()
    }

    /// Frees the ONNX sessions.
    public func unload() {
        _engine = nil
    }

    /// Decodes an audio file (m4a, wav, mp3, caf, WhatsApp .opus, …) and transcribes it.
    public nonisolated func transcribe(fileURL: URL) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let samples = try await AudioLoader.load16kMono(url: fileURL)
                    if Task.isCancelled { throw OzenError.cancelled }
                    try await self.run(samples: samples, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Transcribes 16 kHz mono samples.
    public nonisolated func transcribe(samples: [Float]) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(samples: samples, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Implementation (Engine.swift)

    private var _engine: Engine?

    @discardableResult
    private func engine() async throws -> Engine {
        if let e = _engine { return e }
        let e = try Engine(modelDirectory: modelDirectory)
        _engine = e
        return e
    }

    // The actor is reentrant across `await`, so runs queue here: one window at a
    // time on one set of ONNX sessions keeps peak memory to a single window.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func run(samples: [Float], continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation) async throws {
        await acquire()
        defer { release() }
        if Task.isCancelled { throw OzenError.cancelled }
        let engine = try await engine()
        try await engine.run(samples: samples) { event in
            continuation.yield(event)
        }
    }
}
