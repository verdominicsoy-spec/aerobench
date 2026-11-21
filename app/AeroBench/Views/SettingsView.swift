import AeroBench3D
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
                        .foregroundStyle(S37.C.sageInk)
                } else {
                    Label("No engine at <folder>/.venv/bin/aeroengine. Run `uv sync` in the engine folder.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(S37.C.clayInk)
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
                if let su2 = settings.su2Executable {
                    Label("Found \(su2.path)", systemImage: "checkmark.circle").foregroundStyle(S37.C.sageInk)
                } else {
                    Label("No SU2_CFD found. Install it from Wing Lab, Solvers, RANS CFD, or choose one here.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(S37.C.clayInk)
                }
            } header: {
                Text("SU2")
            } footer: {
                Text("Wing Lab's RANS CFD, angle sweeps and the optimiser's RANS checks run on it. Left empty, the app looks next to the engine and in Homebrew's folders.")
            }

            Section {
                Stepper("Max parallel jobs: \(settings.maxParallelJobs)", value: $settings.maxParallelJobs, in: 1...16)
                Stepper("Cores per job: \(settings.coresPerJob)", value: $settings.coresPerJob, in: 1...max(1, totalCores))
                Stepper("Wing optimiser trials at once: \(settings.parallelTrials)", value: $settings.parallelTrials, in: 1...16)
            } header: {
                Text("Compute")
            } footer: {
                Text("Up to \(settings.maxParallelJobs * settings.coresPerJob) of \(totalCores) cores. Leave some free for the rest of the Mac. "
                     + "A wing optimisation runs its trials at once on \(settings.coresPerJob) cores each, "
                     + "\(settings.parallelTrials * settings.coresPerJob) in all.")
            }

            peekSection(settings)
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func peekSection(_ settings: AppSettings) -> some View {
        @Bindable var settings = settings
        Section {
            Toggle("Hold Shift to peek with head tracking", isOn: $settings.peekEnabled)
                .onChange(of: settings.peekEnabled) { app.applyPeekSettings() }
            peekStatus(app.cad.viewer.peek?.tracker)
        } header: {
            Text("Head-tracked peek")
        } footer: {
            Text("Hold Shift over the CAD or Flow Field view and move your head, as if the screen were a window. Built-in display only.")
        }
    }

    @ViewBuilder
    private func peekStatus(_ tracker: HeadTracker?) -> some View {
        switch tracker?.status {
        case .denied?:
            Label("Camera access is off: System Settings > Privacy & Security > Camera", systemImage: "exclamationmark.triangle")
                .foregroundStyle(S37.C.clayInk)
        case .noCamera?:
            Label("No built-in camera found", systemImage: "exclamationmark.triangle").foregroundStyle(S37.C.clayInk)
        case .needsPermission?:
            Label("The first Shift over the CAD or Flow Field view asks for the camera", systemImage: "info.circle").foregroundStyle(.secondary)
        default:
            EmptyView()
        }
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
