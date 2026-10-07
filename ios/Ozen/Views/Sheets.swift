import SwiftData
import SwiftUI
import UIKit

/// The design's bottom sheets: 44pt radius card inset 8pt, grabber, dimmed backdrop.
struct SheetHost: View {
    @Environment(AppModel.self) private var app
    @State private var drag: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            if app.sheet != nil {
                Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255).opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { app.closeSheet() }
                    .transition(.opacity)
                    .accessibilityLabel("סגירה")
                    .accessibilityAddTraits(.isButton)
            }
            if let sheet = app.sheet {
                VStack(alignment: .leading, spacing: 14) {
                    Capsule()
                        .fill(Oz.line)
                        .frame(width: 40, height: 5)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 4)
                    content(sheet)
                }
                .padding(.top, 10)
                .padding(.horizontal, 22)
                .padding(.bottom, 26)
                .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(Oz.bg))
                .shadow(color: .black.opacity(0.3), radius: 20, y: -10)
                .padding(8)
                .offset(y: max(0, drag))
                .gesture(DragGesture()
                    .onChanged { drag = $0.translation.height }
                    .onEnded { v in
                        if v.translation.height > 90 || v.predictedEndTranslation.height > 220 { app.closeSheet() }
                        withAnimation(Oz.ease(0.35)) { drag = 0 }
                    })
                .transition(.move(edge: .bottom))
                .zIndex(1)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    @ViewBuilder
    private func content(_ sheet: SheetKind) -> some View {
        switch sheet {
        case .keep: KeepSheet()
        case .export: ExportSheet()
        case .importAudio: ImportSheet()
        case .deleteAll: DeleteAllSheet()
        }
    }
}

private struct SheetTitle: View {
    var text: String
    var body: some View {
        Text(text)
            .font(Oz.karantina(40))
            .foregroundStyle(Oz.ink)
            .frame(height: 40, alignment: .center)
    }
}

private struct SheetSubtitle: View {
    var text: String
    var body: some View {
        Text(text)
            .font(Oz.rubik(15))
            .foregroundStyle(Oz.sub)
            .padding(.top, -6)
    }
}

private struct PillButton: View {
    var title: String
    var fill: Color
    var foreground: Color
    var border: Color? = nil
    var height: CGFloat = 56
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Oz.rubik(17, .semibold))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(Capsule().fill(fill))
        }
        .buttonStyle(PressStyle())
    }
}

private struct KeepSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        SheetTitle(text: "לשמור את ההקלטה?")
        SheetSubtitle(text: "התמלול נשמר בכל מקרה")
        HStack(spacing: 10) {
            PillButton(title: "שמירה", fill: Oz.card, foreground: Oz.ink) { app.keepDecision(keep: true) }
            PillButton(title: "מחיקה", fill: Oz.ink, foreground: Oz.bg) { app.keepDecision(keep: false) }
        }
        .padding(.top, 4)
        Button {
            withAnimation(.easeOut(duration: 0.2)) { app.rememberKeepChoice.toggle() }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(app.rememberKeepChoice ? Oz.orange : .clear)
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Oz.ink, lineWidth: 2)
                    if app.rememberKeepChoice {
                        Icon(glyph: .check, size: 13, lineWidth: 3.4).foregroundStyle(Oz.charcoal)
                    }
                }
                .frame(width: 22, height: 22)
                Text("לזכור את הבחירה")
                    .font(Oz.rubik(15))
                    .foregroundStyle(Oz.ink)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(app.rememberKeepChoice ? .isSelected : [])
    }
}

private struct ExportSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SheetTitle(text: "ייצוא")
        row(title: "טקסט", trailing: AnyView(ext(".txt"))) { export(markdown: false) }
        row(title: "Markdown", trailing: AnyView(ext(".md"))) { export(markdown: true) }
        row(title: "שיתוף…", trailing: AnyView(Icon(glyph: .share, size: 20, lineWidth: 1.9).opacity(0.6))) { shareText() }
    }

    private func ext(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 14, design: .monospaced))
            .foregroundStyle(Oz.sub)
    }

    private func row(title: String, trailing: AnyView, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(Oz.rubik(17, .medium))
                Spacer()
                trailing
            }
            .foregroundStyle(Oz.ink)
            .padding(.horizontal, 20)
            .frame(height: 60)
            .background(RoundedRectangle(cornerRadius: 20).fill(Oz.card))
        }
        .buttonStyle(PressStyle())
    }

    private var current: Recording? { app.recording(app.currentID) }

    private func export(markdown: Bool) {
        guard let rec = current else { return }
        let date = HebrewDate.relative(rec.createdAt)
        let text = markdown
            ? TranscriptText.markdown(title: rec.title, date: date, duration: rec.duration, segments: rec.segments)
            : TranscriptText.plain(title: rec.title, date: date, duration: rec.duration, segments: rec.segments)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(TranscriptText.fileName(title: rec.title, ext: markdown ? "md" : "txt"))
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            app.showToast("הייצוא נכשל")
            return
        }
        app.closeSheet()
        ShareSheet.present(items: [url]) { done in
            if done { app.showToast("נשמר \(url.lastPathComponent)") }
        }
    }

    private func shareText() {
        guard let rec = current else { return }
        let text = TranscriptText.plain(title: rec.title, date: HebrewDate.relative(rec.createdAt),
                                        duration: rec.duration, segments: rec.segments)
        app.closeSheet()
        ShareSheet.present(items: [text]) { _ in }
    }
}

private struct ImportSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SheetTitle(text: "ייבוא שמע")
        PillButton(title: "בחירת קובץ", fill: Oz.orange, foreground: Oz.charcoal, height: 60) { app.pickFile() }
        Text("אפשר גם לשתף הקלטה מוואטסאפ ישירות לאוזן")
            .font(Oz.rubik(14))
            .foregroundStyle(Oz.sub)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

private struct DeleteAllSheet: View {
    @Environment(AppModel.self) private var app
    @Query private var all: [Recording]

    var body: some View {
        let n = all.filter { !app.hiddenIDs.contains($0.id) }.count
        SheetTitle(text: "למחוק הכל?")
        SheetSubtitle(text: "\(n) תמלולים יימחקו מהמכשיר")
        HStack(spacing: 10) {
            PillButton(title: "מחיקה", fill: Oz.red, foreground: .white) { app.deleteAllVisible() }
            PillButton(title: "ביטול", fill: Oz.card, foreground: Oz.ink) { app.closeSheet() }
        }
        .padding(.top, 4)
    }
}

/// Presents UIActivityViewController from the top view controller (after any sheet animation).
enum ShareSheet {
    @MainActor
    static func present(items: [Any], completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard let root = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
            var top = root
            while let p = top.presentedViewController { top = p }
            let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
            vc.completionWithItemsHandler = { _, done, _, _ in completion(done) }
            top.present(vc, animated: true)
        }
    }
}

/// The design's bottom pill toast, with optional "ביטול".
struct ToastView: View {
    @Environment(AppModel.self) private var app
    var toast: Toast

    var body: some View {
        HStack(spacing: 14) {
            Text(toast.text)
            if toast.undo {
                Button("ביטול") { app.undoDelete() }
                    .font(Oz.rubik(15, .semibold))
                    .foregroundStyle(Oz.orange)
            }
        }
        .font(Oz.rubik(15))
        .foregroundStyle(Oz.bg)
        .lineLimit(1)
        .padding(.horizontal, 20)
        .frame(height: 46)
        .background(Capsule().fill(Oz.ink))
        .shadow(color: .black.opacity(0.4), radius: 15, y: 12)
    }
}
