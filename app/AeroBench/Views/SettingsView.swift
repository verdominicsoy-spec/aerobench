import AeroBenchKit
import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        let totalCores = ProcessInfo.processInfo.activeProcessorCount

        Form {
            Section {
                HStack {
                    TextField("Engine folder", text: $settings.enginePath)
                    Button("Choose…") {
                        if let url = chooseFolder(title: "Choose the repo's engine folder") { settings.enginePath = url.path }
                    }
                }
                if settings.engineIsReady {
                    Label("Found \(settings.engineExecutable?.path ?? "")", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Label("No engine at <folder>/.venv/bin/aeroengine. Run `uv sync` in the engine folder.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Engine")
            }

            Section {
                HStack {
                    TextField("SU2_CFD binary or its folder", text: $settings.su2Path)
                    Button("Choose…") {
                        if let url = chooseFolder(title: "Choose the SU2 folder", files: true) { settings.su2Path = url.path }
                    }
                }
            } header: {
                Text("SU2")
            } footer: {
                Text("Used by Wing Lab from Phase 4.")
            }

            Section {
                Stepper("Max parallel jobs: \(settings.maxParallelJobs)", value: $settings.maxParallelJobs, in: 1...16)
                Stepper("Cores per job: \(settings.coresPerJob)", value: $settings.coresPerJob, in: 1...max(1, totalCores))
            } header: {
                Text("Compute")
            } footer: {
                Text("Up to \(settings.maxParallelJobs * settings.coresPerJob) of \(totalCores) cores. Leave room for the Parallels VM.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder(title: String, files: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = files
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
