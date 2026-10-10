import AVFoundation
import Foundation
import Observation

/// Records to AAC m4a (16 kHz mono) with metering. One instance for the app: the Live Activity
/// intents reach it through `RecordingControlBridge`.
@MainActor
@Observable
final class Recorder: NSObject {
    enum State: Equatable { case idle, recording, paused }

    struct Finished {
        var fileURL: URL
        var duration: Double
        var startedAt: Date
    }

    private(set) var state: State = .idle
    /// Elapsed seconds before the current running stretch (pauses excluded).
    private(set) var accumulated: Double = 0
    /// Start of the current running stretch; nil while paused / idle.
    private(set) var runningSince: Date?
    private(set) var startedAt: Date?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var demo = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Called on every state change (Live Activity updates).
    @ObservationIgnored var onStateChange: ((Recorder) -> Void)?
    /// Called when a recording ends with audio worth transcribing.
    @ObservationIgnored var onFinish: ((Finished) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                // A call or Siri took the mic: the system has paused the recorder; reflect it (resume is manual).
                if raw == AVAudioSession.InterruptionType.began.rawValue, self?.state == .recording {
                    self?.pause()
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.state != .idle { _ = self?.stop() }
            }
        })
    }

    var isActive: Bool { state != .idle }

    func elapsed(at now: Date = Date()) -> Double {
        accumulated + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    // MARK: Control

    enum StartError: Error {
        /// The person just answered "Don't Allow" in the system prompt. Respect it: say nothing.
        case permissionDeclined
        /// Access was denied earlier and the record button was tapped again.
        case permissionUnavailable
        case failed
    }

    func start() async throws {
        guard state == .idle else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .denied:
            throw StartError.permissionUnavailable
        default:
            guard await AVAudioApplication.requestRecordPermission() else { throw StartError.permissionDeclined }
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)

        let url = Storage.recordingsDirectory.appendingPathComponent(Storage.newAudioFileName(ext: "m4a"))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 40_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        rec.delegate = self
        guard rec.record() else { throw StartError.failed }
        recorder = rec
        fileURL = url
        demo = false
        begin()
    }

    #if DEBUG
    /// Screenshot mode: a recording with no microphone, already `elapsed` seconds in.
    func startDemo(elapsed: Double) {
        demo = true
        begin()
        accumulated = elapsed
    }
    #endif

    private func begin() {
        accumulated = 0
        startedAt = Date()
        runningSince = Date()
        state = .recording
        onStateChange?(self)
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        accumulated = elapsed()
        runningSince = nil
        state = .paused
        onStateChange?(self)
    }

    func resume() {
        guard state == .paused else { return }
        if !demo {
            try? AVAudioSession.sharedInstance().setActive(true)
            guard recorder?.record() == true else { return }
        }
        runningSince = Date()
        state = .recording
        onStateChange?(self)
    }

    func togglePause() {
        state == .recording ? pause() : resume()
    }

    /// Ends the recording and hands the file to `onFinish`.
    @discardableResult
    func stop() -> Finished? {
        guard state != .idle else { return nil }
        let duration = elapsed()
        recorder?.stop()
        recorder = nil
        let started = startedAt ?? Date()
        state = .idle
        accumulated = 0
        runningSince = nil
        startedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onStateChange?(self)
        defer { fileURL = nil }
        guard !demo, let url = fileURL else { return nil }
        let finished = Finished(fileURL: url, duration: duration, startedAt: started)
        onFinish?(finished)
        return finished
    }

    // MARK: Metering

    /// 0…1 loudness for the orb; ~-50 dB is silence, ~-10 dB loud speech.
    func level(at time: Double) -> Double {
        guard state == .recording else { return 0 }
        if demo {
            // The design's synthetic level.
            let t = time
            return max(0, 0.42 + 0.3 * sin(t * 6.1) * sin(t * 1.7) + 0.22 * sin(t * 15.3 + sin(t * 3)))
        }
        guard let recorder else { return 0 }
        recorder.updateMeters()
        let db = Double(recorder.averagePower(forChannel: 0))
        return min(1, max(0, (db + 50) / 40))
    }
}

extension Recorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in _ = self.stop() }
    }
}
