#if DEBUG
import Foundation
import OzenCore
import SwiftData

/// The design's sample content, for screenshots and UI work before the engine lands.
/// Only reachable through DEBUG launch arguments (-seedDemo, -fakeTranscriber, -screen, -sheet).
enum DemoContent {
    static let sample: [TranscriptSegment] = {
        let rows: [(Double, String)] = [
            (0, "טוב, בואו נתחיל. המטרה היום היא לסגור את הדדליין להשקה של הגרסה החדשה."),
            (9, "סיימנו את רוב הבדיקות ב־QA. נשארו שני באגים קטנים במסך ההגדרות, ואני מעריכה שנסגור אותם עד יום שלישי."),
            (24, "מצוין. ומה עם התרגום לאנגלית? זה עדיין חוסם את הספרינט?"),
            (31, "לא ממש. קיבלנו את הקבצים אתמול, אני עובר עליהם היום ושולח לכם פידבק מחר בבוקר."),
            (42, "אז אם הכל מסתדר, אפשר לכוון להשקה ביום ראשון הבא, החמישה עשר בחודש."),
            (51, "מקובל עליי. בואו נקבע פגישת סטטוס קצרה בזום ביום חמישי ונוודא שאין הפתעות."),
            (60, "אני אשלח זימון. ומי מכין את המייל ללקוחות?"),
            (66, "אני לוקחת את זה. טיוטה ראשונה עם דמו של הפיצ׳רים תהיה מוכנה עד סוף השבוע."),
        ]
        return rows.enumerated().map { i, r in
            TranscriptSegment(start: r.0, end: i + 1 < rows.count ? rows[i + 1].0 : 74, text: r.1)
        }
    }()

    struct Item {
        var title: String
        var daysAgo: Int
        var hour: Int
        var minute: Int
        var duration: Double
        var texts: [String]
        var whatsapp = false
    }

    static let initial: [Item] = [
        Item(title: "פגישת השקה של גרסה 2.4", daysAgo: 0, hour: 9, minute: 12, duration: 1421,
             texts: ["טוב, בואו נתחיל. המטרה היום היא לסגור את לוח הזמנים להשקה של הגרסה החדשה."] + sample.dropFirst().map(\.text)),
        Item(title: "הודעה קולית מדנה", daysAgo: 1, hour: 18, minute: 3, duration: 72,
             texts: ["היי, רציתי רק לעדכן שהספק אישר את ההזמנה, והמשלוח אמור להגיע ביום ראשון.",
                     "תגיד לי אם זה מסתדר לך מבחינת הזמנים."], whatsapp: true),
        Item(title: "שיחה עם רואה החשבון", daysAgo: 2, hour: 11, minute: 40, duration: 2465,
             texts: ["לגבי הדוח השנתי, יש כמה מסמכים שחסרים לנו כדי לסגור את השנה.",
                     "אני צריך את האישורים מהבנק ואת הקבלות על ההוצאות של הרבעון האחרון."]),
        Item(title: "הרצאה על עיצוב מוצר", daysAgo: 6, hour: 14, minute: 0, duration: 4350,
             texts: ["השאלה הראשונה שצריך לשאול היא בשביל מי אנחנו בונים את המוצר.",
                     "רק אחרי שעונים על זה אפשר להתחיל לדבר על פיצ׳רים."]),
        Item(title: "רעיונות לפרויקט", daysAgo: 9, hour: 22, minute: 15, duration: 200,
             texts: ["אולי כדאי להתחיל דווקא מהצד של המשתמש, ולא מהטכנולוגיה."]),
        Item(title: "ישיבת צוות שבועית", daysAgo: 14, hour: 10, minute: 0, duration: 1830,
             texts: ["נעבור על המשימות הפתוחות מהשבוע שעבר, ואז נחלק את העבודה לשבוע הבא."]),
    ]

    @MainActor
    static func apply(_ o: LaunchOptions, to model: AppModel) {
        var first: Recording?
        if o.seedDemo {
            let cal = Calendar.current
            for (i, it) in initial.enumerated() {
                let day = cal.date(byAdding: .day, value: -it.daysAgo, to: Date())!
                let date = cal.date(bySettingHour: it.hour, minute: it.minute, second: 0, of: day)!
                var t = 0.0
                let step = it.duration / Double(max(1, it.texts.count))
                let segs: [TranscriptSegment] = i == 0 ? sample : it.texts.map { text in
                    defer { t += step }
                    return TranscriptSegment(start: t, end: t + step, text: text)
                }
                let rec = Recording(title: it.title, createdAt: date, duration: i == 0 ? 74 : it.duration,
                                    audioFileName: i == 0 ? silentAudio(seconds: 74) : nil,
                                    source: it.whatsapp ? .whatsapp : .record, status: .done, segments: segs)
                model.context.insert(rec)
                if i == 0 { first = rec }
            }
            try? model.context.save()
        }

        if let path = o.importFile {
            // End-to-end check of the real engine: transcribe a host file and log the result.
            model.importFile(at: URL(fileURLWithPath: path))
        }

        switch o.screen {
        case "list":
            model.screen = .list
        case "transcript":
            if let first {
                model.currentID = first.id
                model.transcriptFrom = .list
                model.screen = .transcript
                if let url = first.audioURL {
                    model.player.play(url: url, from: 9.4)
                    model.player.toggle()
                }
            }
        case "processing":
            let rec = Recording(title: Titles.whatsapp, audioFileName: silentAudio(seconds: 94), source: .whatsapp,
                                originalFileName: "PTT-20261008-WA0012.opus")
            model.context.insert(rec)
            try? model.context.save()
            model.jobs.enqueue(rec.id)
        case "recording":
            model.recorder.startDemo(elapsed: 42)
        case "autoRecord":
            // Real microphone recording that stops by itself: exercises the recorder, Live Activity, job queue and keep sheet.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                model.toggleRecord()
                try? await Task.sleep(for: .seconds(o.autoRecordSeconds))
                if model.recorder.isActive { model.recorder.stop() }
            }
        default:
            break
        }

        switch o.sheet {
        case "import": model.sheet = .importAudio
        case "export": model.sheet = .export
        case "deleteAll": model.sheet = .deleteAll
        case "keep": if let first { model.sheet = .keep(first.id) }
        default: break
        }
    }

    /// A silent 8 kHz WAV in the recordings folder, so the demo player has something to play.
    static func silentAudio(seconds: Double) -> String {
        let name = "demo-\(Int(seconds)).wav"
        let url = Storage.recordingsDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return name }
        let rate: UInt32 = 8000
        let samples = UInt32(seconds * Double(rate))
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples * 2)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(samples * 2)
        d.append(Data(count: Int(samples) * 2))
        try? d.write(to: url)
        return name
    }
}

/// Streams the design's SAMPLE sentences with design-like progress pacing.
final class FakeTranscriptionEngine: TranscriptionEngine {
    let duration: Double

    init(duration: Double) {
        self.duration = max(0.5, duration)
    }

    func transcribe(fileURL: URL) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        let total = duration
        return AsyncThrowingStream { continuation in
            let task = Task {
                let segs = DemoContent.sample
                var emitted = 0
                let steps = 60
                for step in 1...steps {
                    try await Task.sleep(for: .seconds(total / Double(steps)))
                    let p = Double(step) / Double(steps)
                    while emitted < segs.count, Double(emitted) / Double(segs.count) <= p {
                        continuation.yield(.segment(segs[emitted]))
                        emitted += 1
                    }
                    continuation.yield(.progress(p, eta: (1 - p) * 60))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func unload() async {}
}
#endif
