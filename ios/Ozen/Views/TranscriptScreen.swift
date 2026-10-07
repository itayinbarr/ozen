import OzenCore
import SwiftUI
import UIKit

struct TranscriptScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let rec = app.recording(app.currentID) {
            TranscriptContent(rec: rec)
                .id(rec.id)
        } else {
            Color.clear
        }
    }
}

private struct TranscriptContent: View {
    @Environment(AppModel.self) private var app
    let rec: Recording

    @State private var searchOpen = false
    @State private var query = ""
    @State private var editing = false
    @State private var drafts: [String] = []
    @State private var titleEditing = false
    @State private var titleDraft = ""
    @State private var copied = false
    @State private var copyTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @FocusState private var titleFocused: Bool

    var body: some View {
        let segments = rec.segments
        let player = app.player
        let hasPlayer = player.loadedURL != nil && rec.audioURL != nil
        let activeIndex = hasPlayer ? segments.lastIndex(where: { $0.start <= player.position + 0.05 }) : nil
        let q = searchOpen ? query.trimmingCharacters(in: .whitespaces) : ""
        let matchCount = q.isEmpty ? 0 : segments.reduce(0) { $0 + TranscriptText.matches(of: q, in: $1.text).count }

        VStack(spacing: 0) {
            header
            searchField(matchCount: matchCount, hasQuery: !q.isEmpty)
            titleBlock

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if segments.isEmpty {
                            Text(rec.status == .done ? "לא זוהה דיבור בהקלטה" : rec.preview)
                                .font(Oz.rubik(16))
                                .foregroundStyle(Oz.sub)
                                .padding(12)
                        }
                        ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                            SegmentView(segment: seg,
                                        query: q,
                                        isActive: activeIndex == i,
                                        editing: editing,
                                        draft: Binding(get: { i < drafts.count ? drafts[i] : seg.text },
                                                       set: { if i < drafts.count { drafts[i] = $0 } }))
                                .id(i)
                                .onTapGesture { tapSegment(seg) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: activeIndex) { _, idx in
                    if let idx, player.isPlaying { withAnimation(Oz.ease(0.5)) { proxy.scrollTo(idx, anchor: .center) } }
                }
            }

            if hasPlayer {
                MiniPlayer(player: player, onClose: { withAnimation(Oz.ease(0.4)) { player.stop() } })
                    .padding(.horizontal, 14)
                    .padding(.bottom, 2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            bottomBar
        }
        .background(Oz.bg)
        .animation(Oz.ease(0.4), value: hasPlayer)
        .onChange(of: app.screen) { _, s in
            if s != .transcript { endEditing(save: true); searchOpen = false; query = "" }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            CircleIconButton(glyph: .chevronBack, lineWidth: 2, label: "חזרה") {
                endEditing(save: true)
                app.backFromTranscript()
            }
            Spacer()
            HStack(spacing: 4) {
                CircleIconButton(glyph: .search, size: 22, lineWidth: 1.9, label: "חיפוש",
                                 background: searchOpen ? Oz.card : .clear) {
                    withAnimation(Oz.ease(0.35)) {
                        searchOpen.toggle()
                        if !searchOpen { query = "" }
                    }
                    if searchOpen {
                        Task { try? await Task.sleep(for: .milliseconds(250)); searchFocused = true }
                    }
                }
                CircleIconButton(glyph: editing ? .check : .pencil, size: 22, lineWidth: editing ? 2.4 : 1.8,
                                 label: editing ? "שמירה" : "עריכה",
                                 background: editing ? Oz.orange : .clear,
                                 foreground: editing ? Oz.charcoal : Oz.ink) {
                    toggleEdit()
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 52)
        .padding(.top, 8)
    }

    private func searchField(matchCount: Int, hasQuery: Bool) -> some View {
        HStack(spacing: 10) {
            Icon(glyph: .search, size: 18, lineWidth: 2)
                .opacity(0.55)
            TextField("חיפוש", text: $query)
                .font(Oz.rubik(16))
                .foregroundStyle(Oz.ink)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if hasQuery {
                Text("\(matchCount)")
                    .font(Oz.rubik(13))
                    .monospacedDigit()
                    .foregroundStyle(Oz.sub)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 16).fill(Oz.card))
        .padding(.top, 4)
        .padding(.bottom, 8)
        .padding(.horizontal, 18)
        .frame(height: searchOpen ? 62 : 0, alignment: .top)
        .clipped()
        .opacity(searchOpen ? 1 : 0)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if titleEditing {
                TextField("", text: $titleDraft, axis: .vertical)
                    .font(Oz.karantina(46))
                    .foregroundStyle(Oz.ink)
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit { saveTitle() }
                    .onChange(of: titleDraft) { _, v in
                        if v.contains("\n") { titleDraft = v.replacingOccurrences(of: "\n", with: ""); saveTitle() }
                    }
                    .padding(.bottom, 2)
                    .overlay(alignment: .bottom) { Rectangle().fill(Oz.orange).frame(height: 2) }
                    .onChange(of: titleFocused) { _, f in if !f { saveTitle() } }
            } else {
                Text(rec.title)
                    .font(Oz.karantina(46))
                    .foregroundStyle(Oz.ink)
                    .lineSpacing(-6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        titleDraft = rec.title
                        titleEditing = true
                        titleFocused = true
                    }
                    .accessibilityHint("הקישו לשינוי השם")
            }
            // A plain String (not an interpolated LocalizedStringKey, whose arguments get bidi-isolated
            // and would flip the line to LTR).
            Text(verbatim: "\u{200F}" + HebrewDate.relative(rec.createdAt) + " · " + formatClock(rec.duration))
                .font(Oz.rubik(14))
                .foregroundStyle(Oz.sub)
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button(action: copyAll) {
                HStack(spacing: 10) {
                    Icon(glyph: copied ? .check : .copy, size: 22, lineWidth: copied ? 2.4 : 1.9)
                        .transition(.opacity)
                    Text(copied ? "הועתק" : "העתקה")
                        .font(Oz.rubik(18, .semibold))
                }
                .foregroundStyle(Oz.charcoal)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(Capsule().fill(copied ? Oz.sage : Oz.orange))
                .animation(.easeInOut(duration: 0.3), value: copied)
            }
            .buttonStyle(PressStyle())

            Button { endEditing(save: true); app.present(.export) } label: {
                Icon(glyph: .share, size: 22, lineWidth: 1.9)
                    .foregroundStyle(Oz.ink)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(Oz.card))
            }
            .buttonStyle(PressStyle(scale: 0.94))
            .accessibilityLabel("ייצוא")
        }
        .padding(.top, 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
    }

    // MARK: Actions

    private func tapSegment(_ seg: TranscriptSegment) {
        guard !editing, let url = rec.audioURL, FileManager.default.fileExists(atPath: url.path) else { return }
        withAnimation(Oz.ease(0.4)) { app.player.play(url: url, from: seg.start) }
    }

    private func toggleEdit() {
        if editing {
            endEditing(save: true)
        } else {
            app.player.stop()
            drafts = rec.segments.map(\.text)
            withAnimation(.easeInOut(duration: 0.25)) { editing = true }
        }
    }

    private func endEditing(save: Bool) {
        if titleEditing { saveTitle() }
        guard editing else { return }
        if save {
            var segs = rec.segments
            for i in segs.indices where i < drafts.count {
                segs[i].text = drafts[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if segs != rec.segments {
                rec.segments = segs
                try? app.context.save()
            }
        }
        withAnimation(.easeInOut(duration: 0.25)) { editing = false }
    }

    private func saveTitle() {
        guard titleEditing else { return }
        let t = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, t != rec.title {
            rec.title = t
            try? app.context.save()
        }
        titleEditing = false
    }

    private func copyAll() {
        endEditing(save: true)
        UIPasteboard.general.string = TranscriptText.plain(title: rec.title, date: HebrewDate.relative(rec.createdAt),
                                                           duration: rec.duration, segments: rec.segments)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        copied = true
        copyTask?.cancel()
        copyTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { copied = false }
        }
    }
}

private struct SegmentView: View {
    let segment: TranscriptSegment
    let query: String
    let isActive: Bool
    let editing: Bool
    @Binding var draft: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(formatClock(segment.start))
                .font(Oz.rubik(13))
                .monospacedDigit()
                .foregroundStyle(Oz.sub)
            if editing {
                TextField("", text: $draft, axis: .vertical)
                    .font(Oz.rubik(18, relativeTo: .body))
                    .lineSpacing(18 * 0.62 - 4)
                    .foregroundStyle(Oz.ink)
                    .lineLimit(2...)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Oz.card))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Oz.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            } else {
                Text(highlighted)
                    .font(Oz.rubik(18, relativeTo: .body))
                    .lineSpacing(18 * 0.62 - 4)
                    .foregroundStyle(Oz.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Oz.sage.opacity(isActive ? 0.42 : 0)))
        .animation(.easeInOut(duration: 0.35), value: isActive)
        .contentShape(Rectangle())
    }

