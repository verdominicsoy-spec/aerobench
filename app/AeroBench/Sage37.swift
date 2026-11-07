import AeroBenchKit
import AppKit
import CoreText
import SwiftUI

// sage37, Dominic's design system (tokens v6, November 2026), as the
// sage37-swift skill translates it. The values are the design system's; if
// it changes, regenerate them from it rather than editing here. AeroBench
// ships dark only, so each token is its dark value. Content sits on solid
// panes with a hairline; glass is kept for controls and the dock. Behind the
// panes runs a quiet space-filling curve per tool (S37Motifs.swift), drawn
// flat: Dominic keeps the curves although the November skill drops
// backdrops (docs/DECISIONS.md). The job log is the one glassout
// console (Glassout.swift).

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

    /// A nested corner: the parent's radius less the padding between them, squared off to sm below 8
    static func concentric(_ outer: CGFloat, _ padding: CGFloat) -> CGFloat { max(Radius.sm, outer - padding) }

    enum Motion {
        /// Every curve eases out with no overshoot
        static let press = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.24)
        static let toggle = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.28)
        static let thumb = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.36)
        static let lens = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.32)
        static let colour = Animation.easeInOut(duration: 0.2)
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

    /// The soft dark text shadow that keeps the header readable over the curve
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

// MARK: root

/// Root of the window: plain bg, the tool's curve drawn flat behind the panes, content on top
struct S37Root<Content: View>: View {
    var motif: S37Motif = .hilbert
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack(alignment: .topLeading) {
            if contrast != .increased {
                S37Backdrop(motif: motif).equatable().id(motif).transition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: S37.Motion.motifCrossfade), value: motif)
            }
            content
        }
        .background(S37.C.bg)
    }
}

/// A pane's ground: solid surface
struct S37PaneFill: View {
    var radius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(S37.C.surface)
    }
}

/// A pane's 1 point hairline, controlBorder under Increase Contrast
struct S37PaneRim: View {
    var radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(contrast == .increased ? S37.C.controlBorder : S37.C.separator, lineWidth: 1)
            .allowsHitTesting(false)
    }
}

extension View {
    /// A solid content pane with padding inside
    func s37Pane(radius: CGFloat = S37.Radius.xlContent, padding: CGFloat = S37.Space.s6) -> some View {
        self.padding(padding)
            .background { ZStack { S37PaneFill(radius: radius); S37PaneRim(radius: radius) } }
    }

    /// A working region (a form, a canvas, a 3D view) as a solid pane: drawn
    /// edge to edge and clipped, the hairline on top, the form's own ground
    /// cleared so the pane shows.
    func s37Region(radius: CGFloat = S37.Radius.xlContent) -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(S37PaneFill(radius: radius))
            .overlay(S37PaneRim(radius: radius))
            .padding(3)
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
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let small = controlSize == .small || controlSize == .mini  // dense toolbars
        configuration.label
            .font(.system(size: small ? 13 : 14, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, kind == .plain ? S37.Space.s2 : (small ? S37.Space.s3 : 16))
            .frame(minHeight: small ? 28 : 32)
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

/// A mode you switch on and leave on (Measure, Section): a glass button that
/// stays sage-tinted while it's on
struct S37ToggleButtonStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(S37ButtonStyle())
            .overlay {
                if configuration.isOn {
                    Capsule().fill(S37.C.sageWash)
                        .overlay(Capsule().strokeBorder(S37.C.sage.opacity(0.7), lineWidth: 1))
                        .allowsHitTesting(false)
                }
            }
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
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
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
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

// MARK: field row

/// The one dense field row: label left, a recessed number field, its unit.
/// An error outlines the field in critical and says the fix under it.
struct S37FieldRow: View {
    var label: String
    var unit: String = ""
    @Binding var value: Double?
    var prompt: String? = nil
    var error: String? = nil
    var width: CGFloat = 112
    var check: ((Double) -> String?)? = nil
    private var optional = true
    @State private var typed: String?

    /// A field that may be cleared: empty is nil (the prompt shows).
    init(label: String, unit: String = "", value: Binding<Double?>, prompt: String? = nil, error: String? = nil,
         width: CGFloat = 112, check: ((Double) -> String?)? = nil) {
        self.label = label
        self.unit = unit
        self._value = value
        self.prompt = prompt
        self.error = error
        self.width = width
        self.check = check
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: S37.Space.s1) {
            HStack(spacing: S37.Space.s2) {
                Text(label).font(.system(size: 13)).foregroundStyle(S37.C.ink).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: S37.Space.s2)
                S37NumberInput(label: label, value: $value, digits: 6, prompt: prompt, check: check, problem: $typed,
                               outlined: error != nil, width: width, optional: optional)
                    .font(.system(size: 13))
                Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkTertiary)
                    .frame(width: 40, alignment: .leading)
            }
            if let message = typed ?? error {
                Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.critical)
                    .padding(.trailing, 48)
            }
        }
        .padding(.vertical, (typed ?? error) == nil ? 0 : S37.Space.s1)
    }
}

