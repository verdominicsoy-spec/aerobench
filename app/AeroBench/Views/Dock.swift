import SwiftUI

/// The frosted dock along the bottom that switches tools, in glassout's
/// dress (mono caps labels, the current tool in inverse-video sage) with
/// sage37's lens. Tap to
/// switch, or press, hold and slide: the thumb lifts into a lens that
/// magnifies the labels it passes and springs onto the nearest tool on
/// release.
struct Dock: View {
    @Binding var selection: Tool
    var tools: [Tool]
    var label: (Tool) -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var frames: [Tool: CGRect] = [:]
    @State private var held = false
    @State private var drag: DragState?
    @State private var holdTask: Task<Void, Never>?

    struct DragState { var target: Tool; var x0: CGFloat; var w: CGFloat; var x: CGFloat; var moved = false }

    var body: some View {
        // Off the dock (the Project screen) the thumb has nowhere to sit.
        let current = frames[selection] ?? .zero
        let thumbX = drag?.x ?? current.minX
        let thumbW = drag?.w ?? current.width
        let under = drag.map { nearest($0.x + $0.w / 2) } ?? selection

        ZStack(alignment: .topLeading) {
            if !held { thumb(x: thumbX, w: thumbW, lens: false) }
            labels(highlight: under, live: true)
            if held { thumb(x: thumbX, w: thumbW, lens: true) }
        }
        .coordinateSpace(name: "dock")
        .padding(4)
        .background(shell)
        .gesture(press)
        .onPreferenceChange(DockFrameKey.self) { frames = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
    }

    /// The items; the live copy takes the clicks and the ⌘ shortcuts, the
    /// copy inside the lens only shows.
    func labels(highlight: Tool, live: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(tools) { t in
                if live {
                    Button { selection = t } label: { item(t, highlight: highlight) }
                        .buttonStyle(.plain)
                        .keyboardShortcut(t.key, modifiers: .command)
                        .help("\(t.title) (⌘\(String(t.key.character)))")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: DockFrameKey.self, value: [t: g.frame(in: .named("dock"))])
                        })
                        .accessibilityLabel(t.title)
                        .accessibilityAddTraits(t == selection ? .isSelected : [])
                } else {
                    item(t, highlight: highlight)
                }
            }
        }
    }

    func item(_ t: Tool, highlight: Tool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: t.symbol).font(.system(size: 17, weight: .regular)).frame(height: 20)
            Text(label(t)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(t == selection && drag == nil ? GO.C.onSage : (t == highlight && drag != nil ? GO.C.phosphorBright : GO.C.phosphorDim))
        .padding(.horizontal, 14)
        .frame(height: 52)
        .contentShape(Capsule())
    }

    @ViewBuilder func thumb(x: CGFloat, w: CGFloat, lens: Bool) -> some View {
        let shape = Capsule()
        ZStack {
            if lens {
                if !reduceTransparency { shape.fill(.ultraThinMaterial) }
                shape.fill(Color(31, 28, 24, reduceTransparency ? 1 : 0.55))
                shape.fill(RadialGradient(stops: [.init(color: .white.opacity(0.14), location: 0), .init(color: .clear, location: 0.6)],
                                          center: .top, startRadius: 0, endRadius: 40))
                // the magnified copy: the same labels, read through the lens
                labels(highlight: drag.map { nearest($0.x + $0.w / 2) } ?? selection, live: false)
                    .offset(x: -x)
                    .frame(width: w, alignment: .leading)
                    .shadow(color: .red.opacity(0.5), radius: 0, x: 0.7)
                    .shadow(color: .blue.opacity(0.5), radius: 0, x: -0.7)
                    .clipShape(shape)
                    .allowsHitTesting(false)
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.2)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                shape.strokeBorder(Color(232, 224, 206, 0.4), lineWidth: 0.5)
            } else {
                // glassout's lit block: sage with its 1 point ring and glow
                shape.fill(GO.C.sage)
                shape.strokeBorder(Color(214, 235, 196, 0.25), lineWidth: 1)
            }
        }
        .frame(width: max(0, w), height: 52)
        .scaleEffect(lens && !reduceMotion ? 1.26 : 1)
        .shadow(color: lens ? .black.opacity(0.7) : Color(150, 183, 127, 0.35), radius: lens ? 14 : 9, y: lens ? 12 : 0)
        .offset(x: x)
        .opacity(w > 0 ? 1 : 0)
        .animation(drag?.moved == true || reduceMotion ? nil : S37.Motion.thumb, value: x)
        .animation(reduceMotion ? nil : S37.Motion.thumb, value: w)
        .animation(reduceMotion ? nil : S37.Motion.lens, value: lens)
        .allowsHitTesting(false)
    }

    var shell: some View {
        let shape = Capsule()
        return ZStack {
            if reduceTransparency {
                shape.fill(S37.C.surfaceRaised)
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(LinearGradient(colors: [Color(42, 38, 33, 0.72), Color(18, 16, 13, 0.80)], startPoint: .top, endPoint: .bottom))
            }
            shape.s37GlassRim()
            let g = UnitPoint.css(160)
            shape.strokeBorder(LinearGradient(stops: [
                .init(color: .white.opacity(0.34), location: 0), .init(color: .white.opacity(0.07), location: 0.32),
                .init(color: .white.opacity(0.02), location: 0.62), .init(color: .white.opacity(0.16), location: 1)],
                startPoint: g.start, endPoint: g.end), lineWidth: 1)
            if contrast == .increased { shape.strokeBorder(S37.C.controlBorder, lineWidth: 1) }
        }
        .s37ShadowFloat()
    }

    func nearest(_ cx: CGFloat) -> Tool {
        tools.min { abs((frames[$0]?.midX ?? 0) - cx) < abs((frames[$1]?.midX ?? 0) - cx) } ?? selection
    }

    var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("dock"))
            .onChanged { v in
                if drag == nil {
                    let t = nearest(v.startLocation.x)
                    guard let f = frames[t] else { return }
                    drag = DragState(target: t, x0: f.minX, w: f.width, x: f.minX)
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(S37.Motion.lensHold))
                        if !Task.isCancelled, drag != nil { held = true }
                    }
                }
                guard var d = drag else { return }
                let dx = v.translation.width
                if !d.moved && abs(dx) < S37.Motion.lensDrag { return }
                d.moved = true
                held = true
                let maxX = (frames.values.map(\.maxX).max() ?? 0) - d.w
                var x = d.x0 + dx
                if x < 0 { x *= 0.3 } else if x > maxX { x = maxX + (x - maxX) * 0.3 }
                d.x = x
                d.target = nearest(x + d.w / 2)
                drag = d
            }
            .onEnded { _ in
                holdTask?.cancel()
                let t = drag?.target
                drag = nil
                held = false
                if let t { selection = t }
            }
    }
}

struct DockFrameKey: PreferenceKey {
    static let defaultValue: [Tool: CGRect] = [:]
    static func reduce(value: inout [Tool: CGRect], nextValue: () -> [Tool: CGRect]) { value.merge(nextValue()) { $1 } }
}
