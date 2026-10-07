import Foundation
import Observation
import OzenCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum Screen: Int {
    case home, list, processing, transcript

    /// The design's DEPTH table.
    var depth: Int {
        switch self {
        case .home: return 0
        case .list, .processing: return 1
        case .transcript: return 2
        }
    }
}

enum SheetKind: Equatable {
    case keep(UUID)
    case export
    case importAudio
    case deleteAll
}

struct Toast: Equatable {
    var id = UUID()
    var text: String
    var undo: Bool
}

/// What to do with the audio after a recording is transcribed.
enum KeepPreference: String {
    case ask, keep, discard
}

enum AudioTypes {
    static let opus = UTType(importedAs: "org.xiph.opus", conformingTo: .audio)
    static let ogg = UTType(importedAs: "org.xiph.ogg-audio", conformingTo: .audio)
    static let importable: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, opus, ogg]
}

@MainActor
@Observable
final class AppModel {
    // Navigation
    var screen: Screen = .home
    var transcriptFrom: Screen = .home
    var currentID: UUID?
    var sheet: SheetKind?
    var toast: Toast?
    var showFileImporter = false

    // List selection
    var selectMode = false
    var selected: Set<UUID> = []
    /// Rows deleted but still undoable.
    var hiddenIDs: Set<UUID> = []

    // Keep-recording sheet
    var rememberKeepChoice = false
    var keepPreference: KeepPreference {
        get { KeepPreference(rawValue: keepPreferenceRaw) ?? .ask }
        set { keepPreferenceRaw = newValue.rawValue }
    }
    private var keepPreferenceRaw: String = UserDefaults.standard.string(forKey: "keepRecordingPreference") ?? "ask" {
        didSet { UserDefaults.standard.set(keepPreferenceRaw, forKey: "keepRecordingPreference") }
    }

    let recorder = Recorder()
    let player = Player()
    let jobs: JobQueue
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    /// Bumped to restart the orb's draw-in animation.
    var orbDrawToken = 0

    @ObservationIgnored private let live = LiveActivityController()
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDeletion: Set<UUID> = []

    init(container: ModelContainer, engine: TranscriptionEngine) {
        self.container = container
        self.jobs = JobQueue(engine: engine, context: container.mainContext)

        live.endStale()
        recorder.onStateChange = { [weak self] r in self?.live.sync(with: r) }
        recorder.onFinish = { [weak self] f in self?.recordingFinished(f) }
        RecordingControlBridge.handler = { [weak self] action in self?.handle(action) }

        jobs.canStart = { [weak self] in
            guard let self else { return false }
            if self.recorder.isActive { return false }
            if case .keep = self.sheet { return false }
            return true
        }
        jobs.onStart = { [weak self] _ in
            guard let self else { return }
            self.player.stop()
            withAnimation(Oz.ease(0.6)) {
                self.sheet = nil
                self.selectMode = false
                self.screen = .processing
            }
        }
        jobs.onFinish = { [weak self] rec in
            #if DEBUG
            for seg in rec.segments { print("OZEN_SEGMENT [\(seg.start)-\(seg.end)] \(seg.text)") }
            print("OZEN_DONE \(rec.segments.count)")
            #endif
            self?.jobFinished(rec)
        }
        jobs.onFail = { [weak self] _ in
            guard let self else { return }
            self.showToast("לא הצלחנו לתמלל את הקובץ")
            if self.jobs.hasQueued { self.jobs.pump() } else if self.screen == .processing { self.go(.home) }
        }
    }

    // MARK: Navigation

    func go(_ s: Screen) {
        withAnimation(Oz.ease()) { screen = s }
    }

    func goHome() {
        withAnimation(Oz.ease()) {
            screen = .home
            selectMode = false
            selected = []
        }
    }

    func goList() { go(.list) }

    func open(_ id: UUID, from: Screen) {
        player.stop()
        currentID = id
        transcriptFrom = from
        go(.transcript)
    }

    func backFromTranscript() {
        player.stop()
        go(transcriptFrom == .list ? .list : .home)
    }

