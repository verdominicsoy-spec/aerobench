import AeroBenchKit
import AppKit
import Charts
import SwiftUI
import simd

struct WingLabView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let lab = app.wingLab
        HSplitView {
            AirfoilLibraryPanel()
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            VSplitView {
                WingCanvas()
                    .frame(minHeight: 280, maxHeight: .infinity)
                WingResultsPane()
                    .frame(minHeight: 170, idealHeight: 240)
            }
            .frame(minWidth: 420, maxWidth: .infinity)
            WingInspector()
                .frame(minWidth: 290, idealWidth: 330, maxWidth: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { lab.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z")
                    .disabled(lab.undoStack.isEmpty)
                Button { lab.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(lab.redoStack.isEmpty)
            }
        }
        .onAppear {
            if lab.library.isEmpty { lab.loadLibrary(engineDirectory: app.settings.engineDirectory) }
            if lab.wing.elements.isEmpty && lab.undoStack.isEmpty { lab.reset(to: WingLabModel.starter) }
        }
    }
}

// MARK: Library

struct AirfoilLibraryPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var lab = app.wingLab
        VStack(spacing: 0) {
            if lab.library.isEmpty {
                missingLibrary(lab)
            } else {
                filters($lab)
                Divider()
                let shown = lab.shown
                List(shown) { airfoil in
                    AirfoilRow(airfoil: airfoil, favourite: lab.favourites.contains(airfoil.key)) {
                        if lab.favourites.contains(airfoil.key) { lab.favourites.remove(airfoil.key) } else { lab.favourites.insert(airfoil.key) }
                    } add: {
                        lab.add(airfoil)
                    }
                    .draggable(airfoil.key)
                }
                .listStyle(.plain)
                Divider()
                HStack {
                    Text("\(shown.count) of \(lab.library.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import .dat…") { app.importAirfoilsPanel() }
                }
                .padding(8)
            }
            if let job = lab.libraryJob, !job.status.isFinished || job.status == .failed {
                JobInlineStatus(job: job).padding(8)
            }
        }
    }

    @ViewBuilder private func missingLibrary(_ lab: WingLabModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Airfoil library").font(.headline)
            Text("The UIUC airfoil database (about 1,600 sections) is downloaded to your Mac, not shipped with AeroBench. NACA 4 and 5-digit sections are always there.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Download the Library") { app.downloadAirfoils() }
                .buttonStyle(.borderedProminent)
            Button("NACA Sections Only") { app.buildAirfoilIndex() }
            if let error = lab.libraryError {
                Text(error).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder private func filters(_ lab: Bindable<WingLabModel>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search, e.g. 4412 or e423", text: lab.filter.text)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Family", selection: lab.filter.family) {
                    Text("All families").tag(String?.none)
                    ForEach(lab.wrappedValue.families, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                Picker("Source", selection: lab.filter.source) {
                    Text("All").tag(String?.none)
                    Text("NACA").tag(String?.some("naca"))
                    Text("UIUC").tag(String?.some("uiuc"))
                    Text("Mine").tag(String?.some("mine"))
                }
                .labelsHidden()
                .frame(width: 80)
            }
            RangeRow(label: "Thickness", range: lab.filter.thickness, bounds: 0...0.4)
            RangeRow(label: "Camber", range: lab.filter.camber, bounds: -0.05...0.15)
            Toggle("Favourites only", isOn: lab.filter.favouritesOnly)
                .font(.caption)
        }
        .padding(8)
    }
}

/// A min/max pair of sliders in percent.
struct RangeRow: View {
    let label: String
    @Binding var range: ClosedRange<Double>
    let bounds: ClosedRange<Double>

    var body: some View {
        let lo = max(range.lowerBound, bounds.lowerBound), hi = min(range.upperBound, bounds.upperBound)
        VStack(alignment: .leading, spacing: 0) {
            Text("\(label) \(Int((lo * 100).rounded()))–\(Int((hi * 100).rounded()))%").font(.caption)
            HStack(spacing: 4) {
                Slider(value: Binding(get: { lo }, set: { range = min($0, hi)...range.upperBound }), in: bounds)
                Slider(value: Binding(get: { hi }, set: { range = range.lowerBound...max($0, lo) }), in: bounds)
            }
            .controlSize(.mini)
        }
    }
}

struct AirfoilRow: View {
    let airfoil: Airfoil
    let favourite: Bool
    let toggleFavourite: () -> Void
    let add: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            AirfoilThumbnail(coords: airfoil.coords)
                .frame(width: 64, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(airfoil.name).lineLimit(1)
                Text(String(format: "t %.1f%%  c %.1f%%", airfoil.thickness * 100, airfoil.camber * 100)
                     + (airfoil.teThickness > 0.002 ? String(format: "  TE %.1f%%", airfoil.teThickness * 100) : ""))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: toggleFavourite) { Image(systemName: favourite ? "star.fill" : "star") }
                .buttonStyle(.borderless)
                .foregroundStyle(favourite ? .yellow : .secondary)
            Button(action: add) { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
                .help("Add as the next element (or drag it onto the canvas)")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: add)
    }
}

struct AirfoilThumbnail: View {
    let coords: [SIMD2<Double>]

    var body: some View {
        Canvas { ctx, size in
            guard coords.count > 2 else { return }
            let ys = coords.map(\.y)
            let span = max((ys.max() ?? 0) - (ys.min() ?? 0), 0.05)
            let s = min(size.width, size.height / span)
            let mid = ((ys.max() ?? 0) + (ys.min() ?? 0)) / 2
            var path = Path()
            for (i, p) in coords.enumerated() {
                let q = CGPoint(x: p.x * s, y: size.height / 2 - (p.y - mid) * s)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            path.closeSubpath()
            ctx.fill(path, with: .color(.secondary.opacity(0.35)))
            ctx.stroke(path, with: .color(.primary.opacity(0.7)), lineWidth: 0.8)
        }
    }
}

// MARK: Canvas

/// World (metres, y up) to view mapping that fits the wing and rules box.
struct WingMapping {
    let scale: Double
    let origin: CGPoint  // view position of world (0, 0)

