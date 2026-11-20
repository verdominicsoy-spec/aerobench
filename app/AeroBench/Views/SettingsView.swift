import AeroBench3D
import AeroBenchKit
import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var calibrating = false
    @State private var calibrationMessage: String?

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
        let tracker = app.cad.viewer.peek?.tracker
        Section {
            Toggle("Hold Shift to peek with head tracking", isOn: Binding(
                get: { settings.peekEnabled },
                set: { on in
                    guard on else {
                        settings.peekEnabled = false
                        app.applyPeekSettings()
                        return
                    }
                    Task {
                        let granted = await tracker?.requestAccess() ?? false
                        settings.peekEnabled = granted
                        app.applyPeekSettings()
                    }
                }))
            Stepper("Your distance to the screen: \(Int(settings.peekDistanceCM)) cm",
                    value: $settings.peekDistanceCM, in: 30...120)
                .onChange(of: settings.peekDistanceCM) { app.applyPeekSettings() }
            HStack {
                Button(calibrating ? "Calibrating…" : "Calibrate") { calibrate(settings) }
                    .disabled(calibrating || !settings.peekEnabled)
                Text("Sit at that distance and look at the screen.").foregroundStyle(.secondary)
            }
            peekStatus(settings, tracker: tracker)
        } header: {
            Text("Head-tracked peek")
        } footer: {
            Text("In the CAD viewer, hold Shift and move your head to look around a part, as if through a window. "
                 + "Works on the built-in display, where the camera is. Closing one eye makes it stronger.")
        }
    }

    @ViewBuilder
    private func peekStatus(_ settings: AppSettings, tracker: HeadTracker?) -> some View {
        switch tracker?.status {
        case .denied?:
            Label("Camera access is off: System Settings > Privacy & Security > Camera", systemImage: "exclamationmark.triangle")
                .foregroundStyle(S37.C.clayInk)
        case .needsPermission? where settings.peekEnabled:
            HStack {
                Label("Camera access needed", systemImage: "exclamationmark.triangle").foregroundStyle(S37.C.clayInk)
                Button("Allow…") { Task { _ = await tracker?.requestAccess() } }
            }
        case .noCamera?:
            Label("No built-in camera found", systemImage: "exclamationmark.triangle").foregroundStyle(S37.C.clayInk)
        default:
            if let calibrationMessage {
                Label(calibrationMessage, systemImage: "exclamationmark.triangle").foregroundStyle(S37.C.clayInk)
            } else if settings.peekHFOVDegrees > 0 {
                Label(String(format: "Calibrated: webcam field of view %.1f°", settings.peekHFOVDegrees),
                      systemImage: "checkmark.circle")
                    .foregroundStyle(S37.C.sageInk)
            } else {
                Label("Not calibrated: \(Int(AppSettings.assumedHFOVDegrees))° field of view assumed",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func calibrate(_ settings: AppSettings) {
        guard let peek = app.cad.viewer.peek else { return }
        calibrating = true
        calibrationMessage = nil
        Task {
            if let hfov = await peek.calibrate(distanceCM: settings.peekDistanceCM) {
                settings.peekHFOVDegrees = hfov
                app.applyPeekSettings()
            } else {
                calibrationMessage = "No face seen. Sit facing the screen and try again."
            }
            calibrating = false
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