    func recording(_ id: UUID?) -> Recording? {
        guard let id else { return nil }
        var d = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: Recording

    func toggleRecord() {
        guard screen == .home, sheet == nil else { return }
        switch recorder.state {
        case .idle:
            Task {
                do {
                    try await recorder.start()
                    orbDrawToken += 1
                } catch Recorder.StartError.permissionDenied {
                    showToast("צריך גישה למיקרופון — אפשר לאשר בהגדרות")
                } catch {
                    showToast("ההקלטה לא התחילה")
                }
            }
        case .recording, .paused:
            recorder.stop()
        }
    }

    private func handle(_ action: RecordingControlAction) {
        switch action {
        case .togglePause: recorder.togglePause()
        case .stop: recorder.stop()
        }
    }

    private func recordingFinished(_ f: Recorder.Finished) {
        let rec = Recording(title: Titles.recording(at: f.startedAt), createdAt: f.startedAt,
                            duration: f.duration, audioFileName: f.fileURL.lastPathComponent, source: .record)
        context.insert(rec)
        try? context.save()
        jobs.enqueue(rec.id)
    }

    // MARK: Jobs

    private func jobFinished(_ rec: Recording) {
        if rec.source == .record {
            switch keepPreference {
            case .ask:
                rememberKeepChoice = false
                withAnimation(Oz.ease(0.42)) { sheet = .keep(rec.id) }
                return
            case .keep: break
            case .discard: discardAudio(of: rec)
            }
        }
        finish(rec)
    }

    private func finish(_ rec: Recording) {
        withAnimation(Oz.ease(0.42)) { sheet = nil }
        if jobs.hasQueued {
            jobs.pump()
        } else {
            jobs.clearLive()
            open(rec.id, from: .home)
        }
    }

    func keepDecision(keep: Bool) {
        guard case let .keep(id) = sheet, let rec = recording(id) else { sheet = nil; return }
        if rememberKeepChoice { keepPreference = keep ? .keep : .discard }
        if !keep { discardAudio(of: rec) }
        finish(rec)
    }

    private func discardAudio(of rec: Recording) {
        Storage.removeAudio(named: rec.audioFileName)
        rec.audioFileName = nil
        try? context.save()
    }

    func closeSheet() {
        if case .keep = sheet {
            keepDecision(keep: true)
        } else {
            withAnimation(Oz.ease(0.42)) { sheet = nil }
        }
    }

    func present(_ s: SheetKind) {
        withAnimation(Oz.ease(0.42)) { sheet = s }
    }

    // MARK: Import

    func pickFile() {
        withAnimation(Oz.ease(0.42)) { sheet = nil }
        guard !recorder.isActive else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            showFileImporter = true
        }
    }

    /// A file from the document picker or "Open in / Copy to אוזן".
    func importFile(at url: URL, origin: ImportOrigin? = nil) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let o = origin ?? ImportOrigin.guess(fileName: name)
        let stored = Storage.newAudioFileName(ext: url.pathExtension)
        do {
            let dst = Storage.recordingsDirectory.appendingPathComponent(stored)
            try FileManager.default.copyItem(at: url, to: dst)
        } catch {
            showToast("לא הצלחנו לפתוח את הקובץ")
            return
        }
        // Files handed over with "Copy to" land in Documents/Inbox; we own that copy.
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        addImported(storedName: stored, originalName: name, origin: o, receivedAt: Date())
    }

    /// Takes everything the share extension left in the App Group inbox.
    func drainInbox() {
        guard let dir = OzenAppGroup.inboxURL else { return }
        let inbox = Inbox(directory: dir)
        for item in inbox.pending() {
            let stored = Storage.newAudioFileName(ext: (item.storedName as NSString).pathExtension)
            do {
                _ = try inbox.take(item, into: Storage.recordingsDirectory, as: stored)
                addImported(storedName: stored, originalName: item.originalName, origin: item.origin, receivedAt: item.receivedAt)
            } catch {
                inbox.discard(item)
            }
        }
    }

    private func addImported(storedName: String, originalName: String, origin: ImportOrigin, receivedAt: Date) {
        let rec = Recording(title: Titles.imported(named: originalName, origin: origin), createdAt: receivedAt,
                            audioFileName: storedName, source: origin == .whatsapp ? .whatsapp : .file,
                            originalFileName: originalName)
        context.insert(rec)
        try? context.save()
        jobs.enqueue(rec.id)
    }

    // MARK: Deletion (undoable)

    func delete(_ ids: Set<UUID>, label: String) {
        guard !ids.isEmpty else { return }
        commitDeletion()
        pendingDeletion = ids
        withAnimation(Oz.ease(0.32)) {
            hiddenIDs.formUnion(ids)
            selected = []
            selectMode = false
        }
        showToast(label, undo: true)
    }

    func undoDelete() {
        withAnimation(Oz.ease(0.32)) { hiddenIDs.subtract(pendingDeletion) }
        pendingDeletion = []
        dismissToast()
    }

    /// Makes pending deletions permanent (toast expired, or the app is going to the background).
    func commitDeletion() {
        guard !pendingDeletion.isEmpty else { return }
        for id in pendingDeletion {
            if let rec = recording(id) {
                Storage.removeAudio(named: rec.audioFileName)
                context.delete(rec)
            }
        }
        try? context.save()
        hiddenIDs.subtract(pendingDeletion)
        pendingDeletion = []
    }

    func deleteAllVisible() {
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        let ids = Set(all.map(\.id)).subtracting(hiddenIDs)
        withAnimation(Oz.ease(0.42)) { sheet = nil }
        delete(ids, label: "כל התמלולים נמחקו")
    }

    // MARK: Toast

    func showToast(_ text: String, undo: Bool = false) {
        toastTask?.cancel()
        withAnimation(Oz.ease(0.4)) { toast = Toast(text: text, undo: undo) }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(undo ? 4.2 : 2.0))
            guard !Task.isCancelled, let self else { return }
            if undo { self.commitDeletion() }
            self.dismissToast()
        }
    }

    func dismissToast() {
        withAnimation(.easeOut(duration: 0.25)) { toast = nil }
    }

    // MARK: Lifecycle

    func becameActive() {
        drainInbox()
        jobs.resumePending()
    }

    func enteredBackground() {
        commitDeletion()
        // The ONNX sessions hold ~500 MB; don't keep them while suspended.
        jobs.unloadModel()
    }

    func memoryWarning() {
        jobs.unloadModel()
    }
}
