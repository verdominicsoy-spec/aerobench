import AeroBenchKit
import AppKit
import Charts
import SwiftUI
import simd

struct WingLabView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let lab = app.wingLab
        HSplitView {
            if lab.showLibrary {
                AirfoilLibraryPanel()
                    .s37Region()
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            }
            VSplitView {
                CanvasHost()
                    .s37Region()
                    .frame(minHeight: 200, maxHeight: .infinity)
                WingResultsPane()
                    .s37Region()
                    .frame(minHeight: 200, idealHeight: 300)
            }
            .frame(minWidth: 440, maxWidth: .infinity)
            if lab.showInspector {
                WingInspector()
                    .s37Region()
                    .frame(minWidth: 320, idealWidth: 350, maxWidth: 440)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { lab.showLibrary.toggle() } label: { Label("Library", systemImage: "sidebar.left") }
                    .help(lab.showLibrary ? "Hide library (⌥⌘L)" : "Show library (⌥⌘L)")
            }
            ToolbarItemGroup {
                Menu {
                    Button(lab.pinned == nil ? "Pin This Wing as A" : "Pin This Wing as A Instead") { lab.pinCurrent() }
                        .disabled(lab.wing.elements.isEmpty)
                    Button("Swap A and This Wing") { lab.swapWithPinned() }
                        .disabled(lab.pinned == nil)
                    Button("Clear A") { lab.pinned = nil }
                        .disabled(lab.pinned == nil)
                } label: {
                    Label("Compare", systemImage: lab.pinned == nil ? "pin" : "pin.fill")
                }
                .help("Pin a design as A to compare the wing you edit against it")
                Button { openWindow(id: "accuracy") } label: { Label("Accuracy", systemImage: "questionmark.circle") }
                    .help("How far to trust each solver")
                Button { lab.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help(lab.showInspector ? "Hide inspector (⌥⌘I)" : "Show inspector (⌥⌘I)")
            }
        }
        .onChange(of: app.car.selected) {
            lab.carX = nil  // another combination: the wing takes its end's place there
            lab.carHeight = nil
            app.syncCarRulesBox(picked: true)
        }
        .onAppear {
            app.loadCar()
            app.refreshSections()
            if lab.library.isEmpty { lab.loadLibrary(engineDirectory: app.settings.engineDirectory) }
            app.syncCarRulesBox()
        }
        .onChange(of: lab.wing.rulesFor) { app.syncCarRulesBox() }
        .onChange(of: lab.wing.span) { app.syncCarRulesBox() }  // the rear box starts at the lowest band the span fits
    }
}

/// The canvas: the wing in its own plane, or the car's side view with the wing on it.
struct CanvasHost: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let lab = app.wingLab
        // The view fills the pane; the picker floats over it (the Wing canvas puts it in its own top row)
        ZStack(alignment: .topTrailing) {
            switch lab.canvasMode {
            case .wing:
                WingCanvas()
            case .car:
                ScrollView {
                    if app.car.setup == nil {
                        Text("Set up the base car in the inspector's Car section to put this wing on it.")
                            .foregroundStyle(S37.C.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(S37.Space.s4)
                    } else {
                        SideViewPane().padding(6)
                    }
                }
                .scrollIndicators(.never)
                .onAppear { app.putDraftOnCar() }
            case .mesh:
                MeshCanvas()
            }
            if lab.canvasMode != .wing { CanvasModePicker().padding(6) }
        }
    }
}

/// Wing, Car or Mesh: the views of the canvas
struct CanvasModePicker: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var lab = app.wingLab
        S37Segmented(options: WingLabModel.CanvasMode.allCases.map { ($0, $0.rawValue) }, selection: $lab.canvasMode)
            .fixedSize()
    }
}

// MARK: Library

struct AirfoilLibraryPanel: View {
    @Environment(AppState.self) private var app
    @State private var opening: WingCard?

