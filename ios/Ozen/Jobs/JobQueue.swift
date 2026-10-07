import AVFoundation
import Foundation
import Observation
import OzenCore
import SwiftData
import UIKit

/// Runs transcriptions one at a time. Jobs are `Recording`s with status `.pending`, so a job
/// interrupted by suspension or termination is picked up again by `resumePending()`.
@MainActor
@Observable
final class JobQueue {
    /// The job on the processing screen.
    struct Live: Equatable {
        var recordingID: UUID
        var progress: Double = 0
        var eta: Double?
        var latestText: String = ""
        var source: RecordingSource
        var sourceLabel: String?
    }

    private(set) var live: Live?

    @ObservationIgnored let engine: TranscriptionEngine
    @ObservationIgnored let context: ModelContext
    /// The app vetoes starting a job (e.g. while recording, or while the keep sheet is up).
    @ObservationIgnored var canStart: () -> Bool = { true }
    @ObservationIgnored var onStart: ((Recording) -> Void)?
    @ObservationIgnored var onFinish: ((Recording) -> Void)?
    @ObservationIgnored var onFail: ((Recording) -> Void)?

    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(engine: TranscriptionEngine, context: ModelContext) {
        self.engine = engine
        self.context = context
    }

    var isBusy: Bool { task != nil }
    var hasQueued: Bool { !queue.isEmpty }

    func enqueue(_ id: UUID) {
        if live?.recordingID == id && task != nil { return }
        if !queue.contains(id) { queue.append(id) }
        pump()
    }

    /// Re-queues every unfinished recording, oldest first.
    func resumePending() {
        let pending = TranscriptionStatus.pending.rawValue
        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.statusRaw == pending },
                                                    sortBy: [SortDescriptor(\.createdAt)])
        for rec in (try? context.fetch(descriptor)) ?? [] where !queue.contains(rec.id) && live?.recordingID != rec.id {
            queue.append(rec.id)
        }
        pump()
    }

    func clearLive() {
        if task == nil { live = nil }
    }

    /// Starts the next job if nothing is running and the app allows it.
    func pump() {
        guard task == nil, !queue.isEmpty, canStart() else { return }
        let id = queue.removeFirst()
        guard let rec = fetch(id), rec.status == .pending, let url = rec.audioURL,
              FileManager.default.fileExists(atPath: url.path) else {
            if let rec = fetch(id), rec.status == .pending {
                rec.status = .failed
                try? context.save()
            }
            pump()
            return
        }
        live = Live(recordingID: id, source: rec.source,
                    sourceLabel: rec.source == .record ? nil : rec.originalFileName)
        onStart?(rec)
        beginBackgroundTask()
        task = Task { [weak self] in
            await self?.run(rec, url: url)
        }
    }

    private func run(_ rec: Recording, url: URL) async {
        var segments: [TranscriptSegment] = []
        var outcome: Bool? // true = done, false = failed, nil = interrupted (stays pending)
        if rec.duration <= 0, let d = await Self.audioDuration(url) { rec.duration = d }
        do {
            for try await event in engine.transcribe(fileURL: url) {
                switch event {
                case let .progress(p, eta):
                    let previous = live?.progress ?? 0
                    live?.progress = min(1, max(previous, p))
                    live?.eta = eta
                case let .segment(s):
                    segments.append(s)
                    live?.latestText = s.text
                }
            }
            try Task.checkCancellation()
            outcome = true
        } catch is CancellationError {
            outcome = nil
        } catch OzenError.cancelled {
            outcome = nil
        } catch {
            outcome = false
        }

        task = nil
        switch outcome {
        case true?:
            rec.segments = segments
            rec.status = .done
            if rec.duration <= 0 { rec.duration = segments.last?.end ?? 0 }
            try? context.save()
            live?.progress = 1
            live?.eta = 0
            try? await Task.sleep(for: .milliseconds(400))
            onFinish?(rec)
        case false?:
            rec.status = .failed
            try? context.save()
            live = nil
            onFail?(rec)
        case nil:
            live = nil
        }
        endBackgroundTask()
        // Finished while suspended-bound: drop the ~500 MB of ONNX sessions (a no-op if the next job started).
        if UIApplication.shared.applicationState == .background { unloadModel() }
    }

    /// Stops the running job; it stays pending and resumes later.
    func interrupt() {
        task?.cancel()
    }

    func unloadModel() {
        guard task == nil else { return }
        Task { await engine.unload() }
    }

    // MARK: -

    private func fetch(_ id: UUID) -> Recording? {
        var d = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "transcribe") { [weak self] in
            MainActor.assumeIsolated {
                // Out of background time: stop; the job stays pending and resumes on the next foreground.
                self?.interrupt()
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    static func audioDuration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return nil }
        let s = CMTimeGetSeconds(d)
        return s.isFinite && s > 0 ? s : nil
    }
}
