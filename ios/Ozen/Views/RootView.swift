import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        GeometryReader { geo in
            let width = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
            ZStack {
                Oz.bg.ignoresSafeArea()

                // Screens slide horizontally in physical coordinates (LTR context);
                // each screen's content is RTL.
                ZStack {
                    screen(.home) { HomeView() }
                    screen(.list) { ListScreen() }
                    screen(.processing) { ProcessingScreen() }
                    screen(.transcript) { TranscriptScreen() }
                }
                .environment(\.layoutDirection, .leftToRight)
                .modifier(ScreenWidth(width: width))

                if let toast = app.toast {
                    VStack {
                        Spacer()
                        ToastView(toast: toast)
                            .id(toast.id)
                            .padding(.bottom, toastBottom)
                            .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .offset(y: 14)).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                    .zIndex(45)
                }

                SheetHost()
                    .zIndex(50)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "he_IL"))
        .font(Oz.rubik(16))
        .foregroundStyle(Oz.ink)
        .tint(Oz.orange)
        .fileImporter(isPresented: $app.showFileImporter, allowedContentTypes: AudioTypes.importable,
                      allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first { app.importFile(at: url) }
        }
    }

    private var toastBottom: CGFloat {
        if app.screen == .transcript { return 112 }
        if app.screen == .list && app.selectMode { return 104 }
        return 28
    }

    @ViewBuilder
    private func screen<Content: View>(_ s: Screen, @ViewBuilder content: () -> Content) -> some View {
        let current = app.screen
        let isCurrent = s == current
        content()
            .environment(\.layoutDirection, .rightToLeft)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if s == .list || s == .transcript { Oz.bg.ignoresSafeArea() }
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .modifier(ScreenPlacement(screen: s, current: current))
            .allowsHitTesting(isCurrent)
            .accessibilityHidden(!isCurrent)
            .zIndex(isCurrent ? 2 : (s.depth > current.depth ? 1 : 0))
    }
}

private struct ScreenWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 390
}

extension EnvironmentValues {
    var screenWidth: CGFloat {
        get { self[ScreenWidthKey.self] }
        set { self[ScreenWidthKey.self] = newValue }
    }
}

private struct ScreenWidth: ViewModifier {
    var width: CGFloat
    func body(content: Content) -> some View { content.environment(\.screenWidth, width) }
}

/// The design's per-screen transform: current at rest; shallower screens drift right 30% and fade;
/// deeper screens wait off-screen to the left; processing scales in/out.
private struct ScreenPlacement: ViewModifier {
    var screen: Screen
    var current: Screen
    @Environment(\.screenWidth) private var width

    func body(content: Content) -> some View {
        let (x, opacity, scale): (CGFloat, Double, CGFloat) = {
            if screen == current { return (0, 1, 1) }
            if screen == .processing { return (0, 0, 0.9) }
            if screen.depth < current.depth || (current == .processing && screen == .home) { return (width * 0.3, 0, 1) }
            return (-width, 1, 1)
        }()
        content
            .scaleEffect(scale)
            .offset(x: x)
            .opacity(opacity)
            .animation(Oz.ease(screen == .processing || current == .processing ? 0.6 : 0.55), value: current)
    }
}
