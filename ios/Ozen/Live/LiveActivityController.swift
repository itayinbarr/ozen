import ActivityKit
import Foundation
import os

private let log = Logger(subsystem: "com.itayinbar.ozen", category: "live-activity")

/// Mirrors the recorder into a Live Activity (lock screen + Dynamic Island).
@MainActor
final class LiveActivityController {
    private var activity: Activity<OzenRecordingAttributes>?

    /// Ends activities left over from a previous run (e.g. the app was killed while recording).
    func endStale() {
        for a in Activity<OzenRecordingAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func sync(with recorder: Recorder) {
        switch recorder.state {
        case .idle:
            end()
        case .recording, .paused:
            let elapsed = recorder.elapsed()
            let state = OzenRecordingAttributes.ContentState(
                timerStart: Date().addingTimeInterval(-elapsed),
                elapsed: elapsed,
                isPaused: recorder.state == .paused)
            if let activity {
                Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            } else {
                start(state)
            }
        }
    }

    private func start(_ state: OzenRecordingAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.info("Live Activities are disabled")
            return
        }
        do {
            activity = try Activity.request(attributes: OzenRecordingAttributes(),
                                            content: ActivityContent(state: state, staleDate: nil),
                                            pushType: nil)
        } catch {
            log.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
