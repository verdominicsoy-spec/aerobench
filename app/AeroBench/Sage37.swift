import AppKit
import SwiftUI

// sage37, Dominic's design system (tokens v5, October 2026), as the
// sage37-swift skill translates it. The values are the design system's; if
// it changes, regenerate them from it rather than editing here. AeroBench
// takes the light version: dark grounds, sage as the accent, the sidebar as
// a solid surface and sage37's buttons. No refraction or blooms behind the
// tools, which are dense working screens.

extension Color {
    /// 0xRRGGBB with optional opacity, sRGB
    init(hex: UInt32, _ opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: opacity)
    }

    /// rgba(r, g, b, a) exactly as written in CSS
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
        self.init(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }

    /// Dark and light values in one colour, resolved by the current appearance
    static func s37(_ dark: Color, _ light: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

enum S37 {
    enum C {
        static let bg            = Color.s37(Color(hex: 0x100e0b), Color(hex: 0xf3f0e9))
        static let surface       = Color.s37(Color(hex: 0x191714), Color(hex: 0xfaf8f4))
        static let surfaceRaised = Color.s37(Color(hex: 0x23201c), Color(hex: 0xffffff))
        static let separator     = Color.s37(Color(242, 238, 228, 0.08), Color(28, 26, 21, 0.12))
        static let controlBorder = Color.s37(Color(hex: 0x848078), Color(hex: 0x8a857e))
        static let edgeHighlight = Color.s37(Color(255, 255, 255, 0.24), Color(255, 255, 255, 0.90))
        static let edgeShade     = Color.s37(Color(0, 0, 0, 0.55), Color(28, 26, 21, 0.14))
        static let ink           = Color.s37(Color(hex: 0xf2eee4), Color(hex: 0x1c1a15))
        static let inkSecondary  = Color.s37(Color(hex: 0xb5b0a9), Color(hex: 0x57524a))
        static let sage          = Color.s37(Color(hex: 0x96b77f), Color(hex: 0x7a8b6f))
        static let sageInk       = Color.s37(Color(hex: 0xb1cf9d), Color(hex: 0x475d37))
        static let onSage        = Color.s37(Color(hex: 0x11180d), Color(hex: 0x10140e))
    }

    enum Space {
        static let s3: CGFloat = 12, s5: CGFloat = 20, s6: CGFloat = 24
    }

    enum Motion {
        /// buttons: 240ms, slight overshoot
        static let press = Animation.timingCurve(0.3, 1.5, 0.5, 1, duration: 0.24)
    }
}

extension UnitPoint {
    /// Start and end points for a CSS linear-gradient angle (0deg points up, 90deg points right)
    static func css(_ deg: Double) -> (start: UnitPoint, end: UnitPoint) {
        let r = deg * .pi / 180
        let dx = sin(r) / 2, dy = -cos(r) / 2
        return (UnitPoint(x: 0.5 - dx, y: 0.5 - dy), UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}

extension View {
    func s37ShadowControl() -> some View {  // 0 2 8 .40
        shadow(color: .black.opacity(0.40), radius: 4, y: 2)
    }

    func s37ShadowDrop() -> some View {  // 0 1 1 .5, 0 8 20 -10 .7 (spread dropped)
        shadow(color: .black.opacity(0.5), radius: 0.5, y: 1).shadow(color: .black.opacity(0.7), radius: 10, y: 8)
    }
}

/// sage37's capsule button: glass (lit, the default), prominent (sage, one
/// per view) or plain (sage text).
struct S37ButtonStyle: ButtonStyle {
    enum Kind { case glass, prominent, plain }
    var kind: Kind = .glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, kind == .plain ? S37.Space.s3 : S37.Space.s5)
            .frame(minHeight: 28)
            .foregroundStyle(kind == .prominent ? S37.C.onSage : (kind == .plain ? S37.C.sageInk : S37.C.ink))
            .background { background(pressed: pressed) }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : S37.Motion.press, value: pressed)
    }

    @ViewBuilder private func background(pressed: Bool) -> some View {
        switch kind {
        case .glass:
            let rim = UnitPoint.css(160)
            ZStack {
                Capsule().fill(S37.C.surfaceRaised)
                Capsule().fill(LinearGradient(stops: [.init(color: .white.opacity(0.09), location: 0),
                                                      .init(color: .white.opacity(0.02), location: 0.55),
                                                      .init(color: .white.opacity(0.04), location: 1)],
                                              startPoint: .top, endPoint: .bottom))
                Capsule().strokeBorder(LinearGradient(stops: [
                    .init(color: S37.C.edgeHighlight, location: 0), .init(color: .white.opacity(0.06), location: 0.32),
                    .init(color: .white.opacity(0.02), location: 0.62), .init(color: S37.C.edgeHighlight, location: 1)],
                    startPoint: rim.start, endPoint: rim.end), lineWidth: 1)
                if contrast == .increased { Capsule().strokeBorder(S37.C.controlBorder, lineWidth: 1) }
            }
            .s37ShadowDrop()
        case .prominent:
            ZStack {
                Capsule().fill(S37.C.sage)
                Capsule().fill(Color.clear.shadow(.inner(color: S37.C.edgeHighlight, radius: 0, y: 1)))
                Capsule().strokeBorder(contrast == .increased ? S37.C.onSage : S37.C.edgeShade,
                                       lineWidth: contrast == .increased ? 1.5 : 1)
                if pressed { Capsule().fill(Color.clear.shadow(.inner(color: .white.opacity(0.16), radius: 8))) }
            }
            .s37ShadowControl()
        case .plain:
            if contrast == .increased { Capsule().strokeBorder(S37.C.controlBorder, lineWidth: 1) }
        }
    }
}
