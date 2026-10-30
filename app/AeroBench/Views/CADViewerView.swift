import AeroBench3D
import AeroBenchKit
import SwiftUI

struct CADViewerView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HSplitView {
            CADSidePanel()
                .frame(minWidth: 240, idealWidth: 290, maxWidth: 420)
            VStack(spacing: 0) {
                CADToolbar()
                Divider()
                ZStack {
                    Viewer3DView(viewer: app.cad.viewer)
                    overlay
                }
                if app.cad.sectionOn {
                    Divider()
                    CADSectionView()
                        .frame(height: 260)
                }
                Divider()
                CADStatusBar()
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var overlay: some View {
        switch app.cad.status {
        case .empty:
            ContentUnavailableView {
                Label("No Model", systemImage: "cube")
            } description: {
                Text("Drop a STEP, IGES, STL or OBJ file on the window, or press Open.")
            } actions: {
                Button("Open…") { app.openCADPanel() }
            }
            .background(.background)
        case .loading(let message):
            VStack(spacing: 8) {
                if let job = app.cad.job, !job.status.isFinished {
                    ProgressView(value: job.progress, total: 100).frame(width: 220)
                    Text(job.progressMessage.isEmpty ? message : job.progressMessage).font(.caption)
                    Button("Cancel") { app.jobs.cancel(job) }
                } else {
                    ProgressView()
                    Text(message).font(.caption)
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        case .failed(let message, let detail):
            ContentUnavailableView {
                Label(message, systemImage: "xmark.octagon")
            } description: {
                Text(detail ?? "").font(.caption.monospaced())
            } actions: {
                Button("Open…") { app.openCADPanel() }
            }
            .background(.background)
        case .ready:
            EmptyView()
        }
    }
}

struct CADToolbar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var cad = app.cad
        HStack(spacing: 10) {
            Button("Open…") { app.openCADPanel() }
            Divider().frame(height: 18)
            ForEach(StandardView.allCases) { view in
                Button(view.title) { cad.viewer.look(from: view) }
            }
            Button("Fit") { cad.viewer.fitAll() }
            Picker("Projection", selection: $cad.projection) {
                Text("Persp").tag(Projection.perspective)
                Text("Ortho").tag(Projection.orthographic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            Divider().frame(height: 18)
            Toggle("Measure", isOn: $cad.measuring).toggleStyle(.button)
            Toggle("Section", isOn: $cad.sectionOn).toggleStyle(.button)
                .disabled(cad.model == nil)
                .help("Cut the visible parts with a plane and see them in section")
            Button("Check Geometry") { app.checkGeometry() }
                .disabled(cad.fileURL == nil || (cad.checkJob.map { !$0.status.isFinished } ?? false))
            Toggle("Snap to vertex", isOn: $cad.snap)
            Spacer()
            Toggle("FPS", isOn: $cad.showStatistics)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct CADSidePanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var cad = app.cad
        Form {
            Section("File") {
                if let url = cad.fileURL {
                    LabeledContent("Name") { Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle) }
                        .help(url.path)
                } else {
                    Text("No file open").foregroundStyle(.secondary)
                }
                Picker("Tessellation", selection: $cad.preset) {
                    ForEach(TessellationPreset.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .onChange(of: cad.preset) { if cad.isTessellatedFormat { app.reloadCAD() } }
                Picker("STL/OBJ units", selection: $cad.meshUnits) {
                    ForEach(LengthUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: cad.meshUnits) { if cad.fileURL != nil && !cad.isTessellatedFormat { app.reloadCAD() } }
                Picker("Up axis", selection: $cad.upAxis) {
                    Text("Z up (CAD)").tag(UpAxis.z)
                    Text("Y up").tag(UpAxis.y)
                }
                if cad.model != nil {
                    LabeledContent("Triangles", value: cad.triangleCount.formatted())
                    if cad.fromCache { Text("Loaded from the tessellation cache").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if cad.checkJob != nil || cad.report != nil {
                GeometryCheckSection()
            }
            if let model = cad.model {
                Section {
                    PartTree(model: model)
                } header: {
                    HStack {
                        Text("Parts")
                        Spacer()
                        Button("Show All") { cad.hidden = [] }
                            .buttonStyle(.link)
                            .disabled(cad.hidden.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PartTree: View {
    @Environment(AppState.self) private var app
    let model: Model3D

    var body: some View {
        OutlineGroup(model.roots, children: \.childNodes) { node in
            Toggle(isOn: Binding(get: { app.cad.isVisible(node.id) }, set: { app.cad.setVisible(node.id, $0) })) {
                HStack {
                    Text(node.name).lineLimit(1)
                    Spacer()
                    if let m = node.mesh {
                        Text(model.meshes[m].triangleCount.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
        }
    }
}

struct CADStatusBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let cad = app.cad
        HStack(spacing: 16) {
            if let b = cad.visibleBounds {
                let s = (b.max - b.min) * 1000
                Text("Visible bounds  \(mm(s.x)) × \(mm(s.y)) × \(mm(s.z)) mm")
            }
            Spacer()
            if cad.measuring {
                if cad.points.count == 2 {
                    let a = cad.points[0], b = cad.points[1]
                    let d = (b - a) * 1000
                    Text("Distance \(mm(Measure.distance(a, b) * 1000)) mm   Δx \(mm(d.x))  Δy \(mm(d.y))  Δz \(mm(d.z))")
                        .bold()
                        .textSelection(.enabled)
                    Button("Clear") { cad.clearMeasurement() }.buttonStyle(.link)
                } else {
                    Text(cad.points.isEmpty ? "Click the first point" : "Click the second point")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func mm(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(2))) }
}

struct GeometryCheckSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let cad = app.cad
        Section {
            if let job = cad.checkJob, !job.status.isFinished {
                HStack {
                    ProgressView(value: job.progress, total: 100)
                    Text(job.progressMessage).font(.caption).lineLimit(1)
                }
            } else if let job = cad.checkJob, job.status == .failed {
                Label(job.message ?? "The check failed", systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if let report = cad.report {
                if report.problems == 0 {
                    Label("No problems found", systemImage: "checkmark.seal").foregroundStyle(.green)
                } else {
                    Label("\(report.problems) problems", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                LabeledContent("Bodies", value: "\(report.mesh.bodies)")
                LabeledContent("Closed", value: report.mesh.closed ? "yes, watertight" : "no")
                if report.mesh.intersectionsComplete == false {
                    Text("The pierced-face check stopped early on this model.").font(.caption).foregroundStyle(.orange)
                }
                ForEach(report.allIssues.filter { $0.count > 0 }) { issue in
                    IssueRow(issue: issue)
                }
                let passed = report.allIssues.filter { $0.count == 0 }.map(\.title)
                if !passed.isEmpty {
                    Text("Passed: " + passed.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                if report.anyFixable {
                    HStack {
                        Button("Repair…") { app.repairGeometry() }
                            .disabled(cad.repairJob.map { !$0.status.isFinished } ?? false)
                        if let job = cad.repairJob, !job.status.isFinished { ProgressView().controlSize(.small) }
                    }
                    Text("Merges duplicate vertices, removes degenerate and duplicate faces, makes normals consistent and outward, closes small holes (STEP/IGES: shape fixing and sewing). Pierced faces and non-manifold edges are left for you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let summary = cad.repairSummary {
                    Text(summary).font(.caption)
                }
                if let job = cad.repairJob, job.status == .failed {
                    Label(job.message ?? "Repair failed", systemImage: "xmark.octagon").foregroundStyle(.red)
                }
            }
        } header: {
            Text("Geometry check")
        }
    }
}

struct IssueRow: View {
    @Environment(AppState.self) private var app
    let issue: GeometryReport.Issue

    var body: some View {
        let cad = app.cad
        let c = CADViewerModel.color(for: issue.kind)
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { cad.shownIssues.contains(issue.kind) },
                set: { on in if on { cad.shownIssues.insert(issue.kind) } else { cad.shownIssues.remove(issue.kind) } })) {
                HStack {
                    Circle().fill(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))).frame(width: 10, height: 10)
                    Text(issue.title)
                    Spacer()
                    Text("\(issue.count)").monospacedDigit()
                        .foregroundStyle(issue.severity == "error" ? .red : issue.severity == "warning" ? .orange : .secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(issue.points.isEmpty)
            Text(issue.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The visible parts cut by a plane across x, y or z, drawn flat and to
/// scale, with the plane's position on a slider.
struct CADSectionView: View {
    @Environment(AppState.self) private var app
    @State private var hover: SIMD2<Double>?

    var body: some View {
        @Bindable var cad = app.cad
        let axes = SectionCutter.planeAxes(cad.sectionAxis)
        let u = axes.0, v = axes.1
        let names = ["x", "y", "z"]
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Picker("Across", selection: $cad.sectionAxis) {
                    ForEach(0..<3, id: \.self) { Text(names[$0]).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Slider(value: $cad.sectionPosition, in: cad.sectionRange)
                TextField("mm", value: Binding(get: { cad.sectionPosition * 1000 }, set: { cad.sectionPosition = $0 / 1000 }),
                          format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 70)
                Text("mm").foregroundStyle(.secondary)
                if let h = hover {
                    Text(String(format: "%@ %.1f, %@ %.1f mm", names[u], h.x * 1000, names[v], h.y * 1000))
                        .font(.caption.monospacedDigit())
                        .frame(width: 170, alignment: .trailing)
                }
            }
            .controlSize(.small)
            GeometryReader { geo in
                let fit = fit(geo.size, cad, u, v)
                Canvas { ctx, _ in
                    var path = Path()
                    for (a, b) in cad.sectionSegments {
                        path.move(to: fit.view(a))
                        path.addLine(to: fit.view(b))
                    }
                    ctx.stroke(path, with: .color(.primary), lineWidth: 1)
                    if cad.sectionSegments.isEmpty {
                        ctx.draw(Text("The plane misses the visible parts").foregroundStyle(.secondary),
                                 at: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2))
                    }
                    let bar = SliceExportView.niceLength(fit.span / 5)
                    let y = geo.size.height - 10
                    ctx.stroke(Path { p in p.move(to: CGPoint(x: 10, y: y)); p.addLine(to: CGPoint(x: 10 + bar * fit.scale, y: y)) },
                               with: .color(.secondary), lineWidth: 2)
                    ctx.draw(Text(bar >= 1 ? String(format: "%g m", bar) : String(format: "%g mm", bar * 1000)).font(.caption2),
                             at: CGPoint(x: 10 + bar * fit.scale / 2, y: y - 9))
                    ctx.draw(Text("\(names[v]) up, \(names[u]) across").font(.caption2).foregroundStyle(.secondary),
                             at: CGPoint(x: geo.size.width - 70, y: geo.size.height - 10))
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hover = fit.world(p)
                    case .ended: hover = nil
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .padding(6)
    }

    private struct Fit {
        let scale: Double
        let x0: Double
        let y1: Double
        let ox: Double
        let oy: Double
        let span: Double

        func view(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: ox + (p.x - x0) * scale, y: oy + (y1 - p.y) * scale) }
        func world(_ p: CGPoint) -> SIMD2<Double> { SIMD2(x0 + (p.x - ox) / scale, y1 - (p.y - oy) / scale) }
    }

    /// Framed on all the visible parts, not just this cut, so the scale holds
    /// still while the plane moves.
    private func fit(_ size: CGSize, _ cad: CADViewerModel, _ u: Int, _ v: Int) -> Fit {
        let b = cad.visibleBounds ?? (SIMD3(repeating: 0), SIMD3(repeating: 1))
        let w = max(b.max[u] - b.min[u], 1e-6), h = max(b.max[v] - b.min[v], 1e-6)
        let pad = 16.0
        let scale = min((size.width - 2 * pad) / w, (size.height - 2 * pad) / h)
        return Fit(scale: scale, x0: b.min[u], y1: b.max[v], ox: (size.width - w * scale) / 2, oy: (size.height - h * scale) / 2, span: w)
    }
}
