import AppKit
import CoreText
import SwiftUI

// sage37, Dominic's design system (tokens v5, October 2026), as the
// sage37-swift skill translates it. The values are the design system's; if
// it changes, regenerate them from it rather than editing here. AeroBench
// ships dark only, so each token is its dark value. The window is the
// airfoil bloom bent under clear glass panes, one per working region; the
// dock at the bottom switches tools. Machine output sits in glassout
// consoles (Glassout.swift). It leans a little toward glassout to set it
// apart from Pit Wall: the phosphor dot grid under the bloom, the meta line
// in mono caps, and glassout's dock (inverse-video sage, mono caps labels).

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
}

enum S37 {
    enum C {
        static let bg = Color(hex: 0x100e0b)
        static let surface = Color(hex: 0x191714)
        static let surfaceRaised = Color(hex: 0x23201c)
        static let inset = Color(242, 238, 228, 0.04)
        static let recess = Color(9, 8, 6, 0.62)
        static let glass = Color(30, 27, 23, 0.62)
        static let glassTinted = Color(19, 17, 14, 0.78)
        static let glassPane = Color(24, 22, 19, 0.34)
        static let glassPaneSolid = Color(25, 23, 20, 0.86)
        static let glassSage = Color(150, 183, 127, 0.26)
        static let edgeHighlight = Color(255, 255, 255, 0.24)
        static let edgeShade = Color(0, 0, 0, 0.55)
        static let separator = Color(242, 238, 228, 0.08)
        static let controlBorder = Color(hex: 0x848078)
        static let ink = Color(hex: 0xf2eee4)
        static let inkSecondary = Color(hex: 0xb5b0a9)
        static let inkTertiary = Color(hex: 0x95928b)
        static let sage = Color(hex: 0x96b77f)
        static let sageInk = Color(hex: 0xb1cf9d)
        static let sageWash = Color(150, 183, 127, 0.18)
        static let ochre = Color(hex: 0xe6b14e)
        static let ochreWash = Color(230, 177, 78, 0.15)
        static let spotlight = Color(hex: 0xebe4d2)
        static let onSpotlight = Color(hex: 0x1c1a15)
        static let onSpotlightSecondary = Color(hex: 0x57524a)
        static let clay = Color(hex: 0xd97757)
        static let clayInk = Color(hex: 0xe8906f)
        static let clayWash = Color(217, 119, 87, 0.14)
        static let onSage = Color(hex: 0x11180d)
        static let critical = Color(hex: 0xff8a7a)
        static let chart1 = Color(hex: 0x96b77f)  // sage
        static let chart2 = Color(hex: 0xe6b14e)  // ochre
        static let chart3 = Color(hex: 0xebe4d2)  // bone
        static let chart4 = Color(hex: 0x7a8b6f)  // sage brand
        static let chart5 = Color(hex: 0xa9705c)  // rust
        static let chart6 = Color(hex: 0x7f8a99)  // slate
    }

    /// Chart series in order, for Swift Charts' foreground style scale
    static let series = [C.chart1, C.chart2, C.chart3, C.chart4, C.chart5, C.chart6]

    enum Space {
        static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
        static let s5: CGFloat = 20, s6: CGFloat = 24, s8: CGFloat = 32, s12: CGFloat = 48
    }

    enum Radius {
        static let sm: CGFloat = 8, md: CGFloat = 12, lgIn: CGFloat = 16, lg: CGFloat = 20, xlContent: CGFloat = 24, xl: CGFloat = 28
    }

    enum Motion {
        /// buttons: 240ms, slight overshoot
        static let press = Animation.timingCurve(0.3, 1.5, 0.5, 1, duration: 0.24)
        static let thumb = Animation.timingCurve(0.3, 1.35, 0.5, 1, duration: 0.42)
        static let lens = Animation.timingCurve(0.3, 1.35, 0.5, 1, duration: 0.38)
        static let colour = Animation.easeInOut(duration: 0.2)
        static let viewRise = 0.34
        static let lensHold = 0.18
        static let lensDrag: CGFloat = 6
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
    func s37ShadowFloat() -> some View {  // 0 16 48 .56, 0 2 8 .36
        shadow(color: .black.opacity(0.56), radius: 24, y: 16).shadow(color: .black.opacity(0.36), radius: 4, y: 2)
    }

    func s37ShadowControl() -> some View {  // 0 2 8 .40
        shadow(color: .black.opacity(0.40), radius: 4, y: 2)
    }

