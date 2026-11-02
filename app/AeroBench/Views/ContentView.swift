import AeroBenchKit
import SwiftUI

/// The tools, in working order: design the wing, see what it is worth on a
/// lap, check it on the car, then look at the flow from STAR, with the
/// prism layer sizes for STAR's mesher alongside.
enum Tool: String, CaseIterable, Identifiable {
    case project, wingLab, lapSim, cadViewer, flowField, prismLayer, jobs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: "Project"
        case .wingLab: "Wing Lab"
        case .lapSim: "Lap Sim"
        case .cadViewer: "CAD Viewer"
        case .flowField: "Flow Field"
        case .prismLayer: "Prism Layer"
        case .jobs: "Jobs"
        }
    }

    var symbol: String {
        switch self {
        case .project: "folder"
        case .wingLab: "airplane"
        case .lapSim: "flag.checkered"
        case .cadViewer: "cube"
        case .flowField: "wind"
        case .prismLayer: "square.stack.3d.up"
        case .jobs: "list.bullet.rectangle"
        }
    }

    /// Short label under the icon in the dock
    var dockTitle: String {
        switch self {
        case .cadViewer: "CAD"
        case .flowField: "Flow"
        case .prismLayer: "Prism"
        default: title
        }
    }

    /// What the tool is for, in one plain line beside its title
    var note: String {
        switch self {
        case .project: "A project is a folder: project.json, a subfolder per tool and jobs/ for every run."
        case .wingLab: "Draw the wing element by element, then score it with the panel solver, RANS or the optimiser."
        case .lapSim: "What the aero is worth on the lap: ClA and CdA against lap time on the event tracks."
        case .cadViewer: "Open the car's CAD and check it is watertight and clean before it meshes."
        case .flowField: "Turn STAR's plane-sweep videos into a 3D flow field you can slice."
        case .prismLayer: "Prism layer sizes for a target y+, ready to type into STAR's mesher."
        case .jobs: "Every engine run: its progress, its log and its result."
        }
    }

    /// The line drawing behind the tool
    var motif: S37Motif {
        switch self {
        case .project, .jobs: .plain
        case .wingLab: .wing
        case .lapSim: .track
        case .cadViewer: .floor
        case .flowField: .vortex
        case .prismLayer: .prism
        }
    }

    /// The dock's tools; the project sits in the header.
    static let docked: [Tool] = [.wingLab, .lapSim, .cadViewer, .flowField, .prismLayer, .jobs]

    /// ⌘1 to ⌘7: the project, then the dock in order.
    var key: KeyEquivalent { KeyEquivalent(Character(String((Tool.allCases.firstIndex(of: self) ?? 0) + 1))) }
}

struct ContentView: View {
    @Environment(AppState.self) private var app
    @SceneStorage("tool") private var selection: Tool = .project
    @State private var takeaway: String?

    var body: some View {
        S37Root(motif: selection.motif) {
            VStack(alignment: .leading, spacing: 0) {
                ToolHeader(selection: $selection, takeaway: takeaway)
                    .padding(.horizontal, S37.Space.s6)
                    .padding(.top, S37.Space.s2)
                    .padding(.bottom, S37.Space.s1)
                if app.updatesBehind > 0, !app.updateDismissed {
                    UpdateBanner()
                        .padding(.horizontal, S37.Space.s4)
                        .padding(.bottom, S37.Space.s2)
                }
                Group {
                    switch selection {
                    case .project:
                        ProjectView()
                    case .wingLab:
                        WingLabView()
                    case .cadViewer:
                        CADViewerView()
                    case .flowField:
                        FlowFieldView()
                    case .lapSim:
                        LapSimView()
                    case .prismLayer:
                        PrismLayerView()
                    case .jobs:
                        JobsView()
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onPreferenceChange(ToolTakeawayKey.self) { takeaway = $0 }
                Dock(selection: $selection, tools: Tool.docked) { tool in
                    tool == .jobs && app.jobs.runningCount > 0 ? "Jobs · \(app.jobs.runningCount)" : tool.dockTitle
                }
                .frame(maxWidth: .infinity)
                .padding(.top, S37.Space.s1)
                .padding(.bottom, S37.Space.s3)
            }
        }
        .foregroundStyle(S37.C.ink)
        .navigationTitle(windowTitle)
        .task { app.setUpBundledEngineIfNeeded() }
        .sheet(isPresented: Binding(get: { app.engineSetup.map { $0.phase != .done } ?? false },
                                    set: { if !$0 { app.engineSetup = nil } })) {
            EngineSetupView()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            let ext = url.pathExtension.lowercased()
            if CADViewerModel.openableExtensions.contains(ext) {
                selection = .cadViewer
                app.openCAD(url)
                return true
            }
            if ["mp4", "mov", "m4v"].contains(ext) {
                selection = .flowField
                app.openFlowVideo(url)
                return true
            }
            return false
        }
        .alert(
            app.alert?.title ?? "",
            isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } }),
            presenting: app.alert
        ) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
    }

    private var windowTitle: String {
        guard let project = app.project else { return "AeroBench" }
        return app.hasUnsavedChanges ? "\(project.manifest.name) — Edited" : project.manifest.name
    }
}


