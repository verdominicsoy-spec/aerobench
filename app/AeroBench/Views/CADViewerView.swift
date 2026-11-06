import AeroBench3D
import AeroBenchKit
import SwiftUI

struct CADViewerView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HSplitView {
            CADSidePanel()
                .s37Region()
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
            .s37Region()
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var overlay: some View {
        switch app.cad.status {
        case .empty:
            S37EmptyState(title: "No model", line: "Open a STEP, IGES, STL or OBJ file, or drop one on the window.") {
                Button("Open…") { app.openCADPanel() }.buttonStyle(S37ButtonStyle(kind: .prominent))
            }
            .background(S37.C.surface)
        case .loading(let message):
            VStack(spacing: 8) {
                if let job = app.cad.job, !job.status.isFinished {
                    ProgressView(value: job.progress, total: 100).frame(width: 220)
                    Text(job.progressMessage.isEmpty ? message : job.progressMessage).font(.system(size: 12))
                    Button("Cancel") { app.jobs.cancel(job) }.buttonStyle(S37ButtonStyle(kind: .plain))
                } else {
                    ProgressView()
                    Text(message).font(.system(size: 12))
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        case .failed(let message, let detail):
            S37EmptyState(title: message, line: detail ?? "Try another file.") {
                Button("Open…") { app.openCADPanel() }.buttonStyle(S37ButtonStyle(kind: .prominent))
            }
            .background(S37.C.surface)
        case .ready:
            EmptyView()
        }
    }
}

struct CADToolbar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var cad = app.cad
        HStack(spacing: S37.Space.s2) {
            if cad.model != nil {
                Button("Open…") { app.openCADPanel() }
                Divider().frame(height: 18)
            }
            // The view, measuring and section tools need a model to act on.
            Group {
                ForEach(StandardView.allCases) { view in
                    Button(view.title) { cad.viewer.look(from: view) }
                }
                Button("Fit") { cad.viewer.fitAll() }
                S37Segmented(options: [(Projection.perspective, "Persp"), (.orthographic, "Ortho")], selection: $cad.projection)
                    .fixedSize()
                Divider().frame(height: 18)
                Toggle("Measure", isOn: $cad.measuring)
                if cad.measuring {
                    Toggle("Snap", isOn: $cad.snap).help("Snap measuring points to the nearest vertex")
                }
                Toggle("Section", isOn: $cad.sectionOn)
            }
            .disabled(cad.model == nil)
            Spacer()
        }
        .buttonStyle(S37ButtonStyle())
        .toggleStyle(S37ToggleButtonStyle())
        .controlSize(.small)
        .padding(.horizontal, S37.Space.s2)
        .padding(.vertical, S37.Space.s2)
    }
}

struct CADSidePanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.partEdit.on {
            PartEditView()
        } else {
            inspector
        }
    }

    @ViewBuilder private var inspector: some View {
        @Bindable var cad = app.cad
        ScrollView {
            VStack(alignment: .leading, spacing: S37.Space.s6) {
                S37Section("File") {
                    if let url = cad.fileURL {
                        LabeledContent("Name") { Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle) }
                            .help(url.path)
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
                        LabeledContent("Triangles", value: cad.triangleCount.formatted() + (cad.fromCache ? ", from cache" : ""))
                    }
                }
                if cad.fileURL != nil {
                    GeometryCheckSection()
                }
                if cad.isStep && cad.model != nil {
                    BodyRepairSection()
                    S37Section("Edit") {
                        Button("Edit part") { app.enterPartEdit() }.buttonStyle(S37ButtonStyle())
                            .padding(.vertical, S37.Space.s2)
                    }
                }
                if let model = cad.model {
                    S37Section("Parts") {
                        if !cad.hidden.isEmpty {
                            Button("Show all") { cad.hidden = [] }.buttonStyle(S37ButtonStyle(kind: .plain))
                        }
                        PartTree(model: model).padding(.vertical, S37.Space.s2)
                    }
                }
            }
            .padding(S37.Space.s5)
        }
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
                        Text(model.meshes[m].triangleCount.formatted()).font(.system(size: 12)).monospacedDigit().foregroundStyle(S37.C.inkTertiary)
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
                        .fontWeight(.semibold)
                        .textSelection(.enabled)
                    Button("Clear") { cad.clearMeasurement() }.buttonStyle(S37ButtonStyle(kind: .plain)).controlSize(.small)
                } else {
                    Text(cad.points.isEmpty ? "Click the first point" : "Click the second point")
                        .foregroundStyle(S37.C.inkSecondary)
                }
            }
        }
        .font(.system(size: 13).monospacedDigit())
        .padding(.horizontal, S37.Space.s3)
        .padding(.vertical, S37.Space.s1)
    }

    private func mm(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(2))) }
}

