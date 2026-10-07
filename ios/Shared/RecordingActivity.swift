import ActivityKit
import AppIntents
import Foundation

/// Live Activity for an ongoing recording. Compiled into the app and the OzenLive widget extension.
struct OzenRecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// While running: now − elapsed, so `Text(timerInterval:)` ticks on its own without updates.
        var timerStart: Date
        /// Elapsed seconds (excluding pauses) at the moment of the last update; shown while paused.
        var elapsed: Double
        var isPaused: Bool
    }
}

// MARK: - Lock screen / Dynamic Island buttons

/// What the Live Activity buttons ask the recorder to do.
enum RecordingControlAction: Sendable {
    case togglePause
    case stop
}

/// The app installs `handler` at launch. `LiveActivityIntent.perform()` runs in the app's process,
/// so the handler reaches the app's recorder; in the widget process it is never called.
@MainActor
enum RecordingControlBridge {
    static var handler: ((RecordingControlAction) -> Void)?

    static func perform(_ action: RecordingControlAction) {
        handler?(action)
    }
}

struct ToggleRecordingPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "השהיה או המשך הקלטה"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        await RecordingControlBridge.perform(.togglePause)
        return .result()
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "סיום הקלטה"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        await RecordingControlBridge.perform(.stop)
        return .result()
    }
}
