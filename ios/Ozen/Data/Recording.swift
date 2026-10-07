import Foundation
import OzenCore
import SwiftData

enum RecordingSource: String, Codable, CaseIterable {
    case record
    case file
    case whatsapp
}

enum TranscriptionStatus: String, Codable {
    /// Audio is saved; transcription has not finished yet (also survives app suspension / relaunch).
    case pending
    case done
    case failed
}

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    /// Seconds of audio (recordings: excluding pauses).
    var duration: Double
    /// File name inside `Storage.recordingsDirectory`; nil once the user chose not to keep the audio.
    var audioFileName: String?
    var sourceRaw: String
    /// Name of the imported file (shown on the processing screen).
    var originalFileName: String?
    var statusRaw: String
    /// JSON-encoded `[TranscriptSegment]`.
    var segmentsData: Data

    init(id: UUID = UUID(), title: String, createdAt: Date = Date(), duration: Double = 0,
         audioFileName: String? = nil, source: RecordingSource, originalFileName: String? = nil,
         status: TranscriptionStatus = .pending, segments: [TranscriptSegment] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.sourceRaw = source.rawValue
        self.originalFileName = originalFileName
        self.statusRaw = status.rawValue
        self.segmentsData = (try? JSONEncoder().encode(segments)) ?? Data()
    }

    var source: RecordingSource {
        get { RecordingSource(rawValue: sourceRaw) ?? .file }
        set { sourceRaw = newValue.rawValue }
    }

    var status: TranscriptionStatus {
        get { TranscriptionStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var segments: [TranscriptSegment] {
        get { (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? [] }
        set { segmentsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var audioURL: URL? {
        audioFileName.map { Storage.recordingsDirectory.appendingPathComponent($0) }
    }

    var preview: String {
        switch status {
        case .pending: return "ממתין לתמלול…"
        case .failed: return "התמלול נכשל"
        case .done:
            let text = segments.map(\.text).joined(separator: " ")
            return text.isEmpty ? "לא זוהה דיבור" : String(text.prefix(160))
        }
    }
}

enum Storage {
    /// Application Support/Recordings. Kept in device backups: these are the user's own recordings.
    static let recordingsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func newAudioFileName(ext: String) -> String {
        let e = ext.isEmpty ? "m4a" : ext.lowercased()
        return "\(UUID().uuidString).\(e)"
    }

    static func removeAudio(named name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: recordingsDirectory.appendingPathComponent(name))
    }
}
