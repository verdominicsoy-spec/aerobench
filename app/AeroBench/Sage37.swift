import AppKit
import CoreText
import SwiftUI

// sage37, Dominic's design system (tokens v5, October 2026), as the
// sage37-swift skill translates it. The values are the design system's; if
// it changes, regenerate them from it rather than editing here. AeroBench
// ships dark only, so each token is its dark value. The window is a quiet
// line drawing per tool (S37Motifs.swift) bent under clear glass panes, one
// per working region; the dock at the bottom switches tools. Machine output
// sits in glassout consoles (Glassout.swift). It leans a little toward
// glassout to set it apart from Pit Wall: the meta line in mono caps, and
// glassout's dock (inverse-video sage, mono caps labels).

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
        static let motifCrossfade = 0.36  // the web's bloom crossfade
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

/// The current tool's motif (S37Motifs.swift), drawn once per window size
/// and tool.
struct S37Backdrop: View, Equatable {
    let motif: S37Motif
    nonisolated static func == (a: Self, b: Self) -> Bool { a.motif == b.motif }
    var body: some View {
        Canvas(rendersAsynchronously: true) { ctx, size in S37Motifs.draw(&ctx, size, motif) }
            .drawingGroup()
    }
}

// MARK: refraction

struct S37PaneFrame: Equatable { var rect: CGRect; var radius: CGFloat }
struct S37PaneKey: PreferenceKey {
    static let defaultValue: [S37PaneFrame] = []
    static func reduce(value: inout [S37PaneFrame], nextValue: () -> [S37PaneFrame]) { value += nextValue() }
}

/// Root of the window: the tool's curve, bent under every glass pane, content on top
struct S37Root<Content: View>: View {
    var motif: S37Motif = .hilbert
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    ZStack {
                        S37Backdrop(motif: motif).equatable().id(motif).transition(.opacity)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: S37.Motion.motifCrossfade), value: motif)
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