/// A tool's live takeaway for the header, in place of its note
struct ToolTakeawayKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) { value = nextValue() ?? value }
}

/// Meta line and Fraunces title on the left, the tool's takeaway (or a
/// one-line note about it) beside it, and on the right the project, which
/// opens its screen.
struct ToolHeader: View {
    @Environment(AppState.self) private var app
    @Binding var selection: Tool
    var takeaway: String?

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: S37.Space.s6) {
            VStack(alignment: .leading, spacing: S37.Space.s1) {
                Text(meta).font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(0.96)
                    .textCase(.uppercase).foregroundStyle(GO.C.phosphorFaint).lineLimit(1)
                Text(selection.title).font(.fraunces(32)).tracking(-0.32).foregroundStyle(S37.C.ink)
                    .lineLimit(1).fixedSize()
            }
            Text(takeaway ?? selection.note).font(.system(size: 14, weight: .medium)).foregroundStyle(S37.C.inkSecondary)
                .lineLimit(2).frame(maxWidth: 520, alignment: .leading)
            Spacer(minLength: S37.Space.s3)
            Button { selection = .project } label: {
                Label(app.project?.manifest.name ?? "No project", systemImage: Tool.project.symbol).lineLimit(1)
            }
            .buttonStyle(S37ButtonStyle())
            .keyboardShortcut(Tool.project.key, modifiers: .command)
            .help("Project (⌘1)")
            .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
        .s37HeaderShadow()
    }

    private var meta: String {
        var parts = ["AeroBench", app.project.map { app.hasUnsavedChanges ? "\($0.manifest.name), edited" : $0.manifest.name } ?? "No project open"]
        if app.jobs.runningCount > 0 { parts.append(app.jobs.runningCount == 1 ? "1 job running" : "\(app.jobs.runningCount) jobs running") }
        return parts.joined(separator: " · ")
    }
}

/// The packaged app's one-time engine setup.
struct EngineSetupView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setting up the engine").font(.title3.bold())
            switch app.engineSetup?.phase {
            case .working(let message):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(message)
                }
                Text("The engine's Python packages (NeuralFoil, gmsh, Optuna and the rest) are installed once into ~/Library/Application Support/AeroBench.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .needsUV:
                Text("AeroBench sets up its engine with uv, which is not installed. Install it with Homebrew (brew install uv) and reopen AeroBench, or let AeroBench install it from astral.sh.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Install uv") { app.installUVAndSetUp() }.buttonStyle(S37ButtonStyle(kind: .prominent))
                    Button("Later") { app.engineSetup = nil }
                }
            case .failed(let why):
                Text("The setup did not finish.").foregroundStyle(S37.C.critical)
                ScrollView { Text(why).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 160)
                HStack {
                    Button("Try Again") {
                        if let source = BundledEngine.source() { app.runEngineSetup(source: source, home: BundledEngine.home) }
                    }
                    .buttonStyle(S37ButtonStyle(kind: .prominent))
                    Button("Close") { app.engineSetup = nil }
                }
            case .done, nil:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// A newer version on GitHub: update now (AeroBench.command in Terminal) or later.
struct UpdateBanner: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").foregroundStyle(S37.C.sageInk)
            Text(app.updatesBehind == 1 ? "There is an update since this build." : "There are \(app.updatesBehind) updates since this build.")
            Text("Update & Restart pulls it, rebuilds (a minute or two) and reopens; your project is saved first.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Later") { app.updateDismissed = true }
                .buttonStyle(S37ButtonStyle(kind: .plain))
            // glass, not prominent: the tool below keeps the screen's one prominent button
            Button("Update & Restart") { app.updateAndRestart() }
                .buttonStyle(S37ButtonStyle())
        }
        .s37Pane(radius: S37.Radius.lgIn, padding: S37.Space.s2)
    }
}
