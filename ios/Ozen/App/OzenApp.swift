import SwiftData
import SwiftUI
import UIKit

@main
struct OzenApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer

    init() {
        let launch = LaunchOptions.current
        let container: ModelContainer
        do {
            // Creates Application Support (and Recordings) before the store opens there.
            _ = Storage.recordingsDirectory
            // The app's own container, not the App Group (SwiftData would pick the group by default).
            let config = ModelConfiguration(isStoredInMemoryOnly: launch.inMemoryStore, groupContainer: .none)
            container = try ModelContainer(for: Recording.self, configurations: config)
        } catch {
            fatalError("Could not open the transcript store: \(error)")
        }
        self.container = container

        var engine: TranscriptionEngine = CoreTranscriptionEngine()
        #if DEBUG
        if launch.fakeTranscriber { engine = FakeTranscriptionEngine(duration: launch.fakeDuration) }
        #endif
        let model = AppModel(container: container, engine: engine)
        _model = State(initialValue: model)
        #if DEBUG
        DemoContent.apply(launch, to: model)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(container)
                .onOpenURL { url in
                    if url.isFileURL { model.importFile(at: url) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    model.memoryWarning()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: model.enteredBackground()
            default: break
            }
        }
    }
}

/// Launch arguments. Everything except the defaults is honoured in DEBUG builds only.
struct LaunchOptions {
    var fakeTranscriber = false
    var fakeDuration: Double = 4.5
    var seedDemo = false
    var screen: String?
    var sheet: String?
    var autoRecordSeconds: Double = 8
    var importFile: String?

    var inMemoryStore: Bool { seedDemo }

    static let current: LaunchOptions = {
        var o = LaunchOptions()
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        o.fakeTranscriber = args.contains("-fakeTranscriber")
        o.seedDemo = args.contains("-seedDemo")
        o.screen = value("-screen")
        o.sheet = value("-sheet")
        o.importFile = value("-importFile")
        if let d = value("-fakeDuration").flatMap(Double.init) { o.fakeDuration = d }
        if let d = value("-autoRecordSeconds").flatMap(Double.init) { o.autoRecordSeconds = d }
        #endif
        return o
    }()
}
