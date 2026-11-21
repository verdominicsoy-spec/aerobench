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
                    MeasureLabels()
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
            S37EmptyState(title: "No model", line: "Open STEP, IGES, STL or OBJ files, or drop them on the window. Several open together.") {
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
        @Bindable var measure = app.cad.measure
        HStack(spacing: S37.Space.s2) {
            if cad.model != nil {
                Button("Open…") { app.openCADPanel() }
                Button("Add…") { app.openCADPanel(adding: true) }.help("Show more files with the open ones")
                Divider().frame(height: 18)
            }
            // The view, measuring and section tools need a model to act on.
            Group {
                ForEach(StandardView.allCases) { view in
                    Button(view.title) { cad.viewer.look(from: view) }.help("\(view.title) view (\(view.key))")
                }
                Button("Fit") { cad.viewer.fitAll() }.help("Fit everything (F)")
                S37Segmented(options: [(Projection.perspective, "Persp"), (.orthographic, "Ortho")], selection: $cad.projection)
                    .fixedSize()
                Divider().frame(height: 18)
                Toggle("Measure", isOn: $measure.on)
                if cad.measure.on {
                    S37Segmented(options: MeasureMode.allCases.map { ($0, $0.rawValue) }, selection: $measure.mode)
                        .fixedSize()
                    Toggle("Snap", isOn: $measure.snap)
                        .help("Snap to the part's corners, edge midpoints, hole centres and edges under the pointer")
                    if !cad.measure.pending.isEmpty {
                        Button("Cancel") { cad.measure.cancelPending() }.keyboardShortcut(.escape, modifiers: [])
                    }
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
        .padding(.vertical, S37.Space.s1)
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
            VStack(alignment: .leading, spacing: S37.Space.s4) {
                S37Section("File") {
                    ForEach(cad.fileURLs, id: \.self) { url in
                        LabeledContent("Name") { Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle) }
                            .help(url.path)
                    }
                    if cad.fileURLs.count > 1 {
                        Text("Check, repair and Edit Part work with one file open.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Picker("Tessellation", selection: $cad.preset) {
                        ForEach(TessellationPreset.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .onChange(of: cad.preset) { if cad.hasTessellatedFile { app.reloadCAD() } }
                    Picker("STL/OBJ units", selection: $cad.meshUnits) {
                        ForEach(LengthUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .onChange(of: cad.meshUnits) { if cad.hasMeshFile { app.reloadCAD() } }
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
                            .padding(.vertical, S37.Space.s1)
                    }
                }
                if !cad.measure.items.isEmpty {
                    MeasurementsSection()
                }
                if let model = cad.model {
                    S37Section("Parts") {
                        HStack {
                            if !cad.hidden.isEmpty {
                                Button("Show all") { cad.hidden = [] }.buttonStyle(S37ButtonStyle(kind: .plain))
                            }
                            if !cad.removed.isEmpty {
                                Button("Restore deleted (\(cad.removed.count))") { cad.restoreRemoved() }.buttonStyle(S37ButtonStyle(kind: .plain))
                            }
                        }
                        PartTree(model: model).padding(.vertical, S37.Space.s1)
                        Text("Click a part, then press Delete to take it out of the scene. The file is not changed.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(S37.Space.s3)
        }
    }
}

struct PartTree: View {
    @Environment(AppState.self) private var app
    let model: Model3D

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OutlineGroup(visibleRoots, children: \.childNodes) { node in
                HStack {
                    Toggle("", isOn: Binding(get: { app.cad.isVisible(node.id) }, set: { app.cad.setVisible(node.id, $0) }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Text(node.name).lineLimit(1)
                    Spacer()
                    if let m = node.mesh {
                        Text(model.meshes[m].triangleCount.formatted()).font(.system(size: 12)).monospacedDigit().foregroundStyle(S37.C.inkTertiary)
                    }
                }
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(app.cad.selectedPart == node.id ? S37.C.sageWash : .clear))
                .contentShape(Rectangle())
                .onTapGesture { app.cad.selectedPart = node.id }
                .contextMenu { Button("Delete from scene") { app.deleteCADPart(node.id) } }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand { if let id = app.cad.selectedPart { app.deleteCADPart(id) } }
    }

    /// The tree without deleted parts.
    private var visibleRoots: [ModelNode] {
        func keep(_ n: ModelNode) -> ModelNode? {
            guard !app.cad.removed.contains(n.id) else { return nil }
            var n = n
            n.children = n.children.compactMap(keep)
            return n
        }
        return model.roots.compactMap(keep)
    }
}

/// Every measurement kept, with its value; select one and press Delete to remove it.
struct MeasurementsSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let m = app.cad.measure
        S37Section("Measurements") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(m.items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(item.mode.rawValue)  \(item.title)").fontWeight(.medium).textSelection(.enabled)
                            if let d = item.detail { Text(d).font(.system(size: 11)).foregroundStyle(S37.C.inkSecondary).textSelection(.enabled) }
                        }
                        Spacer()
                        Button { m.remove(item.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Delete this measurement").accessibilityLabel("Delete measurement")
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(m.selected == item.id ? S37.C.sageWash : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { m.selected = item.id }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onDeleteCommand { if let id = m.selected { m.remove(id) } }
            Button("Delete all") { m.removeAll() }.buttonStyle(S37ButtonStyle(kind: .plain)).padding(.vertical, S37.Space.s1)
        }
    }
}

/// Each measurement's value beside it in the view, following the camera.
struct MeasureLabels: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let m = app.cad.measure
        GeometryReader { geo in
            let _ = m.cameraTick  // redraw when the camera moves
            ForEach(m.items) { item in
                let p = m.project(item.anchor)
                if p.z >= 0, p.z <= 1 {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(m.selected == item.id ? S37.C.sageWash : S37.C.surface.opacity(0.92)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(S37.C.critical.opacity(0.6), lineWidth: 1))
                        .fixedSize()
                        .position(x: p.x, y: geo.size.height - p.y - 14)
                        .onTapGesture { m.selected = item.id }
                }
            }
        }
        .allowsHitTesting(!m.items.isEmpty)
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
            if cad.measure.on {
                Text(cad.measure.prompt).foregroundStyle(cad.measure.message == nil ? S37.C.inkSecondary : S37.C.clayInk)
                if let h = cad.measure.hover, h.kind != .surface {
                    Text("Snap: \(h.kind.rawValue)").foregroundStyle(S37.C.inkTertiary)
                }
            } else if let m = cad.measure.items.last {
                Text(m.title + (m.detail.map { "   " + $0 } ?? "")).fontWeight(.semibold).textSelection(.enabled)
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
                .padding(.vertical, S37.Space.s1)
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
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, S37.Space.s1)
                }
                if report.anyFixable {
                    HStack {
                        Button("Repair…") { app.repairGeometry() }
                            .buttonStyle(S37ButtonStyle())
                            .disabled(cad.repairJob.map { !$0.status.isFinished } ?? false)
                            .help("Merges duplicate vertices, drops degenerate and duplicate faces, fixes normals and closes small holes (STEP/IGES: shape fixing and sewing). Pierced faces and non-manifold edges stay.")
                        if let job = cad.repairJob, !job.status.isFinished { ProgressView().controlSize(.small) }
                    }
                    .padding(.vertical, S37.Space.s1)
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
            .padding(.vertical, S37.Space.s1)
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
                    .padding(.vertical, S37.Space.s1)
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
                S37NumberInput(label: "mm", value: Binding(get: { cad.sectionPosition * 1000 }, set: { cad.sectionPosition = $0 / 1000 }),
                               digits: 1, width: 70)
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
