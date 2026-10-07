import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct OzenLiveBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

/// Lock screen card and Dynamic Island for an ongoing recording (the design's lock-screen card).
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OzenRecordingAttributes.self) { context in
            LockScreenCard(state: context.state)
                .activityBackgroundTint(Color(hex: 0x262626))
                .activitySystemActionForegroundColor(Oz.cream)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Brand()
                        .padding(.leading, 6)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Controls(isPaused: state.isPaused, size: 44)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 14) {
                        Clock(state: state, size: 44)
                        Bars(isPaused: state.isPaused)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .environment(\.layoutDirection, .rightToLeft)
                }
            } compactLeading: {
                RecDot(size: 10, isPaused: state.isPaused)
                    .padding(.horizontal, 6)
            } compactTrailing: {
                Clock(state: state, size: 14, karantina: false)
                    .frame(maxWidth: 52)
            } minimal: {
                RecDot(size: 10, isPaused: state.isPaused)
            }
            .keylineTint(Oz.red)
        }
    }
}

private struct LockScreenCard: View {
    var state: OzenRecordingAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Brand()
                HStack(spacing: 14) {
                    Clock(state: state, size: 48)
                    Bars(isPaused: state.isPaused)
                }
            }
            Spacer(minLength: 0)
            Controls(isPaused: state.isPaused, size: 50)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .foregroundStyle(Oz.cream)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

private struct Brand: View {
    var body: some View {
        HStack(spacing: 8) {
            EarLogo(width: 14, height: 20, strokeUnits: 10)
            Text("אוזן")
                .font(Oz.karantina(26))
                .foregroundStyle(Oz.cream)
            RecDot(size: 8, isPaused: false)
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

private struct RecDot: View {
    var size: CGFloat
    var isPaused: Bool
    var body: some View {
        Circle()
            .fill(Oz.red)
            .frame(width: size, height: size)
            .opacity(isPaused ? 0.35 : 1)
    }
}

/// Elapsed time that ticks by itself while running (Text(timerInterval:)), fixed while paused.
private struct Clock: View {
    var state: OzenRecordingAttributes.ContentState
    var size: CGFloat
    var karantina = true

    var body: some View {
        Group {
            if state.isPaused {
                Text(formatClock(state.elapsed))
                    .opacity(0.5)
            } else {
                Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false)
            }
        }
        .font(karantina ? Oz.karantina(size, bold: false) : .system(size: size, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(Oz.cream)
        .multilineTextAlignment(.leading)
        .lineLimit(1)
        .frame(width: karantina ? size * 1.45 : nil, alignment: .leading)
    }
}

/// The design's orange level bars (static: Live Activities cannot run repeating animations).
private struct Bars: View {
    var isPaused: Bool
    private let heights: [CGFloat] = [0.55, 0.85, 0.45, 1.0, 0.65, 0.9, 0.5]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule()
                    .fill(Oz.orange)
                    .frame(width: 4, height: 30 * (isPaused ? 0.25 : heights[i]))
            }
        }
        .frame(height: 30)
    }
}

private struct Controls: View {
    var isPaused: Bool
    var size: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: ToggleRecordingPauseIntent()) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Oz.cream)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Oz.cream.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPaused ? "המשך הקלטה" : "השהיית הקלטה")
            Button(intent: StopRecordingIntent()) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Oz.cream)
                    .frame(width: 16, height: 16)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Oz.red))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("סיום הקלטה ותמלול")
        }
    }
}