    init(wing: Wing, size: CGSize, zoom: Double, pan: CGSize) {
        var pts = wing.elements.flatMap { $0.placed() }
        if let b = wing.rulesBox { pts += [SIMD2(b.minX, b.minY), SIMD2(b.maxX, b.maxY)] }
        if pts.isEmpty { pts = [SIMD2(-0.05, -0.1), SIMD2(0.45, 0.1)] }
        let lo = pts.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, $1) }
        let hi = pts.reduce(SIMD2(-Double.infinity, -.infinity)) { simd_max($0, $1) }
        let span = simd_max(hi - lo, SIMD2(0.05, 0.05))
        let fit = 0.8 * min(Double(size.width) / span.x, Double(size.height) / span.y)
        scale = fit * zoom
        let centre = (lo + hi) / 2
        origin = CGPoint(x: size.width / 2 - centre.x * scale + pan.width, y: size.height / 2 + centre.y * scale + pan.height)
    }

    func view(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y - p.y * scale) }
    func world(_ p: CGPoint) -> SIMD2<Double> { SIMD2((p.x - origin.x) / scale, (origin.y - p.y) / scale) }
}

struct WingCanvas: View {
    @Environment(AppState.self) private var app
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var drag: DragKind?
    @State private var panStart = CGSize.zero
    @State private var gestureStart: WingElement?

    enum DragKind { case move(Int), rotate(Int), resize(Int), pan }

    var body: some View {
        let lab = app.wingLab
        GeometryReader { geo in
            let m = WingMapping(wing: lab.wing, size: geo.size, zoom: zoom, pan: pan)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(ctx, m, lab) }
                    .background(Color(nsColor: .textBackgroundColor))
                    .contentShape(Rectangle())
                    .gesture(dragGesture(m, lab))
                    .onTapGesture(coordinateSpace: .local) { point in
                        lab.selection = lab.element(at: m.world(point))
                    }
                    .dropDestination(for: String.self) { keys, location in
                        guard let key = keys.first, let airfoil = lab.airfoil(key) else { return false }
                        let p = m.world(location)
                        if let i = lab.element(at: p) { lab.swap(airfoil, into: i) } else { lab.add(airfoil, at: p) }
                        return true
                    }
                overlay(lab)
            }
        }
    }

    @ViewBuilder private func overlay(_ lab: WingLabModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("INVISCID PREVIEW").font(.caption2.bold()).foregroundStyle(.secondary)
                if let r = lab.preview {
                    Text(String(format: "Cl %.3f   Cm %.3f   α %.1f°", r.clTotal, r.cmTotal, lab.wing.alpha))
                        .font(.caption.monospacedDigit())
                }
                Spacer()
                Button { zoom /= 1.25 } label: { Image(systemName: "minus.magnifyingglass") }
                Button { zoom *= 1.25 } label: { Image(systemName: "plus.magnifyingglass") }
                Button("Fit") { zoom = 1; pan = .zero }
            }
            .buttonStyle(.borderless)
            if let error = lab.previewError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            ForEach(Array(lab.wing.issues.enumerated()), id: \.offset) { _, issue in
                Label(issue.message, systemImage: "exclamationmark.octagon").font(.caption).foregroundStyle(.red)
            }
            Spacer()
            Text("Drag an airfoil here to add an element, or onto one to swap its section. Drag an element to move it, the round handle to turn it, the square one to change its chord.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private func draw(_ ctx: GraphicsContext, _ m: WingMapping, _ lab: WingLabModel) {
        let wing = lab.wing
        let flagged = Set(wing.issues.filter { $0.kind != .outsideRules }.flatMap(\.elements))
        let outside = Set(wing.issues.filter { $0.kind == .outsideRules }.flatMap(\.elements))
        if let b = wing.rulesBox {
            let a = m.view(SIMD2(b.minX, b.maxY)), c = m.view(SIMD2(b.maxX, b.minY))
            let rect = CGRect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y)
            ctx.stroke(Path(rect), with: .color(.purple), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            ctx.draw(Text("Rules box").font(.caption2).foregroundStyle(.purple), at: CGPoint(x: rect.minX + 30, y: rect.minY - 8))
        }
        // Freestream arrow.
        let al = wing.alpha * .pi / 180
        let start = CGPoint(x: 30, y: 40)
        var arrow = Path()
        arrow.move(to: start)
        let tip = CGPoint(x: start.x + 40 * cos(al), y: start.y - 40 * sin(al))
        arrow.addLine(to: tip)
        ctx.stroke(arrow, with: .color(.secondary), lineWidth: 1.5)
        ctx.draw(Text("V").font(.caption2), at: CGPoint(x: tip.x + 8, y: tip.y))

        for (i, e) in wing.elements.enumerated() {
            let pts = e.placed()
            var path = Path()
            for (k, p) in pts.enumerated() {
                if k == 0 { path.move(to: m.view(p)) } else { path.addLine(to: m.view(p)) }
            }
            path.closeSubpath()
            let selected = lab.selection == i
            let colour: Color = flagged.contains(i) ? .red : (outside.contains(i) ? .purple : (selected ? .accentColor : .gray))
            ctx.fill(path, with: .color(colour.opacity(selected ? 0.35 : 0.2)))
            ctx.stroke(path, with: .color(colour), lineWidth: selected ? 2 : 1.2)
            ctx.draw(Text(WingIssue.label(i)).font(.caption2).foregroundStyle(.secondary),
                     at: m.view(e.leadingEdge + SIMD2(0, (e.inverted ? 1 : -1) * 0.02)))
            if selected {
                let le = m.view(e.leadingEdge), te = m.view(e.trailingEdge)
                let beyond = m.view(e.trailingEdge + 0.12 * e.chord * e.chordDirection)
                ctx.fill(Path(ellipseIn: CGRect(x: le.x - 4, y: le.y - 4, width: 8, height: 8)), with: .color(.accentColor))
                ctx.stroke(Path(ellipseIn: CGRect(x: te.x - 7, y: te.y - 7, width: 14, height: 14)), with: .color(.accentColor), lineWidth: 2)
                ctx.fill(Path(CGRect(x: beyond.x - 6, y: beyond.y - 6, width: 12, height: 12)), with: .color(.accentColor))
            }
        }
    }

    private func dragGesture(_ m: WingMapping, _ lab: WingLabModel) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if drag == nil {
                    drag = hit(v.startLocation, m, lab)
                    switch drag {
                    case .move(let i), .rotate(let i), .resize(let i):
                        lab.selection = i
                        gestureStart = lab.wing.elements[i]
                        lab.beginGesture()
                    case .pan:
                        panStart = pan
                    case nil:
                        break
                    }
                }
                let p = m.world(v.location)
                switch drag {
                case .move(let i):
                    guard let start = gestureStart else { return }
                    let delta = p - m.world(v.startLocation)
                    lab.live {
                        $0.elements[i].leadingEdge = SIMD2(lab.snapped(start.leadingEdge.x + delta.x, step: 0.001),
                                                           lab.snapped(start.leadingEdge.y + delta.y, step: 0.001))
                    }
                case .rotate(let i):
                    guard !lab.lockAngle else { return }
                    let e = lab.wing.elements[i]
                    let d = p - e.leadingEdge
                    let phi = atan2(d.y, d.x) * 180 / .pi
                    lab.live { $0.elements[i].angle = lab.snapped(e.inverted ? phi : -phi, step: 0.5) }
                case .resize(let i):
                    guard !lab.lockChord else { return }
                    let e = lab.wing.elements[i]
                    let along = simd_dot(p - e.leadingEdge, e.chordDirection) / 1.12  // the handle sits 12% beyond the TE
                    lab.live { $0.elements[i].chord = max(lab.snapped(along, step: 0.001), 0.01) }
                case .pan:
                    pan = CGSize(width: panStart.width + v.translation.width, height: panStart.height + v.translation.height)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                drag = nil
                gestureStart = nil
            }
    }

    private func hit(_ point: CGPoint, _ m: WingMapping, _ lab: WingLabModel) -> DragKind {
        if let i = lab.selection, lab.wing.elements.indices.contains(i) {
            let e = lab.wing.elements[i]
            let te = m.view(e.trailingEdge), beyond = m.view(e.trailingEdge + 0.12 * e.chord * e.chordDirection)
            if hypot(point.x - beyond.x, point.y - beyond.y) < 10 { return .resize(i) }
            if hypot(point.x - te.x, point.y - te.y) < 10 { return .rotate(i) }
        }
        if let i = lab.element(at: m.world(point)) { return .move(i) }
        return .pan
    }
}

