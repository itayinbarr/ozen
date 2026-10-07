import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let recorder = app.recorder
        let active = recorder.isActive
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                TimerText(recorder: recorder)
                    .opacity(active ? 1 : 0)
                    .animation(.easeInOut(duration: 0.5), value: active)
                Button { app.toggleRecord() } label: {
                    OrbView(recorder: recorder, drawToken: app.orbDrawToken)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 36)
                .accessibilityLabel(active ? "סיום הקלטה" : "התחלת הקלטה")
                Text(hint)
                    .font(Oz.rubik(16, .medium))
                    .foregroundStyle(Oz.sub)
                    .frame(height: 22)
                    .padding(.top, 14)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: recorder.state)
            }
            Spacer(minLength: 0)
            ZStack(alignment: .top) {
                if active {
                    Button { recorder.togglePause() } label: {
                        Icon(glyph: recorder.state == .paused ? .play : .pause, size: 18)
                            .foregroundStyle(Oz.ink)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Oz.card))
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel(recorder.state == .paused ? "המשך הקלטה" : "השהיית הקלטה")
                    .transition(.opacity)
                }
            }
            .frame(height: 132, alignment: .top)
            .padding(.top, 4)
            .animation(.easeInOut(duration: 0.4), value: active)
        }
    }

    private var hint: String {
        switch app.recorder.state {
        case .idle: return "לחצו להתחלת הקלטה"
        case .paused: return "מושהה · לחצו לסיום"
        case .recording: return "לחצו לסיום"
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                CircleIconButton(glyph: .menu, label: "תמלולים") { app.goList() }
                    .offset(y: 4)
                HStack(spacing: 9) {
                    EarLogo(width: 24, height: 34)
                        .padding(.top, 9)
                    Text("אוזן")
                        .font(Oz.karantina(46))
                        .frame(height: 34)
                        .padding(.top, 4)
                }
            }
            Spacer()
            CircleIconButton(glyph: .upload, label: "ייבוא שמע") { app.present(.importAudio) }
                .offset(y: 4)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 62)
    }
}

/// "m:ss" in Karantina 84, ticking from the recorder's clock; blinks while paused.
struct TimerText: View {
    var recorder: Recorder

    var body: some View {
        let paused = recorder.state == .paused
        TimelineView(.animation(minimumInterval: paused ? nil : 0.25)) { tl in
            let blink = paused ? 0.25 + 0.75 * (cos(tl.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2) + 1) / 2 : 1
            Text(formatClock(recorder.elapsed(at: tl.date)))
                .font(Oz.karantina(84, bold: false))
                .monospacedDigit()
                .frame(height: 80)
                .opacity(blink)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}

/// 46pt round icon button (header buttons).
struct CircleIconButton: View {
    var glyph: Glyph
    var size: CGFloat = 24
    var lineWidth: CGFloat = 1.8
    var label: String
    var background: Color = .clear
    var foreground: Color = Oz.ink
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(glyph: glyph, size: size, lineWidth: lineWidth)
                .foregroundStyle(foreground)
                .frame(width: 46, height: 46)
                .background(Circle().fill(background))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .accessibilityLabel(label)
    }
}

struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
