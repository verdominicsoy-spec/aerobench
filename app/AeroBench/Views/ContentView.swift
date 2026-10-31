import AeroBenchKit
import SwiftUI

/// The tools, in working order: design the wing, see what it is worth on a
/// lap, check it on the car, then look at the flow from STAR.
enum Tool: String, CaseIterable, Identifiable {
    case project, wingLab, lapSim, cadViewer, flowField, jobs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: "Project"
        case .wingLab: "Wing Lab"
        case .lapSim: "Lap Sim"
        case .cadViewer: "CAD Viewer"
        case .flowField: "Flow Field"
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
        case .jobs: "list.bullet.rectangle"
        }
    }

    /// ⌘1 to ⌘6, in dock order.
    var key: KeyEquivalent { KeyEquivalent(Character(String((Tool.allCases.firstIndex(of: self) ?? 0) + 1))) }
}

struct ContentView: View {
    @Environment(AppState.self) private var app
    @SceneStorage("tool") private var selection: Tool = .project

    var body: some View {
        VStack(spacing: 0) {
            ToolDock(selection: $selection)
            Divider().overlay(S37.C.separator)
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
                case .jobs:
                    JobsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        return app.hasUnsavedChanges ? "\(project.manifest.name) — Edited" : project.manifest.name
    }
}


/// The dock across the top: the project, the four tools, the engine's jobs.
struct ToolDock: View {
    @Environment(AppState.self) private var app
    @Binding var selection: Tool

    var body: some View {
        HStack(spacing: 6) {
            item(.project, title: app.project?.manifest.name ?? "No Project")
            Divider().frame(height: 18).padding(.horizontal, 4)
            ForEach([Tool.wingLab, .lapSim, .cadViewer, .flowField]) { item($0, title: $0.title) }
            Spacer(minLength: 12)
            item(.jobs, title: app.jobs.runningCount > 0 ? "Jobs · \(app.jobs.runningCount) running" : "Jobs")
        }
        .padding(.horizontal, S37.Space.s3)
        .padding(.vertical, 6)
        .background(S37.C.surface)
    }

    private func item(_ tool: Tool, title: String) -> some View {
        let on = selection == tool
        return Button { selection = tool } label: {
            Label(title, systemImage: tool.symbol)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? S37.C.onSage : S37.C.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 26)
                .background { if on { Capsule().fill(S37.C.sage) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(tool.key, modifiers: .command)
        .help("\(tool.title) (⌘\(String(tool.key.character)))")
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