// MARK: Results

struct WingResultsPane: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var lab = app.wingLab
        VStack(alignment: .leading, spacing: 0) {
            Picker("Results", selection: $lab.resultsTab) {
                ForEach(WingLabModel.ResultsTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .padding([.top, .horizontal], 8)
            switch lab.resultsTab {
            case .pressure: CpPlot()
            case .polar: PolarPlots()
            case .cfd: CFDResults()
            case .study: StudyResults()
            }
        }
    }
}

struct PolarPlots: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let lab = app.wingLab
        if let polar = lab.polar {
            let rows = polar.rows
            let element = lab.polarElement.map { WingIssue.label($0) } ?? ""
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(element), quick viscous (NeuralFoil), Re \(String(format: "%.0f", polar.re)), Ncrit \(String(format: "%.0f", polar.nCrit))")
                        .font(.caption).foregroundStyle(.secondary)
                    if rows.contains(where: { !$0.trusted }) {
                        Label("Hollow points: NeuralFoil is not confident there (usually past stall).", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 12) {
                    Chart(rows) { r in
                        LineMark(x: .value("α", r.alpha), y: .value("Cl", r.cl))
                        PointMark(x: .value("α", r.alpha), y: .value("Cl", r.cl))
                            .symbol(r.trusted ? .circle : .square).opacity(r.trusted ? 1 : 0.35)
                    }
                    .chartXAxisLabel("α (°)").chartYAxisLabel("Cl")
                    Chart(rows) { r in
                        LineMark(x: .value("Cd", r.cd), y: .value("Cl", r.cl))
                        PointMark(x: .value("Cd", r.cd), y: .value("Cl", r.cl)).opacity(r.trusted ? 1 : 0.35)
                    }
                    .chartXAxisLabel("Cd").chartYAxisLabel("Cl")
                    Chart(rows) { r in
                        LineMark(x: .value("α", r.alpha), y: .value("x/c", r.transitionSuction), series: .value("Side", "Suction side"))
                            .foregroundStyle(by: .value("Side", "Suction side"))
                        LineMark(x: .value("α", r.alpha), y: .value("x/c", r.transitionPressure), series: .value("Side", "Pressure side"))
                            .foregroundStyle(by: .value("Side", "Pressure side"))
                    }
                    .chartXAxisLabel("α (°)").chartYAxisLabel("Transition x/c")
                    .chartYScale(domain: 0...1)
                }
                if let i = lab.polarElement, lab.wing.elements.indices.contains(i),
                   let here = polar.row(near: lab.wing.elements[i].angle + lab.wing.alpha * (lab.wing.elements[i].inverted ? -1 : 1)) {
                    HStack {
                        Text(String(format: "At this element's angle (%.1f°): Cl %.3f, Cd %.4f, L/D %.0f, turbulent from %.0f%% chord on the suction side",
                                    here.alpha, here.cl, here.cd, here.liftToDrag, here.transitionSuction * 100))
                            .font(.caption.monospacedDigit())
                        Button("Use this Cd for the Lap Sim") { lab.cdEstimate = here.cd }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
            .padding(8)
        } else if let job = lab.polarJob, !job.status.isFinished {
            ProgressView("Running NeuralFoil…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Pick Quick viscous in Solvers, select an element and run its polar.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CFDResults: View {
    @Environment(AppState.self) private var app

    struct Point: Identifiable {
        let id: Int
        let element: String
        let x: Double
        let minusCp: Double
    }

    var body: some View {
        let lab = app.wingLab
        if let r = lab.ransResult {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if r.converged {
                        Label("Converged", systemImage: "checkmark.seal").foregroundStyle(.green)
                    } else {
                        Label("Not converged: not a result", systemImage: "xmark.octagon").foregroundStyle(.red)
                        Text(r.reason ?? "").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("\(r.modelName), \(r.meshLevel) mesh, Re \(String(format: "%.0f", r.re))").font(.caption)
                    Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 2) {
                        GridRow {
                            Text("").gridColumnAlignment(.leading)
                            Text("Cl").bold()
                            Text("Cd").bold()
                        }
                        ForEach(Array(r.elements.enumerated()), id: \.offset) { i, e in
                            GridRow {
                                Text(WingIssue.label(i))
                                Text(e.cl.map { String(format: "%.3f", $0) } ?? "–")
                                Text(e.cd.map { String(format: "%.4f", $0) } ?? "–")
                            }
                        }
                        GridRow {
                            Text("Total").bold()
                            Text(String(format: "%.3f", r.cl)).bold()
                            Text(String(format: "%.4f", r.cd)).bold()
                        }
                    }
                    .font(.caption.monospacedDigit())
                    Text(String(format: "L/D %.1f · %ld iterations · residual down %.1f orders", r.liftToDrag, r.iterations, r.residualDrop))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("\(r.mesh.cells) cells: \(r.mesh.quads) quads (\(r.mesh.layers) wall layers), \(r.mesh.triangles) triangles")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let attempts = r.attempts, attempts.count > 1 {
                        Text("Diverged at CFL \(attempts.dropLast().map { String(format: "%g", $0.cfl) }.joined(separator: ", ")); finished at CFL \(String(format: "%g", r.cfl ?? 0)).")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if r.scheme == "fds" {
                        Text("Finished only on the upwind fallback scheme, which is more dissipative: drag reads high (about 40% at 10° on NACA 0012). Lift is fine for comparisons.")
                            .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if r.converged {
                            Button("Use for the Lap Sim") {
                                lab.cdEstimate = r.cd
                                app.sendWingToLapSim(cl: r.cl, cd: r.cd, replacedCla: lab.replacedCla, replacedCda: lab.replacedCda)
                            }
                            .help("Car B becomes car A with this wing (see Use in the Lap Sim for span and the 3D factor)")
                        }
                        if let folder = lab.ransFolder, let field = r.field {
                            Button("Show Flow Field") { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(field)]) }
                                .help("flow.vtu, for ParaView")
                        }
                    }
                    .buttonStyle(.link).font(.caption)
                }
                .frame(width: 260, alignment: .leading)
                Chart(points(r)) { p in
                    LineMark(x: .value("x (mm)", p.x), y: .value("−Cp", p.minusCp))
                        .foregroundStyle(by: .value("Element", p.element))
                }
                .chartXAxisLabel("x (mm)").chartYAxisLabel("−Cp")
                .opacity(r.converged ? 1 : 0.35)
            }
            .padding(8)
        } else if let job = lab.ransJob, !job.status.isFinished {
            VStack {
                ProgressView(value: job.progress, total: 100)
                Text(job.progressMessage).font(.caption)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Pick RANS CFD in Solvers and run it.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func points(_ r: WingRansResult) -> [Point] {
        var out: [Point] = []
        var id = 0
        for (i, s) in r.surface.enumerated() {
            let sides = s.side ?? Array(repeating: "", count: s.x.count)
            for k in s.x.indices {
                let series = sides[k].isEmpty ? WingIssue.label(i) : "\(WingIssue.label(i)) \(sides[k])"
                out.append(Point(id: id, element: series, x: s.x[k] * 1000, minusCp: -s.cp[k]))
                id += 1
            }
        }
        return out
    }
}

// MARK: Cp

struct CpPlot: View {
    @Environment(AppState.self) private var app

    struct Point: Identifiable {
        let id: Int
        let element: String
        let x: Double
        let minusCp: Double
    }

    var body: some View {
        let lab = app.wingLab
        let points = makePoints(lab)
        VStack(alignment: .leading, spacing: 2) {
            Text("Surface pressure, inviscid (−Cp up)").font(.caption).foregroundStyle(.secondary)
            if points.isEmpty {
                Rectangle().fill(.quaternary)
            } else {
                Chart(points) { p in
                    LineMark(x: .value("x (mm)", p.x), y: .value("−Cp", p.minusCp))
                        .foregroundStyle(by: .value("Element", p.element))
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
                .chartXAxisLabel("x (mm)")
            }
        }
        .padding(8)
    }

    private func makePoints(_ lab: WingLabModel) -> [Point] {
        guard let r = lab.preview, r.cp.count == lab.wing.elements.count else { return [] }
        var out: [Point] = []
        var id = 0
        for (i, e) in lab.wing.elements.enumerated() {
            let pts = e.placed()
            let name = "\(WingIssue.label(i)) upper" , lower = "\(WingIssue.label(i)) lower"
            let half = (pts.count - 1) / 2
            for k in pts.indices {
                // The two surfaces as separate series so the line does not wrap round the nose.
                out.append(Point(id: id, element: k <= half ? name : lower, x: pts[k].x * 1000, minusCp: -r.cp[i][k]))
                id += 1
            }
        }
        return out
    }
}

// MARK: Inspector

struct WingInspector: View {
    @Environment(AppState.self) private var app
    @State private var sentNote: String?

    var body: some View {
        @Bindable var lab = app.wingLab
        let wing = lab.wing
        Form {
            Section("Elements") {
                ForEach(Array(wing.elements.enumerated()), id: \.element.id) { i, e in
                    HStack {
                        Text(WingIssue.label(i)).bold().frame(width: 50, alignment: .leading)
                        Text(e.airfoil.name).lineLimit(1)
                        Spacer()
                        if lab.selection == i { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { lab.selection = i }
                }
                Toggle("Inverted for downforce", isOn: Binding(
                    get: { wing.elements.first?.inverted ?? true },
                    set: { on in lab.edit { w in for k in w.elements.indices { w.elements[k].inverted = on } } }))
                HStack {
                    Toggle("Snap", isOn: $lab.snap)
                    Toggle("Lock angle", isOn: $lab.lockAngle)
                    Toggle("Lock chord", isOn: $lab.lockChord)
                }
                .font(.caption)
            }

            if let i = lab.selection, wing.elements.indices.contains(i) {
                elementSection(lab, i)
            }

            Section {
                NumberField(label: "Wing angle to the flow", unit: "°", value: Binding(
                    get: { wing.alpha }, set: { v in lab.edit { $0.alpha = v } }))
                NumberField(label: "Minimum gap", unit: "mm", value: mm({ wing.minGap }, { v in lab.edit { $0.minGap = v } }))
                Toggle("Rules box", isOn: Binding(
                    get: { wing.rulesBox != nil },
                    set: { on in lab.edit { $0.rulesBox = on ? RulesBox(minX: -0.05, minY: -0.05, maxX: 0.6, maxY: 0.4) : nil } }))
                if let box = wing.rulesBox {
                    NumberField(label: "Box from x", unit: "mm", value: mm({ box.minX }, { v in lab.edit { $0.rulesBox?.minX = v } }))
                    NumberField(label: "Box to x", unit: "mm", value: mm({ box.maxX }, { v in lab.edit { $0.rulesBox?.maxX = v } }))
                    NumberField(label: "Box from y", unit: "mm", value: mm({ box.minY }, { v in lab.edit { $0.rulesBox?.minY = v } }))
                    NumberField(label: "Box to y", unit: "mm", value: mm({ box.maxY }, { v in lab.edit { $0.rulesBox?.maxY = v } }))
                }
            } header: {
                Text("Wing")
            } footer: {
                Text("The wing sits in its own plane, not on the car. The rules box is wherever you put it; data/rules/fs2027_aero.json has the FS and FSUK limits it comes from.")
            }

            solversSection(lab)
            optimiseSection(lab)
            previewSection(lab)
            lapSimSection(lab)

            Section("Export") {
                HStack {
                    Button("Elements as .dat…") { app.exportWingDat() }
                    Button("Points as CSV…") { app.exportWingCSV() }
                }
                Text("In mm, in the wing's frame, ready for CATIA.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func elementSection(_ lab: WingLabModel, _ i: Int) -> some View {
        let e = lab.wing.elements[i]
        Section {
            NumberField(label: "Chord", unit: "mm", value: mm({ e.chord }, { v in lab.edit { $0.elements[i].chord = max(v, 0.005) } }))
            NumberField(label: "Angle of attack", unit: "°", value: Binding(get: { e.angle }, set: { v in lab.edit { $0.elements[i].angle = v } }))
            NumberField(label: "Leading edge x", unit: "mm", value: mm({ e.leadingEdge.x }, { v in lab.edit { $0.elements[i].leadingEdge.x = v } }))
            NumberField(label: "Leading edge y", unit: "mm", value: mm({ e.leadingEdge.y }, { v in lab.edit { $0.elements[i].leadingEdge.y = v } }))
            if i > 0 {
                NumberField(label: "Gap", unit: "mm", value: mm({ lab.wing.gap(of: i) ?? 0 }, { v in lab.edit { $0.setGap(v, of: i) } }))
                NumberField(label: "Overlap", unit: "mm", value: mm({ lab.wing.overlap(of: i) ?? 0 }, { v in lab.edit { $0.setOverlap(v, of: i) } }))
            }
            if let r = lab.preview, r.cl.indices.contains(i) {
                LabeledContent("Cl (inviscid)", value: String(format: "%.3f", r.cl[i]))
            }
            Button("Remove \(WingIssue.label(i))", role: .destructive) { lab.remove(i) }
        } header: {
            Text("\(WingIssue.label(i)): \(e.airfoil.name)")
        } footer: {
            Text("Gap: from the element in front's trailing edge to this one's surface. Overlap: along the main chord, positive when this leading edge is ahead of that trailing edge. Typing either moves the element.")
        }
    }

    @ViewBuilder private func solversSection(_ lab: WingLabModel) -> some View {
        let wing = lab.wing
        Section {
            Picker("Solver", selection: Binding(get: { lab.solver }, set: { lab.solver = $0 })) {
                ForEach(WingLabModel.Solver.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(lab.solver.purpose).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            NumberField(label: "Speed", unit: "m/s", value: Binding(get: { wing.speed }, set: { v in lab.edit { $0.speed = max(v, 0.1) } }))
            NumberField(label: "Air density", unit: "kg/m³", value: Binding(get: { wing.rho }, set: { v in lab.edit { $0.rho = max(v, 0.01) } }))
            NumberField(label: "Viscosity (×10⁻⁵)", unit: "Pa s", value: Binding(
                get: { wing.mu * 1e5 }, set: { v in lab.edit { $0.mu = max(v, 0.01) * 1e-5 } }))
            ForEach(Array(wing.elements.enumerated()), id: \.element.id) { i, e in
                LabeledContent("Re, \(WingIssue.label(i))", value: String(format: "%.0f", wing.reynolds(chord: e.chord)))
                    .font(.caption)
            }
            switch lab.solver {
            case .preview:
                EmptyView()
            case .quickViscous:
                quickViscousControls(lab)
            case .rans:
                ransControls(lab)
            }
        } header: {
            Text("Solvers")
        }
    }

    @ViewBuilder private func quickViscousControls(_ lab: WingLabModel) -> some View {
        NumberField(label: "From α", unit: "°", value: Binding(get: { lab.alphaStart }, set: { lab.alphaStart = $0 }))
        NumberField(label: "To α", unit: "°", value: Binding(get: { lab.alphaEnd }, set: { lab.alphaEnd = $0 }))
        NumberField(label: "Step", unit: "°", value: Binding(get: { lab.alphaStep }, set: { lab.alphaStep = max($0, 0.1) }))
        NumberField(label: "Turbulence (Ncrit)", value: Binding(get: { lab.nCrit }, set: { lab.nCrit = min(max($0, 1), 14) }))
        Text("Ncrit 9 is a clean wind tunnel; lower (4 to 6) for the turbulent air behind a car, which trips the boundary layer sooner.")
            .font(.caption).foregroundStyle(.secondary)
        if let i = lab.selection, lab.wing.elements.indices.contains(i) {
            Button("Polar of \(WingIssue.label(i)) (\(lab.wing.elements[i].airfoil.name))") { app.runWingPolar() }
                .disabled(lab.polarJob.map { !$0.status.isFinished } ?? false)
        } else {
            Text("Select an element.").foregroundStyle(.secondary)
        }
        if let job = lab.polarJob, !job.status.isFinished || job.status == .failed {
            JobInlineStatus(job: job)
        }
    }

    @ViewBuilder private func ransControls(_ lab: WingLabModel) -> some View {
        Picker("Model", selection: Binding(get: { lab.turbulenceModel }, set: { lab.turbulenceModel = $0 })) {
            ForEach(WingLabModel.TurbulenceModel.allCases) { Text($0.title).tag($0) }
        }
        Text(lab.turbulenceModel.purpose).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Picker("Mesh", selection: Binding(get: { lab.meshLevel }, set: { lab.meshLevel = $0 })) {
            Text("Coarse (quick look)").tag("coarse")
            Text("Medium").tag("medium")
            Text("Fine").tag("fine")
        }
        Toggle("Laminar zones from the quick viscous solver", isOn: Binding(get: { lab.predictTransition }, set: { lab.predictTransition = $0 }))
        Text("Where each element's flow is still laminar gets a finer, flow-aligned wall mesh (structured quads); turbulent regions and wakes get unstructured cells. With a fully turbulent model the zones only refine the mesh.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if lab.turbulenceModel != .sa {
            NumberField(label: "Turbulence intensity", unit: "%", value: Binding(get: { lab.turbulenceIntensity }, set: { lab.turbulenceIntensity = max($0, 0.01) }))
        }
        let haveSU2 = app.settings.su2Executable != nil
        if !haveSU2 { su2Install(lab) }
        Button("Run CFD") { app.runWingRANS() }
            .buttonStyle(.borderedProminent)
            .disabled(!haveSU2 || lab.wing.elements.isEmpty || !lab.wing.issues.filter { $0.kind != .outsideRules }.isEmpty
                      || (lab.ransJob.map { !$0.status.isFinished } ?? false))
        if !lab.wing.issues.filter({ $0.kind != .outsideRules }).isEmpty {
            Text("Fix the overlapping or touching elements first.").font(.caption).foregroundStyle(.orange)
        }
        let needsSU2 = lab.ransJob.map { $0.status == .failed && ($0.message ?? "").contains("SU2 is not installed") } ?? false
        if let job = lab.ransJob, !job.status.isFinished || job.status == .failed {
            JobInlineStatus(job: job)
        }
        if needsSU2 && haveSU2 {
            Text("SU2 is installed now: run it again.").font(.caption).foregroundStyle(.secondary)
        }
        if haveSU2, let job = lab.su2Job {
            JobInlineStatus(job: job)
        }
    }

    @ViewBuilder private func optimiseSection(_ lab: WingLabModel) -> some View {
        let running = lab.optimiseJob.map { !$0.status.isFinished } ?? false
        Section {
            ForEach(Array(lab.wing.elements.enumerated()), id: \.element.id) { i, _ in
                HStack {
                    Text(WingIssue.label(i)).frame(width: 50, alignment: .leading)
                    ForEach(WingLabModel.DesignVariable.Kind.allCases, id: \.self) { kind in
                        if kind == .angle || i > 0 {
                            Toggle(kind.rawValue.capitalized, isOn: Binding(
                                get: { lab.variable(kind, of: i) != nil }, set: { _ in lab.toggleVariable(kind, of: i) }))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
                .disabled(running)
            }
            ForEach(lab.optimise.variables) { v in
                HStack {
                    Text("\(WingIssue.label(v.element)) \(v.kind.rawValue)").font(.caption).frame(width: 110, alignment: .leading)
                    TextField("from", value: Binding(get: { v.low }, set: { lab.setBounds(of: v.id, low: $0) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing)
                    Text("to").foregroundStyle(.secondary)
                    TextField("to", value: Binding(get: { v.high }, set: { lab.setBounds(of: v.id, high: $0) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing)
                    Text(v.unit).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
                }
                .disabled(running)
            }
            Picker("Objective", selection: Binding(get: { lab.optimise.objective }, set: { lab.optimise.objective = $0 })) {
                ForEach(WingLabModel.Objective.allCases) { Text($0.title).tag($0) }
            }
            .disabled(running)
            if lab.optimise.objective == .maxClCdCap {
                NumberField(label: "Cd cap", value: Binding(get: { lab.optimise.cdCap }, set: { lab.optimise.cdCap = $0 }))
            }
            if lab.optimise.objective == .minCdClTarget {
                NumberField(label: "Downforce Cl target", value: Binding(get: { lab.optimise.clTarget }, set: { lab.optimise.clTarget = $0 }))
            }
            Picker("Search", selection: Binding(get: { lab.optimise.sampler }, set: { lab.optimise.sampler = $0 })) {
                Text("TPE (default)").tag("tpe")
                Text("CMA-ES").tag("cmaes")
            }
            .disabled(running)
            Stepper("Trials: \(lab.optimise.trials)", value: Binding(get: { lab.optimise.trials }, set: { lab.optimise.trials = $0 }),
                    in: 2...2000, step: 10)
            LabeledContent("Study") {
                TextField("name", text: Binding(get: { lab.optimise.studyName }, set: { lab.optimise.studyName = $0 }))
                    .multilineTextAlignment(.trailing)
                    .onSubmit { lab.reloadStudy(project: app.project?.url) }
            }
            .disabled(running)
            Text("\(app.settings.parallelTrials) trials at a time on \(app.settings.coresPerJob) cores each (Settings). Each trial is one RANS run with the model and mesh above.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem = lab.optimiseProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            if app.settings.su2Executable == nil {
                Text("Each trial is an SU2 run: install SU2 under Solvers, RANS CFD.").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                let resume = lab.study.map { $0.study == WingLabModel.studyFile(project: app.project?.url ?? URL(fileURLWithPath: "/"), name: lab.optimise.studyName).deletingPathExtension().lastPathComponent } ?? false
                Button(resume ? "Resume Study" : "Start Study") { app.runWingOptimise() }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || lab.optimiseProblem != nil || app.project == nil || app.settings.su2Executable == nil)
                if app.project == nil {
                    Text("Save the project first: studies live in it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let job = lab.optimiseJob { JobInlineStatus(job: job) }
        } header: {
            Text("Optimise")
        } footer: {
            Text("Tick the angles, gaps and overlaps to search, and their ranges. Wings that break the minimum gap or the rules box are never run. Trials whose mesh fails or whose run diverges or does not converge are recorded as failed and the study carries on. Stopping is safe: Resume picks up where it left off.")
        }
    }

    @ViewBuilder private func su2Install(_ lab: WingLabModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SU2 is built on your Mac from its source, once: 10 to 20 minutes. It needs Xcode's command line tools (xcode-select --install). With Open MPI (brew install open-mpi) first, it can use several cores.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Button("Install SU2") { app.installSU2() }
                .disabled(lab.su2Job.map { !$0.status.isFinished } ?? false)
            if let job = lab.su2Job { JobInlineStatus(job: job) }
        }
    }

    @ViewBuilder private func previewSection(_ lab: WingLabModel) -> some View {
        Section {
            if let r = lab.preview {
                ForEach(Array(r.cl.enumerated()), id: \.offset) { i, cl in
                    LabeledContent(WingIssue.label(i), value: String(format: "Cl %.3f", cl))
                }
                LabeledContent("Total", value: String(format: "Cl %.3f   Cm %.3f", r.clTotal, r.cmTotal))
                Text(String(format: "On the total chord, %.0f mm. Solved in %.0f ms.", lab.wing.refChord * 1000, lab.previewMilliseconds))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(lab.previewError ?? "Add an element.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Inviscid preview")
        } footer: {
            Text("A panel method: no viscosity, so no drag and nothing about the slot effects that set the best gap. Use it for angle trends and how the load splits.")
        }
    }

    @ViewBuilder private func lapSimSection(_ lab: WingLabModel) -> some View {
        let wing = lab.wing
        let cl = lab.preview?.clTotal ?? 0
        let add = wing.carContribution(cl: cl, cd: lab.cdEstimate)
        Section {
            NumberField(label: "Span", unit: "mm", value: mm({ wing.span }, { v in lab.edit { $0.span = max(v, 0.01) } }))
            NumberField(label: "2D to 3D factor", value: Binding(get: { wing.factor3D }, set: { v in lab.edit { $0.factor3D = max(v, 0) } }))
            NumberField(label: "Cd (estimate until a viscous run)", value: Binding(get: { lab.cdEstimate }, set: { lab.cdEstimate = $0 }))
            LabeledContent("Adds", value: String(format: "ClA %.3f m²   CdA %.3f m²", add.cla, add.cda))
            NumberField(label: "Replaces a wing worth ClA", unit: "m²", value: Binding(get: { lab.replacedCla }, set: { lab.replacedCla = $0 }))
            NumberField(label: "and CdA", unit: "m²", value: Binding(get: { lab.replacedCda }, set: { lab.replacedCda = $0 }))
            Button("Compare in the Lap Sim") {
                app.sendWingToLapSim(cl: cl, cd: lab.cdEstimate, replacedCla: lab.replacedCla, replacedCda: lab.replacedCda)
                sentNote = "Lap Sim car B is now car A with this wing. Run the Lap Sim to see the lap time difference."
            }
            .disabled(lab.preview == nil)
            if let note = sentNote { Text(note).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Use in the Lap Sim")
        } footer: {
            Text("ClA = −Cl × span × total chord × factor (positive for downforce). A finite wing makes less than the 2D section: endplates help; around 0.7–0.9 is typical, but it is your estimate. Inviscid Cl is optimistic; viscous solvers come next.")
        }
    }
}

/// The optimiser's trials: a sortable table, the best so far, and Cl against
/// Cd with the Pareto front. Clicking a trial puts its wing on the canvas.
struct StudyResults: View {
    @Environment(AppState.self) private var app
    @State private var order = [KeyPathComparator(\Row.number)]
    @State private var selection: Int?

    struct Row: Identifiable {
        let id: Int
        let number: Int
        let state: String
        let load: Double
        let cd: Double
        let ld: Double
        let value: Double
        let design: String
        let note: String
    }

    var body: some View {
        let lab = app.wingLab
        if let study = lab.study {
            VStack(alignment: .leading, spacing: 6) {
                header(study, lab)
                HSplitView {
                    table(study, lab).frame(minWidth: 380)
                    VStack(spacing: 8) {
                        bestSoFar(study)
                        scatter(study, lab)
                    }
                    .frame(minWidth: 260)
                }
            }
            .padding(8)
        } else if let job = lab.optimiseJob, !job.status.isFinished {
            VStack {
                ProgressView(value: job.progress, total: 100)
                Text(job.progressMessage).font(.caption)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Set up a study under Optimise and start it.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func header(_ s: WingStudy, _ lab: WingLabModel) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(s.study): \(s.objectiveName)").bold()
            Text("\(s.complete + s.failed) of \(s.target) run · \(s.failed) failed · \((s.invalid ?? 0)) invalid wings skipped")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let b = s.bestTrial, let v = b.value {
                Text(String(format: "best: trial %ld, %.4g", b.number, v)).font(.caption.monospacedDigit())
                Button("Load Best") { lab.load(trial: b) }.font(.caption)
            }
        }
    }

    private func rows(_ s: WingStudy) -> [Row] {
        s.trials.filter { $0.state != "invalid" }.map { t in
            let design = s.spec.variables.map { v -> String in
                guard let x = t.params[v.name] else { return "" }
                return v.kind == "angle" ? String(format: "%@ %.1f°", short(v), x) : String(format: "%@ %.1f mm", short(v), x * 1000)
            }.joined(separator: "  ")
            let load = t.load ?? -.infinity, cd = t.cd ?? .infinity
            return Row(id: t.number, number: t.number, state: t.state == "complete" && t.feasible == false ? "over limit" : t.state,
                       load: load, cd: cd, ld: load.isFinite && cd.isFinite ? load / cd : -.infinity,
                       value: t.value ?? (s.direction == "minimize" ? .infinity : -.infinity), design: design,
                       note: t.reason ?? "")
        }
    }

    private func short(_ v: WingStudy.Variable) -> String {
        "\(v.kind == "angle" ? "α" : v.kind == "gap" ? "gap" : "ovl")\(v.element)"
    }

    private func fmt(_ x: Double, _ f: String) -> String { x.isFinite ? String(format: f, x) : "–" }

    @ViewBuilder private func table(_ s: WingStudy, _ lab: WingLabModel) -> some View {
        Table(rows(s).sorted(using: order), selection: $selection, sortOrder: $order) {
            TableColumn("#", value: \.number) { Text("\($0.number)").monospacedDigit() }.width(32)
            TableColumn("State", value: \.state) { r in
                Text(r.state).foregroundStyle(r.state == "complete" ? Color.primary : r.state == "fail" ? Color.red : Color.secondary)
                    .help(r.note)
            }
            .width(70)
            TableColumn("−Cl", value: \.load) { Text(fmt($0.load, "%.3f")).monospacedDigit() }.width(54)
            TableColumn("Cd", value: \.cd) { Text(fmt($0.cd, "%.4f")).monospacedDigit() }.width(54)
            TableColumn("L/D", value: \.ld) { Text(fmt($0.ld, "%.1f")).monospacedDigit() }.width(44)
            TableColumn("Score", value: \.value) { Text(fmt($0.value, "%.4g")).monospacedDigit() }.width(54)
            TableColumn("Design", value: \.design) { r in
                Text(r.design.isEmpty ? r.note : r.design).font(.caption).help(r.note)
            }
        }
        .onChange(of: selection) { _, n in
            if let n, let t = s.trials.first(where: { $0.number == n }) { lab.load(trial: t) }
        }
    }

    @ViewBuilder private func bestSoFar(_ s: WingStudy) -> some View {
        let best = s.bestSoFar
        let all = s.results
        Chart {
            ForEach(all) { t in
                PointMark(x: .value("Trial", t.number), y: .value("Score", t.value ?? 0)).symbolSize(12).foregroundStyle(.gray)
            }
            ForEach(Array(best.enumerated()), id: \.offset) { _, b in
                LineMark(x: .value("Trial", b.trial), y: .value("Score", b.value)).interpolationMethod(.stepEnd)
            }
        }
        .chartXAxisLabel("Trial").chartYAxisLabel("Best so far")
        .chartYScale(domain: .automatic(includesZero: false))
    }

    @ViewBuilder private func scatter(_ s: WingStudy, _ lab: WingLabModel) -> some View {
        let ran = s.trials.filter { $0.isResult && $0.load != nil && $0.cd != nil }
        let front = s.paretoFront
        Chart {
            ForEach(ran) { t in
                PointMark(x: .value("Cd", t.cd!), y: .value("−Cl", t.load!))
                    .symbolSize(t.number == lab.selectedTrial ? 80 : 20)
                    .foregroundStyle(t.number == lab.selectedTrial ? Color.accentColor : t.feasible == false ? Color.orange : Color.gray)
            }
            ForEach(front) { t in
                LineMark(x: .value("Cd", t.cd!), y: .value("−Cl", t.load!), series: .value("", "front"))
                    .foregroundStyle(.green)
            }
        }
        .chartXAxisLabel("Cd").chartYAxisLabel("Downforce Cl (lift upright)")
        .chartXScale(domain: .automatic(includesZero: false)).chartYScale(domain: .automatic(includesZero: false))
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame else { return }
                        let origin = geo[frame].origin
                        let p = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
                        let nearest = ran.min { a, b in
                            dist(proxy, p, a) < dist(proxy, p, b)
                        }
                        if let t = nearest, dist(proxy, p, t) < 20 {
                            selection = t.number
                        }
                    }
            }
        }
        .help("Green: the Pareto front, trials nothing else beats on both downforce and drag. Click a point to load it.")
    }

    private func dist(_ proxy: ChartProxy, _ p: CGPoint, _ t: WingStudy.Trial) -> Double {
        guard let q = proxy.position(for: (t.cd!, t.load!)) else { return .infinity }
        return hypot(q.x - p.x, q.y - p.y)
    }
}