struct GeometryCheckSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let cad = app.cad
        S37Section("Geometry check") {
            Button(cad.report == nil ? "Check geometry" : "Check again") { app.checkGeometry() }
                .buttonStyle(S37ButtonStyle())
                .disabled(cad.checkJob.map { !$0.status.isFinished } ?? false)
                .padding(.vertical, S37.Space.s2)
            if let job = cad.checkJob, !job.status.isFinished {
                HStack {
                    ProgressView(value: job.progress, total: 100)
                    Text(job.progressMessage).font(.system(size: 12)).lineLimit(1)
                }
            } else if let job = cad.checkJob, job.status == .failed {
                Label(job.message ?? "The check failed", systemImage: "xmark.octagon").foregroundStyle(S37.C.critical)
            }
            if let report = cad.report {
                if report.problems == 0 {
                    Label("No problems found", systemImage: "checkmark.seal").foregroundStyle(S37.C.sageInk)
                } else {
                    Label("\(report.problems) problems", systemImage: "exclamationmark.triangle").foregroundStyle(S37.C.clayInk)
                }
                LabeledContent("Bodies", value: "\(report.mesh.bodies)")
                LabeledContent("Closed", value: report.mesh.closed ? "yes, watertight" : "no")
                if report.mesh.intersectionsComplete == false {
                    Text("The pierced-face check stopped early on this model.").font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.clayInk)
                }
                ForEach(report.allIssues.filter { $0.count > 0 }) { issue in
                    IssueRow(issue: issue).padding(.vertical, S37.Space.s1)
                }
                let passed = report.allIssues.filter { $0.count == 0 }.map(\.title)
                if !passed.isEmpty {
                    Text("Passed: " + passed.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, S37.Space.s2)
                }
                if report.anyFixable {
                    HStack {
                        Button("Repair…") { app.repairGeometry() }
                            .buttonStyle(S37ButtonStyle())
                            .disabled(cad.repairJob.map { !$0.status.isFinished } ?? false)
                            .help("Merges duplicate vertices, drops degenerate and duplicate faces, fixes normals and closes small holes (STEP/IGES: shape fixing and sewing). Pierced faces and non-manifold edges stay.")
                        if let job = cad.repairJob, !job.status.isFinished { ProgressView().controlSize(.small) }
                    }
                    .padding(.vertical, S37.Space.s2)
                }
                if let summary = cad.repairSummary {
                    Text(summary).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                if let job = cad.repairJob, job.status == .failed {
                    Label(job.message ?? "Repair failed", systemImage: "xmark.octagon").foregroundStyle(S37.C.critical)
                }
            }
        }
    }
}

