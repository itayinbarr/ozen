import SwiftUI

/// The home orb: ring + disc + the ear strokes, drawn in, breathing when idle, red and
/// mic-reactive while recording, with a light "spark" running along the outer ear.
struct OrbView: View {
    var recorder: Recorder
    var drawToken: Int

    @State private var anim = OrbAnimator()
    @Environment(\.colorScheme) private var scheme

    private let size: CGFloat = 280
    private let pad: CGFloat = 40

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, _ in
                anim.draw(in: &ctx, now: timeline.date, recorder: recorder, card: cardColor, pad: pad)
            }
        }
        .frame(width: size + pad * 2, height: size + pad * 2)
        .padding(-pad)
        .frame(width: size, height: size)
        .environment(\.layoutDirection, .leftToRight)
        .onAppear { anim.restartDraw() }
        .onChange(of: drawToken) { anim.restartDraw() }
    }

    private var cardColor: Color {
        scheme == .dark ? Color(hex: 0x343532) : Color(hex: 0xeef2e0)
    }
}

/// Per-frame state, mirroring the design's requestAnimationFrame loop.
@MainActor
final class OrbAnimator {
    private var lvl = 0.0
    private var hot = 0.0          // 0 = orange, 1 = red (stroke transition .6s)
    private var sparkOpacity = 0.0 // opacity transition .5s
    private var spPos = 0.0
    private var lastT: Double?
    private var drawT0 = Date()

    nonisolated(unsafe) private static let outerLength = pathLength(EarPaths.outer)

    func restartDraw() {
        drawT0 = Date()
        spPos = 0
    }

    func draw(in ctx: inout GraphicsContext, now: Date, recorder: Recorder, card: Color, pad: CGFloat) {
        let t = now.timeIntervalSinceReferenceDate
        let dt = min(0.05, t - (lastT ?? t))
        lastT = t
        let isRec = recorder.state == .recording

        let target = isRec ? recorder.level(at: t) : 0
        lvl += (target - lvl) * min(1, 0.15 * dt * 60)
        let breath = (sin(t * 1.4) + 1) / 2
        hot += ((isRec ? 1 : 0) - hot) * min(1, dt / 0.15)

        let orange = (r: 1.0, g: 127.0 / 255, b: 17.0 / 255)
        let red = (r: 1.0, g: 27.0 / 255, b: 28.0 / 255)
        let col = Color(.sRGB, red: orange.r + (red.r - orange.r) * hot,
                        green: orange.g + (red.g - orange.g) * hot,
                        blue: orange.b + (red.b - orange.b) * hot)

        let c = CGPoint(x: 140 + pad, y: 140 + pad)

        // Ring
        let ringScale = isRec ? 1 + lvl * 0.1 : 1 + breath * 0.035
        let ringOpacity = isRec ? 0.25 + lvl * 0.4 : 0.28
        let rr = 134 * ringScale
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                   with: .color(col.opacity(ringOpacity)), lineWidth: 1.5)

        // Disc
        let discScale = isRec ? 1 + lvl * 0.045 : 1 + breath * 0.02
        let dr = 124 * discScale
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - dr, y: c.y - dr, width: dr * 2, height: dr * 2)), with: .color(card))

        // Ear group transform: translate(140 140+dy) rotate(rot) scale(sc) translate(-56 -50)
        let rot = isRec ? sin(t * 2.3) * 4 + lvl * 5 * sin(t * 9) : sin(t * 0.9) * 3
        let sc = 1.6 * (isRec ? 1 + lvl * 0.09 : 1 + breath * 0.035)
        let dy = isRec ? -lvl * 4 : sin(t * 1.1) * 2.5
        let transform = CGAffineTransform(translationX: c.x, y: c.y + dy)
            .rotated(by: rot * .pi / 180)
            .scaledBy(x: sc, y: sc)
            .translatedBy(x: -56, y: -50)

        var ear = ctx
        ear.concatenate(transform)
        let style = StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round)

        // Draw-in: outer over 1.1 s, inner starting at .45 s over .9 s, ease-out cubic.
        let since = now.timeIntervalSince(drawT0)
        let k = min(1, max(0, since / 1.1))
        let e = 1 - pow(1 - k, 3)
        let k2 = min(1, max(0, (since - 0.45) / 0.9))
        let e2 = 1 - pow(1 - k2, 3)
        if e > 0 { ear.stroke(EarPaths.outer.trimmedPath(from: 0, to: e), with: .color(col), style: style) }
        if e2 > 0 { ear.stroke(EarPaths.inner.trimmedPath(from: 0, to: e2), with: .color(col), style: style) }

        // Spark: a 12-unit dash running along the outer ear with a gap of L+30.
        let sparkTarget = (isRec && k >= 1) ? 0.95 : 0
        sparkOpacity += (sparkTarget - sparkOpacity) * min(1, dt / 0.12)
        spPos += dt * (isRec ? 70 + lvl * 90 : 0)
        let L = Self.outerLength
        let s0 = spPos.truncatingRemainder(dividingBy: L + 30)
        if sparkOpacity > 0.01, s0 < L {
            let from = s0 / L, to = min(1, (s0 + 12) / L)
            ear.stroke(EarPaths.outer.trimmedPath(from: from, to: to),
                       with: .color(Color(hex: 0xe2e8ce).opacity(sparkOpacity)),
                       style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        }
    }

    /// Arc length of a path, by flattening.
    nonisolated static func pathLength(_ path: Path) -> Double {
        var length = 0.0
        var last = CGPoint.zero
        var start = CGPoint.zero
        func seg(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(b.x - a.x, b.y - a.y)) }
        path.forEach { el in
            switch el {
            case let .move(to: p):
                last = p; start = p
            case let .line(to: p):
                length += seg(last, p); last = p
            case let .quadCurve(to: p, control: c):
                var prev = last
                for i in 1...24 {
                    let t = CGFloat(i) / 24, u = 1 - t
                    let a: CGFloat = u * u, b: CGFloat = 2 * u * t, d: CGFloat = t * t
                    let q = CGPoint(x: a * last.x + b * c.x + d * p.x, y: a * last.y + b * c.y + d * p.y)
                    length += seg(prev, q); prev = q
                }
                last = p
            case let .curve(to: p, control1: c1, control2: c2):
                var prev = last
                for i in 1...48 {
                    let t = CGFloat(i) / 48, u = 1 - t
                    let a: CGFloat = u * u * u, b: CGFloat = 3 * u * u * t
                    let cc: CGFloat = 3 * u * t * t, d: CGFloat = t * t * t
                    let qx: CGFloat = a * last.x + b * c1.x + cc * c2.x + d * p.x
                    let qy: CGFloat = a * last.y + b * c1.y + cc * c2.y + d * p.y
                    let q = CGPoint(x: qx, y: qy)
                    length += seg(prev, q); prev = q
                }
                last = p
            case .closeSubpath:
                length += seg(last, start); last = start
            }
        }
        return length
    }
}
