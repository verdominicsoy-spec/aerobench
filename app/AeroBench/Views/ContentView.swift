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
        } detail: {
            switch selection ?? .project {
            case .project:
                ProjectView()
            case .wingLab:
                ToolPlaceholderView(title: "Wing Lab", systemImage: "airplane", phase: 4,
                                    summary: "Multi-element wings from the airfoil library, inviscid preview, SU2 runs and gap and angle optimisation.")
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
                Task { await app.flow.open(url) }
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

struct ToolPlaceholderView: View {
    let title: String
    let systemImage: String
    let phase: Int
    let summary: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text("\(summary)\nArrives in Phase \(phase).")
        }
    }
}