/// STEP to one closed body: safe fixes run without asking, gaps between
/// the automatic limit and 10 mm wait here for accept or skip.
struct BodyRepairSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var cad = app.cad
        let running = cad.bodyJob.map { !$0.status.isFinished } ?? false
        S37Section("Repair to one body") {
            HStack {
                Button("Repair to one body…") { app.planBodyRepair() }.buttonStyle(S37ButtonStyle()).disabled(running)
                if running, let job = cad.bodyJob {
                    ProgressView(value: job.progress, total: 100).frame(maxWidth: 120)
                    Text(job.progressMessage).font(.system(size: 12)).lineLimit(1)
                }
            }
            .padding(.vertical, S37.Space.s2)
            NumberField(label: "Fix gaps up to", unit: "mm", digits: 2,
                        value: Binding(get: { cad.bodyLimitMM }, set: { cad.bodyLimitMM = min(max($0, 0.01), 10) }))
                .help("Gaps from this size to 10 mm are listed for you to accept or skip; wider ones are never closed")
            if let job = cad.bodyJob, job.status == .failed {
                Label(job.message ?? "The repair failed", systemImage: "xmark.octagon").foregroundStyle(S37.C.critical)
            }
            if let plan = cad.bodyPlan {
                let review = plan.items.filter(\.reviewable)
                let reports = plan.items.filter { !$0.reviewable }
                if let summary = cad.bodySummary {
                    Text(summary).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                if !review.isEmpty {
                    List(selection: $cad.selectedBodyItem) {
                        ForEach(review) { item in
                            BodyRepairRow(item: item).tag(item.id)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 240)
                    HStack {
                        Button("Accept all") { for item in review where item.fix != "open_shell" && item.fix != "failed" { cad.bodyDecisions[item.id] = true } }
                            .buttonStyle(S37ButtonStyle(kind: .plain))
                        Spacer()
                        Text("\(cad.pendingBodyItems) to decide").font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
                        Button("Apply") { app.applyBodyRepair() }.buttonStyle(S37ButtonStyle()).disabled(running)
                    }
                    .padding(.vertical, S37.Space.s2)
                }
                ForEach(reports) { item in
                    Label(item.kind == "wide_gap"
                          ? String(format: "%@: %.2f mm gap, too wide to close", item.part, item.sizeMM ?? 0)
                          : "\(item.part): edge shared by 3+ faces",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.clayInk)
                        .onTapGesture { cad.selectedBodyItem = item.id }
                }
                if review.isEmpty && reports.isEmpty && cad.bodySummary == nil {
                    Text("Nothing to review.")
                }
            }
        }
    }
}

struct BodyRepairRow: View {
    @Environment(AppState.self) private var app
    let item: BodyRepairResult.Item

    var body: some View {
        let cad = app.cad
        HStack {
            Text(item.fix == "failed" ? "Gap, bridge failed"
                 : item.kind == "gap" ? "Gap" : item.fix == "fill" ? "Hole" : "Hole, can\u{2019}t patch")
            Text(item.part).foregroundStyle(S37.C.inkSecondary).lineLimit(1)
            Spacer()
            if let size = item.sizeMM {
                Text(String(format: "%.2f mm", size)).monospacedDigit()
            }
            S37Segmented(options: [(Bool?.none, "–"), (Bool?.some(true), "Accept"), (Bool?.some(false), "Skip")],
                         selection: Binding(get: { cad.bodyDecisions[item.id] }, set: { cad.bodyDecisions[item.id] = $0 }))
                .fixedSize()
                .disabled(item.fix == "open_shell" || item.fix == "failed")
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
                        .foregroundStyle(issue.severity == "error" ? S37.C.critical : issue.severity == "warning" ? S37.C.clayInk : S37.C.inkSecondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(issue.points.isEmpty)
            Text(issue.detail).font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
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
                S37Segmented(options: (0..<3).map { ($0, names[$0]) }, selection: $cad.sectionAxis).fixedSize()
                Slider(value: $cad.sectionPosition, in: cad.sectionRange)
                TextField("mm", value: Binding(get: { cad.sectionPosition * 1000 }, set: { cad.sectionPosition = $0 / 1000 }),
                          format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing).monospacedDigit()
                    .padding(.horizontal, S37.Space.s2).frame(width: 70, height: 24)
                    .background(RoundedRectangle(cornerRadius: S37.Radius.sm, style: .continuous).fill(S37.C.recess))
                Text("mm").foregroundStyle(S37.C.inkTertiary)
                if let h = hover {
                    Text(String(format: "%@ %.1f, %@ %.1f mm", names[u], h.x * 1000, names[v], h.y * 1000))
                        .font(.system(size: 12).monospacedDigit())
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