    var body: some View {
        @Bindable var lab = app.wingLab
        VStack(spacing: 0) {
            S37Segmented(options: WingLabModel.LibraryTab.allCases.map { ($0, $0.rawValue) }, selection: $lab.libraryTab)
                .fixedSize()
                .padding(8)
            if lab.libraryTab == .cards {
                ScrollView {
                    CardsPane(embedded: true) { card in
                        if app.carDraftUnsaved && !lab.wing.elements.isEmpty { opening = card } else { lab.open(card: card) }
                    }
                    .padding(8)
                }
                .confirmationDialog("Discard the changes to this wing?", isPresented: Binding(
                    get: { opening != nil }, set: { if !$0 { opening = nil } })) {
                    Button("Open \(opening?.name ?? "the Card")", role: .destructive) {
                        if let c = opening { lab.open(card: c) }
                        opening = nil
                    }
                } message: {
                    Text("The wing being edited is not saved as a card. Undo brings it back.")
                }
            } else if lab.library.isEmpty {
                missingLibrary(lab)
            } else {
                filters($lab)
                Divider()
                let shown = lab.shown
                List(shown) { airfoil in
                    AirfoilRow(airfoil: airfoil, favourite: lab.favourites.contains(airfoil.key), polar: lab.libraryPolars?.rows[airfoil.key]) {
                        if lab.favourites.contains(airfoil.key) { lab.favourites.remove(airfoil.key) } else { lab.favourites.insert(airfoil.key) }
                    } add: {
                        lab.add(airfoil)
                    }
                    .draggable(airfoil.key)
                    .opacity(lab.hidden.contains(airfoil.key) ? 0.5 : 1)
                    .contextMenu {
                        Button("Add to the Wing") { lab.add(airfoil) }
                        if let i = lab.selection, lab.wing.elements.indices.contains(i) {
                            Button("Use for \(WingIssue.label(i))") { lab.swap(airfoil, into: i) }
                        }
                        Divider()
                        if airfoil.source == "mine" {
                            Button("Delete from My Airfoils…", role: .destructive) { app.deleteAirfoils([airfoil]) }
                        } else if lab.hidden.contains(airfoil.key) {
                            Button("Show in the Library") { lab.hidden.remove(airfoil.key) }
                        } else {
                            Button("Hide from the Library") { lab.hidden.insert(airfoil.key) }
                        }
                    }
                }
                .listStyle(.plain)
                Divider()
                HStack {
                    Text("\(shown.count) of \(lab.library.count)").font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
                    if !lab.hidden.isEmpty {
                        Toggle("Show \(lab.hidden.count) hidden", isOn: $lab.showHidden).toggleStyle(.checkbox).font(.caption)
                    }
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
                .font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
            Button("Download the Library") { app.downloadAirfoils() }
                .buttonStyle(S37ButtonStyle(kind: .prominent))
            Button("NACA Sections Only") { app.buildAirfoilIndex() }
            if let error = lab.libraryError {
                Text(error).font(.caption2).foregroundStyle(S37.C.inkSecondary)
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
            polarControls(lab.wrappedValue)
        }
        .padding(8)
    }

    @ViewBuilder private func polarControls(_ lab: WingLabModel) -> some View {
        HStack {
            Picker("Sort", selection: Binding(get: { lab.librarySort }, set: { lab.librarySort = $0 })) {
                ForEach(AirfoilLibrary.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .disabled(lab.libraryPolars == nil)
            .frame(maxWidth: 150)
            Spacer()
            let re = lab.libraryRe
            Button(lab.libraryPolars == nil ? "Compute Polars" : "Recompute") { app.computeLibraryPolars() }
                .disabled(lab.polarsJob.map { !$0.status.isFinished } ?? false)
                .help(String(format: "NeuralFoil for every section at Re %.2g (the main element's), a few seconds", re))
        }
        .font(.caption)
        .controlSize(.small)
        if let p = lab.libraryPolars {
            let stale = abs(p.re - lab.libraryRe) / p.re > 0.2
            Text(String(format: "Polars at Re %.2g%@", p.re, stale ? ", the main element is now at a different Re" : ""))
                .font(.caption2).foregroundStyle(stale ? S37.C.clayInk : Color.secondary)
        }
        if let job = lab.polarsJob, !job.status.isFinished || job.status == .failed {
            JobInlineStatus(job: job)
        }
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
    var polar: AirfoilLibrary.Polars.Summary?
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
                    .font(.caption2.monospacedDigit()).foregroundStyle(S37.C.inkSecondary)
                if let p = polar {
                    Text(String(format: "Cl max %.2f at %.0f°  L/D %.0f", p.clMax, p.alphaClMax, p.ldMax) + (p.trusted ? "" : " ?"))
                        .font(.caption2.monospacedDigit()).foregroundStyle(p.trusted ? Color.secondary : S37.C.clayInk)
                        .help(p.trusted ? "NeuralFoil, this section alone" : "NeuralFoil is unsure here, or maximum lift is past 24°")
                }
            }
            Spacer()
            Button(action: toggleFavourite) { Image(systemName: favourite ? "star.fill" : "star") }
                .buttonStyle(.borderless)
                .foregroundStyle(favourite ? S37.C.ochre : .secondary)
            Button(action: add) { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
                .help("Or drag it onto the canvas")
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
        if let b = wing.rulesBox {
            pts += [SIMD2(b.minX, b.minY), SIMD2(b.maxX, b.maxY)]
            if let low = b.bands?.first { pts.append(SIMD2(b.minX, low.minY)) }  // the bands below the box too
        }
        if let g = wing.groundLine { pts.append(g.point) }  // keep the ground in view
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
    @State private var fitDuringDrag: Wing?  // the view holds its fit while a drag lasts
    @State private var hover: SIMD2<Double>?  // the pointer, wing frame (metres)

    enum DragKind { case move(Int), rotate(Int), resize(Int), pan }

    var body: some View {
        let lab = app.wingLab
        GeometryReader { geo in
            let m = WingMapping(wing: fitDuringDrag ?? lab.wing, size: geo.size, zoom: zoom, pan: pan)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(ctx, m, lab) }
                    .background(Color(nsColor: .textBackgroundColor))
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hover = m.world(p)
                        case .ended: hover = nil
                        }
                    }
                    .gesture(dragGesture(m, lab))
                    .onTapGesture(coordinateSpace: .local) { point in
                        if lab.replayIndex != nil {  // a click ends a time-lapse: back to the wing as drawn
                            lab.stopReplay()
                            return
                        }
                        lab.selection = lab.element(at: m.world(point))
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .onDeleteCommand {
                        if let i = lab.selection { lab.remove(i) }
                    }
                    .contextMenu {
                        if let i = lab.selection, lab.wing.elements.indices.contains(i) {
                            Button("Duplicate \(WingIssue.label(i))") { lab.duplicate(i) }
                            Button("Remove \(WingIssue.label(i)) (\(lab.wing.elements[i].airfoil.name))", role: .destructive) { lab.remove(i) }
                        } else {
                            Text("Click an element to select it first")
                        }
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
                Text("Showing").font(.system(size: 12, weight: .semibold)).foregroundStyle(S37.C.inkSecondary)
                Text((lab.pinned != nil && lab.replayIndex == nil ? "B: " : "") + lab.shownVersion)
                    .font(.caption.monospacedDigit()).lineLimit(1)
                if let a = lab.pinned, lab.replayIndex == nil {
                    Text("A: " + a.version).font(.caption).foregroundStyle(S37.C.chart6).lineLimit(1)
                }
            }
            .canvasPlate()
            .help("\"Edited\": changed since it was put there; Undo goes back")
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)  // the picker's height, so the row below clears it
            .overlay(alignment: .topTrailing) { CanvasModePicker() }
            HStack(alignment: .top, spacing: 6) {
            HStack(spacing: 6) {
                Text("Live estimate").font(.system(size: 12, weight: .semibold)).foregroundStyle(S37.C.inkSecondary)
                // NeuralFoil's viscous numbers once they are in; the panel method's lift until then.
                if let e = lab.estimate?.row(nearest: lab.wing.alpha), lab.liveStatus == nil {
                    Text(String(format: "Cl %.3f   Cd %.4f   L/D %.1f   α %.1f°", lab.wing.shownCl(e.cl), e.cd, abs(e.cl) / max(e.cd, 1e-9), lab.wing.alpha))
                        .font(.caption.monospacedDigit())
                    if e.separating == true {
                        // Past separation the estimate's drag is far too low (a stalled wing: Cd 0.09 here, 0.36 in RANS).
                        Text("separating: check with RANS").font(.caption.weight(.semibold)).foregroundStyle(S37.C.clayInk)
                            .help(e.why ?? "An element separates here.")
                    }
                } else if let r = lab.preview {
                    Text(String(format: "Cl %.3f (inviscid)   Cm %.3f   α %.1f°", lab.wing.shownCl(r.clTotal), r.cmTotal, lab.wing.alpha))
                        .font(.caption.monospacedDigit())
                }
                fieldControls(lab)
            }
            .canvasPlate()
                Spacer()
                HStack(spacing: 6) {
                    Button { zoom /= 1.25 } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { zoom *= 1.25 } label: { Image(systemName: "plus.magnifyingglass") }
                    Button("Fit") { zoom = 1; pan = .zero }
                }
                .canvasPlate()
            }
            .buttonStyle(.borderless)
            if let stage = lab.designStage {
                HStack(spacing: 8) {
                    Text("Setting up").font(.system(size: 12, weight: .semibold)).foregroundStyle(S37.C.sageInk)
                    Text(stage).font(.caption).lineLimit(1)
                    ProgressView().controlSize(.small)
                }
                .canvasPlate()
            }
            if let job = lab.optimiseJob, !job.status.isFinished {
                HStack(spacing: 8) {
                    Text("Optimising").font(.system(size: 12, weight: .semibold)).foregroundStyle(S37.C.sageInk)
                    ProgressView(value: job.progress, total: 100).frame(width: 120)
                    Text(job.progressMessage).font(.caption.monospacedDigit()).foregroundStyle(S37.C.inkSecondary).lineLimit(1)
                }
                .canvasPlate()
            }
            if let t = lab.replayTrial, let i = lab.replayIndex {
                HStack(spacing: 8) {
                    Text("Time-lapse").font(.system(size: 12, weight: .semibold)).foregroundStyle(S37.C.clayInk)
                    Text("trial \(t.number) (\(i + 1) of \(lab.replayOrder.count))").font(.caption.monospacedDigit())
                    if t.state == "fail" {
                        Text(t.reason ?? "failed").font(.caption).foregroundStyle(S37.C.critical).lineLimit(1)
                    } else if let load = t.load {
                        Text(String(format: "downforce Cl %.3f", load)).font(.caption.monospacedDigit())
                    }
                    if let best = lab.replayBestSoFar {
                        Text(String(format: "best so far %.4g", best)).font(.caption.monospacedDigit()).foregroundStyle(S37.C.inkSecondary)
                    }
                    Text("dashed: the wing as drawn").font(.caption2).foregroundStyle(S37.C.inkSecondary)
                }
                .canvasPlate()
            }
            if lab.pinned != nil, lab.replayIndex == nil {
                Text("Dashed slate: A, the pinned design. The wing you edit is B.").font(.caption2).foregroundStyle(S37.C.chart6)
                    .canvasPlate()
            }
            if let error = lab.previewError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(S37.C.clayInk)
                    .canvasPlate()
            }
            ForEach(Array(lab.wing.issues.enumerated()), id: \.offset) { _, issue in
                Label(issue.message, systemImage: "exclamationmark.octagon").font(.caption).foregroundStyle(S37.C.critical)
                    .canvasPlate()
            }
            if let r = lab.ransResult, lab.ransField != nil, lab.fieldOnCanvas {
                if !lab.fieldIsCurrent {
                    Text("Flow field hidden: the wing has changed since the last RANS run.")
                        .font(.caption2).foregroundStyle(S37.C.inkSecondary)
                        .canvasPlate()
                } else if !r.converged {
                    Text("This RANS run did not converge: the field is not a result.").font(.caption2).foregroundStyle(S37.C.clayInk)
                        .canvasPlate()
                }
            }
            Spacer()
            if let scalar = shownScalar(lab) {
                Group {
                    if lab.showChange, let change = lab.changeImage(scalar.key) {
                        ChangeColorbar(name: scalar.name, limit: change.limit)
                    } else {
                        FieldColorbar(scalar: scalar)
                    }
                }
                .canvasPlate()
            }
            Text("Drop an airfoil to add or swap an element. Drag to move; round handle turns, square resizes.")
                .font(.caption2).foregroundStyle(S37.C.inkSecondary)
                .canvasPlate()
        }
        .padding(6)
    }

    /// The scalar on the canvas, if the field is shown.
    private func shownScalar(_ lab: WingLabModel) -> WingField.Scalar? {
        guard lab.fieldOnCanvas, lab.fieldIsCurrent, let f = lab.ransField else { return nil }
        return f.scalars.first { $0.key == lab.fieldScalar } ?? f.scalars.first
    }

    /// Which RANS scalar to show behind the wing, streamlines, the value under the pointer.
    @ViewBuilder private func fieldControls(_ lab: WingLabModel) -> some View {
        if let f = lab.ransField, let r = lab.ransResult {
            Picker("Field", selection: Binding(get: { lab.fieldOnCanvas ? lab.fieldScalar : "" },
                                               set: { key in
                                                   lab.fieldOnCanvas = !key.isEmpty
                                                   if !key.isEmpty { lab.fieldScalar = key }
                                               })) {
                Text("Off").tag("")
                ForEach(f.scalars) { Text($0.name).tag($0.key) }
            }
            .pickerStyle(.menu).fixedSize().font(.caption)
            .disabled(!lab.fieldIsCurrent)
            .help("The last RANS run's flow over the plane, behind the wing")
            if lab.canShowChange {
                Toggle("Change from A", isOn: Binding(get: { lab.showChange }, set: { lab.showChange = $0 }))
                    .toggleStyle(.checkbox).font(.caption)
                    .help("B's field minus A's: blue where it fell, red where it rose, white where it held")
            }
            if let scalar = shownScalar(lab) {
                Toggle("Streamlines", isOn: Binding(get: { lab.showStreamlines }, set: { lab.showStreamlines = $0 }))
                    .toggleStyle(.checkbox).font(.caption)
                if let p = hover, let v = f.value(scalar.key, at: r.toRun(p)) {
                    Text(String(format: "%@ %.3f at %.0f, %.0f mm", scalar.name, v, p.x * 1000, p.y * 1000))
                        .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ m: WingMapping, _ lab: WingLabModel) {
        if let replay = lab.replayWing {
            drawReplay(ctx, m, lab, replay)
            return
        }
        let onField = shownScalar(lab) != nil
        if onField, let r = lab.ransResult, let f = lab.ransField { drawField(ctx, m, lab, r, f) }
        if let a = lab.pinned {
            for e in a.wing.elements {
                let path = Self.outline(e, m)
                ctx.fill(path, with: .color(S37.C.chart6.opacity(0.08)))
                ctx.stroke(path, with: .color(S37.C.chart6.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
            }
        }
        let wing = lab.wing
        let flagged = Set(wing.issues.filter { $0.kind != .outsideRules }.flatMap(\.elements))
        let outside = Set(wing.issues.filter { $0.kind == .outsideRules }.flatMap(\.elements))
        if let b = wing.rulesBox {
            let a = m.view(SIMD2(b.minX, b.maxY)), c = m.view(SIMD2(b.maxX, b.minY))
            let rect = CGRect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y)
            // Rear on a car: the T8.2.2 width bands, the ones too narrow for this span shaded
            for band in b.bands ?? [] {
                let p = m.view(SIMD2(b.minX, band.maxY)), q = m.view(SIMD2(b.maxX, band.minY))
                let r = CGRect(x: p.x, y: p.y, width: q.x - p.x, height: q.y - p.y)
                let narrow = wing.span > band.maxSpan + 1e-6
                if narrow { ctx.fill(Path(r), with: .color(S37.C.clayWash)) }
                var edge = Path()
                edge.move(to: CGPoint(x: r.minX, y: r.maxY))
                edge.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                ctx.stroke(edge, with: .color(S37.C.chart6.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
                ctx.draw(Text("≤ \(Int((band.maxSpan * 1000).rounded())) mm span").font(.caption2)
                            .foregroundStyle(narrow ? S37.C.clayInk : S37.C.chart6),
                         at: CGPoint(x: r.maxX - 60, y: r.midY))
            }
            ctx.stroke(Path(rect), with: .color(S37.C.chart6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            ctx.draw(Text("Rules box").font(.caption2).foregroundStyle(S37.C.chart6), at: CGPoint(x: rect.minX + 30, y: rect.minY - 8))
        }
        if let g = wing.groundLine {
            // The ground, along the flow, hatched underneath.
            let a = m.view(g.point - 5 * g.direction), b = m.view(g.point + 5 * g.direction)
            var line = Path()
            line.move(to: a)
            line.addLine(to: b)
            ctx.stroke(line, with: .color(.secondary), lineWidth: 1.5)
            var hatch = Path()
            for k in stride(from: -60, through: 60, by: 1) {
                let p0 = m.view(g.point + Double(k) * 0.02 * g.direction)
                hatch.move(to: p0)
                hatch.addLine(to: CGPoint(x: p0.x - 6, y: p0.y + 6))
            }
            ctx.stroke(hatch, with: .color(.secondary.opacity(0.5)), lineWidth: 0.8)
            ctx.draw(Text(String(format: "Ground, %.0f mm below", (wing.rideHeight ?? 0) * 1000)).font(.caption2).foregroundStyle(S37.C.inkSecondary),
                     at: CGPoint(x: m.view(g.point).x, y: m.view(g.point).y + 14))
        }
        for (i, e) in wing.elements.enumerated() {
            let pts = e.placed()
            var path = Path()
            for (k, p) in pts.enumerated() {
                if k == 0 { path.move(to: m.view(p)) } else { path.addLine(to: m.view(p)) }
            }
            path.closeSubpath()
            let selected = lab.selection == i
            let colour: Color = flagged.contains(i) ? S37.C.critical : (outside.contains(i) ? S37.C.chart6 : (selected ? S37.C.sage : S37.C.inkTertiary))
            // Over the field the elements are solid, so the wing reads against the colours.
            ctx.fill(path, with: onField ? GraphicsContext.Shading.color(Color(white: selected ? 0.7 : 0.55))
                                     : GraphicsContext.Shading.color(colour.opacity(selected ? 0.35 : 0.2)))
            ctx.stroke(path, with: .color(colour), lineWidth: selected ? 2 : 1.2)
            ctx.draw(Text(WingIssue.label(i)).font(.caption2).foregroundStyle(S37.C.inkSecondary),
                     at: m.view(e.leadingEdge + SIMD2(0, (e.inverted ? 1 : -1) * 0.02)))
            if selected {
                let le = m.view(e.leadingEdge), te = m.view(e.trailingEdge)
                let beyond = m.view(e.trailingEdge + 0.12 * e.chord * e.chordDirection)
                ctx.fill(Path(ellipseIn: CGRect(x: le.x - 4, y: le.y - 4, width: 8, height: 8)), with: .color(S37.C.sage))
                ctx.stroke(Path(ellipseIn: CGRect(x: te.x - 7, y: te.y - 7, width: 14, height: 14)), with: .color(S37.C.sage), lineWidth: 2)
                ctx.fill(Path(CGRect(x: beyond.x - 6, y: beyond.y - 6, width: 12, height: 12)), with: .color(S37.C.sage))
            }
        }
    }

    /// The RANS field behind the wing: the scalar as an image placed in the
    /// wing's frame (the run's frame turned back), then the streamlines.
    private func drawField(_ ctx: GraphicsContext, _ m: WingMapping, _ lab: WingLabModel, _ r: WingRansResult, _ f: WingField) {
        guard let scalar = shownScalar(lab) else { return }
        let t = -(r.frameTurn ?? 0) * .pi / 180, c = cos(t), sn = sin(t), s = m.scale
        let w = f.window.x1 - f.window.x0, h = f.window.y1 - f.window.y0
        let change = lab.showChange ? lab.changeImage(scalar.key)?.image : nil
        if let image = change ?? lab.fieldImage(scalar.key) {
            var g = ctx
            if !r.converged { g.opacity = 0.5 }
            // Image space (metres from the window's top left, y down) to the view:
            // into the run's frame, turned into the wing's, then the canvas mapping.
            let tx = m.origin.x + s * (c * f.window.x0 - sn * f.window.y1)
            let ty = m.origin.y - s * (sn * f.window.x0 + c * f.window.y1)
            g.concatenate(CGAffineTransform(a: s * c, b: -s * sn, c: s * sn, d: s * c, tx: tx, ty: ty))
            g.draw(Image(decorative: image, scale: 1), in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        if lab.showStreamlines {
            var path = Path()
            for line in f.streamlines where line.count > 1 {
                path.move(to: m.view(r.toWing(line[0])))
                for p in line.dropFirst() { path.addLine(to: m.view(r.toWing(p))) }
            }
            ctx.stroke(path, with: .color(.black.opacity(0.4)), lineWidth: 0.6)
        }
    }

    /// A time-lapse frame: the trial's wing, over the current wing as a dashed ghost.
    private static func outline(_ e: WingElement, _ m: WingMapping) -> Path {
        var path = Path()
        for (k, p) in e.placed().enumerated() {
            if k == 0 { path.move(to: m.view(p)) } else { path.addLine(to: m.view(p)) }
        }
        path.closeSubpath()
        return path
    }

    private func drawReplay(_ ctx: GraphicsContext, _ m: WingMapping, _ lab: WingLabModel, _ replay: Wing) {
        func outline(_ e: WingElement) -> Path { Self.outline(e, m) }
        for e in lab.wing.elements {
            ctx.stroke(outline(e), with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        let failed = lab.replayTrial?.state == "fail"
        let colour: Color = failed ? S37.C.critical : S37.C.clayInk
        for e in replay.elements {
            let path = outline(e)
            ctx.fill(path, with: .color(colour.opacity(0.3)))
            ctx.stroke(path, with: .color(colour), lineWidth: 1.6)
        }
    }

    private func dragGesture(_ m: WingMapping, _ lab: WingLabModel) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if drag == nil {
                    fitDuringDrag = lab.wing
                    drag = hit(v.startLocation, m, lab)
                    switch drag {
                    case .move(let i), .rotate(let i), .resize(let i):
                        lab.selection = i
                        gestureStart = lab.wing.elements[i]
                        let verb = if case .move = drag { "Move" } else if case .rotate = drag { "Turn" } else { "Resize" }
                        lab.beginGesture("\(verb) \(WingIssue.label(i))")
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
                fitDuringDrag = nil
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
            ResultsSummary()
            Divider()
            S37Segmented(options: WingLabModel.ResultsTab.allCases.map { ($0, $0.rawValue) }, selection: $lab.resultsTab)
                .fixedSize()
                .padding([.top, .horizontal], 8)
            switch lab.resultsTab {
            case .pressure, .polar:
                // Side by side when the pane is wide enough; otherwise the tab picks one
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        CpPlot().frame(minWidth: 420)
                        Rectangle().fill(S37.C.separator).frame(width: 1)
                        PolarPlots().frame(minWidth: 420)
                    }
                    if lab.resultsTab == .pressure { CpPlot() } else { PolarPlots() }
                }
            case .estimate: EstimateResults()
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
                        .font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
                    if rows.contains(where: { !$0.trusted }) {
                        Label("Hollow points: NeuralFoil is not confident there (usually past stall).", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(S37.C.clayInk)
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
                    .chartForegroundStyleScale(range: S37.series)
                    .chartYScale(domain: 0...1)
                }
                if let i = lab.polarElement, lab.wing.elements.indices.contains(i),
                   let here = polar.row(near: lab.wing.elements[i].angle + lab.wing.alpha * (lab.wing.elements[i].inverted ? -1 : 1)) {
                    HStack {
                        Text(String(format: "At this element's angle (%.1f°): Cl %.3f, Cd %.4f, L/D %.0f, turbulent from %.0f%% chord on the suction side",
                                    here.alpha, here.cl, here.cd, here.liftToDrag, here.transitionSuction * 100))
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            .padding(8)
        } else if let job = lab.polarJob, !job.status.isFinished {
            ProgressView("Running NeuralFoil…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let lab = app.wingLab
            VStack(spacing: 8) {
                Text("No polar yet: NeuralFoil runs one element's section over a range of angles, a few seconds.")
                    .foregroundStyle(S37.C.inkSecondary)
                if let i = lab.selection, lab.wing.elements.indices.contains(i) {
                    Button("Run polar of \(WingIssue.label(i))") {
                        lab.solver = .quickViscous
                        app.runWingPolar()
                    }
                    .buttonStyle(S37ButtonStyle())
                } else {
                    Text("Click an element on the canvas first.").font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CFDResults: View {
    @Environment(AppState.self) private var app

    /// A is pinned but A and B do not both have a field yet: run them together.
    @ViewBuilder private func compareBar(_ lab: WingLabModel) -> some View {
        let running = [lab.pinnedRansJob, lab.ransJob].contains { $0.map { !$0.status.isFinished } ?? false }
        HStack(spacing: 8) {
            Text("A and B side by side: their flow fields and the change between them (Field, Change from A).")
                .font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
            Spacer()
            if running {
                ProgressView().controlSize(.small)
                Text("running both…").font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
            } else {
                Button("Run CFD on A and B") { app.runCFDOnBoth() }
                    .disabled(app.settings.su2Executable == nil)
                    .help("Both at once on the quick mesh (within 0.3% of medium): about a minute and a half")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
    }

    struct Point: Identifiable {
        let id: Int
        let element: String
        let x: Double
        let minusCp: Double
        var run = 0
    }

    var body: some View {
        let lab = app.wingLab
        VStack(spacing: 0) {
            if let a = lab.pinned, a.field == nil || !lab.fieldIsCurrent { compareBar(lab) }
            if let sweep = lab.sweep {
                SweepStrip(sweep: sweep)
            } else if case let points = app.ransPolar, !points.isEmpty {
                ransRuns(points, lab)
            }
            run(lab)
        }
    }

    /// The RANS runs of this wing so far, one point per wing angle.
    @ViewBuilder private func ransRuns(_ points: [PolarCharts.Point], _ lab: WingLabModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("RANS runs of this wing").font(.caption).bold()
                Text(points.count == 1
                     ? "One angle so far: run RANS at other wing angles (or a sweep, in free air) to draw the curves."
                     : "\(points.count) wing angles, the latest run at each, \(lab.turbulenceModel.rawValue) model.")
                    .font(.caption2).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
                if points.contains(where: { !$0.good }) {
                    Text("Rust points did not converge: not results.").font(.caption2).foregroundStyle(S37.C.chart5)
                }
            }
            .frame(width: 260, alignment: .leading)
            PolarCharts(points: points.map { var p = $0; p.cl = lab.wing.shownCl(p.cl); return p }, mark: lab.ransResult?.alpha)
        }
        .padding(8)
        .frame(height: 170)
        Divider()
    }

    @ViewBuilder private func run(_ lab: WingLabModel) -> some View {
        if let r = lab.ransResult {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if r.converged && r.averaged == true {
                        Label("Converged on average", systemImage: "checkmark.seal").foregroundStyle(S37.C.sageInk)
                        Text(r.reason ?? "").font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    } else if r.converged {
                        Label("Converged", systemImage: "checkmark.seal").foregroundStyle(S37.C.sageInk)
                    } else {
                        Label("Not converged: not a result", systemImage: "xmark.octagon").foregroundStyle(S37.C.critical)
                        Text(r.reason ?? "").font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("\(r.modelName), \(r.meshLevel) mesh, Re \(String(format: "%.0f", r.re))").font(.caption)
                    MeshAdviceView(advice: app.meshAdvice(r), level: r.meshLevel, running: lab.ransJob.map { !$0.status.isFinished } ?? false) { app.runCFDOnMesh($0) }
                    Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 2) {
                        GridRow {
                            Text("").gridColumnAlignment(.leading)
                            Text("Cl").bold()
                            Text("Cd").bold()
                        }
                        ForEach(Array(r.elements.enumerated()), id: \.offset) { i, e in
                            GridRow {
                                Text(WingIssue.label(i))
                                Text(e.cl.map { String(format: "%.3f", lab.wing.shownCl($0)) } ?? "–")
                                Text(e.cd.map { String(format: "%.4f", $0) } ?? "–")
                            }
                        }
                        GridRow {
                            Text("Total").bold()
                            Text(String(format: "%.3f", lab.wing.shownCl(r.cl))).bold()
                            Text(String(format: "%.4f", r.cd)).bold()
                        }
                    }
                    .font(.caption.monospacedDigit())
                    Text(String(format: "L/D %.1f · %ld iterations · residual down %.1f orders", r.liftToDrag, r.iterations, r.residualDrop))
                        .font(.caption2).foregroundStyle(S37.C.inkSecondary)
                    Text("\(r.mesh.cells) cells: \(r.mesh.quads) quads (\(r.mesh.layers) wall layers), \(r.mesh.triangles) triangles")
                        .font(.caption2).foregroundStyle(S37.C.inkSecondary)
                    if let attempts = r.attempts, attempts.count > 1 {
                        Text("Diverged at CFL \(attempts.dropLast().map { String(format: "%g", $0.cfl) }.joined(separator: ", ")); finished at CFL \(String(format: "%g", r.cfl ?? 0)).")
                            .font(.caption2).foregroundStyle(S37.C.inkSecondary)
                    }
                    if r.scheme == "fds" {
                        Text("Finished only on the upwind fallback scheme, which is more dissipative: drag reads high (about 40% at 10° on NACA 0012). Lift is fine for comparisons.")
                            .font(.caption2).foregroundStyle(S37.C.clayInk).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if let folder = lab.ransFolder, let field = r.field {
                            Button("Show Flow Field") { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(field)]) }
                                .help("flow.vtu, for ParaView")
                        }
                    }
                    .buttonStyle(.link).font(.caption)
                }
                .frame(width: 260, alignment: .leading)
                .scrollableColumn()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Surface Cp").font(.caption).bold()
                        Spacer()
                        Text(lab.ransField == nil ? "No flow field for this run (from before the field view, or the flow file was not written)."
                             : lab.fieldIsCurrent ? "The flow field is on the canvas (Field, top left)."
                             : "The wing has changed since this run, so its flow field is not on the canvas.")
                            .font(.caption2).foregroundStyle(S37.C.inkSecondary)
                    }
                    Chart(points(r)) { p in
                        LineMark(x: .value("x (mm)", p.x), y: .value("−Cp", p.minusCp), series: .value("Series", "\(p.element) \(p.run)"))
                            .foregroundStyle(by: .value("Element", p.element))
                    }
                    .chartXAxisLabel("x (mm)").chartYAxisLabel("−Cp")
                    .chartYScale(domain: CpSpikes.domain(points(r).map(\.minusCp)))
                    .chartXScale(domain: CpSpikes.domain(points(r).map(\.x)))
                    .chartForegroundStyleScale(range: S37.series)
                }
                .opacity(r.converged ? 1 : 0.35)
            }
            .padding(8)
        } else if let job = [lab.ransJob, lab.sweepJob].compactMap({ $0 }).first(where: { !$0.status.isFinished }) {
            VStack {
                ProgressView(value: job.progress, total: 100)
                Text(job.progressMessage).font(.caption)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Text("No CFD yet: a 2D RANS run of the whole wing with SU2, 2 to 5 minutes.").foregroundStyle(S37.C.inkSecondary)
                if app.settings.su2Executable == nil {
                    Text("Needs SU2: install it under Solvers, RANS CFD.").font(.caption).foregroundStyle(S37.C.clayInk)
                }
                Button("Run CFD") {
                    app.wingLab.solver = .rans
                    app.runCFD()
                }
                .disabled(app.settings.su2Executable == nil || app.wingLab.wing.elements.isEmpty
                          || !app.wingLab.wing.issues.filter { $0.kind != .outsideRules }.isEmpty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func points(_ r: WingRansResult) -> [Point] {
        var out: [Point] = []
        var id = 0
        for (i, s) in r.surface.enumerated() {
            let sides = s.side ?? Array(repeating: "", count: s.x.count)
            let ks = s.x.indices.filter { $0 < s.cp.count }
            for side in Set(ks.map { sides[$0] }) {
                let mine = ks.filter { sides[$0] == side }
                let runs = CpSpikes.runs(x: mine.map { s.x[$0] * 1000 }, y: mine.map { -s.cp[$0] })
                for (k, run) in zip(mine, runs) {
                    guard let run else { continue }
                    let series = side.isEmpty ? WingIssue.label(i) : "\(WingIssue.label(i)) \(side)"
                    out.append(Point(id: id, element: series, x: s.x[k] * 1000, minusCp: -s.cp[k], run: run))
                    id += 1
                }
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
        let design: String
        let x: Double
        let minusCp: Double
        var run = 0
    }

    var body: some View {
        let lab = app.wingLab
        let points = makePoints(lab)
        VStack(alignment: .leading, spacing: 2) {
            Text("Surface pressure, inviscid (−Cp up)").font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
            if points.isEmpty {
                Rectangle().fill(.quaternary)
            } else {
                Chart(points) { p in mark(p) }
                    .chartYScale(domain: CpSpikes.domain(points.map(\.minusCp)))
                    .chartXScale(domain: CpSpikes.domain(points.map(\.x)))
                    .chartLineStyleScale(domain: ["B", "A"], range: Self.lineStyles)
                    .chartForegroundStyleScale(range: S37.series)
                    .chartXAxisLabel("x (mm)")
            }
        }
        .padding(8)
    }

    /// The wing being edited solid, the pinned design A dashed.
    private static let lineStyles = [StrokeStyle(lineWidth: 1.2), StrokeStyle(lineWidth: 1, dash: [4, 3])]

    private func mark(_ p: Point) -> some ChartContent {
        let series: String = p.design + " " + p.element + " \(p.run)"
        return LineMark(x: .value("x (mm)", p.x), y: .value("−Cp", p.minusCp), series: .value("Series", series))
            .foregroundStyle(by: .value("Element", p.element))
            .lineStyle(by: .value("Design", p.design))
    }

    private func makePoints(_ lab: WingLabModel) -> [Point] {
        var out: [Point] = []
        // A (pinned) first, dashed, so the wing being edited draws on top.
        if let a = lab.pinned, let r = a.preview { add(a.wing, r, "A", to: &out) }
        if let r = lab.preview { add(lab.wing, r, "B", to: &out) }
        // With nothing pinned there is only one design: no legend entry for it.
        return out
    }

    private func add(_ wing: Wing, _ r: PanelSolution, _ design: String, to out: inout [Point]) {
        guard r.cp.count == wing.elements.count else { return }
        for (i, e) in wing.elements.enumerated() {
            let pts = e.placed()
            let name = "\(WingIssue.label(i)) upper", lower = "\(WingIssue.label(i)) lower"
            guard pts.count > 1 else { continue }
            let half = (pts.count - 1) / 2
            // The two surfaces as separate series so the line does not wrap round the nose.
            for (surface, ks) in [(name, Array(0...half)), (lower, Array((half + 1)..<pts.count))] {
                let ks = ks.filter { $0 < r.cp[i].count }
                let runs = CpSpikes.runs(x: ks.map { pts[$0].x * 1000 }, y: ks.map { -r.cp[i][$0] })
                for (k, run) in zip(ks, runs) {
                    guard let run else { continue }
                    out.append(Point(id: out.count, element: surface, design: design, x: pts[k].x * 1000, minusCp: -r.cp[i][k], run: run))
                }
            }
        }
    }
}

// MARK: Inspector

struct WingInspector: View {
    @Environment(AppState.self) private var app
    @State private var sentNote: String?
    @State private var modelHelp = false

    var body: some View {
        @Bindable var lab = app.wingLab
        let wing = lab.wing
        ScrollView {
          VStack(alignment: .leading, spacing: S37.Space.s4) {
            DesignCard()
            S37Section("Elements") {
                ForEach(Array(wing.elements.enumerated()), id: \.element.id) { i, e in
                    HStack {
                        Text(WingIssue.label(i)).fontWeight(.semibold).frame(width: 50, alignment: .leading)
                        Text(e.airfoil.name).lineLimit(1)
                        Spacer()
                        if lab.selection == i { Image(systemName: "checkmark").foregroundStyle(S37.C.sageInk) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { lab.selection = i }
                    .contextMenu {
                        Button("Duplicate \(WingIssue.label(i))") { lab.duplicate(i) }
                        Button("Remove \(WingIssue.label(i))", role: .destructive) { lab.remove(i) }
                    }
                }
                Toggle("Inverted for downforce", isOn: Binding(
                    get: { wing.elements.first?.inverted ?? true },
                    set: { on in lab.edit(on ? "Invert Wing" : "Turn Wing Upright") { w in for k in w.elements.indices { w.elements[k].inverted = on } } }))
                HStack(spacing: S37.Space.s2) {
                    Toggle("Snap", isOn: $lab.snap)
                    Toggle("Lock angle", isOn: $lab.lockAngle)
                    Toggle("Lock chord", isOn: $lab.lockChord)
                }
                .toggleStyle(S37ToggleButtonStyle())
                .controlSize(.small)
                .padding(.vertical, S37.Space.s1)
            }

            if let i = lab.selection, wing.elements.indices.contains(i) {
                elementSection(lab, i)
            }

            S37Section("Wing", footer: app.car.setup != nil
                       ? "The car's rules box for the \(wing.rulesFor == .front ? "front" : "rear") wing, from the base car." : nil) {
                NumberField(label: "Minimum gap", unit: "mm", value: mm({ wing.minGap }, { v in lab.edit("Change Minimum Gap") { $0.minGap = v } }))
                Toggle("Rules box", isOn: Binding(
                    get: { wing.rulesBox != nil },
                    set: { on in
                        let box = app.rulesBox(for: wing.rulesFor)  // from the last base car when this project has none
                        lab.edit(on ? "Turn On Rules Box" : "Turn Off Rules Box") { $0.rulesBox = on ? box : nil }
                    }))  // off by default, on a car too
                if let box = wing.rulesBox {
                    S37Segmented(options: [(WingPosition.front, "Front wing"), (.rear, "Rear wing")],
                                 selection: Binding(get: { wing.rulesFor }, set: { p in lab.edit("Change Rules Box") { $0.switchRules(to: p) } }))
                        .fixedSize()
                    NumberField(label: "Box from x", unit: "mm", value: mm({ box.minX }, { v in lab.edit("Change Box from x") { $0.rulesBox?.minX = v } }))
                        .disabled(app.car.setup != nil)
                    NumberField(label: "Box to x", unit: "mm", value: mm({ box.maxX }, { v in lab.edit("Change Box to x") { $0.rulesBox?.maxX = v } }))
                        .disabled(app.car.setup != nil)
                    NumberField(label: "Box from y", unit: "mm", value: mm({ box.minY }, { v in lab.edit("Change Box from y") { $0.rulesBox?.minY = v } }))
                        .disabled(app.car.setup != nil)
                    NumberField(label: "Box to y", unit: "mm", value: mm({ box.maxY }, { v in lab.edit("Change Box to y") { $0.rulesBox?.maxY = v } }))
                        .disabled(app.car.setup != nil)
                }
            }

            flowSection(lab)
            optimiseSection(lab)
            solversSection(lab)
            carSection
            lapSimSection(lab)

            S37Section("Export", footer: "Points in mm, in the wing's frame, ready for CATIA.") {
                HStack(spacing: S37.Space.s3) {
                    Button("Elements as .dat…") { app.exportWingDat() }
                    Button("Points as CSV…") { app.exportWingCSV() }
                    Button("Report as PDF…") { app.exportWingReport() }
                }
                .buttonStyle(S37ButtonStyle())
                .controlSize(.small)
                .padding(.vertical, S37.Space.s1)
            }

            DisclosureGroup("How it's calculated") {
                VStack(alignment: .leading, spacing: S37.Space.s3) {
                    Text("Flow is shared by every solver. Ncrit 9 is a clean wind tunnel; lower (4 to 6) for the turbulent air behind a car, which trips the boundary layer sooner. The ground moves with the flow, as on track or a rolling road: an image wing in the quick solvers, a slip wall in RANS. Over a ground a RANS angle sweep meshes each angle again, so it takes longer.")
                    Text("ClA = −Cl × span × total chord × 3D factor (positive for downforce). Estimated, the factor is lifting-line theory on the aspect ratio raised by the endplates (Hoerner), AR_eff / (AR_eff + 2), and CdA gains induced drag CL² / (π AR_eff): a first number for a finite wing, not a 3D solution. The Lap Sim numbers use converged CFD if there is one, else the quick estimate, else the inviscid preview (optimistic) with the Cd typed in.")
                    Text("Optimise runs the study for hand-picked variables (Design runs the whole chain). Wings that break the minimum gap or the rules box are never run; trials that fail or don't converge are recorded as failed and the study carries on. Stopping is safe: Resume picks up where it left off.")
                    Text("The rules box limits come from data/rules/fs2027_aero.json (FS and FSUK). Without a base car the wing sits in its own plane and the box is wherever you put it.")
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, S37.Space.s2)
            }
            .font(.system(size: 14, weight: .semibold))
          }
          .padding(S37.Space.s3)
        }
    }

    @ViewBuilder private func elementSection(_ lab: WingLabModel, _ i: Int) -> some View {
        let e = lab.wing.elements[i]
        S37Section("\(WingIssue.label(i)): \(e.airfoil.name)",
                   footer: i > 0 ? "Gap: from the trailing edge in front to this surface. Overlap: positive when this leading edge is ahead of that trailing edge." : nil) {
            NumberField(label: "Chord", unit: "mm", digits: 1, value: mm({ e.chord }, { v in lab.edit("Change Chord") { $0.elements[i].chord = max(v, 0.005) } }))
            NumberField(label: "Angle of attack", unit: "°", value: Binding(get: { e.angle }, set: { v in lab.edit("Change Angle of Attack") { $0.elements[i].angle = v } }))
            NumberField(label: "Leading edge x", unit: "mm", value: mm({ e.leadingEdge.x }, { v in lab.edit("Change Leading Edge x") { $0.elements[i].leadingEdge.x = v } }))
            NumberField(label: "Leading edge y", unit: "mm", value: mm({ e.leadingEdge.y }, { v in lab.edit("Change Leading Edge y") { $0.elements[i].leadingEdge.y = v } }))
            if i > 0 {
                NumberField(label: "Gap", unit: "mm", value: mm({ lab.wing.gap(of: i) ?? 0 }, { v in lab.edit("Change Gap") { $0.setGap(v, of: i) } }))
                NumberField(label: "Overlap", unit: "mm", value: mm({ lab.wing.overlap(of: i) ?? 0 }, { v in lab.edit("Change Overlap") { $0.setOverlap(v, of: i) } }))
            }
            if let r = lab.preview, r.cl.indices.contains(i) {
                LabeledContent("Cl (inviscid)", value: String(format: "%.3f", lab.wing.shownCl(r.cl[i])))
            }
            HStack(spacing: S37.Space.s3) {
                Button("Duplicate \(WingIssue.label(i))") { lab.duplicate(i) }
                Button("Remove \(WingIssue.label(i))", role: .destructive) { lab.remove(i) }
            }
            .buttonStyle(S37ButtonStyle())
            .controlSize(.small)
            .padding(.vertical, S37.Space.s1)
        }
    }

    /// What every solver shares: the wing's angle to the flow and the air.
    @ViewBuilder private func flowSection(_ lab: WingLabModel) -> some View {
        let wing = lab.wing
        S37Section("Flow", footer: "Ncrit 9 is a clean tunnel; 4 to 6 for the air behind a car.") {
            NumberField(label: "Wing angle to the flow", unit: "°", value: Binding(
                get: { wing.alpha }, set: { v in lab.edit { $0.alpha = v } }))
            NumberField(label: "Speed", unit: "m/s", value: Binding(get: { wing.speed }, set: { v in lab.edit("Change Speed") { $0.speed = max(v, 0.1) } }))
            NumberField(label: "Air density", unit: "kg/m³", value: Binding(get: { wing.rho }, set: { v in lab.edit("Change Air Density") { $0.rho = max(v, 0.01) } }))
            NumberField(label: "Viscosity (×10⁻⁵)", unit: "Pa s", value: Binding(
                get: { wing.mu * 1e5 }, set: { v in lab.edit { $0.mu = max(v, 0.01) * 1e-5 } }))
            ForEach(Array(wing.elements.enumerated()), id: \.element.id) { i, e in
                LabeledContent("Reynolds number, \(WingIssue.label(i))",
                               value: wing.reynolds(chord: e.chord).formatted(.number.precision(.fractionLength(0))))
            }
            NumberField(label: "Turbulence (Ncrit)", value: Binding(get: { lab.nCrit }, set: { lab.nCrit = min(max($0, 1), 14) }))
            Toggle("Ground (a front wing)", isOn: Binding(
                get: { wing.rideHeight != nil }, set: { on in lab.edit { $0.rideHeight = on ? 0.05 : nil } }))
            if wing.rideHeight != nil {
                NumberField(label: "Ride height (lowest point)", unit: "mm", value: Binding(
                    get: { (wing.rideHeight ?? 0) * 1000 }, set: { v in lab.edit { $0.rideHeight = max(v, 1) / 1000 } }))
            }
        }
    }

    @ViewBuilder private func solversSection(_ lab: WingLabModel) -> some View {
        S37Section("Solvers") {
            FittingPicker(title: "Solver", options: WingLabModel.Solver.allCases.map { ($0, "\($0.rawValue) · \($0.accuracy)") },
                          selection: Binding(get: { lab.solver }, set: { lab.solver = $0 })) {
                ForEach(WingLabModel.Solver.allCases) { Text("\($0.rawValue) · \($0.accuracy)").tag($0) }
            }
            Text(lab.solver.purpose).font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
            switch lab.solver {
            case .live:
                previewControls(lab)
                quickEstimateControls(lab)
            case .quickViscous:
                quickViscousControls(lab)
            case .rans:
                ransControls(lab)
            }
        }
    }

    @ViewBuilder private func quickViscousControls(_ lab: WingLabModel) -> some View {
        NumberField(label: "From α", unit: "°", value: Binding(get: { lab.alphaStart }, set: { lab.alphaStart = $0 }))
        NumberField(label: "To α", unit: "°", value: Binding(get: { lab.alphaEnd }, set: { lab.alphaEnd = $0 }))
        NumberField(label: "Step", unit: "°", value: Binding(get: { lab.alphaStep }, set: { lab.alphaStep = max($0, 0.1) }))
        if let i = lab.selection, lab.wing.elements.indices.contains(i) {
            Button("Polar of \(WingIssue.label(i)) (\(lab.wing.elements[i].airfoil.name))") { app.runWingPolar() }
                .disabled(lab.polarJob.map { !$0.status.isFinished } ?? false)
        } else {
            Text("Select an element.").foregroundStyle(S37.C.inkSecondary)
        }
        if let job = lab.polarJob, !job.status.isFinished || job.status == .failed {
            JobInlineStatus(job: job)
        }
    }

    @ViewBuilder private func ransControls(_ lab: WingLabModel) -> some View {
        Picker("Model", selection: Binding(get: { lab.turbulenceModel }, set: { lab.turbulenceModel = $0 })) {
            ForEach(WingLabModel.TurbulenceModel.allCases) { Text("\($0.title) · \($0.accuracy)").tag($0) }
        }
        Text(lab.turbulenceModel.purpose).font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
        Button { modelHelp.toggle() } label: { Label("More", systemImage: "questionmark.circle") }
            .popover(isPresented: $modelHelp, arrowEdge: .trailing) { ModelHelpView() }
        Picker("Mesh", selection: Binding(get: { lab.meshLevel }, set: { lab.meshLevel = $0 })) {
            Text("Quick · Rough").tag("quick")
            Text("Coarse · Fair").tag("coarse")
            Text("Medium · Good").tag("medium")
            Text("Fine · Best").tag("fine")
        }
        Toggle("Laminar zones from the quick viscous solver", isOn: Binding(get: { lab.predictTransition }, set: { lab.predictTransition = $0 }))
        Text("Laminar zones get a finer, flow-aligned wall mesh.")
            .font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
        if lab.turbulenceModel != .sa {
            NumberField(label: "Turbulence intensity", unit: "%", value: Binding(get: { lab.turbulenceIntensity }, set: { lab.turbulenceIntensity = max($0, 0.01) }))
        }
        let haveSU2 = app.settings.su2Executable != nil
        if !haveSU2 { su2Install(lab) }
        ransSweepControls(lab)
        Button("Run CFD") { app.runCFD() }
            .buttonStyle(S37ButtonStyle(kind: .prominent))
            .disabled(!haveSU2 || lab.wing.elements.isEmpty || !lab.wing.issues.filter { $0.kind != .outsideRules }.isEmpty
                      || [lab.ransJob, lab.sweepJob].contains { $0.map { !$0.status.isFinished } ?? false })
        if !lab.wing.issues.filter({ $0.kind != .outsideRules }).isEmpty {
            Text("Fix the overlapping or touching elements first.").font(.caption).foregroundStyle(S37.C.clayInk)
        }
        let needsSU2 = lab.ransJob.map { $0.status == .failed && ($0.message ?? "").contains("SU2 is not installed") } ?? false
        if let job = lab.ransJob, !job.status.isFinished || job.status == .failed {
            JobInlineStatus(job: job)
        }
        if let job = lab.sweepJob, !job.status.isFinished || job.status == .failed {
            JobInlineStatus(job: job)
        }
        if needsSU2 && haveSU2 {
            Text("SU2 is installed now: run it again.").font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
        }
        if haveSU2, let job = lab.su2Job {
            JobInlineStatus(job: job)
        }
    }

    /// One box of the variables grid: tick to search it.
    private func variableBox(_ lab: WingLabModel, _ kind: WingLabModel.DesignVariable.Kind, _ i: Int) -> some View {
        Toggle(isOn: Binding(get: { lab.variable(kind, of: i) != nil }, set: { _ in
            lab.toggleVariable(kind, of: i)
            if kind == .airfoil, lab.shortlists[i] == nil { app.findShortlists() }
        })) { EmptyView() }
            .toggleStyle(.checkbox).labelsHidden()
            .help("\(WingIssue.label(i)): search its \(kind.title.lowercased())")
    }

    @ViewBuilder private func optimiseSection(_ lab: WingLabModel) -> some View {
        let running = lab.optimiseJob.map { !$0.status.isFinished } ?? false
        S37Section("Optimise") {
            variablesGrid(lab, running: running)
            studyControls(lab, running: running)
        }
    }

    /// What to search: a row per element, a column per variable.
    @ViewBuilder private func variablesGrid(_ lab: WingLabModel, running: Bool) -> some View {
        HStack {
            Text("Search").font(.caption).bold()
            Spacer()
            Menu("Preset") {
                ForEach(WingLabModel.Preset.allCases) { preset in
                    Button(preset.rawValue) {
                        lab.apply(preset)
                        if preset.kinds.contains(.airfoil), lab.shortlists.isEmpty { app.findShortlists() }
                    }
                }
                Divider()
                Button("Clear") { lab.optimise.variables = [] }
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .disabled(running)
        let kinds = WingLabModel.DesignVariable.Kind.grid
        Grid(alignment: .center, horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Text("")
                ForEach(kinds, id: \.self) { Text($0.title).font(.caption2).foregroundStyle(S37.C.inkSecondary).lineLimit(1).minimumScaleFactor(0.7) }
            }
            ForEach(Array(lab.wing.elements.indices), id: \.self) { i in
                GridRow {
                    Text(WingIssue.label(i)).font(.caption).gridColumnAlignment(.leading)
                    ForEach(kinds, id: \.self) { kind in
                        if kind.applies(to: i) { variableBox(lab, kind, i) } else { Text("–").foregroundStyle(.tertiary) }
                    }
                }
            }
        }
        .disabled(running)
        if lab.wing.rideHeight != nil {
            Toggle("Ride height", isOn: Binding(get: { lab.variable(.height, of: 0) != nil }, set: { _ in lab.toggleVariable(.height, of: 0) }))
                .toggleStyle(.checkbox).disabled(running)
        }
        let sections = lab.optimise.variables.filter { $0.kind == .airfoil }
        if !sections.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections) { v in
                    let names = (v.choices ?? []).map { lab.airfoil($0)?.name ?? $0 }
                    Text("\(WingIssue.label(v.element)): " + (names.count > 1 ? names.joined(separator: ", ") : "finding sections…"))
                        .font(.caption2).foregroundStyle(S37.C.inkSecondary).lineLimit(2)
                }
                HStack {
                    Button("Find Sections Again") { app.findShortlists() }
                        .buttonStyle(.link).font(.caption)
                        .disabled(lab.shortlistJob.map { !$0.status.isFinished } ?? false)
                        .help("Rank the library again at each element's Reynolds number (after changing chords or speed)")
                    if let job = lab.shortlistJob, !job.status.isFinished { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    @ViewBuilder private func studyControls(_ lab: WingLabModel, running: Bool) -> some View {
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
        if lab.optimise.objective == .minLapTime {
            Text("Each trial is a lap of \(app.lapSim.track.kind.title) in car A with this wing, using Use in the Lap Sim's 3D settings.")
                .font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
        Picker("Each trial", selection: Binding(get: { lab.optimise.solver }, set: { lab.optimise.solver = $0 })) {
            Text("Estimate (tenths of a second)").tag("estimate")
            Text("RANS CFD (minutes)").tag("rans")
        }
        .disabled(running)
        HStack {
            let trials = Binding(get: { lab.optimise.trials }, set: { lab.optimise.trials = min(max($0, 2), 2000) })
            Text("Trials:")
            TextField("Trials", value: trials, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
            Stepper("Trials", value: trials, in: 2...2000, step: 10).labelsHidden()
            if lab.optimise.trials != lab.optimise.suggestedTrials {
                Button("Use \(lab.optimise.suggestedTrials)") { lab.optimise.trials = lab.optimise.suggestedTrials }
                    .buttonStyle(.link).font(.caption)
                    .help("About 25 quick-estimate trials a variable (\(lab.optimise.variables.count) ticked)")
            }
        }
        if lab.optimise.solver == "estimate" {
            Stepper(lab.optimise.checkBest == 0 ? "RANS check: off" : lab.optimise.checkBest == 1 ? "RANS check: the best"
                    : "RANS check: up to \(lab.optimise.checkBest) designs",
                    value: Binding(get: { lab.optimise.checkBest }, set: { lab.optimise.checkBest = $0 }), in: 0...10)
                .disabled(running)
            if lab.optimise.checkBest > 1 {
                Toggle("Stop at the first design RANS confirms", isOn: Binding(get: { lab.optimise.untilPass }, set: { lab.optimise.untilPass = $0 }))
                    .toggleStyle(.checkbox).font(.caption)
            }
        }
        Toggle("Put the best on the canvas when done", isOn: Binding(get: { lab.optimise.loadBest }, set: { lab.optimise.loadBest = $0 }))
            .toggleStyle(.checkbox).font(.caption)
        DisclosureGroup("Advanced") {
            ForEach(lab.optimise.variables.filter { $0.kind != .airfoil }) { v in
                HStack {
                    Text("\(WingIssue.label(v.element)) \(v.kind.title.lowercased())").font(.caption).frame(width: 96, alignment: .leading)
                    TextField("from", value: Binding(get: { v.low }, set: { lab.setBounds(of: v.id, low: $0) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing)
                    Text("to").foregroundStyle(S37.C.inkSecondary)
                    TextField("to", value: Binding(get: { v.high }, set: { lab.setBounds(of: v.id, high: $0) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing)
                    Text(v.unit).foregroundStyle(S37.C.inkSecondary).font(.caption).frame(width: 64, alignment: .leading)
                }
                .disabled(running)
            }
            Picker("Sampler", selection: Binding(get: { lab.optimise.sampler }, set: { lab.optimise.sampler = $0 })) {
                Text("TPE (default)").tag("tpe")
                Text("CMA-ES").tag("cmaes")
            }
            .disabled(running)
            Text("CMA-ES samples section choices at random.")
                .font(.caption2).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
        Text(lab.optimise.solver == "estimate"
             ? "Each trial is a quick estimate, a few tenths of a second; separating wings are steered away from." + (lab.optimise.checkBest > 0 ? " RANS checks run on the model and mesh under Solvers, 2 to 5 minutes each on 4 cores." : "")
             : "\(app.settings.parallelTrials) trials at a time on \(app.settings.coresPerJob) cores each (Settings), each one RANS run with the model and mesh under Solvers.")
            .font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
        if let problem = lab.optimiseProblem {
            Text(problem).font(.caption).foregroundStyle(S37.C.clayInk)
        }
        if lab.optimise.needsSU2 && app.settings.su2Executable == nil {
            Text("RANS needs SU2: install it under Solvers, RANS CFD.").font(.caption).foregroundStyle(S37.C.clayInk)
        }
        LabeledContent("Study name") {
            TextField("name", text: Binding(get: { lab.optimise.studyName }, set: { lab.optimise.studyName = $0 }))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .onSubmit { lab.reloadStudy(project: app.workFolder) }
        }
        .disabled(running)
        .help("A new name starts a new study; a saved study's name resumes it")
        HStack {
            let resume = lab.study.map { $0.study == WingLabModel.studyFile(project: app.workFolder, name: lab.optimise.studyName).deletingPathExtension().lastPathComponent } ?? false
            Button(resume ? "Resume Study" : "Start Study") { app.runWingOptimise() }
                .buttonStyle(S37ButtonStyle(kind: .prominent))
                .disabled(running || lab.optimiseProblem != nil
                          || (lab.optimise.needsSU2 && app.settings.su2Executable == nil))
        }
        if let job = lab.optimiseJob { JobInlineStatus(job: job) }
    }

    @ViewBuilder private func quickEstimateControls(_ lab: WingLabModel) -> some View {
        NumberField(label: "From", unit: "°", value: Binding(get: { lab.estimateFrom }, set: { lab.estimateFrom = $0; app.scheduleLiveEstimate() }))
        NumberField(label: "To", unit: "°", value: Binding(get: { lab.estimateTo }, set: { lab.estimateTo = $0; app.scheduleLiveEstimate() }))
        NumberField(label: "Step", unit: "°", value: Binding(get: { lab.estimateStep }, set: { lab.estimateStep = max($0, 0.25); app.scheduleLiveEstimate() }))
        Text("Wing angles \(lab.estimateAngles.first.map { String(format: "%g", $0) } ?? "")° to \(lab.estimateAngles.last.map { String(format: "%g", $0) } ?? "")°, \(lab.estimateAngles.count) of them, and the wing's own.")
            .font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
        if let status = lab.liveStatus {
            Text(status).font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
        } else if !lab.wing.issues.allSatisfy({ $0.kind == .outsideRules }) {
            Text("Viscous part paused: elements overlap or are too close").font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
        }
    }

    @ViewBuilder private func ransSweepControls(_ lab: WingLabModel) -> some View {
        Toggle("Vary the angle", isOn: Binding(get: { lab.sweepOn }, set: { lab.sweepOn = $0 }))
            .help(lab.wing.rideHeight != nil ? "Over a ground each angle is meshed again and solved from rest: slower than in free air" : "")
        if lab.sweepOn {
            FittingPicker(title: "Sweep", options: [(false, "Quick scan"), (true, "Full polar")], selection: Binding(get: { lab.sweepRising }, set: { lab.sweepRising = $0 })) {
                Text("Quick scan").tag(false)
                Text("Full polar").tag(true)
            }
            NumberField(label: "From", unit: "°", value: Binding(get: { lab.sweepFrom }, set: { lab.sweepFrom = $0 }))
            NumberField(label: "To", unit: "°", value: Binding(get: { lab.sweepTo }, set: { lab.sweepTo = $0 }))
            NumberField(label: "Step", unit: "°", value: Binding(get: { lab.sweepStep }, set: { lab.sweepStep = max($0, 0.5) }))
            Text("\(lab.sweepAngles.map { String(format: "%g°", $0) }.joined(separator: ", ")). " + (lab.sweepRising
                 ? "\(lab.meshLevel.capitalized) mesh, each angle from the one below. Several minutes an angle."
                 : "Quick mesh, at most 5 minutes; angles that don't fit are skipped and listed."))
                .font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func su2Install(_ lab: WingLabModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Builds SU2 once, 10 to 20 minutes. Needs xcode-select --install; brew install open-mpi first for several cores.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Button("Install SU2") { app.installSU2() }
                .disabled(lab.su2Job.map { !$0.status.isFinished } ?? false)
            if let job = lab.su2Job { JobInlineStatus(job: job) }
        }
    }

    /// The preview runs on every change, so its controls are its numbers.
    @ViewBuilder private func previewControls(_ lab: WingLabModel) -> some View {
        if let r = lab.preview {
            Text("Panel method (inviscid): how the load splits").font(.caption).bold()
            ForEach(Array(r.cl.enumerated()), id: \.offset) { i, cl in
                LabeledContent(WingIssue.label(i), value: String(format: "Cl %.3f", lab.wing.shownCl(cl)))
            }
            LabeledContent("Total, inviscid", value: String(format: "Cl %.3f   Cm %.3f", lab.wing.shownCl(r.clTotal), r.cmTotal))
            Text(String(format: "On the total chord, %.0f mm. Solved in %.0f ms.", lab.wing.refChord * 1000, lab.previewMilliseconds))
                .font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
        } else {
            Text(lab.previewError ?? "Add an element.").foregroundStyle(S37.C.inkSecondary)
        }
    }

    private func saveCard(asNew: Bool) {
        if let card = app.saveWingCard(asNew: asNew) {
            sentNote = "Saved as the car card \(card.name)" + (app.car.selectedCombo == nil ? "." : ", on \(app.car.selectedCombo!.name).")
        }
    }

    private func send(_ cl: Double, _ cd: Double, into car: Int?) {
        let lab = app.wingLab
        let label = app.sendWingToLapSim(cl: cl, cd: cd, replacedCla: lab.replacedCla, replacedCda: lab.replacedCda, into: car)
        sentNote = "Lap Sim car \(label) now has this wing (\(lab.shownVersion)). Run the Lap Sim to compare it with A."
    }

    @ViewBuilder private var carSection: some View {
        S37Section("Car", footer: "The wing being edited takes its end of the selected combination.") {
            BaseCarPane(embedded: true)
            if app.car.setup != nil {
                SectionPane(embedded: true)
                CombinationsPane(embedded: true)
            }
        }
    }

    @ViewBuilder private func lapSimSection(_ lab: WingLabModel) -> some View {
        let wing = lab.wing
        // The best answer there is, as in the results strip: converged CFD, then
        // the quick estimate, then the inviscid preview with a typed-in Cd.
        let best = lab.bestNumbers
        let from = best.flatMap { $0.name == "inviscid preview" ? nil : $0 }
        let cl = best?.cl ?? 0
        let cd = best?.cd ?? lab.cdEstimate
        let add = wing.carContribution(cl: cl, cd: cd)
        S37Section("Use in the Lap Sim") {
            NumberField(label: "Span", unit: "mm", value: mm({ wing.span }, { v in lab.edit("Change Span") { $0.span = max(v, 0.01) } }))
            Toggle("Estimate 3D from span and endplates", isOn: Binding(
                get: { wing.endplateHeight != nil }, set: { on in lab.edit { $0.endplateHeight = on ? 0.25 : nil } }))
            if let f = wing.finite3D {
                NumberField(label: "Endplate height", unit: "mm", value: mm({ wing.endplateHeight ?? 0 }, { v in lab.edit("Change Endplate Height") { $0.endplateHeight = max(v, 0) } }))
                LabeledContent("3D lift factor", value: String(format: "%.2f", f.liftFactor))
                LabeledContent("Aspect ratio", value: String(format: "%.1f, %.1f with endplates", f.aspectRatio, f.effectiveAspectRatio))
            } else {
                NumberField(label: "2D to 3D factor", value: Binding(get: { wing.factor3D }, set: { v in lab.edit("Change 2D to 3D Factor") { $0.factor3D = max(v, 0) } }))
            }
            if let from {
                LabeledContent("From the \(from.name)", value: String(format: "Cl %.3f   Cd %.4f", wing.shownCl(from.cl), from.cd))
            } else {
                NumberField(label: "Cd (typed in: no estimate or CFD yet)", value: Binding(get: { lab.cdEstimate }, set: { lab.cdEstimate = $0 }))
            }
            LabeledContent("Adds", value: String(format: "ClA %.3f m²   CdA %.3f m²", add.cla, add.cda))
            NumberField(label: "Replaces: old wing's ClA", unit: "m²", value: Binding(get: { lab.replacedCla }, set: { lab.replacedCla = $0 }))
            NumberField(label: "Replaces: old wing's CdA", unit: "m²", value: Binding(get: { lab.replacedCda }, set: { lab.replacedCda = $0 }))
            HStack {
                Button(lab.cardID == nil ? "Save as Car Card" : "Update Car Card") { saveCard(asNew: false) }
                if lab.cardID != nil { Button("Save as New Card") { saveCard(asNew: true) } }
            }
            .help("A card for the car, with this wing as a \(wing.rulesFor == .front ? "front" : "rear") wing and these numbers")
            Menu("Put in a Lap Sim Car") {
                let cars = app.lapSim.cars.indices
                ForEach(cars, id: \.self) { i in
                    Button("Car \(LapSimSetup.labels[i]): swap its wing for this one") { send(cl, cd, into: i) }
                }
                if cars.count < LapSimSetup.maxCars {
                    Divider()
                    Button("New car \(LapSimSetup.labels[cars.count]): car A with this wing") { send(cl, cd, into: nil) }
                }
            }
            .fixedSize()
            .disabled(from == nil && lab.preview == nil)
            if let note = sentNote { Text(note).font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary) }
        }
    }
}

/// The optimiser's trials: a sortable table, the best so far, and Cl against
/// Cd with the Pareto front. Clicking a trial puts its wing on the canvas.
struct StudyResults: View {
    @Environment(AppState.self) private var app
    @State private var order = [KeyPathComparator(\Row.number)]
    @State private var selection: Int?
    @State private var chart = ChartKind.progress

    // One chart at a time, so it gets the panel's height instead of half of it.
    enum ChartKind: String, CaseIterable, Identifiable {
        case progress = "Best so far"
        case front = "Downforce vs drag"
        case polars = "Selected design"
        var id: String { rawValue }
    }

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
                ViewThatFits(in: .horizontal) {
                    HSplitView {
                        // Wide enough for every column without a sideways scroller over the last row.
                        table(study, lab).frame(minWidth: 580)
                        charts(study, lab).frame(minWidth: 260)
                    }
                    .frame(minWidth: 860)
                    VSplitView {
                        table(study, lab).frame(minHeight: 140)
                        charts(study, lab).frame(minHeight: 160)
                    }
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
            Text("Set up a study under Optimise and start it.").foregroundStyle(S37.C.inkSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func header(_ s: WingStudy, _ lab: WingLabModel) -> some View {
        if let checks = s.checks, !checks.isEmpty { checkTable(s, checks, lab) }
        HStack(alignment: .firstTextBaseline) {
            Text("\(s.study): \(s.objectiveName)").bold()
            Text(s.solver == "estimate" ? "estimates" : "RANS").font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
            Text("\(s.complete + s.failed) of \(s.target) run · \(s.failed) failed · \((s.invalid ?? 0)) invalid wings skipped")
                .font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
            Spacer()
            if let b = s.bestTrial, let v = b.value {
                Text(String(format: "best: trial %ld, %.4g", b.number, v)).font(.caption.monospacedDigit())
                Button("Load Best") { lab.load(trial: b) }.font(.caption)
                Button("Compare Start and Best") { app.compareStartAndBest() }.font(.caption)
                    .help("Start as A (dashed), best as B, so every chart shows what the study changed")
            }
        }
        timeLapse(lab)
    }

    /// Plays the study back on the canvas: each trial's wing in the order it ran.
    @ViewBuilder private func timeLapse(_ lab: WingLabModel) -> some View {
        let count = lab.replayOrder.count
        HStack(spacing: 8) {
            Text("Time-lapse").font(.caption).bold()
            Button {
                if lab.replayPlaying { lab.pauseReplay() } else { lab.playReplay() }
            } label: {
                Image(systemName: lab.replayPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(count < 2)
            .help("Plays the trials in the order they ran: the canvas shows each one's wing, the charts fill in")
            Slider(value: Binding(get: { Double(lab.replayIndex ?? 0) },
                                  set: { lab.pauseReplay(); lab.replayIndex = Int($0.rounded()) }),
                   in: 0...Double(max(count - 1, 1)))
                .disabled(count < 2)
                .frame(minWidth: 120)
            Picker("Speed", selection: Binding(get: { lab.replaySpeed }, set: { lab.replaySpeed = $0 })) {
                Text("2/s").tag(2.0)
                Text("8/s").tag(8.0)
                Text("30/s").tag(30.0)
            }
            .labelsHidden()
            .fixedSize()
            if lab.replayIndex != nil {
                Button("Stop") { lab.stopReplay() }
                    .help("Back to the wing as drawn")
            }
        }
        .font(.caption)
        .controlSize(.small)
    }

    /// The best estimate designs run again with RANS: does RANS agree on the order?
    @ViewBuilder private func checkTable(_ s: WingStudy, _ checks: [WingStudy.Check], _ lab: WingLabModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Checked with RANS").font(.caption).bold()
                if let b = s.bestCheck, let t = s.trials.first(where: { $0.number == b.number }) {
                    Text("RANS's pick: trial \(b.number)").font(.caption)
                    Button("Load It") { lab.load(trial: t) }.font(.caption)
                }
            }
            if let a = s.anchor {
                Text(a.converged == true
                     ? String(format: "Ranked after calibrating on a RANS run of the starting wing: lift ×%.2f, drag ×%.2f of the estimate's.", a.clScale ?? 1, a.cdScale ?? 1)
                     : "The calibration run of the starting wing did not settle, so the ranking is the estimate's own.")
                    .font(.caption2).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 1) {
                GridRow {
                    Text("Trial").gridColumnAlignment(.leading)
                    Text("Estimate")
                    Text("RANS")
                    Text("")
                }
                .bold()
                ForEach(checks) { c in
                    GridRow {
                        Text("\(c.number)")
                        Text(c.estimateValue.map { String(format: "%.4g", $0) } ?? "–")
                        Text(c.value.map { String(format: "%.4g", $0) } ?? "–")
                        let note = c.value == nil ? (c.reason ?? "failed") : (c.feasible == false ? "over limit" : "")
                        Text(note)
                            .foregroundStyle(S37.C.inkSecondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .help(note)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.caption.monospacedDigit())
        }
        .padding(.bottom, 4)
    }

    private func rows(_ s: WingStudy) -> [Row] {
        s.trials.filter { $0.state != "invalid" }.map { t in
            let design = s.spec.variables.map { v -> String in
                guard let x = t.params[v.name] else { return "" }
                switch v.kind {
                case "angle": return String(format: "%@ %.1f°", short(v), x)
                case "airfoil":
                    let key = v.choices.flatMap { c in c.indices.contains(Int(x.rounded())) ? c[Int(x.rounded())] : nil } ?? "?"
                    return "\(short(v)) \(app.wingLab.airfoil(key)?.name ?? key)"
                case "camber": return String(format: "%@ +%.1f%%", short(v), x * 100)
                case "thickness": return String(format: "%@ %.0f%%", short(v), x * 100)
                default: return String(format: "%@ %.1f mm", short(v), x * 1000)  // gap, overlap, chord, height
                }
            }.joined(separator: "  ")
            let load = t.load ?? -.infinity, cd = t.cd ?? .infinity
            return Row(id: t.number, number: t.number, state: t.state == "complete" && t.feasible == false ? "over limit" : t.state,
                       load: load, cd: cd, ld: load.isFinite && cd.isFinite ? load / cd : -.infinity,
                       value: t.value ?? (s.direction == "minimize" ? .infinity : -.infinity), design: design,
                       note: t.reason ?? "")
        }
    }

    private func short(_ v: WingStudy.Variable) -> String {
        let names = ["angle": "α", "gap": "gap", "overlap": "ovl", "chord": "c", "airfoil": "sec",
                     "camber": "cmb", "thickness": "thk", "height": "h"]
        return "\(names[v.kind] ?? v.kind)\(v.element)"
    }

    private func fmt(_ x: Double, _ f: String) -> String { x.isFinite ? String(format: f, x) : "–" }

    @ViewBuilder private func table(_ s: WingStudy, _ lab: WingLabModel) -> some View {
        Table(rows(s).sorted(using: order), selection: $selection, sortOrder: $order) {
            TableColumn("#", value: \.number) { Text("\($0.number)").monospacedDigit() }.width(32)
            TableColumn("State", value: \.state) { r in
                Text(r.state).foregroundStyle(r.state == "complete" ? Color.primary : r.state == "fail" ? S37.C.critical : Color.secondary)
                    .help(r.note)
            }
            .width(70)
            TableColumn("−Cl", value: \.load) { Text(fmt($0.load, "%.3f")).monospacedDigit() }.width(54)
            TableColumn("Cd", value: \.cd) { Text(fmt($0.cd, "%.4f")).monospacedDigit() }.width(54)
            TableColumn("L/D", value: \.ld) { Text(fmt($0.ld, "%.1f")).monospacedDigit() }.width(44)
            TableColumn("Score", value: \.value) { Text(fmt($0.value, "%.4g")).monospacedDigit() }.width(54)
            TableColumn("Design", value: \.design) { r in
                Text(r.design.isEmpty ? r.note : r.design).font(.caption)
                    .help(r.note.isEmpty ? r.design : r.design + "\n" + r.note)
            }
            .width(min: 120)  // fills what is left: an ideal width made the table scroll sideways
        }
        .onChange(of: selection) { _, n in
            if let n, let t = s.trials.first(where: { $0.number == n }) { lab.load(trial: t) }
        }
    }

    @ViewBuilder private func charts(_ s: WingStudy, _ lab: WingLabModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            S37Segmented(options: ChartKind.allCases.map { ($0, $0.rawValue) }, selection: $chart).fixedSize()
            switch chart {
            case .progress: bestSoFar(s, lab)
            case .front: scatter(s, lab)
            case .polars: selectedPolars(lab)
            }
        }
    }

    /// Every trial runs at one wing angle; the one on the canvas, over the angles, from the live estimate.
    @ViewBuilder private func selectedPolars(_ lab: WingLabModel) -> some View {
        if let est = lab.estimate, let here = est.row(nearest: lab.wing.alpha) {
            VStack(alignment: .leading, spacing: 2) {
                Text((lab.selectedTrial.map { "Trial \($0)" } ?? "The wing on the canvas") + ", live estimate over the wing angle")
                    .font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
                PolarCharts(points: est.rows.map { .init(alpha: $0.alpha, cl: lab.wing.shownCl($0.cl), cd: $0.cd, good: $0.trusted) }, mark: here.alpha)
            }
        } else {
            Text("Pick a trial in the table: its polars come from the live estimate.").font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
        }
    }

    @ViewBuilder private func bestSoFar(_ s: WingStudy, _ lab: WingLabModel) -> some View {
        // During a time-lapse, only what had run by then.
        let upTo = lab.replayTrial?.number ?? Int.max
        let best = s.bestSoFar.filter { $0.trial <= upTo }
        let all = s.results.filter { $0.number <= upTo }
        Chart {
            ForEach(all) { t in
                PointMark(x: .value("Trial", t.number), y: .value("Score", t.value ?? 0)).symbolSize(12).foregroundStyle(.gray)
            }
            ForEach(Array(best.enumerated()), id: \.offset) { _, b in
                LineMark(x: .value("Trial", b.trial), y: .value("Score", b.value)).interpolationMethod(.stepEnd)
            }
            if let t = lab.replayTrial {
                RuleMark(x: .value("Trial", t.number)).foregroundStyle(S37.C.chart5.opacity(0.7))
            }
        }
        .chartXScale(domain: 0...max(s.trials.last?.number ?? 1, 1))
        .chartXAxisLabel("Trial").chartYAxisLabel("Best so far")
        .chartYScale(domain: .automatic(includesZero: false))
    }

    @ViewBuilder private func scatter(_ s: WingStudy, _ lab: WingLabModel) -> some View {
        let upTo = lab.replayTrial?.number ?? Int.max
        let ran = s.trials.filter { $0.isResult && $0.load != nil && $0.cd != nil && $0.number <= upTo }
        let front = s.paretoFront.filter { $0.number <= upTo }
        let current = lab.replayTrial?.number ?? lab.selectedTrial
        Chart {
            ForEach(ran) { t in
                PointMark(x: .value("Cd", t.cd!), y: .value("−Cl", t.load!))
                    .symbolSize(t.number == current ? 80 : 20)
                    .foregroundStyle(t.number == current ? (lab.replayTrial != nil ? S37.C.chart5 : S37.C.sage)
                                     : t.feasible == false ? S37.C.chart5.opacity(0.5) : Color.gray)
            }
            ForEach(front) { t in
                LineMark(x: .value("Cd", t.cd!), y: .value("−Cl", t.load!), series: .value("", "front"))
                    .foregroundStyle(S37.C.sageInk)
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

/// A field scalar's colours and the values at each end (the middle 98% of
/// the window's values).
/// The change from A: blue where the scalar fell, red where it rose.
struct ChangeColorbar: View {
    let name: String
    let limit: Double

    var body: some View {
        let colors = stride(from: -1.0, through: 1.0, by: 0.25).map { f -> Color in
            let c = WingField.diverging(f)
            return Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255)
        }
        HStack(spacing: 6) {
            Text("Change in \(name), B − A").font(.caption2)
            Text(String(format: "%+.2f", -limit)).font(.caption2.monospacedDigit())
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                .frame(width: 160, height: 8).clipShape(RoundedRectangle(cornerRadius: 2))
            Text(String(format: "%+.2f", limit)).font(.caption2.monospacedDigit())
        }
        .help("B's field minus A's at the same points. The colours span the 95th percentile of the change, so a moved edge does not wash out the rest.")
    }
}

struct FieldColorbar: View {
    let scalar: WingField.Scalar

    var body: some View {
        let s = scalar
        let colors = s.colormap.map { Color(red: $0[0], green: $0[1], blue: $0[2]) }
        HStack(spacing: 6) {
            Text(s.name).font(.caption2)
            Text(String(format: "%.2f", s.range.first ?? s.min)).font(.caption2.monospacedDigit())
            LinearGradient(colors: colors.isEmpty ? [.black, .white] : colors, startPoint: .leading, endPoint: .trailing)
                .frame(width: 160, height: 8).clipShape(RoundedRectangle(cornerRadius: 2))
            Text(String(format: "%.2f", s.range.last ?? s.max)).font(.caption2.monospacedDigit())
        }
        .help("\(s.name): \(String(format: "%.3f", s.min)) to \(String(format: "%.3f", s.max)) in the window; the colours span the middle 98%.")
    }
}

/// A quick-estimate sweep: Cl and Cd against the wing angle, and which
/// angle the results below show.
struct SweepStrip: View {
    @Environment(AppState.self) private var app
    let sweep: WingSweep

    var body: some View {
        let lab = app.wingLab
        let rows = Array(sweep.rows.enumerated())
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sweep.timeLimit == 0 ? "Polar through stall" : "Sweep, quick mesh").font(.caption).bold()
                S37Segmented(options: rows.map { ($0.offset, String(format: "%g°", $0.element.alpha ?? 0)) },
                             selection: Binding(get: { lab.sweepRow ?? 0 }, set: { lab.showSweepRow($0) }))
                Text(String(format: "%.0f s in all", sweep.seconds)
                     + (sweep.skipped.isEmpty ? "" : "; not run, out of time: " + sweep.skipped.map { String(format: "%g°", $0) }.joined(separator: ", ")))
                    .font(.caption2).foregroundStyle(sweep.skipped.isEmpty ? Color.secondary : S37.C.chart5)
                if rows.contains(where: { !$0.element.converged }) {
                    Text("Rust points did not converge: not results.").font(.caption2).foregroundStyle(S37.C.chart5)
                }
            }
            .frame(width: 260, alignment: .leading)
            PolarCharts(points: rows.map { .init(alpha: $0.element.alpha ?? 0, cl: lab.wing.shownCl($0.element.cl), cd: $0.element.cd,
                                                 good: $0.element.converged) },
                        mark: lab.sweepRow.flatMap { sweep.rows.indices.contains($0) ? sweep.rows[$0].alpha : nil })
        }
        .padding(8)
        .frame(height: 170)
        Divider()
    }
}

/// The quick estimate: Cl and Cd against the wing angle, and each element at
/// the wing's own angle.
struct EstimateResults: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let lab = app.wingLab
        if let est = lab.estimate, let here = est.row(nearest: lab.wing.alpha) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "At %g°: Cl %.3f, Cd %.4f, L/D %.1f", here.alpha, lab.wing.shownCl(here.cl), here.cd, abs(here.cl) / max(here.cd, 1e-9)))
                        .font(.callout.monospacedDigit()).bold()
                    Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 2) {
                        GridRow {
                            Text("").gridColumnAlignment(.leading)
                            Text("Cl").bold()
                            Text("Cd").bold()
                            Text("in place").bold()
                        }
                        ForEach(Array(here.elements.enumerated()), id: \.offset) { i, e in
                            GridRow {
                                Text(WingIssue.label(i))
                                Text(String(format: "%.3f", lab.wing.shownCl(e.cl)))
                                Text(String(format: "%.4f", e.cd))
                                Text(String(format: "%.1f°%@", e.effectiveAngle, e.heldBelowStall ? " (held)" : ""))
                                    .help("The element's own angle of attack in place; its neighbours turn the flow by \(String(format: "%+.1f", e.upwash))°. Held: it has an element behind it, so it is kept below its stall onset, as the slot does on the real wing.")
                            }
                        }
                    }
                    .font(.caption.monospacedDigit())
                    if !here.trusted {
                        Label("NeuralFoil is unsure of one or more sections here: check with RANS.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(S37.C.chart5)
                    }
                    if here.separating == true {
                        Label((here.why.map { "\($0). " } ?? "An element separates here. ") + "Check with RANS.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(S37.C.chart5).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Panel method and NeuralFoil: lift within about 2% of RANS on a main-and-flap wing until the flap nears separation, drag about 10% high. For trends and screening; RANS CFD for numbers to keep.")
                        .font(.caption2).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 290, alignment: .leading)
                .scrollableColumn()
                PolarCharts(points: est.rows.map { .init(alpha: $0.alpha, cl: lab.wing.shownCl($0.cl), cd: $0.cd, good: $0.trusted) },
                            mark: here.alpha,
                            pinned: lab.pinned.flatMap { a in a.estimate?.rows.map { .init(alpha: $0.alpha, cl: a.wing.shownCl($0.cl), cd: $0.cd, good: true) } })
            }
            .padding(8)
        } else {
            Text(app.wingLab.liveStatus ?? "The live estimate runs as you edit: add an element, or move apart ones that overlap.").foregroundStyle(S37.C.inkSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Cl and Cd against the wing angle, and Cl against Cd (the drag polar), for
/// one sweep of angles: points in the warning colour are not to be trusted
/// (NeuralFoil unsure, RANS not converged); `mark` rings the wing's angle now,
/// `pinned` is design A, dashed.
struct PolarCharts: View {
    struct Point {
        var alpha: Double
        var cl: Double
        var cd: Double
        var good: Bool
    }
    let points: [Point]
    var mark: Double?
    var pinned: [Point]?

    var body: some View {
        HStack(spacing: 12) {
            chart("Wing angle (°)", "Cl", \.alpha, \.cl)
            chart("Wing angle (°)", "Cd", \.alpha, \.cd)
            chart("Cd", "Cl", \.cd, \.cl)
        }
    }

    private func chart(_ xName: String, _ yName: String, _ x: KeyPath<Point, Double>, _ y: KeyPath<Point, Double>) -> some View {
        let here = mark.flatMap { m in points.min { abs($0.alpha - m) < abs($1.alpha - m) } }
        return Chart {
            ForEach(Array((pinned ?? []).enumerated()), id: \.offset) { _, p in
                LineMark(x: .value(xName, p[keyPath: x]), y: .value(yName, p[keyPath: y]), series: .value("Design", "A"))
                    .foregroundStyle(S37.C.chart6.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value(xName, p[keyPath: x]), y: .value(yName, p[keyPath: y]), series: .value("Design", "B"))
                PointMark(x: .value(xName, p[keyPath: x]), y: .value(yName, p[keyPath: y]))
                    .symbolSize(p.good ? 16 : 24)
                    .foregroundStyle(p.good ? S37.C.sage : S37.C.chart5)
            }
            if let here {
                PointMark(x: .value(xName, here[keyPath: x]), y: .value(yName, here[keyPath: y]))
                    .foregroundStyle(.clear)
                    .annotation(position: .overlay) { Circle().strokeBorder(S37.C.ink, lineWidth: 1.5).frame(width: 12, height: 12) }
            }
        }
        .chartXAxisLabel(xName).chartYAxisLabel(yName)
        .chartXScale(domain: .automatic(includesZero: x == \Point.alpha))
        .chartYScale(domain: .automatic(includesZero: false))
    }
}

/// One line across the top of the results: the latest answer from each
/// solver for the wing on the canvas, and what it means on the car. Click a
/// card for its tab.
struct ResultsSummary: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let lab = app.wingLab
        let wing = lab.wing
        let estimate = lab.estimate?.row(nearest: wing.alpha)
        let rans = lab.ransResult
        // On the car: CFD when it converged, else the estimate.
        let forCar: (cl: Double, cd: Double, from: String)? = rans.flatMap { $0.converged ? ($0.cl, $0.cd, "CFD") : nil }
            ?? estimate.map { ($0.cl, $0.cd, "estimate") }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                card("Live estimate", tab: .estimate,
                     lines: estimate.map { [String(format: "Cl %.3f  Cd %.4f", wing.shownCl($0.cl), $0.cd),
                                            String(format: "L/D %.1f", abs($0.cl) / max($0.cd, 1e-9)) + ($0.separating == true ? "  separating" : "")] }
                        ?? lab.preview.map { [String(format: "Cl %.3f inviscid", wing.shownCl($0.clTotal)), lab.liveStatus ?? "no drag yet"] } ?? ["—"],
                     warn: estimate.map { !$0.trusted || $0.separating == true } ?? false, lab: lab)
                let advice = rans.map { app.meshAdvice($0) }
                card("RANS CFD", tab: .cfd,
                     lines: rans.map { [String(format: "Cl %.3f  Cd %.4f", wing.shownCl($0.cl), $0.cd),
                                        ($0.converged ? String(format: "L/D %.1f", abs($0.cl) / max($0.cd, 1e-9)) : "not converged") + ", \($0.meshLevel)",
                                        advice.map { MeshAdviceView.short($0) } ?? ""] }
                        ?? ["not run"], warn: rans.map { !$0.converged } ?? false || advice?.verdict == .refine, lab: lab)
                if let c = forCar {
                    let car = wing.carContribution(cl: c.cl, cd: c.cd)
                    card("On the car (\(c.from))", tab: nil,
                         lines: [String(format: "ClA %.3f m²  CdA %.3f m²", car.cla, car.cda),
                                 String(format: "span %.0f mm, 3D factor %.2f", wing.span * 1000, wing.liftFactor3D)], lab: lab)
                }
                if let a = lab.pinned {
                    card("A, pinned", tab: nil, lines: pinnedLines(a, estimate: estimate, lab: lab), lab: lab)
                }
                if let s = lab.study, let b = s.bestTrial, let v = b.value {
                    card("Study best", tab: .study, lines: [String(format: "trial %ld: %.4g", b.number, v),
                                                            "\(s.complete + s.failed) of \(s.target) run"], lab: lab)
                }
            }
            .padding(8)
        }
    }

    /// A's numbers and this wing's difference from them, from the best
    /// solver both have: CFD, then the estimate, then the inviscid preview.
    private func pinnedLines(_ a: WingLabModel.Pinned, estimate: WingEstimate.Row?, lab: WingLabModel) -> [String] {
        func diff(_ name: String, _ a: (Double, Double), _ b: (Double, Double)) -> [String] {
            [String(format: "Cl %.3f  Cd %.4f (%@)", a.0, a.1, name),
             String(format: "this wing: ΔCl %+.3f (%+.1f%%)  ΔCd %+.4f", b.0 - a.0, (b.0 - a.0) / max(abs(a.0), 1e-9) * 100, b.1 - a.1)]
        }
        if let ar = a.rans, ar.converged, let br = lab.ransResult, br.converged {
            return diff("CFD", (a.wing.shownCl(ar.cl), ar.cd), (lab.wing.shownCl(br.cl), br.cd))
        }
        if let ae = a.estimate?.row(nearest: a.wing.alpha), let be = estimate {
            return diff("estimate", (a.wing.shownCl(ae.cl), ae.cd), (lab.wing.shownCl(be.cl), be.cd))
        }
        if let ap = a.preview, let bp = lab.preview {
            let (ac, bc) = (a.wing.shownCl(ap.clTotal), lab.wing.shownCl(bp.clTotal))
            return [String(format: "Cl %.3f (preview)", ac),
                    String(format: "this wing: ΔCl %+.3f (%+.1f%%)", bc - ac, (bc - ac) / max(abs(ac), 1e-9) * 100)]
        }
        return ["no results to compare"]
    }

    /// One cell of the strip: label, then its numbers; clicking shows its tab
    private func card(_ title: String, tab: WingLabModel.ResultsTab?, lines: [String], warn: Bool = false, lab: WingLabModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(warn ? S37.C.clayInk : (tab != nil && lab.resultsTab == tab ? S37.C.sageInk : S37.C.inkTertiary))
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 13).monospacedDigit()).lineLimit(1)
            }
        }
        .padding(.horizontal, S37.Space.s3)
        .overlay(alignment: .leading) { Rectangle().fill(S37.C.separator).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { if let tab { lab.resultsTab = tab } }
    }
}

extension View {
    /// A fixed-width column of numbers that scrolls when the pane is too short, instead of clipping.
    func scrollableColumn() -> some View {
        ScrollView(.vertical) { self }.scrollIndicators(.automatic)
    }
}

/// A segmented picker while all its options fit at full width, a menu when
/// the pane is too narrow, so no option is ever cut off.
struct FittingPicker<Value: Hashable, Content: View>: View {
    let title: String
    /// The same options as `content`, for the segmented form
    var options: [(Value, String)]
    @Binding var selection: Value
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            S37Segmented(options: options, selection: $selection).fixedSize()
            Picker(title, selection: $selection, content: content)
                .pickerStyle(.menu)
        }
    }
}

extension View {
    /// Text over the canvas sits on a dark tinted plate, so it reads over any field image
    func canvasPlate() -> some View {
        padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: S37.Radius.sm, style: .continuous).fill(S37.C.glassTinted))
    }
}

/// The RANS mesh of this wing (wing-mesh), framed on the elements; drag to
/// pan, the buttons to zoom.
struct MeshCanvas: View {
    @Environment(AppState.self) private var app
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var panStart = CGSize.zero

    var body: some View {
        let lab = app.wingLab
        let running = lab.meshJob.map { !$0.status.isFinished } ?? false
        ZStack(alignment: .topLeading) {
            if let mesh = lab.mesh, let path = lab.meshPath, let b = mesh.wallBounds {
                Canvas { ctx, size in
                    let span = (b.max - b.min) * 1.3
                    let scale = min(size.width / max(span.x, 1e-6), size.height / max(span.y, 1e-6)) * zoom
                    let centre = (b.min + b.max) / 2
                    let t = CGAffineTransform(translationX: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
                        .scaledBy(x: scale, y: -scale).translatedBy(x: -centre.x, y: -centre.y)
                    ctx.concatenate(t)
                    ctx.stroke(Path(path), with: .color(S37.C.inkSecondary), lineWidth: 0.6 / scale)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { pan = CGSize(width: panStart.width + $0.translation.width, height: panStart.height + $0.translation.height) }
                    .onEnded { _ in panStart = pan })
            } else if !running {
                S37EmptyState(title: "No mesh yet", line: "Mesh this wing with the RANS settings under Solvers: a few seconds, no SU2 needed.") {
                    Button("Mesh this wing") { app.runWingMesh() }
                        .buttonStyle(S37ButtonStyle(kind: .prominent))
                        .disabled(lab.wing.elements.isEmpty)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    if let job = lab.meshJob, !job.status.isFinished || job.status == .failed {
                        JobInlineStatus(job: job).frame(maxWidth: 360).canvasPlate()
                    } else if lab.mesh != nil {
                        HStack(spacing: 8) {
                            Text(lab.meshInfo ?? "").font(.caption.monospacedDigit())
                            if lab.meshOf != lab.wing {
                                Text("the wing has changed since").font(.caption).foregroundStyle(S37.C.clayInk)
                            }
                            Button(lab.meshOf != lab.wing ? "Mesh again" : "Remesh") { app.runWingMesh() }
                                .buttonStyle(S37ButtonStyle()).controlSize(.small)
                        }
                        .canvasPlate()
                    }
                    Spacer()
                }
                .frame(minHeight: 36, alignment: .top)  // clear of the floating picker
                if lab.mesh != nil {
                    HStack(spacing: 6) {
                        Spacer()
                        HStack(spacing: 6) {
                            Button { zoom /= 1.5 } label: { Image(systemName: "minus.magnifyingglass") }
                                .accessibilityLabel("Zoom out")
                            Button { zoom *= 1.5 } label: { Image(systemName: "plus.magnifyingglass") }
                                .accessibilityLabel("Zoom in")
                            Button("Fit") { zoom = 1; pan = .zero; panStart = .zero }
                        }
                        .buttonStyle(.borderless)
                        .canvasPlate()
                    }
                }
            }
            .padding(6)
        }
        .background(S37.C.surface)
    }
}

/// Whether more cells would make the run more accurate or reliable: the verdict, why, and
/// a run one mesh level finer to check or improve it.
struct MeshAdviceView: View {
    let advice: MeshAdvice
    let level: String  // the run's own: running on it again re-meshes the wall cells
    let running: Bool
    let run: (String) -> Void

    /// One line for the results strip.
    static func short(_ a: MeshAdvice) -> String {
        switch a.verdict {
        case .refine: "mesh: more cells would help"
        case .enough: "mesh: enough cells"
        case .unknown: "mesh: check on \(a.next ?? "medium")"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch advice.verdict {
            case .refine: Label("More cells would make this more accurate", systemImage: "square.grid.3x3.fill").foregroundStyle(S37.C.clayInk)
            case .enough: Label("Enough cells: more would not change it", systemImage: "checkmark.seal").foregroundStyle(S37.C.sageInk)
            case .unknown: Label("Mesh: not known yet whether more cells would help", systemImage: "questionmark.square").foregroundStyle(S37.C.ochre)
            }
            ForEach(advice.reasons, id: \.self) { reason in
                Text(reason).font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if advice.verdict != .enough, let next = advice.next {
                Button(next == level ? "Run Again on the \(next) Mesh" : "Run on the \(next) Mesh") { run(next) }
                    .disabled(running)
                    .help(next == level ? "Meshed again with thinner wall cells" : "The same wing and angle one level finer; the two are then compared here")
            }
        }
    }
}
