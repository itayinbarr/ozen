import SwiftUI

struct ProcessingScreen: View {
    @Environment(AppModel.self) private var app
    @State private var breathe = false

    var body: some View {
        let live = app.jobs.live
        let progress = live?.progress ?? 0
        ZStack(alignment: .bottom) {
            VStack(spacing: 30) {
                ZStack {
                    Circle()
                        .fill(Oz.sage)
                        .opacity(0.38)
                        .padding(30)
                        .scaleEffect(breathe ? 1.045 : 1)
                    Circle()
                        .stroke(Oz.line, lineWidth: 5)
                        .padding(11)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Oz.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(11)
                        .animation(.linear(duration: 0.25), value: progress)
                    Text("\(Int((progress * 100).rounded(.down)))%")
                        .font(Oz.karantina(80, bold: false))
                        .monospacedDigit()
                }
                .frame(width: 230, height: 230)
                .environment(\.layoutDirection, .leftToRight)

                VStack(spacing: 6) {
                    Text("מתמלל")
                        .font(Oz.rubik(21, .medium))
                    Text(ProcessingText.remaining(progress: progress, eta: live?.eta))
                        .font(Oz.rubik(15))
                        .foregroundStyle(Oz.sub)
                        .contentTransition(.opacity)
                }

                ZStack {
                    if let text = live?.latestText, !text.isEmpty {
                        Text(text)
                            .id(text)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .opacity))
                    }
                }
                .font(Oz.rubik(15))
                .lineSpacing(15 * 0.5)
                .foregroundStyle(Oz.sub)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(width: 300, height: 68, alignment: .top)
                .animation(.easeOut(duration: 0.7), value: live?.latestText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let label = live?.sourceLabel, live?.source != .record {
                HStack(spacing: 8) {
                    Circle().fill(Oz.sage).frame(width: 8, height: 8)
                    Text(label)
                        .font(Oz.rubik(13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14).fill(Oz.card))
                .environment(\.layoutDirection, .leftToRight)
                .padding(.bottom, 40)
                .padding(.horizontal, 24)
                .transition(.opacity)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}
