import Foundation
import OzenCore

/// Hebrew date and text formatting, as in the design ("היום, 09:12", "אתמול, 18:03", "6 באוקטובר").
enum HebrewDate {
    static let months = ["ינואר", "פברואר", "מרץ", "אפריל", "מאי", "יוני",
                         "יולי", "אוגוסט", "ספטמבר", "אוקטובר", "נובמבר", "דצמבר"]

    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "he_IL")
        c.timeZone = .current
        return c
    }()

    static func time(_ date: Date, calendar: Calendar = calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "6 באוקטובר", with the year when it is not the current one.
    static func dayMonth(_ date: Date, now: Date = Date(), calendar: Calendar = calendar) -> String {
        let c = calendar.dateComponents([.day, .month, .year], from: date)
        let year = calendar.component(.year, from: now)
        var s = "\(c.day ?? 1) ב\(months[(c.month ?? 1) - 1])"
        if let y = c.year, y != year { s += " \(y)" }
        return s
    }

    /// The list / transcript date: today and yesterday with the time, older days by date.
    static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "היום, \(time(date, calendar: calendar))" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return "אתמול, \(time(date, calendar: calendar))"
        }
        return dayMonth(date, now: now, calendar: calendar)
    }
}

enum Titles {
    /// "הקלטה · 8 באוקטובר, 09:12"
    static func recording(at date: Date, now: Date = Date(), calendar: Calendar = HebrewDate.calendar) -> String {
        "הקלטה · \(HebrewDate.dayMonth(date, now: now, calendar: calendar)), \(HebrewDate.time(date, calendar: calendar))"
    }

    static let whatsapp = "הודעה קולית מוואטסאפ"

    /// The file name without its extension.
    static func file(named name: String) -> String {
        let base = (name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "קובץ שמע" : base
    }

    static func imported(named name: String, origin: ImportOrigin) -> String {
        origin == .whatsapp ? whatsapp : file(named: name)
    }
}

/// The copy / export text (the design's fullText(), without speaker labels).
enum TranscriptText {
    static func plain(title: String, date: String, duration: Double, segments: [TranscriptSegment]) -> String {
        "\(title)\n\(date) · \(formatClock(duration))\n\n"
            + segments.map { "[\(formatClock($0.start))] \($0.text)" }.joined(separator: "\n\n") + "\n"
    }

    static func markdown(title: String, date: String, duration: Double, segments: [TranscriptSegment]) -> String {
        "# \(title)\n\n_\(date) · \(formatClock(duration))_\n\n"
            + segments.map { "**\(formatClock($0.start))**\n\($0.text)" }.joined(separator: "\n\n") + "\n"
    }

    /// A file name safe for the share sheet: the title with path separators removed.
    static func fileName(title: String, ext: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "ozen" : cleaned).\(ext)"
    }

    /// Ranges of case-insensitive matches of `query` in `text`.
    static func matches(of query: String, in text: String) -> [Range<String.Index>] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }
}

/// "עוד כ־N שניות" / "מוכן".
enum ProcessingText {
    static func remaining(progress: Double, eta: Double?) -> String {
        if progress >= 1 { return "מוכן" }
        guard let eta, eta.isFinite else { return "מתחיל…" }
        let s = max(1, Int(eta.rounded()))
        if s < 90 { return s == 1 ? "עוד כשנייה" : "עוד כ־\(s) שניות" }
        let m = Int((eta / 60).rounded())
        return m <= 1 ? "עוד כדקה" : "עוד כ־\(m) דקות"
    }
}