extension S37FieldRow {
    /// A field that always holds a number: clearing it keeps the last one
    init(label: String, unit: String = "", value: Binding<Double>, error: String? = nil, width: CGFloat = 112,
         check: ((Double) -> String?)? = nil) {
        self.init(label: label, unit: unit,
                  value: Binding<Double?>(get: { value.wrappedValue }, set: { if let v = $0 { value.wrappedValue = v } }),
                  error: error, width: width, check: check)
        optional = false
    }
}

// MARK: number input

/// A number box that edits its own text and sets the value on Return or on leaving the box,
/// never while typing: a value the app limits or converts would otherwise be rewritten under
/// the caret (clear 15 to type 20 and a clamp puts a number back). Points for decimals in every
/// locale and no thousands separators, so "1,184" is refused instead of read as 1184. A cleared
/// box keeps the last number unless the value may be empty.
struct S37NumberInput: View {
    var label: String
    @Binding var value: Double?
    var digits = 4
    var prompt: String? = nil
    /// Why a typed number cannot be used, or nil; the value is not set while it says so.
    var check: ((Double) -> String?)? = nil
    var problem: Binding<String?>? = nil
    var outlined = false
    var width: CGFloat = 90
    var optional = false
    /// After a typed number is set (Return or leaving the box).
    var onCommit: (() -> Void)? = nil

    @State private var text = ""
    @State private var local: String?
    @FocusState private var focused: Bool

    init(label: String, value: Binding<Double?>, digits: Int = 4, prompt: String? = nil, check: ((Double) -> String?)? = nil,
         problem: Binding<String?>? = nil, outlined: Bool = false, width: CGFloat = 90, optional: Bool = false,
         onCommit: (() -> Void)? = nil) {
        self.onCommit = onCommit
        self.label = label
        self._value = value
        self.digits = digits
        self.prompt = prompt
        self.check = check
        self.problem = problem
        self.outlined = outlined
        self.width = width
        self.optional = optional
    }

    static func format(_ v: Double, digits: Int) -> String { NumberText.format(v, digits: digits) }
    static func within(_ range: ClosedRange<Double>, _ unit: String = "") -> (Double) -> String? { NumberText.within(range, unit) }

    var body: some View {
        TextField(label, text: $text, prompt: prompt.map { Text($0) })
            .textFieldStyle(.plain).labelsHidden()
            .multilineTextAlignment(.trailing).monospacedDigit()
            .padding(.horizontal, S37.Space.s2).frame(width: width, height: 24)
            .background(RoundedRectangle(cornerRadius: S37.Radius.sm, style: .continuous).fill(S37.C.recess))
            .overlay {
                if outlined || local != nil {
                    RoundedRectangle(cornerRadius: S37.Radius.sm, style: .continuous).strokeBorder(S37.C.critical, lineWidth: 2)
                }
            }
            .help(local ?? "")
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onExitCommand { show(value); say(nil) }
            .onAppear { show(value) }
            .onChange(of: value) { _, v in if !focused { show(v) } }
    }

    private func show(_ v: Double?) { text = v.map { Self.format($0, digits: digits) } ?? "" }

    private func say(_ message: String?) {
        local = message
        problem?.wrappedValue = message
    }

