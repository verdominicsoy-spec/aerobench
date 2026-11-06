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
        ScrollView {
            VStack(alignment: .leading, spacing: S37.Space.s4) {
                VStack(alignment: .leading, spacing: S37.Space.s3) {
                    Text("No project open").font(.system(size: 20, weight: .semibold))
                    Text("A project is a folder: project.json, one subfolder per tool, and jobs/ for every run.")
                        .font(.system(size: 14)).foregroundStyle(S37.C.inkSecondary)
                    HStack(spacing: S37.Space.s3) {
                        Button("New project…") { app.newProjectPanel() }.buttonStyle(S37ButtonStyle(kind: .prominent))
                        Button("Open project…") { app.openProjectPanel() }.buttonStyle(S37ButtonStyle())
                    }
                    .padding(.top, S37.Space.s1)
                }
                if !app.recentProjects.isEmpty {
                    S37Section("Recent") {
                        ForEach(app.recentProjects, id: \.self) { url in
                            Button { app.open(url) } label: {
                                S37Row(url.lastPathComponent) {
                                    Text(url.deletingLastPathComponent().path).foregroundStyle(S37.C.inkSecondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open") { app.open(url) }
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }
                        }
                    }
                }
                S37Section("Engine checks") { EngineChecksView() }
            }
            .padding(S37.Space.s6)
        }
        .scrollIndicators(.never)
        .s37Region()
        .frame(maxWidth: 760)
    }
}

struct ProjectDetailView: View {
    @Environment(AppState.self) private var app
    let project: AppState.OpenProject

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: S37.Space.s4) {
                S37Section("Project") {
                    S37Row("Name") {
                        TextField("Name", text: Binding(get: { project.manifest.name },
                                                        set: { value in app.updateManifest { $0.name = value } }))
                            .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    }
                    S37Row("Folder") { Text(project.url.path).textSelection(.enabled) }
                    S37Row("Created") { Text(project.manifest.created.formatted(date: .abbreviated, time: .shortened)) }
                    S37Row("Saved") { Text(project.manifest.modified.formatted(date: .abbreviated, time: .shortened)) }
                    VStack(alignment: .leading, spacing: S37.Space.s2) {
                        Text("Notes").font(.system(size: 14))
                        TextField("Notes", text: Binding(get: { project.manifest.notes },
                                                         set: { value in app.updateManifest { $0.notes = value } }),
                                  prompt: Text("What this project is testing"), axis: .vertical)
                            .textFieldStyle(.plain).lineLimit(3...8)
                            .padding(S37.Space.s2)
                            .background(RoundedRectangle(cornerRadius: S37.Radius.sm, style: .continuous).fill(S37.C.recess))
                    }
                    .padding(.vertical, S37.Space.s3)
                }
                S37Section("Engine checks") { EngineChecksView() }
            }
            .padding(S37.Space.s6)
        }
        .scrollIndicators(.never)
        .s37Region()
        .frame(maxWidth: 760)
        .toolbar {
            Button("Save", systemImage: "square.and.arrow.down") { app.saveProject() }
                .disabled(!app.hasUnsavedChanges)
            Button("Reveal in Finder", systemImage: "folder") { app.revealProject() }
        }
    }
}

/// Ping and dummy-job buttons, the Phase 0 acceptance checks.
struct EngineChecksView: View {
    @Environment(AppState.self) private var app
    @AppStorage("dummy.duration") private var duration = 10
    @AppStorage("dummy.keepMesh") private var keepMesh = false

    var body: some View {
        if !app.settings.engineIsReady {
            Label("Engine not found. Set the engine folder in Settings (⌘,) and run `uv sync` in it.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(S37.C.clayInk)
        }
        S37Row("Ping") {
            if let job = app.pingJob { PingResultView(job: job) }
            Button("Ping engine") { app.runPing() }.buttonStyle(S37ButtonStyle())
        }
        S37Row("Dummy job") {
            Text("\(duration) s").monospacedDigit()
            Stepper("Duration", value: $duration, in: 1...120).labelsHidden()
            Toggle("Keep mesh", isOn: $keepMesh)
            Button("Run") { app.runDummy(duration: duration, keepMesh: keepMesh) }.buttonStyle(S37ButtonStyle())
        }
        S37Row("Jobs folder") {
            Text(app.jobsRoot.path).textSelection(.enabled).foregroundStyle(S37.C.inkSecondary)
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
                .foregroundStyle(S37.C.sageInk)
        case .failed:
            Label(job.message ?? "failed", systemImage: "xmark.octagon")
                .foregroundStyle(S37.C.critical)
                .help(job.detail ?? "")
        case .cancelled:
            Label("cancelled", systemImage: "stop.circle")
        }
    }
}
