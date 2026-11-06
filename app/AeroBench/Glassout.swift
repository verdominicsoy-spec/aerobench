import SwiftUI

// glassout, Dominic's green-phosphor machine output (tokens v2, November
// 2026), as the glassout-swift skill translates it. In AeroBench it is only
// ever one console, the Jobs log: a solid tube with a hairline, plain
// monospaced lines, brightness for hierarchy. No glow, scanlines, bezel or
// uppercase. It sets its own font and colours so nothing sage37 leaks in.

enum GO {
    enum C {
        static let tube = Color(hex: 0x0a0a08)
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
}

/// A glassout screen: a solid tube with a hairline. As the console in a
/// sage37 view it takes the section radius, 24.
struct GOScreen<Content: View>: View {
    var radius: CGFloat = 24
    var padding = EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(GO.C.phosphor)
            .buttonStyle(.plain)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(GO.C.tube))
            .overlay(shape.strokeBorder(contrast == .increased ? GO.C.controlBorder : GO.C.separator, lineWidth: 1))
            .clipShape(shape)
    }
}

/// The console's meta line, faint
struct GOMeta: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(GO.C.phosphorFaint)
            .lineLimit(1)
    }
}
