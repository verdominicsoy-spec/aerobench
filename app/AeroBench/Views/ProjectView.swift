import AeroBenchKit
import AppKit
import SwiftUI

struct ProjectView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let project = app.project {
            ProjectDetailView(project: project)
        } else {
            WelcomeView()
        }
    }
}

struct WelcomeView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("New Project…") { app.newProjectPanel() }
                    Button("Open Project…") { app.openProjectPanel() }
                }
            } header: {
                Text("AeroBench")
            } footer: {
                Text("A project is a folder with project.json, one subfolder per tool and jobs/ for every run.")
            }
            if !app.recentProjects.isEmpty {
                Section("Recent Projects") {
                    ForEach(app.recentProjects, id: \.self) { url in
                        Button {
                            app.open(url)
                        } label: {
                            LabeledContent(url.lastPathComponent, value: url.deletingLastPathComponent().path)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("Engine Checks") {
                EngineChecksView()
            }
        }
        .formStyle(.grouped)
    }
}

struct ProjectDetailView: View {
    @Environment(AppState.self) private var app
    let project: AppState.OpenProject

    var body: some View {
        Form {
            Section("Project") {
                TextField("Name", text: Binding(
                    get: { project.manifest.name },
                    set: { value in app.updateManifest { $0.name = value } }
                ))
                LabeledContent("Folder") {
                    Text(project.url.path).textSelection(.enabled)
                }
                LabeledContent("Created", value: project.manifest.created.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Saved", value: project.manifest.modified.formatted(date: .abbreviated, time: .shortened))
                TextField("Notes", text: Binding(
                    get: { project.manifest.notes },
                    set: { value in app.updateManifest { $0.notes = value } }
                ), axis: .vertical)
                .lineLimit(3...8)
            }
            Section("Engine Checks") {
                EngineChecksView()
            }
        }
        .formStyle(.grouped)
        .toolbar {
            Button("Save", systemImage: "square.and.arrow.down") { app.saveProject() }
                .disabled(!project.isDirty)
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.url])
            }
        }
    }
}

/// Ping and dummy-job buttons, the Phase 0 acceptance checks.
struct EngineChecksView: View {
    @Environment(AppState.self) private var app
    @State private var duration = 10
    @State private var keepMesh = false

    var body: some View {
        if !app.settings.engineIsReady {
            Label("Engine not found. Set the engine folder in Settings (⌘,) and run `uv sync` in it.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        LabeledContent("Ping") {
            HStack {
                if let job = app.pingJob {
                    PingResultView(job: job)
                }
                Button("Ping Engine") { app.runPing() }
            }
        }
        LabeledContent("Dummy job") {
            HStack {
                Stepper("\(duration) s", value: $duration, in: 1...120)
                Toggle("Keep mesh", isOn: $keepMesh)
                Button("Run") { app.runDummy(duration: duration, keepMesh: keepMesh) }
            }
        }
        LabeledContent("Jobs folder") {
            Text(app.jobsRoot.path).textSelection(.enabled).font(.caption)
        }
    }
}

struct PingResultView: View {
    let job: JobItem

    var body: some View {
        switch job.status {
        case .queued, .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            let data = job.resultData ?? [:]
            Label("pong from Python \(data["python"] as? String ?? "?"), engine \(data["engine_version"] as? String ?? "?")",
                  systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .failed:
            Label(job.message ?? "failed", systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .help(job.detail ?? "")
        case .cancelled:
            Label("cancelled", systemImage: "stop.circle")
        }
    }
}