    func s37ShadowDrop() -> some View {  // 0 1 1 .5, 0 8 20 -10 .7 (spread dropped)
        shadow(color: .black.opacity(0.5), radius: 0.5, y: 1).shadow(color: .black.opacity(0.7), radius: 10, y: 8)
    }

    /// The soft dark text shadow that keeps headers readable over the petals
    func s37HeaderShadow() -> some View { shadow(color: Color(16, 14, 11, 0.9), radius: 9, y: 1) }
}

extension InsettableShape {
    /// glass-rim: inset 0 1px 0 edge-highlight, inset 0 0 0 1px edge-shade
    func s37GlassRim() -> some View {
        ZStack {
            self.fill(Color.clear.shadow(.inner(color: S37.C.edgeHighlight, radius: 0, x: 0, y: 1)))
            self.strokeBorder(S37.C.edgeShade, lineWidth: 1)
        }
    }
}

// MARK: type

enum Fonts {
    /// Registers the bundled Fraunces once at launch
    static func register() {
        guard let url = Bundle.main.url(forResource: "Fraunces-Variable", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

extension Font {
    /// Fraunces at 500 with its optical size matched to the font size
    static func fraunces(_ size: CGFloat, weight: CGFloat = 500) -> Font {
        let wght = 0x77676874, opsz = 0x6F70737A
        let base = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: "Fraunces"] as CFDictionary)
        let desc = CTFontDescriptorCreateCopyWithAttributes(base, [kCTFontVariationAttribute: [wght: weight, opsz: size]] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(desc, size, nil))
    }
}

// MARK: backdrop

/// The airfoil bloom: NACA-section petals in sage line art round ochre
/// seeds, drawn once per window size.
struct S37Backdrop: View, Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { true }
    var body: some View {
        Canvas(rendersAsynchronously: true) { ctx, size in S37Bloom.airfoil(&ctx, size) }
            .drawingGroup()
    }
}

enum S37Bloom {
    static let sage = (150.0, 183.0, 127.0), sageInk = (177.0, 207.0, 157.0)
    static let ochre = (230.0, 177.0, 78.0), bone = (183.0, 176.0, 163.0)
    static func c(_ t: (Double, Double, Double), _ a: Double) -> Color { Color(t.0, t.1, t.2, a) }

    static func petal(_ ctx: inout GraphicsContext, _ x: Double, _ y: Double, _ a: Double, _ len: Double,
                      _ t: Double, _ m: Double, _ color: Color, _ lw: Double) {
        let n = 28, ca = cos(a), sa = sin(a)
        var up: [CGPoint] = [], lo: [CGPoint] = []
        for k in 0...n {
            let s = (1 - cos(Double.pi * Double(k) / Double(n))) / 2
            let yt = 5 * t * (0.2969 * s.squareRoot() - 0.126 * s - 0.3516 * s * s + 0.2843 * s * s * s - 0.1036 * s * s * s * s)
            let yc = m * 4 * s * (1 - s)
            up.append(CGPoint(x: s, y: yc + yt)); lo.append(CGPoint(x: s, y: yc - yt))
        }
        func P(_ p: CGPoint) -> CGPoint { CGPoint(x: x + (p.x * ca - p.y * sa) * len, y: y + (p.x * sa + p.y * ca) * len) }
        var path = Path(); path.move(to: P(up[0]))
        for p in up.dropFirst() { path.addLine(to: P(p)) }
        for p in lo.reversed() { path.addLine(to: P(p)) }
        path.closeSubpath()
        ctx.stroke(path, with: .color(color), lineWidth: lw)
    }

