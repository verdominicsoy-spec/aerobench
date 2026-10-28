import AeroBenchKit
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
                CpPlot()
                    .frame(minHeight: 150, idealHeight: 210)
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
    @State private var cdEstimate = 0.05
    @State private var replacedCla = 0.0
    @State private var replacedCda = 0.0
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
        let add = wing.carContribution(cl: cl, cd: cdEstimate)
        Section {
            NumberField(label: "Span", unit: "mm", value: mm({ wing.span }, { v in lab.edit { $0.span = max(v, 0.01) } }))
            NumberField(label: "2D to 3D factor", value: Binding(get: { wing.factor3D }, set: { v in lab.edit { $0.factor3D = max(v, 0) } }))
            NumberField(label: "Cd (estimate until a viscous run)", value: $cdEstimate)
            LabeledContent("Adds", value: String(format: "ClA %.3f m²   CdA %.3f m²", add.cla, add.cda))
            NumberField(label: "Replaces a wing worth ClA", unit: "m²", value: $replacedCla)
            NumberField(label: "and CdA", unit: "m²", value: $replacedCda)
            Button("Compare in the Lap Sim") {
                app.sendWingToLapSim(cl: cl, cd: cdEstimate, replacedCla: replacedCla, replacedCda: replacedCda)
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
