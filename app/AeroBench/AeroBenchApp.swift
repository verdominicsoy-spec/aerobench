import AeroBench3D
import AppKit
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
    /// Prism Layer's presets, as its Preset menu sets them
    private func preset(yPlus: Double, layers: Int?, stretching: Double, _ undo: UndoManager?) {
        var next = app.prism.inputs
        next.yPlus = yPlus
        next.stretching = stretching
        if let layers { next.layers = layers }
        app.tool = .prismLayer
        app.prism.set(\.self, next, "Preset", undo: undo)
    }

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
            Button("Open CAD File…") { app.tool = .cadViewer; app.openCADPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Open Flow Video…") { app.tool = .flowField; app.openFlowSourcePanel() }
                .keyboardShortcut("o", modifiers: [.command, .option])
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
        // One menu, for the tool on screen: its commands only, so the bar stays short.
        CommandMenu(app.tool.title) {
            switch app.tool {
            case .project: jobsMenu
            case .wingLab: wingMenu
            case .lapSim: lapSimMenu
            case .cadViewer: cadMenu
            case .flowField: flowMenu
            case .prismLayer: prismMenu
            case .jobs: jobsMenu
            }
        }
        CommandGroup(after: .help) {
            Button("How Accurate Is Each Solver?") { openWindow(id: "accuracy") }
        }
    }

    @ViewBuilder private var wingMenu: some View {
        let lab = app.wingLab
        let busy: (JobItem?) -> Bool = { $0.map { !$0.status.isFinished } ?? false }
        let selected = lab.selection.flatMap { lab.wing.elements.indices.contains($0) ? $0 : nil }
        Button("Design") { app.runDesign() }
            .disabled(busy(lab.designRun))
        Button("Quick Estimate") { app.runWingQuickEstimate() }
            .disabled(lab.wing.elements.isEmpty)
        Button("Element Polar") { app.runWingPolar() }
            .disabled(selected == nil || busy(lab.polarJob))
        Button("Mesh Wing") { lab.canvasMode = .mesh; app.runWingMesh() }
            .disabled(lab.wing.elements.isEmpty || busy(lab.meshJob))
        Button("Run CFD") { app.runCFD() }
            .keyboardShortcut("r")
            .disabled(app.settings.su2Executable == nil || lab.wing.elements.isEmpty
                      || !lab.wing.issues.filter { $0.kind != .outsideRules }.isEmpty || busy(lab.ransJob) || busy(lab.sweepJob))
        Button(lab.optimiseJob.map { $0.status.isFinished } ?? true ? "Start Study" : "Study Running") { app.runWingOptimise() }
            .disabled(busy(lab.optimiseJob))
        Button("Stop Study") { lab.optimiseJob.map(app.jobs.cancel) }
            .disabled(!busy(lab.optimiseJob))
        Divider()
        Button("Duplicate Element") { selected.map(lab.duplicate) }
            .keyboardShortcut("d")
            .disabled(selected == nil)
        Button("Remove Element") { selected.map(lab.remove) }
            .disabled(selected == nil)
        Divider()
        Button(lab.pinned == nil ? "Pin This Wing as A" : "Pin This Wing as A Instead") { lab.pinCurrent() }
            .disabled(lab.wing.elements.isEmpty)
        Button("Swap A and This Wing") { lab.swapWithPinned() }.disabled(lab.pinned == nil)
        Button("Clear A") { lab.pinned = nil }.disabled(lab.pinned == nil)
        Divider()
        Toggle("Show Library", isOn: Binding(get: { lab.showLibrary }, set: { lab.showLibrary = $0 }))
            .keyboardShortcut("l", modifiers: [.command, .option])
        Toggle("Show Inspector", isOn: Binding(get: { lab.showInspector }, set: { lab.showInspector = $0 }))
            .keyboardShortcut("i", modifiers: [.command, .option])
        Divider()
        Button("Export Elements as .dat…") { app.exportWingDat() }
        Button("Export Points as CSV…") { app.exportWingCSV() }
        Button("Export Report as PDF…") { app.exportWingReport() }
    }

    @ViewBuilder private var prismMenu: some View {
        let undo = { NSApp.keyWindow?.undoManager }
        Button("Wing / Floor Preset") { preset(yPlus: 1, layers: nil, stretching: 1.2, undo()) }
        Button("Body / Wheels Preset") { preset(yPlus: 40, layers: 4, stretching: 1.25, undo()) }
        Button("Suspension Preset") { preset(yPlus: 40, layers: 3, stretching: 1.3, undo()) }
        Divider()
        Button("Use Project Values") { app.prism.set(\.self, PrismInputs(), "Use Project Values", undo: undo()) }
            .disabled(app.prism.inputs == PrismInputs())
    }

    @ViewBuilder private var lapSimMenu: some View {
        Button("Run Lap Sim") { app.runLapSim() }
            .keyboardShortcut("r")
            .disabled(app.lapSimRunning)
        Button("Cancel Lap Sim") { app.lapSimJob.map(app.jobs.cancel) }
            .disabled(!app.lapSimRunning)
    }

    @ViewBuilder private var flowMenu: some View {
        let flow = app.flow
        let ready = flow.sourceURL != nil && flow.calibration.problems.isEmpty
        Menu("Demo Sweep") {
            Button("Front View") { app.runFlowDemo(view: "front") }
            Button("Rear View") { app.runFlowDemo(view: "rear") }
            Button("Side View") { app.runFlowDemo(view: "side") }
        }
        Button("Look Again") { app.autoDetectFlow() }
            .disabled(flow.sourceURL == nil || !(flow.detectJob?.status.isFinished ?? true))
        Divider()
        Button("Check This Frame") { app.checkFlowFrame() }
            .disabled(!ready || !(flow.previewJob?.status.isFinished ?? true))
        Button("Build 3D") { app.reconstructFlow() }
            .keyboardShortcut("r")
            .disabled(!ready || !(flow.reconstructJob?.status.isFinished ?? true))
        Divider()
        Toggle("Calibrate", isOn: Binding(get: { flow.mode == .calibrate }, set: { if $0 { flow.mode = .calibrate } }))
        Toggle("Explore", isOn: Binding(get: { flow.mode == .explore }, set: { if $0 { flow.mode = .explore } }))
        Divider()
        Button("Save Calibration…") { app.saveFlowCalibrationAs() }
        Button("Load Calibration…") { app.loadFlowCalibration() }
    }

    @ViewBuilder private var jobsMenu: some View {
        let job = app.jobs.selected
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

    @ViewBuilder private var cadMenu: some View {
        let cad = app.cad
        let hasModel = cad.model != nil
        ForEach(StandardView.allCases) { view in
            Button("\(view.title) View") { cad.viewer.look(from: view) }
        }
        .disabled(!hasModel)
        Button("Fit") { cad.viewer.fitAll() }
            .keyboardShortcut("0")
            .disabled(!hasModel)
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
}
