import OzenCore
import XCTest
@testable import Ozen

final class HebrewDateTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testTodayYesterdayAndOlder() {
        let now = date(2026, 10, 8, 10, 0)
        XCTAssertEqual(HebrewDate.relative(date(2026, 10, 8, 9, 12), now: now, calendar: cal), "היום, 09:12")
        XCTAssertEqual(HebrewDate.relative(date(2026, 10, 7, 18, 3), now: now, calendar: cal), "אתמול, 18:03")
        XCTAssertEqual(HebrewDate.relative(date(2026, 10, 6), now: now, calendar: cal), "6 באוקטובר")
        XCTAssertEqual(HebrewDate.relative(date(2026, 9, 29), now: now, calendar: cal), "29 בספטמבר")
        XCTAssertEqual(HebrewDate.relative(date(2025, 12, 31), now: now, calendar: cal), "31 בדצמבר 2025")
    }

    func testYesterdayAcrossMonthBoundary() {
        let now = date(2026, 11, 1, 0, 30)
        XCTAssertEqual(HebrewDate.relative(date(2026, 10, 31, 23, 59), now: now, calendar: cal), "אתמול, 23:59")
    }

    func testDefaultTitles() {
        let now = date(2026, 10, 8, 10, 0)
        XCTAssertEqual(Titles.recording(at: date(2026, 10, 8, 9, 5), now: now, calendar: cal), "הקלטה · 8 באוקטובר, 09:05")
        XCTAssertEqual(Titles.file(named: "ישיבת צוות.m4a"), "ישיבת צוות")
        XCTAssertEqual(Titles.file(named: "archive.2026.mp3"), "archive.2026")
        XCTAssertEqual(Titles.imported(named: "PTT-20261008-WA0012.opus", origin: .whatsapp), "הודעה קולית מוואטסאפ")
    }

    func testClock() {
        XCTAssertEqual(formatClock(0), "0:00")
        XCTAssertEqual(formatClock(72.9), "1:12")
        XCTAssertEqual(formatClock(1421), "23:41")
        XCTAssertEqual(formatClock(4350), "1:12:30")
        XCTAssertEqual(formatClock(-3), "0:00")
    }

    func testRemaining() {
        XCTAssertEqual(ProcessingText.remaining(progress: 1, eta: nil), "מוכן")
        XCTAssertEqual(ProcessingText.remaining(progress: 0.5, eta: 23.4), "עוד כ־23 שניות")
        XCTAssertEqual(ProcessingText.remaining(progress: 0.1, eta: 300), "עוד כ־5 דקות")
    }
}

final class ExportTextTests: XCTestCase {
    let segs = [
        TranscriptSegment(start: 0, end: 9, text: "טוב, בואו נתחיל."),
        TranscriptSegment(start: 9, end: 24, text: "סיימנו את רוב הבדיקות."),
    ]

    func testPlain() {
        let s = TranscriptText.plain(title: "פגישה", date: "היום, 09:12", duration: 74, segments: segs)
        XCTAssertEqual(s, "פגישה\nהיום, 09:12 · 1:14\n\n[0:00] טוב, בואו נתחיל.\n\n[0:09] סיימנו את רוב הבדיקות.\n")
    }

    func testMarkdown() {
        let s = TranscriptText.markdown(title: "פגישה", date: "היום, 09:12", duration: 74, segments: segs)
        XCTAssertEqual(s, "# פגישה\n\n_היום, 09:12 · 1:14_\n\n**0:00**\nטוב, בואו נתחיל.\n\n**0:09**\nסיימנו את רוב הבדיקות.\n")
    }

    func testSearchMatchesAreCaseInsensitiveAndNonOverlapping() {
        XCTAssertEqual(TranscriptText.matches(of: "qa", in: "ב־QA וגם qa").count, 2)
        XCTAssertEqual(TranscriptText.matches(of: "אא", in: "אאאא").count, 2)
        XCTAssertTrue(TranscriptText.matches(of: "  ", in: "abc").isEmpty)
    }

    func testFileName() {
        XCTAssertEqual(TranscriptText.fileName(title: "פגישה 1/2: סיכום", ext: "md"), "פגישה 1-2- סיכום.md")
    }
}

final class InboxTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String, bytes: Int = 16) throws -> URL {
        let url = root.appendingPathComponent("src-\(UUID().uuidString)-\(name)")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func testOriginGuess() {
        XCTAssertEqual(ImportOrigin.guess(fileName: "PTT-20261008-WA0012.opus"), .whatsapp)
        XCTAssertEqual(ImportOrigin.guess(fileName: "WhatsApp Audio 2026-10-08 at 09.12.mp4"), .whatsapp)
        XCTAssertEqual(ImportOrigin.guess(fileName: "AUD-20261008-WA0003.m4a"), .whatsapp)
        XCTAssertEqual(ImportOrigin.guess(fileName: "voice.opus"), .whatsapp)
        XCTAssertEqual(ImportOrigin.guess(fileName: "lecture.m4a"), .file)
        XCTAssertEqual(ImportOrigin.guess(fileName: "x.m4a", typeIdentifiers: ["net.whatsapp.audio"]), .whatsapp)
    }

    func testDepositPendingTakeRoundTrip() throws {
        let inbox = Inbox(directory: root.appendingPathComponent("Inbox"))
        let dest = root.appendingPathComponent("Recordings")
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = try inbox.deposit(fileAt: try makeFile("a.m4a"), originalName: "ישיבה.m4a", now: t0.addingTimeInterval(5))
        let b = try inbox.deposit(fileAt: try makeFile("b.opus"), originalName: "PTT-20261008-WA0012.opus", now: t0)

        let pending = inbox.pending()
        XCTAssertEqual(pending.map(\.id), [b.id, a.id], "oldest first")
        XCTAssertEqual(pending.first?.origin, .whatsapp)
        XCTAssertEqual(pending.last?.origin, .file)
        XCTAssertTrue(pending.first!.storedName.hasSuffix(".opus"))

        let moved = try inbox.take(b, into: dest, as: "x.opus")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertEqual(try Data(contentsOf: moved).count, 16)
        XCTAssertEqual(inbox.pending().map(\.id), [a.id])

        inbox.discard(a)
        XCTAssertTrue(inbox.pending().isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: inbox.directory.path)
        XCTAssertTrue(left.isEmpty, "inbox should be empty, has \(left)")
    }

    func testIgnoresMetadataWithoutAudioAndAudioWithoutMetadata() throws {
        let dir = root.appendingPathComponent("Inbox")
        let inbox = Inbox(directory: dir)
        let item = try inbox.deposit(fileAt: try makeFile("a.m4a"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(item.storedName))
        // An audio file still being written (no JSON yet) is not picked up either.
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("partial.m4a"))
        XCTAssertTrue(inbox.pending().isEmpty)
    }
}
