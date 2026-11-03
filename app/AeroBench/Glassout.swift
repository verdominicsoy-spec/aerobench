import SwiftUI

// glassout, Dominic's green-phosphor terminal behind Liquid Glass (tokens v1,
// October 2026), as the glassout-swift skill translates it. In AeroBench it
// is only ever a console: one per screen, for machine output (a job's log,
// values to paste into STAR). It stays out of sage37's refraction and sets
// its own font and colours so nothing sage37 leaks in.

enum GO {
    enum C {
        static let tube = Color(hex: 0x0a0a08)
        static let surfaceRaised = Color(hex: 0x201e19)
        static let glass = Color(30, 27, 23, 0.62)
        static let edgeHighlight = Color(255, 255, 255, 0.22)
        static let edgeShade = Color(0, 0, 0, 0.55)
        static let sheen = Color(255, 255, 255, 0.05)
        static let scanline = Color(0, 0, 0, 0.32)
        static let bloom = Color(150, 183, 127, 0.11)
        static let phosphorBright = Color(hex: 0xd6ebc4)
        static let phosphor = Color(hex: 0xb1cf9d)  // = sage37 sageInk
        static let phosphorDim = Color(hex: 0x8ea37f)
        static let phosphorFaint = Color(hex: 0x7f8f72)
        static let separator = Color(177, 207, 157, 0.12)
        static let sage = Color(hex: 0x96b77f)
        static let onSage = Color(hex: 0x11180d)
        static let clayInk = Color(hex: 0xe8906f)
        static let critical = Color(hex: 0xff8a7a)
        static let controlBorder = Color(hex: 0x6f7d63)
    }

    enum CRT {
        static let scanlinePitch: CGFloat = 4
        static let typeStep: Double = 0.024  // per character
        static let typeCap: Double = 0.6  // longest a type-on may take
        static let typeMaxChars = 48  // longer lines appear instead
    }
}

extension View {
    /// glow-bright: titles, heads, key figures, the selected value
    func goGlowBright() -> some View {
        shadow(color: Color(214, 235, 196, 0.5), radius: 0.5).shadow(color: Color(150, 183, 127, 0.45), radius: 4)
    }
    /// glow: body text inside a tube
    func goGlow() -> some View { shadow(color: Color(150, 183, 127, 0.28), radius: 3) }
    /// glow-clay: clay-ink inside a tube
    func goGlowClay() -> some View { shadow(color: Color(217, 119, 87, 0.4), radius: 3) }
    func goShadowGlass() -> some View {
        shadow(color: .black.opacity(0.48), radius: 16, y: 8).shadow(color: .black.opacity(0.32), radius: 2, y: 1)
    }
}

extension InsettableShape {
    func goGlassRim() -> some View {
        ZStack {
            fill(Color.clear.shadow(.inner(color: GO.C.edgeHighlight, radius: 0, y: 1)))
            strokeBorder(GO.C.edgeShade, lineWidth: 1)
        }
    }

    /// The vignette
    func goTubeInset() -> some View {
        ZStack {
            fill(Color.clear.shadow(.inner(color: .black.opacity(0.7), radius: 24)))
            strokeBorder(Color.black.opacity(0.6), lineWidth: 1)
        }
    }
}

/// Glow that steps aside under Increase Contrast
struct GOGlow: ViewModifier {
    enum Kind { case body, bright, clay }
    var kind: Kind = .body
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if contrast == .increased {
            content
        } else {
            switch kind {
            case .body: content.goGlow()
            case .bright: content.goGlowBright()
            case .clay: content.goGlowClay()
            }
        }
    }
}

/// A glassout screen: lit glass bezel, opaque phosphor tube inside. As a
/// console in sage37 the bezel takes the section radius, 24.
struct GOScreen<Content: View>: View {
    var bezelRadius: CGFloat = 24
    var tubePadding = EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var content: Content

    var body: some View {
        let bezel = RoundedRectangle(cornerRadius: bezelRadius, style: .continuous)
        let tubeShape = RoundedRectangle(cornerRadius: bezelRadius - 8, style: .continuous)  // concentric
        let increased = contrast == .increased
        content
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(GO.C.phosphor)
            .buttonStyle(.plain)
            .padding(tubePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    tubeShape.fill(GO.C.tube)
                    if !increased { GOTubeCRT().equatable().clipShape(tubeShape) }  // scanlines and bloom, under the text
                    tubeShape.goTubeInset()
                }
            }
            .overlay {
                if !increased {  // faceplate sheen
                    let g = UnitPoint.css(158)
                    tubeShape.fill(LinearGradient(stops: [.init(color: GO.C.sheen, location: 0), .init(color: .clear, location: 0.34)],
                                                  startPoint: g.start, endPoint: g.end))
                        .allowsHitTesting(false)
                }
            }
            .clipShape(tubeShape)
            .padding(8)  // the bezel
            .background {
                ZStack {
                    bezel.fill(reduceTransparency ? GO.C.surfaceRaised : GO.C.glass)
                    bezel.goGlassRim()
                    let g = UnitPoint.css(135)
                    bezel.strokeBorder(LinearGradient(stops: [
                        .init(color: GO.C.edgeHighlight, location: 0), .init(color: .white.opacity(0.02), location: 0.38),
                        .init(color: .white.opacity(0.02), location: 0.62), .init(color: GO.C.edgeHighlight, location: 1)],
                        startPoint: g.start, endPoint: g.end), lineWidth: 1)
                    if increased { bezel.strokeBorder(GO.C.controlBorder, lineWidth: 1) }
                }
                .goShadowGlass()
            }
    }
}

/// Scanlines (2 clear, 2 dark, every 4) over one bloom, drawn once per size
struct GOTubeCRT: View, Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { true }
    var body: some View {
        Canvas { ctx, size in
            var bloom = ctx
            bloom.translateBy(x: size.width * 0.5, y: size.height * 0.42)
            bloom.scaleBy(x: size.width * 0.75, y: size.height * 0.65)
            bloom.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)), with: .radialGradient(
                Gradient(stops: [.init(color: GO.C.bloom, location: 0), .init(color: .clear, location: 0.78)]),
                center: .zero, startRadius: 0, endRadius: 1))
            var y: CGFloat = 2
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 2)), with: .color(GO.C.scanline))
                y += GO.CRT.scanlinePitch
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

/// The console's meta line, uppercase and faint
struct GOMeta: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium, design: .monospaced))
            .tracking(0.96).textCase(.uppercase).foregroundStyle(GO.C.phosphorFaint)
            .lineLimit(1)
    }
}

/// [ COPY ]: brackets faint, label phosphor, snaps to inverse video on hover
struct GOPlainButton: View {
    var label: String
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text("[ ").foregroundStyle(hover ? GO.C.onSage : GO.C.phosphorFaint)
                Text(label).foregroundStyle(hover ? GO.C.onSage : GO.C.phosphor)
                    .modifier(GOGlow())
                Text(" ]").foregroundStyle(hover ? GO.C.onSage : GO.C.phosphorFaint)
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(0.96).textCase(.uppercase)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background { if hover { RoundedRectangle(cornerRadius: 8).fill(GO.C.sage) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .transaction { $0.animation = nil }  // terminal things snap
    }
}

