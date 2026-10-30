import AeroBenchKit
import SwiftUI

enum SidebarItem: Hashable {
    case project, wingLab, cadViewer, flowField, lapSim, jobs
}

struct ContentView: View {
    @Environment(AppState.self) private var app
    @State private var selection: SidebarItem? = .project

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Project") {
                    Label(app.project?.manifest.name ?? "No Project", systemImage: "folder")
                        .tag(SidebarItem.project)
                }
                Section("Tools") {
                    Label("Wing Lab", systemImage: "airplane").tag(SidebarItem.wingLab)
                    Label("CAD Viewer", systemImage: "cube").tag(SidebarItem.cadViewer)
                    Label("Flow Field Viewer", systemImage: "wind").tag(SidebarItem.flowField)
                    Label("Lap Sim", systemImage: "flag.checkered").tag(SidebarItem.lapSim)
                }
                Section("Engine") {
                    Label("Jobs", systemImage: "list.bullet.rectangle")
                        .badge(app.jobs.runningCount)
                        .tag(SidebarItem.jobs)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            // sage37: the sidebar is a solid surface column, not translucent.
            .scrollContentBackground(.hidden)
            .background(S37.C.surface)
        } detail: {
            switch selection ?? .project {
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
            case .jobs:
                JobsView()
            }
        }
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
        return project.isDirty ? "\(project.manifest.name) — Edited" : project.manifest.name
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
                Text("The setup did not finish.").foregroundStyle(.red)
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
