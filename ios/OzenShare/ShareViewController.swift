import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Receives one shared audio file (e.g. a WhatsApp voice note), drops it in the App Group inbox
/// for the app to transcribe, and shows a short confirmation in the app's style.
final class ShareViewController: UIViewController {
    private let status = ShareStatus()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: ShareCard(status: status, close: { [weak self] in self?.finish() }))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        receive()
    }

    private func receive() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        let audioTypes = ["public.audio", "org.xiph.opus", "org.xiph.ogg-audio", "public.mpeg-4-audio", "public.mp3"]
        guard let provider = providers.first(where: { p in
            p.registeredTypeIdentifiers.contains { id in
                audioTypes.contains(id) || (UTType(id)?.conforms(to: .audio) ?? false)
            }
        }) ?? providers.first else {
            fail()
            return
        }
        let typeIDs = provider.registeredTypeIdentifiers
        let type = typeIDs.first { id in UTType(id)?.conforms(to: .audio) ?? audioTypes.contains(id) } ?? typeIDs.first ?? UTType.audio.identifier
        let suggested = provider.suggestedName

        provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, _ in
            // The file at `url` is deleted when this handler returns: copy it synchronously.
            var ok = false
            if let url, let inboxURL = OzenAppGroup.inboxURL {
                var name = url.lastPathComponent
                if let suggested, !suggested.isEmpty {
                    let ext = url.pathExtension
                    name = (suggested as NSString).pathExtension.isEmpty && !ext.isEmpty ? "\(suggested).\(ext)" : suggested
                }
                ok = (try? Inbox(directory: inboxURL).deposit(fileAt: url, originalName: name, typeIdentifiers: typeIDs)) != nil
            }
            DispatchQueue.main.async {
                if ok { self?.succeed() } else { self?.fail() }
            }
        }
    }

    private func succeed() {
        withAnimation(Oz.ease(0.4)) { status.state = .added }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.finish() }
    }

    private func fail() {
        withAnimation(Oz.ease(0.4)) { status.state = .failed }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

final class ShareStatus: ObservableObject {
    enum State { case working, added, failed }
    @Published var state: State = .working
}

private struct ShareCard: View {
    @ObservedObject var status: ShareStatus
    var close: () -> Void
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(shown ? 0.4 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            if shown {
                VStack(alignment: .leading, spacing: 14) {
                    Capsule().fill(Oz.line).frame(width: 40, height: 5)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 4)
                    HStack(spacing: 12) {
                        EarLogo(width: 30, height: 42, strokeUnits: 9)
                        Text(title)
                            .font(Oz.karantina(40))
                            .foregroundStyle(Oz.ink)
                    }
                    Text(subtitle)
                        .font(Oz.rubik(15))
                        .foregroundStyle(Oz.sub)
                    Button(action: close) {
                        Text("סגירה")
                            .font(Oz.rubik(17, .semibold))
                            .foregroundStyle(Oz.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Capsule().fill(Oz.card))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(.top, 10)
                .padding(.horizontal, 22)
                .padding(.bottom, 26)
                .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(Oz.bg))
                .padding(8)
                .transition(.move(edge: .bottom))
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear { withAnimation(Oz.ease(0.42)) { shown = true } }
    }

    private var title: String {
        switch status.state {
        case .working: return "מוסיף לאוזן…"
        case .added: return "נוסף לאוזן"
        case .failed: return "לא הצלחנו להוסיף"
        }
    }

    private var subtitle: String {
        switch status.state {
        case .working: return "רגע אחד"
        case .added: return "פתחו את אוזן כדי לתמלל"
        case .failed: return "אפשר לנסות שוב, או לייבא את הקובץ מתוך אוזן"
        }
    }
}