    private func commit() {
        switch NumberText.parse(text) {
        case .failure(let p):
            say(p.message)
        case .success(nil):
            say(nil)
            if optional { value = nil } else { show(value) }  // cleared: keep the last number
        case .success(let v?):
            if let message = check?(v) { say(message); return }
            say(nil)
            if v != value { value = v; onCommit?() }
            if !focused { show(value) }  // as the app keeps it (limited or rounded)
        }
    }
}

extension S37NumberInput {
    /// For a value that always holds a number.
    init(label: String, value: Binding<Double>, digits: Int = 4, check: ((Double) -> String?)? = nil,
         problem: Binding<String?>? = nil, outlined: Bool = false, width: CGFloat = 90, onCommit: (() -> Void)? = nil) {
        self.init(label: label, value: Binding<Double?>(get: { value.wrappedValue }, set: { if let v = $0 { value.wrappedValue = v } }),
                  digits: digits, check: check, problem: problem, outlined: outlined, width: width, onCommit: onCommit)
    }
}


// MARK: sections and rows

/// A titled group of rows in the pane's inset tint, hairlines between them.
/// Any view inside is a row: padded, at least 40 tall, labels left.
struct S37Section<Rows: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var rows: Rows
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder rows: () -> Rows) {
        self.title = title; self.footer = footer; self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: S37.Space.s1) {
            if let title { Text(title).font(.system(size: 14, weight: .semibold)) }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: rows) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { i, row in
                        if i > 0 { Rectangle().fill(S37.C.separator).frame(height: 1).padding(.horizontal, S37.Space.s3) }
                        row
                            .padding(.horizontal, S37.Space.s3)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    }
                }
            }
            .font(.system(size: 13))
            .controlSize(.small)  // dense rows: compact buttons, pickers and switches
            .labeledContentStyle(S37LabeledContentStyle())
            .toggleStyle(.switch)  // settings apply at once
            .background(RoundedRectangle(cornerRadius: S37.Radius.lgIn, style: .continuous).fill(S37.C.inset))
            if let footer {
                Text(footer).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, S37.Space.s1)
            }
        }
    }
}

/// Label left, its value or control right
struct S37Row<Value: View>: View {
    var label: String
    @ViewBuilder var value: Value
    init(_ label: String, @ViewBuilder value: () -> Value) { self.label = label; self.value = value() }

    var body: some View {
        HStack(spacing: S37.Space.s3) {
            Text(label).foregroundStyle(S37.C.ink)
            Spacer(minLength: S37.Space.s3)
            value.lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 14))
    }
}

/// LabeledContent as a row: the label left, the value right in secondary ink
struct S37LabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: S37.Space.s3) {
            configuration.label.foregroundStyle(S37.C.ink)
            Spacer(minLength: S37.Space.s3)
            configuration.content.foregroundStyle(S37.C.inkSecondary).monospacedDigit()
        }
    }
}

// MARK: empty state

/// What's missing, left-aligned: a headline, one plain line and the action
struct S37EmptyState<Actions: View>: View {
    var title: String
    var line: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(S37.C.ink)
            Text(line).font(.system(size: 14)).foregroundStyle(S37.C.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: S37.Space.s3) { actions }.padding(.top, S37.Space.s1)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(S37.Space.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension S37EmptyState where Actions == EmptyView {
    init(title: String, line: String) { self.init(title: title, line: line) { EmptyView() } }
}

// MARK: undo

/// The target undo registrations hang off when the edit isn't an object's
final class S37UndoTarget: NSObject { static let shared = S37UndoTarget() }

extension Binding where Value: Equatable {
    /// The same binding, with every change registered for undo as `name`
    /// ("Undo Change Velocity"). Undoing goes back through this binding, so
    /// redo registers itself.
    func undoable(_ undo: UndoManager?, _ name: String) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { new in
            let old = wrappedValue
            guard new != old else { return }
            wrappedValue = new
            undo?.registerUndo(withTarget: S37UndoTarget.shared) { _ in self.undoable(undo, name).wrappedValue = old }
            undo?.setActionName(name)
        })
    }
}
