import AeroBenchKit
import SwiftUI

/// Opens the track editor, optionally on a fresh copy of another track.
struct TrackEditorRequest: Identifiable {
    let id = UUID()
    var copyFrom: LapSimTrackKind?
}

/// World (metres, y up) to view, fitting a frozen box so the view holds
/// still while points are dragged.
struct TrackMapping {
    struct Bounds: Equatable {
        var lo: SIMD2<Double>
        var hi: SIMD2<Double>

        init(_ track: DrawnTrack) {
            let pts = track.samples(spacing: 2).map { SIMD2($0.x, $0.y) }
            guard let first = pts.first else {
                (lo, hi) = (SIMD2(-50, -50), SIMD2(50, 50))
                return
            }
            (lo, hi) = pts.reduce((first, first)) { (pointwiseMin($0.0, $1), pointwiseMax($0.1, $1)) }
        }
    }

    let scale: Double  // px per m
    let origin: CGPoint  // view position of world (0, 0)

    init(bounds: Bounds, size: CGSize, zoom: Double, pan: CGSize) {
        let span = pointwiseMax(bounds.hi - bounds.lo, SIMD2(10, 10))
        scale = 0.9 * min(Double(size.width) / span.x, Double(size.height) / span.y) * zoom
        let centre = (bounds.lo + bounds.hi) / 2
        origin = CGPoint(x: size.width / 2 - centre.x * scale + pan.width, y: size.height / 2 + centre.y * scale + pan.height)
    }

    func view(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y - p.y * scale) }
    func world(_ p: CGPoint) -> SIMD2<Double> { SIMD2((p.x - origin.x) / scale, (origin.y - p.y) / scale) }
}