    private var highlighted: AttributedString {
        var a = AttributedString(segment.text)
        guard !query.isEmpty else { return a }
        for r in TranscriptText.matches(of: query, in: segment.text) {
            guard let lo = AttributedString.Index(r.lowerBound, within: a),
                  let hi = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lo..<hi].backgroundColor = Oz.orange
            a[lo..<hi].foregroundColor = Oz.charcoal
        }
        return a
    }
}

private struct MiniPlayer: View {
    var player: Player
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Icon(glyph: player.isPlaying ? .pause : .play, size: 16)
                    .foregroundStyle(Oz.charcoal)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Oz.orange))
            }
            .buttonStyle(PressStyle(scale: 0.92))
            .accessibilityLabel(player.isPlaying ? "השהיה" : "ניגון")

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.5, opacity: 0.35))
                    Capsule().fill(Oz.orange)
                        .frame(width: g.size.width * (player.duration > 0 ? min(1, player.position / player.duration) : 0))
                        .animation(.linear(duration: 0.1), value: player.position)
                }
            }
            .frame(height: 4)
            .environment(\.layoutDirection, .rightToLeft)

            Text(formatClock(player.position))
                .font(Oz.rubik(13))
                .monospacedDigit()
                .frame(minWidth: 34)

            Button(action: onClose) {
                Icon(glyph: .close, size: 16, lineWidth: 2.2)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("סגירת הנגן")
        }
        .foregroundStyle(Oz.bg)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 58)
        .background(RoundedRectangle(cornerRadius: 22).fill(Oz.ink))
    }
}
