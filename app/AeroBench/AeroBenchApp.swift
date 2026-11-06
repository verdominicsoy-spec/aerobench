import AeroBench3D
import SwiftUI

@main
struct AeroBenchApp: App {
    @State private var app = AppState()

    init() { Fonts.register() }

    var body: some Scene {
        Window("AeroBench", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 900, minHeight: 680)  // room for the header and dock round Wing Lab's panes
                .preferredColorScheme(.dark)  // sage37 ships dark
                .tint(S37.C.sage)
        }
        .commands { AeroBenchCommands(app: app) }

        Window("Solver Accuracy", id: "accuracy") {
            AccuracyHelpView()
                .environment(app)  // the UIUC section loads results and runs its job
                .preferredColorScheme(.dark)
                .tint(S37.C.sage)
        }
        .defaultSize(width: 640, height: 720)

        Settings {
            SettingsView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(S37.C.sage)
        }
    }
}

struct AeroBenchCommands: Commands {
    let app: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("dummy.duration") private var dummyDuration = 10
    @AppStorage("dummy.keepMesh") private var dummyKeepMesh = false

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") { app.newProjectPanel() }
                .keyboardShortcut("n")
            Button("Open Project…") { app.openProjectPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(app.recentProjects, id: \.self) { url in
                    Button(url.lastPathComponent) { app.open(url) }
                }
                Divider()
                Button("Clear Menu") { app.clearRecentProjects() }
            }
            Divider()
            Button("Reveal Project in Finder") { app.revealProject() }
                .disabled(app.project == nil)
            Button("Close Project") { app.closeProject() }
                .disabled(app.project == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") { app.save() }
                .keyboardShortcut("s")
        }
        CommandGroup(before: .toolbar) {
            ForEach(Tool.allCases) { t in
                Toggle(t.title, isOn: Binding(get: { app.tool == t }, set: { if $0 { app.tool = t } }))
                    .keyboardShortcut(t.key, modifiers: .command)
            }
            Divider()
        }
        CommandMenu("Lap Sim") {
            Button("Run Lap Sim") { app.tool = .lapSim; app.runLapSim() }
                .keyboardShortcut("r")
                .disabled(app.tool != .lapSim || app.lapSimRunning)
            Button("Cancel Lap Sim") { app.lapSimJob.map(app.jobs.cancel) }
                .disabled(!app.lapSimRunning)
        }
        CommandMenu("Flow") {
            let flow = app.flow
            let ready = flow.sourceURL != nil && flow.calibration.problems.isEmpty
            let inFlow = app.tool == .flowField
            Button("Open Video…") { app.tool = .flowField; app.openFlowSourcePanel() }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Menu("Demo Sweep") {
                Button("Front View") { app.tool = .flowField; app.runFlowDemo(view: "front") }
                Button("Rear View") { app.tool = .flowField; app.runFlowDemo(view: "rear") }
                Button("Side View") { app.tool = .flowField; app.runFlowDemo(view: "side") }
            }
            Button("Look Again") { app.autoDetectFlow() }
                .disabled(flow.sourceURL == nil || !(flow.detectJob?.status.isFinished ?? true))
            Divider()
            Button("Check This Frame") { app.checkFlowFrame() }
                .disabled(!ready || !(flow.previewJob?.status.isFinished ?? true))
            Button("Build 3D") { app.reconstructFlow() }
                .keyboardShortcut("r")
                .disabled(!inFlow || !ready || !(flow.reconstructJob?.status.isFinished ?? true))
            Divider()
            Toggle("Calibrate", isOn: Binding(get: { flow.mode == .calibrate }, set: { if $0 { flow.mode = .calibrate } }))
                .disabled(!inFlow)
            Toggle("Explore", isOn: Binding(get: { flow.mode == .explore }, set: { if $0 { flow.mode = .explore } }))
                .disabled(!inFlow)
            Divider()
            Button("Save Calibration…") { app.saveFlowCalibrationAs() }
            Button("Load Calibration…") { app.loadFlowCalibration() }
        }
        CommandMenu("Jobs") {
            let job = app.tool == .jobs ? app.jobs.selected : nil  // only the job on screen
            Button("Cancel Job") { job.map(app.jobs.cancel) }
                .keyboardShortcut(".")
                .disabled(job.map { $0.status.isFinished || $0.cancelRequested } ?? true)
            Button("Run Again") { job.map { app.jobs.runAgain($0) } }
                .disabled(job == nil)
            Divider()
            Button("Reveal in Finder") { job.map(app.jobs.revealInFinder) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(job == nil)
            Button("Copy Log") { job.map(app.jobs.copyLog) }
                .disabled(job == nil)
            Divider()
            Button("Ping Engine") { app.runPing() }
            Button("Run Dummy Job") { app.runDummy(duration: dummyDuration, keepMesh: dummyKeepMesh) }
        }
        CommandMenu("CAD") {
            let cad = app.cad
            let hasModel = cad.model != nil
            Button("Open CAD File…") { app.tool = .cadViewer; app.openCADPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            ForEach(StandardView.allCases) { view in
                Button("\(view.title) View") { cad.viewer.look(from: view) }
            }
            .disabled(!hasModel || app.tool != .cadViewer)
            Button("Fit") { cad.viewer.fitAll() }
                .keyboardShortcut("0")
                .disabled(!hasModel || app.tool != .cadViewer)
            Toggle("Orthographic", isOn: Binding(get: { cad.projection == .orthographic },
                                                 set: { cad.projection = $0 ? .orthographic : .perspective }))
                .disabled(!hasModel)
            Toggle("Measure", isOn: Binding(get: { cad.measuring }, set: { cad.measuring = $0 })).disabled(!hasModel)
            Toggle("Section", isOn: Binding(get: { cad.sectionOn }, set: { cad.sectionOn = $0 })).disabled(!hasModel)
            Toggle("Show Frame Rate", isOn: Binding(get: { cad.showStatistics }, set: { cad.showStatistics = $0 }))
            Divider()
            Button("Check Geometry") { app.checkGeometry() }
                .disabled(cad.fileURL == nil || !(cad.checkJob?.status.isFinished ?? true))
            Button("Repair Geometry…") { app.repairGeometry() }
                .disabled(!(cad.report?.anyFixable ?? false) || !(cad.repairJob?.status.isFinished ?? true))
            Button("Repair to One Body…") { app.planBodyRepair() }
                .disabled(!cad.isStep || !hasModel || !(cad.bodyJob?.status.isFinished ?? true))
            Divider()
            Button(app.partEdit.on ? "Stop Editing Part" : "Edit Part") {
                app.partEdit.on ? app.exitPartEdit() : app.enterPartEdit()
            }
            .keyboardShortcut("e")
            .disabled(!cad.isStep || !hasModel)
            Button("Save Part…") { app.savePartEdit() }
                .disabled(!app.partEdit.on || app.partEdit.reply == nil)
        }
        CommandGroup(after: .help) {
            Button("How Accurate Is Each Solver?") { openWindow(id: "accuracy") }
        }
    }
}