    static func camber(_ ctx: inout GraphicsContext, _ x: Double, _ y: Double, _ a: Double, _ len: Double, _ m: Double) {
        let ca = cos(a), sa = sin(a); var path = Path()
        for k in 0...20 {
            let u = Double(k) / 20, v = m * 4 * u * (1 - u)
            let p = CGPoint(x: x + (u * ca - v * sa) * len, y: y + (u * sa + v * ca) * len)
            k == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        ctx.stroke(path, with: .color(c(sage, 0.16)), lineWidth: 0.6)
    }

    static func airfoil(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height, tau = 2 * Double.pi
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x100e0b)))
        // AeroBench leans toward glassout: its phosphor dot grid (16 pitch) under the petals
        var gy: Double = 0
        while gy < h {
            var gx: Double = 0
            while gx < w {
                ctx.fill(Path(ellipseIn: CGRect(x: gx + 0.7, y: gy + 0.7, width: 2.6, height: 2.6)), with: .color(Color(150, 183, 127, 0.14)))
                gx += 16
            }
            gy += 16
        }
        let wide = w > 720
        let cx = wide ? min(w * 0.8, w / 2 + 470) : w * 0.74
        let cy = h * (wide ? 0.3 : 0.2)
        let R = min(max(w, h) * (wide ? 0.34 : 0.4), 540)
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(stops: [.init(color: c(ochre, 0.075), location: 0), .init(color: c(ochre, 0.03), location: 0.45),
                             .init(color: c(ochre, 0), location: 1)]),
            center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: R * 1.35))
        for (i, k) in [0.36, 0.7, 1.02, 1.34].enumerated() {
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - R * k, y: cy - R * k, width: 2 * R * k, height: 2 * R * k)),
                       with: .color(c(bone, 0.05 - Double(i) * 0.008)), lineWidth: 0.75)
        }
        let style: [((Double, Double, Double), Double, Double)] = [(sage, 0.38, 1.15), (sageInk, 0.24, 0.8), (bone, 0.17, 0.6)]
        let thick = [0.2, 0.17, 0.15]
        func level(_ x: Double, _ y: Double, _ r: Double, _ n: Int, _ d: Int, _ rot: Double) {
            for i in 0..<n {
                let a = rot + Double(i) * tau / Double(n)
                let (col, al, lw) = style[d]
                let px = x + cos(a) * r * 0.1, py = y + sin(a) * r * 0.1
                petal(&ctx, px, py, a + 0.16, r * 0.9, thick[d], 0.07, c(col, al), lw)
                if d == 0 { camber(&ctx, px, py, a + 0.16, r * 0.9, 0.07) }
                let tx = x + cos(a + 0.05) * r, ty = y + sin(a + 0.05) * r
                if d < 2 {
                    level(tx, ty, r * (d == 0 ? 0.33 : 0.36), d == 0 ? 7 : 5, d + 1, a + 0.35)
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: tx - 1.1, y: ty - 1.1, width: 2.2, height: 2.2)), with: .color(c(ochre, 0.38)))
                }
            }
        }
        level(cx, cy, R * 0.66, 9, 0, -0.2)
        for k in 1...160 {
            let f = Double(k) / 160, rr = R * 0.12 * f.squareRoot(), th = Double(k) * 2.39996
            let dot = 0.7 + 1.3 * f
            ctx.fill(Path(ellipseIn: CGRect(x: cx + rr * cos(th) - dot, y: cy + rr * sin(th) - dot, width: 2 * dot, height: 2 * dot)),
                     with: .color(c(ochre, 0.22 + 0.3 * (1 - f))))
        }
    }
}

// MARK: refraction

struct S37PaneFrame: Equatable { var rect: CGRect; var radius: CGFloat }
struct S37PaneKey: PreferenceKey {
    static let defaultValue: [S37PaneFrame] = []
    static func reduce(value: inout [S37PaneFrame], nextValue: () -> [S37PaneFrame]) { value += nextValue() }
}

/// Root of the window: the bloom, bent under every glass pane, content on top
struct S37Root<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var panes: [S37PaneFrame] = []

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if contrast == .increased {
                    S37.C.bg
                } else {
                    let screen = CGRect(origin: .zero, size: geo.size)
                    let visible = Array(panes.filter { $0.rect.intersects(screen) && $0.rect.width >= 1 }.prefix(16))
                    S37Backdrop().equatable()
                        .layerEffect(ShaderLibrary.sage37Refract(
                            .float2(geo.size),
                            .floatArray(visible.flatMap { [Float($0.rect.minX), Float($0.rect.minY), Float($0.rect.width), Float($0.rect.height)] }),
                            .floatArray(visible.map { Float(min($0.radius, $0.rect.height / 2, $0.rect.width / 2)) }),
                            .float(Float(visible.count))),
                            maxSampleOffset: CGSize(width: 48, height: 48),
                            isEnabled: !reduceTransparency && !visible.isEmpty)
                }
                content
            }
            .coordinateSpace(name: "s37.root")
            .onPreferenceChange(S37PaneKey.self) { panes = $0 }
        }
        .background(S37.C.bg)
    }
}

/// Registers a glass pane's frame so the backdrop bends under it
struct S37PaneRegistration: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear.preference(key: S37PaneKey.self, value: [S37PaneFrame(rect: g.frame(in: .named("s37.root")), radius: radius)])
        })
    }
}

