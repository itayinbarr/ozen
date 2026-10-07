import Foundation

/// The App Group shared by the app and the share extension.
enum OzenAppGroup {
    static let identifier = "group.com.itayinbar.ozen"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// `<group>/Inbox`, where the share extension drops audio for the app to transcribe.
    static var inboxURL: URL? {
        containerURL?.appendingPathComponent("Inbox", isDirectory: true)
    }
}

/// Where an imported file came from.
enum ImportOrigin: String, Codable, Sendable {
    case file
    case whatsapp

    /// WhatsApp voice notes arrive as "PTT-20261008-WA0012.opus", "AUD-…-WA….opus" or
    /// "WhatsApp Audio 2026-10-08 at 09.12.opus"; WhatsApp is also the main source of bare .opus files.
    static func guess(fileName: String, typeIdentifiers: [String] = []) -> ImportOrigin {
        let name = fileName.lowercased()
        if name.hasPrefix("ptt-") || name.contains("whatsapp") { return .whatsapp }
        if name.hasPrefix("aud-") && name.contains("-wa") { return .whatsapp }
        if name.hasSuffix(".opus") { return .whatsapp }
        if typeIdentifiers.contains(where: { $0.lowercased().contains("whatsapp") }) { return .whatsapp }
        return .file
    }
}

/// One file waiting in the inbox. Stored as `<id>.json` next to `<id>.<ext>`.
struct InboxItem: Codable, Equatable, Sendable {
    var id: String
    /// The audio file's name inside the inbox directory.
    var storedName: String
    /// The name the file had when it was shared (shown on the processing screen, used for the title).
    var originalName: String
    var origin: ImportOrigin
    var receivedAt: Date
}

/// A directory of shared audio files plus their metadata. The share extension deposits; the app takes.
struct Inbox {
    let directory: URL
    var fileManager: FileManager = .default

    /// Copies `fileURL` into the inbox and writes its metadata last, so a half-written deposit is never picked up.
    @discardableResult
    func deposit(fileAt fileURL: URL, originalName: String? = nil, origin: ImportOrigin? = nil,
                 typeIdentifiers: [String] = [], now: Date = Date()) throws -> InboxItem {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = originalName ?? fileURL.lastPathComponent
        let id = UUID().uuidString
        let ext = (name as NSString).pathExtension.isEmpty ? fileURL.pathExtension : (name as NSString).pathExtension
        let stored = ext.isEmpty ? id : "\(id).\(ext.lowercased())"
        try fileManager.copyItem(at: fileURL, to: directory.appendingPathComponent(stored))
        let item = InboxItem(id: id, storedName: stored, originalName: name,
                             origin: origin ?? ImportOrigin.guess(fileName: name, typeIdentifiers: typeIdentifiers),
                             receivedAt: now)
        let data = try Inbox.encoder.encode(item)
        try data.write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
        return item
    }

    /// Items whose metadata and audio are both present, oldest first.
    func pending() -> [InboxItem] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let items = names.filter { $0.hasSuffix(".json") }.compactMap { name -> InboxItem? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let item = try? Inbox.decoder.decode(InboxItem.self, from: data) else { return nil }
            guard fileManager.fileExists(atPath: directory.appendingPathComponent(item.storedName).path) else { return nil }
            return item
        }
        return items.sorted { $0.receivedAt < $1.receivedAt }
    }

    /// Moves the item's audio into `destinationDirectory` (as `<newName>`) and removes it from the inbox.
    func take(_ item: InboxItem, into destinationDirectory: URL, as newName: String) throws -> URL {
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let src = directory.appendingPathComponent(item.storedName)
        let dst = destinationDirectory.appendingPathComponent(newName)
        if fileManager.fileExists(atPath: dst.path) { try fileManager.removeItem(at: dst) }
        try fileManager.moveItem(at: src, to: dst)
        try? fileManager.removeItem(at: directory.appendingPathComponent("\(item.id).json"))
        return dst
    }

    /// Drops an item that cannot be imported.
    func discard(_ item: InboxItem) {
        try? fileManager.removeItem(at: directory.appendingPathComponent(item.storedName))
        try? fileManager.removeItem(at: directory.appendingPathComponent("\(item.id).json"))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
