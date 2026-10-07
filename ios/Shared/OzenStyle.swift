import SwiftUI
import UIKit

// Design tokens shared by the app, the Live Activity and the share extension.
// Values are the design's THEMES table; light/dark follow the system.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }

    /// A color that resolves per trait collection (light / dark).
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: alpha)
    }
}

enum Oz {
    // Theme tokens
    static let bg = Color(light: UIColor(hex: 0xe2e8ce), dark: UIColor(hex: 0x262626))
    static let ink = Color(light: UIColor(hex: 0x262626), dark: UIColor(hex: 0xe2e8ce))
    static let sub = Color(light: UIColor(hex: 0x262626, alpha: 0.62), dark: UIColor(hex: 0xe2e8ce, alpha: 0.6))
    static let card = Color(light: UIColor(hex: 0xeef2e0), dark: UIColor(hex: 0x343532))
    static let line = Color(light: UIColor(hex: 0x262626, alpha: 0.1), dark: UIColor(hex: 0xe2e8ce, alpha: 0.12))

    // Accents (same in both themes)
    static let orange = Color(hex: 0xff7f11)
    static let red = Color(hex: 0xff1b1c)
    static let sage = Color(hex: 0xacbfa4)
    static let cream = Color(hex: 0xe2e8ce)
    static let charcoal = Color(hex: 0x262626)

    // Typography
    static func karantina(_ size: CGFloat, bold: Bool = true) -> Font {
        .custom(bold ? "Karantina-Bold" : "Karantina-Regular", fixedSize: size)
    }

    enum Weight { case light, regular, medium, semibold, bold }

    static func rubik(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .custom(rubikName(weight), fixedSize: size)
    }

    /// Rubik that follows Dynamic Type (used for the transcript body).
    static func rubik(_ size: CGFloat, _ weight: Weight = .regular, relativeTo style: Font.TextStyle) -> Font {
        .custom(rubikName(weight), size: size, relativeTo: style)
    }

    static func rubikName(_ weight: Weight) -> String {
        switch weight {
        case .light: return "Rubik-Light"
        case .regular: return "Rubik-Regular"
        case .medium: return "Rubik-Medium"
        case .semibold: return "Rubik-SemiBold"
        case .bold: return "Rubik-Bold"
        }
    }

    /// cubic-bezier(.2,.8,.2,1)
    static func ease(_ duration: Double = 0.55) -> Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    }
}

/// "m:ss" / "h:mm:ss", as the design's fmt().
func formatClock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
    let h = s / 3600, m = (s % 3600) / 60, x = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, x) : String(format: "%d:%02d", m, x)
}

// MARK: - The ear mark

/// The ear strokes from the design (EAR_O / EAR_I), in the design's 112×100 ear space.
enum EarPaths {
    /// M30 40C30 22 44 12 56 12C72 12 82 26 82 40C82 54 72 60 66 68C60 76 60 88 50 88C44 88 40 84 40 80
    static let outer: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 30, y: 40))
        p.addCurve(to: CGPoint(x: 56, y: 12), control1: CGPoint(x: 30, y: 22), control2: CGPoint(x: 44, y: 12))
        p.addCurve(to: CGPoint(x: 82, y: 40), control1: CGPoint(x: 72, y: 12), control2: CGPoint(x: 82, y: 26))
        p.addCurve(to: CGPoint(x: 66, y: 68), control1: CGPoint(x: 82, y: 54), control2: CGPoint(x: 72, y: 60))
        p.addCurve(to: CGPoint(x: 50, y: 88), control1: CGPoint(x: 60, y: 76), control2: CGPoint(x: 60, y: 88))
        p.addCurve(to: CGPoint(x: 40, y: 80), control1: CGPoint(x: 44, y: 88), control2: CGPoint(x: 40, y: 84))
        return p
    }()

    /// M44 42C44 32 50 28 57 28C64 28 68 34 68 40C68 48 60 50 58 56
    static let inner: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 44, y: 42))
        p.addCurve(to: CGPoint(x: 57, y: 28), control1: CGPoint(x: 44, y: 32), control2: CGPoint(x: 50, y: 28))
        p.addCurve(to: CGPoint(x: 68, y: 40), control1: CGPoint(x: 64, y: 28), control2: CGPoint(x: 68, y: 34))
        p.addCurve(to: CGPoint(x: 58, y: 56), control1: CGPoint(x: 68, y: 48), control2: CGPoint(x: 60, y: 50))
        return p
    }()
}

/// The ear logo as drawn in the header: viewBox "24 6 64 88", aspect-fit.
struct EarLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let vb = CGRect(x: 24, y: 6, width: 64, height: 88)
        let s = min(rect.width / vb.width, rect.height / vb.height)
        let dx = rect.minX + (rect.width - vb.width * s) / 2 - vb.minX * s
        let dy = rect.minY + (rect.height - vb.height * s) / 2 - vb.minY * s
        let t = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s)
        var p = Path()
        p.addPath(EarPaths.outer, transform: t)
        p.addPath(EarPaths.inner, transform: t)
        return p
    }
}

/// Ear logo at a fixed size; `strokeUnits` is the stroke width in viewBox units (design: 9 in the header, 10 on the lock screen).
struct EarLogo: View {
    var width: CGFloat
    var height: CGFloat
    var strokeUnits: CGFloat = 9
    var color: Color = Oz.orange

    var body: some View {
        let s = min(width / 64, height / 88)
        EarLogoShape()
            .stroke(color, style: StrokeStyle(lineWidth: strokeUnits * s, lineCap: .round, lineJoin: .round))
            .frame(width: width, height: height)
            .environment(\.layoutDirection, .leftToRight)
    }
}