/// Draws a Lap Sim track as Bézier curves. Turns tighter than the FS
/// hairpin limit show red, straights over the limit orange; the Lap Sim
/// still runs a track that breaks the rules.
struct TrackEditorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: TrackEditorRequest

    @State private var track = DrawnTrack()
    @State private var history: [DrawnTrack] = []
    @State private var selected: Int?
    @State private var bounds = TrackMapping.Bounds(DrawnTrack())
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var drag: Drag?
    @State private var dragOrigin = SIMD2<Double>(0, 0)
    @State private var panStart = CGSize.zero
    @State private var copying = false
    @State private var status: String?

    enum Drag { case node(Int), handle(Int, out: Bool), pan }

    var body: some View {
        let samples = track.samples()
        let issues = track.issues(samples)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Menu("Copy a Track") {
                    ForEach(app.copyableTracks, id: \.self) { kind in
                        Button(app.trackName(kind)) { copy(kind) }
                    }
                }
                .fixedSize()
                .disabled(copying)
                .help("Start again from a copy of another track")
                Picker("Loop", selection: Binding(get: { track.closed }, set: { closed in edit { $0.closed = closed } })) {
                    Text("Closed").tag(true)
                    Text("Open").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Closed: a lap circuit (endurance). Open: start to finish (autocross).")
                Button("Reverse") { edit { $0 = $0.reversed() } }
                    .help("Drive it the other way round")
                    .disabled(!track.isUsable)
                Button("Undo") { undo() }
                    .keyboardShortcut("z")
                    .disabled(history.isEmpty)
                Spacer()
                Button { zoom /= 1.25 } label: { Image(systemName: "minus.magnifyingglass") }
                Button { zoom *= 1.25 } label: { Image(systemName: "plus.magnifyingglass") }
                Button("Fit") { refit() }
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                GeometryReader { geo in
                    let m = TrackMapping(bounds: bounds, size: geo.size, zoom: zoom, pan: pan)
                    Canvas { ctx, size in draw(ctx, size, m, samples, issues) }
                        .contentShape(Rectangle())
                        .gesture(dragGesture(m))
                        .overlay {
                            if copying {
                                ProgressView(status ?? "Copying")
                            } else if track.nodes.isEmpty {
                                Text("Copy a track to start from, then drag its points.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
                .background(S37.C.surface)
                Divider()
                sidebar(samples, issues)
                    .frame(width: 260)
            }
            Divider()
            HStack {
                if let status, !copying {
                    Label(status, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    app.lapSim.track.drawn = track
                    app.lapSim.track.kind = .drawn
                    dismiss()
                }
                .buttonStyle(S37ButtonStyle(kind: .prominent))
                .keyboardShortcut(.defaultAction)
                .disabled(!track.isUsable)
            }
            .padding(12)
        }
        .frame(minWidth: 960, idealWidth: 1100, minHeight: 640, idealHeight: 760)
        .onDeleteCommand(perform: deleteSelected)
        .task {
            if let kind = request.copyFrom {
                copy(kind)
            } else if let drawn = app.lapSim.track.drawn {
                track = drawn
                refit()
            }
        }
    }

    // MARK: Sidebar

    @ViewBuilder
    private func sidebar(_ samples: [DrawnTrack.Sample], _ issues: [DrawnTrack.Issue]) -> some View {
        let ex = track.extremes(samples)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let source = track.source {
                    Text("From \(source)").font(.headline)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Length").foregroundStyle(.secondary); Text("\(samples.last?.s ?? 0, format: .number.precision(.fractionLength(0))) m") }
                    GridRow { Text("Points").foregroundStyle(.secondary); Text("\(track.nodes.count)") }
                    if track.isUsable {
                        GridRow {
                            Text("Tightest turn").foregroundStyle(.secondary)
                            Text("\(ex.minRadius, format: .number.precision(.fractionLength(1))) m radius")
                        }
                        GridRow {
                            Text("Longest straight").foregroundStyle(.secondary)
                            Text("\(ex.longestStraight, format: .number.precision(.fractionLength(0))) m")
                        }
                    }
                }
                if track.isUsable {
                    if issues.isEmpty {
                        Label("Within the FS layout rules", systemImage: "checkmark.circle").foregroundStyle(S37.C.sageInk)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                Label(describe(issue), systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(issue.kind == .tooTight ? .red : .orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("FS rules D 7.1.1 and D 6.1.1. The Lap Sim still runs a track that breaks them.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let i = selected, i < track.nodes.count {
                    Divider()
                    Text("Point \(i + 1)").font(.headline)
                    Text("x \(track.nodes[i].x, format: .number.precision(.fractionLength(1))) m, y \(track.nodes[i].y, format: .number.precision(.fractionLength(1))) m")
                        .font(.callout.monospacedDigit())
                    Button("Delete Point", action: deleteSelected)
                        .disabled(track.nodes.count <= (track.closed ? 3 : 2))
                }
                Divider()
                Text("Drag a point to move it. Click a point to show its handles; drag them to bend the line through it. Click the line to add a point, and press Delete to remove the selected one. Drag empty space to pan.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("The band is the 3 m minimum track width. The triangle marks the start and the way round.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    private func describe(_ issue: DrawnTrack.Issue) -> String {
        let at = issue.s.formatted(.number.precision(.fractionLength(0)))
        switch issue.kind {
        case .tooTight:
            return "At \(at) m: a \(issue.value.formatted(.number.precision(.fractionLength(1)))) m radius, tighter than a 9 m outside hairpin diameter allows (\(DrawnTrack.minRadius.formatted(.number.precision(.fractionLength(1)))) m on the centreline)"
        case .longStraight:
            return "At \(at) m: a \(issue.value.formatted(.number.precision(.fractionLength(0)))) m straight, over the \(DrawnTrack.straightMax.formatted()) m limit"
        }
    }

    // MARK: Canvas

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ m: TrackMapping,
                      _ samples: [DrawnTrack.Sample], _ issues: [DrawnTrack.Issue]) {
        // Grid every 10 m, or 50 m when that would be too dense.
        let step = m.scale * 10 >= 14 ? 10.0 : 50.0
        let lo = m.world(CGPoint(x: 0, y: size.height)), hi = m.world(CGPoint(x: size.width, y: 0))
        var grid = Path()
        for x in stride(from: (lo.x / step).rounded(.down) * step, through: hi.x, by: step) {
            grid.move(to: m.view(SIMD2(x, lo.y)))
            grid.addLine(to: m.view(SIMD2(x, hi.y)))
        }
        for y in stride(from: (lo.y / step).rounded(.down) * step, through: hi.y, by: step) {
            grid.move(to: m.view(SIMD2(lo.x, y)))
            grid.addLine(to: m.view(SIMD2(hi.x, y)))
        }
        ctx.stroke(grid, with: .color(S37.C.separator), lineWidth: 1)
        ctx.draw(Text("Grid \(Int(step)) m").font(.caption).foregroundStyle(.secondary),
                 at: CGPoint(x: 10, y: size.height - 10), anchor: .bottomLeading)

        guard samples.count > 1 else { return }
        let line = path(samples, 0, samples.count, m)
        // Opaque: a translucent band shows blotches where the renderer overlaps pieces of a long stroke.
        ctx.stroke(line, with: .color(S37.C.sage.mix(with: S37.C.surface, by: 0.75)),
                   style: StrokeStyle(lineWidth: max(3 * m.scale, 2), lineCap: .round, lineJoin: .round))
        ctx.stroke(line, with: .color(S37.C.ink), lineWidth: 1.5)
        let pts = track.closed ? samples.count - 1 : samples.count
        for issue in issues {
            let colour: Color = issue.kind == .tooTight ? .red : .orange
            ctx.stroke(path(samples, issue.start, issue.count, m, wrap: pts), with: .color(colour), lineWidth: 4)
            let mid = samples[(issue.start + issue.count / 2) % pts]
            let label = issue.kind == .tooTight
                ? "R \(issue.value.formatted(.number.precision(.fractionLength(1)))) m"
                : "\(issue.value.formatted(.number.precision(.fractionLength(0)))) m"
            ctx.draw(Text(label).font(.caption.bold()).foregroundStyle(colour),
                     at: m.view(SIMD2(mid.x, mid.y)) + CGSize(width: 8, height: -8), anchor: .bottomLeading)
        }

        // Start, pointing the way round.
        if let first = track.nodes.first {
            var dir = first.outHandle
            if (dir * dir).sum() < 1e-12 { dir = SIMD2(samples[1].x - first.x, samples[1].y - first.y) }
            dir /= max((dir * dir).sum().squareRoot(), 1e-12)
            let p = m.view(first.point), d = CGVector(dx: dir.x, dy: -dir.y), n = CGVector(dx: -d.dy, dy: d.dx)
            var tri = Path()
            tri.move(to: p + CGSize(width: d.dx * 16, height: d.dy * 16))
            tri.addLine(to: p + CGSize(width: n.dx * 7, height: n.dy * 7))
            tri.addLine(to: p + CGSize(width: -n.dx * 7, height: -n.dy * 7))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(S37.C.sageInk))
            if !track.closed, let last = samples.last {
                ctx.draw(Text("Finish").font(.caption.bold()), at: m.view(SIMD2(last.x, last.y)) + CGSize(width: 8, height: 8), anchor: .topLeading)
            }
        }

        for (i, node) in track.nodes.enumerated() {
            let p = m.view(node.point)
            if i == selected {
                for h in [node.inHandle, node.outHandle] where (h * h).sum() > 1e-12 {
                    let q = m.view(node.point + h)
                    var arm = Path()
                    arm.move(to: p)
                    arm.addLine(to: q)
                    ctx.stroke(arm, with: .color(S37.C.inkSecondary), lineWidth: 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: q.x - 4, y: q.y - 4, width: 8, height: 8)), with: .color(S37.C.inkSecondary))
                }
            }
            let box = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.fill(Path(box), with: .color(i == selected ? S37.C.sage : S37.C.surfaceRaised))
            ctx.stroke(Path(box), with: .color(S37.C.ink), lineWidth: 1)
        }
    }

    private func path(_ samples: [DrawnTrack.Sample], _ start: Int, _ count: Int, _ m: TrackMapping, wrap: Int? = nil) -> Path {
        var p = Path()
        for k in 0..<count {
            let s = samples[wrap.map { (start + k) % $0 } ?? start + k]
            let q = m.view(SIMD2(s.x, s.y))
            if k == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        return p
    }

    // MARK: Editing

    private func dragGesture(_ m: TrackMapping) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil { begin(at: v.startLocation, m) }
                switch drag {
                case .node(let i):
                    let p = dragOrigin + SIMD2(v.translation.width, -v.translation.height) / m.scale
                    (track.nodes[i].x, track.nodes[i].y) = (p.x, p.y)
                case .handle(let i, let out):
                    track.setHandle(i, out: out, to: m.world(v.location) - track.nodes[i].point)
                case .pan:
                    pan = CGSize(width: panStart.width + v.translation.width, height: panStart.height + v.translation.height)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                if case .pan = drag {} else if history.last == track { history.removeLast() }  // a click, not an edit
                drag = nil
            }
    }

    /// What a press grabs: a handle of the selected point, a point, the line (adding a point there), or empty space.
    private func begin(at location: CGPoint, _ m: TrackMapping) {
        let near = { (p: SIMD2<Double>, px: Double) in
            let q = m.view(p)
            return hypot(q.x - location.x, q.y - location.y) <= px
        }
        if let i = selected, i < track.nodes.count {
            let node = track.nodes[i]
            for (out, h) in [(true, node.outHandle), (false, node.inHandle)] where (h * h).sum() > 1e-12 && near(node.point + h, 8) {
                history.append(track)
                drag = .handle(i, out: out)
                return
            }
        }
        if let i = track.nodes.indices.min(by: { dist(track.nodes[$0].point, location, m) < dist(track.nodes[$1].point, location, m) }),
           near(track.nodes[i].point, 9) {
            history.append(track)
            selected = i
            dragOrigin = track.nodes[i].point
            drag = .node(i)
            return
        }
        if let hit = track.nearest(to: m.world(location)), hit.distance * m.scale <= 7 {
            history.append(track)
            let i = track.split(segment: hit.segment, at: hit.t)
            selected = i
            dragOrigin = track.nodes[i].point
            drag = .node(i)
            return
        }
        selected = nil
        panStart = pan
        drag = .pan
    }

    private func dist(_ p: SIMD2<Double>, _ location: CGPoint, _ m: TrackMapping) -> Double {
        let q = m.view(p)
        return hypot(q.x - location.x, q.y - location.y)
    }

    private func edit(_ change: (inout DrawnTrack) -> Void) {
        history.append(track)
        change(&track)
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        track = last
        if let i = selected, i >= track.nodes.count { selected = nil }
    }

    private func deleteSelected() {
        guard let i = selected, track.nodes.indices.contains(i), track.nodes.count > (track.closed ? 3 : 2) else { return }
        edit { $0.nodes.remove(at: i) }
        selected = nil
    }

    private func refit() {
        bounds = TrackMapping.Bounds(track)
        zoom = 1
        pan = .zero
    }

    private func copy(_ kind: LapSimTrackKind) {
        copying = true
        status = "Loading the engine (a few seconds, once)"
        Task { @MainActor in
            do {
                let copy = try await app.drawnCopy(of: kind)
                if !track.nodes.isEmpty { history.append(track) }
                track = copy
                selected = nil
                status = nil
                refit()
            } catch {
                status = error.localizedDescription
            }
            copying = false
        }
    }
}

private func + (p: CGPoint, d: CGSize) -> CGPoint { CGPoint(x: p.x + d.width, y: p.y + d.height) }