/// The glass under a pane: its tint and a faint top sheen (the web's .vg-pane)
struct S37PaneFill: View {
    var radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(reduceTransparency ? S37.C.glassPaneSolid : S37.C.glassPane)
            shape.fill(EllipticalGradient(stops: [.init(color: .white.opacity(0.06), location: 0), .init(color: .clear, location: 0.55)],
                                          center: UnitPoint(x: 0.3, y: 0), endRadiusFraction: 1))
        }
    }
}

/// A pane's lit gradient rim
struct S37PaneRim: View {
    var radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let g = UnitPoint.css(135)
        ZStack {
            shape.strokeBorder(LinearGradient(stops: [
                .init(color: .white.opacity(0.34), location: 0), .init(color: .white.opacity(0.05), location: 0.30),
                .init(color: .white.opacity(0), location: 0.50), .init(color: .white.opacity(0.04), location: 0.70),
                .init(color: .white.opacity(0.22), location: 1)], startPoint: g.start, endPoint: g.end), lineWidth: 1)
            if contrast == .increased { shape.strokeBorder(S37.C.controlBorder, lineWidth: 1) }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// A clear glass pane with padding inside, bending the bloom behind it
    func s37Pane(radius: CGFloat = S37.Radius.xlContent, padding: CGFloat = S37.Space.s6) -> some View {
        self.padding(padding)
            .background { ZStack { S37PaneFill(radius: radius); S37PaneRim(radius: radius) } }
            .modifier(S37PaneRegistration(radius: radius))
    }

    /// A working region (a form, a canvas, a 3D view) as a glass pane: drawn
    /// edge to edge and clipped, the rim on top, the form's own ground cleared
    /// so the glass shows.
    func s37Region(radius: CGFloat = S37.Radius.xlContent) -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(S37PaneFill(radius: radius))
            .overlay(S37PaneRim(radius: radius))
            .modifier(S37PaneRegistration(radius: radius))
            .padding(6)
    }
}

// MARK: controls

/// sage37's capsule button: glass (lit, the default), prominent (sage, one
/// per view) or plain (sage text).
struct S37ButtonStyle: ButtonStyle {
    enum Kind { case glass, prominent, plain }
    var kind: Kind = .glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, kind == .plain ? S37.Space.s3 : 16)
            .frame(minHeight: 32)
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
                if !reduceTransparency {
                    Capsule().fill(LinearGradient(stops: [.init(color: .white.opacity(0.09), location: 0),
                                                          .init(color: .white.opacity(0.02), location: 0.55),
                                                          .init(color: .white.opacity(0.04), location: 1)],
                                                  startPoint: .top, endPoint: .bottom))
                    Capsule().fill(Color.clear.shadow(.inner(color: .white.opacity(pressed ? 0.18 : 0.1), radius: 6, y: -8)))
                }
                if pressed { Capsule().fill(Color.clear.shadow(.inner(color: .white.opacity(0.08), radius: 8))) }
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

/// Two to five views of the same thing, the selected one on a raised capsule
struct S37Segmented<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var selection: T
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selection == value ? S37.C.ink : S37.C.inkSecondary)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                        .background {
                            if selection == value {
                                Capsule().fill(S37.C.surfaceRaised)
                                    .overlay(Capsule().strokeBorder(S37.C.edgeShade, lineWidth: 1))
                                    .s37ShadowControl()
                                    .matchedGeometryEffect(id: "sel", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
            ZStack {
                Capsule().fill(S37.C.glass)
                Capsule().s37GlassRim()
                if contrast == .increased { Capsule().strokeBorder(S37.C.controlBorder, lineWidth: 1) }
            }
            .s37ShadowControl()
        }
        .animation(reduceMotion ? nil : S37.Motion.thumb, value: selection)
        .accessibilityRepresentation {
            Picker("Pages", selection: $selection) { ForEach(options, id: \.0) { Text($0.1).tag($0.0) } }
        }
    }
}

/// The page's one loud thing: a bone tile with the hero figure in Fraunces
struct S37Spotlight: View {
    var label: String
    var figure: String
    var unit: String
    var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: S37.Space.s2) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.onSpotlightSecondary)
            HStack(alignment: .firstTextBaseline, spacing: S37.Space.s2) {
                Text(figure).font(.fraunces(64)).tracking(-1.28).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(unit).font(.system(size: 20, weight: .semibold))
            }
            .foregroundStyle(S37.C.onSpotlight)
            Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.onSpotlightSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(S37.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: S37.Radius.xlContent, style: .continuous).fill(S37.C.spotlight))
        .s37ShadowControl()
        .textSelection(.enabled)
    }
}
