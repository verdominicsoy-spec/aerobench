import AeroBenchKit
import AppKit
import Observation
import UniformTypeIdentifiers

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor @Observable
final class AppState {
    struct OpenProject {
        var url: URL
        var manifest: ProjectManifest
        var isDirty = false
    }

    let settings: AppSettings
    let jobs: JobManager
    let cad: CADViewerModel
    let partEdit = PartEditModel()
    let car = CarModel()
    let flow: FlowFieldModel
    let wingLab: WingLabModel
    var project: OpenProject?
    /// A packaged app setting up its engine; nil otherwise.
    var engineSetup: EngineSetup?
    var recentProjects: [URL] = []
    var alert: AppAlert?
    /// The most recent ping, shown on the project screen.
    var pingJob: JobItem?
    /// Commits on GitHub this checkout does not have yet (AppState+Update); 0 when up to date.
    var updatesBehind = 0
    var updateDismissed = false

    /// Lap Sim inputs. Saved to the project's lapsim/setup.json on save.
    var lapSim = LapSimSetup() {
        didSet { if lapSim != oldValue { project?.isDirty = true } }
    }
    var lapSimJob: JobItem?
    var lapSimOutput: LapSimOutput?

    private static let recentsKey = "recentProjects"
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    init() {
        let settings = AppSettings()
        self.settings = settings
        jobs = JobManager(settings: settings)
        cad = CADViewerModel()
        flow = FlowFieldModel()
        wingLab = WingLabModel()
        recentProjects = (UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { ProjectStore.isProject($0) }
        jobs.loadHistory(from: jobsRoot)
        wingLab.reloadStudy(project: workFolder)
        showLatestLapSim()
        checkForUpdates()
        flow.onCalibrationChange = { [weak self] in self?.project?.isDirty = true }
        wingLab.onChange = { [weak self] in self?.scheduleLiveEstimate() }
        scheduleLiveEstimate()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, self.hasUnsavedChanges { self.saveProject() }
                self?.jobs.stopAllForQuit()
            }
        }
    }

    // MARK: Where jobs go

    /// Runs write into the open project, or into a scratch folder laid out
    /// like one when no project is open: a project is only needed to save.
    var workFolder: URL { project?.url ?? Self.scratchFolder }

    var jobsRoot: URL { ProjectStore.jobsURL(for: workFolder) }

    /// In Application Support, not Caches: the system may empty Caches, and
    /// studies and the Jobs list read back from here.
    static var scratchFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AeroBench")
            .appendingPathComponent("Scratch")
    }

    // MARK: Projects

    /// Creates a project. Keeping the work moves what is on screen into it
    /// (for Save with no project), instead of starting from defaults.
    func newProjectPanel(keepingWork: Bool = false) {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.nameFieldLabel = "Project name:"
        panel.nameFieldStringValue = "Untitled Project"
        panel.prompt = "Create"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = try ProjectStore.create(at: url, name: url.lastPathComponent)
            if keepingWork {
                // Studies run without a project come along so they can be resumed;
                // their job folders stay in the scratch folder.
                let studies = ProjectStore.toolURL(for: Self.scratchFolder, tool: "wing").appendingPathComponent("studies")
                if FileManager.default.fileExists(atPath: studies.path) {
                    let dest = ProjectStore.toolURL(for: url, tool: "wing").appendingPathComponent("studies")
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: studies, to: dest)
                }
                project = OpenProject(url: url, manifest: manifest)
                noteRecent(url)
                saveProject()
                wingLab.reloadStudy(project: url)
                jobs.loadHistory(from: jobsRoot)
            } else {
                setProject(url: url, manifest: manifest)
            }
        } catch {
            show("Could not create project", error)
        }
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.message = "Choose a project folder (or its project.json)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.lastPathComponent == ProjectStore.manifestName { url.deleteLastPathComponent() }
        open(url)
    }

    func open(_ url: URL) {
        do {
            let manifest = try ProjectStore.open(at: url)
            setProject(url: url, manifest: manifest)
        } catch {
            recentProjects.removeAll { $0 == url }
            storeRecents()
            show("Could not open project", error)
        }
    }

    /// Save from the menu: with no project open, ask for one first.
    func save() {
        guard project == nil else { return saveProject() }
        let ask = NSAlert()
        ask.messageText = "Saving needs a project"
        ask.informativeText = "Create a project to keep this work in it. Opening a project loads that project's own work in place of this."
        ask.addButton(withTitle: "New Project…")
        ask.addButton(withTitle: "Open Project…")
        ask.addButton(withTitle: "Cancel")
        switch ask.runModal() {
        case .alertFirstButtonReturn: newProjectPanel(keepingWork: true)
        case .alertSecondButtonReturn: openProjectPanel()
        default: break
        }
    }

    /// Writes the open project; does nothing without one (runs and quitting
    /// call it too, and must not stop to ask).
    func saveProject() {
        guard let project else { return }
        do {
            try lapSim.save(toProject: project.url)
            try saveFlowState(toProject: project.url)
            try wingLab.save(toProject: project.url)
            let saved = try ProjectStore.save(project.manifest, at: project.url)
            self.project?.manifest = saved
            self.project?.isDirty = false
        } catch {
            show("Could not save project", error)
        }
    }

    func closeProject() {
        if hasUnsavedChanges { saveProject() }
        project = nil
        pingJob = nil
        wingLab.reloadStudy(project: workFolder)
        jobs.loadHistory(from: jobsRoot)
        showLatestLapSim()
    }

    /// Anything not yet written to the project: the wing lab compares with its files.
    var hasUnsavedChanges: Bool {
        guard let project else { return false }
        return project.isDirty || wingLab.hasUnsavedChanges
    }

    func updateManifest(_ change: (inout ProjectManifest) -> Void) {
        guard project != nil else { return }
        change(&project!.manifest)
        project!.isDirty = true
    }

    func clearRecentProjects() {
        recentProjects = []
        storeRecents()
    }

    private func setProject(url: URL, manifest: ProjectManifest) {
        if hasUnsavedChanges { saveProject() }
        project = OpenProject(url: url, manifest: manifest)
        pingJob = nil
        lapSim = LapSimSetup.load(fromProject: url) ?? LapSimSetup()
        wingLab.reset(to: WingLabModel.load(fromProject: url) ?? WingLabModel.starter)
        wingLab.restoreVersion(fromProject: url)
        wingLab.optimise = WingLabModel.loadOptimise(fromProject: url) ?? .init()
        wingLab.reloadStudy(project: url)
        wingLab.markSaved()
        scheduleLiveEstimate()
        project?.isDirty = false
        noteRecent(url)
        jobs.loadHistory(from: jobsRoot)
        showLatestLapSim()
        loadFlowState(fromProject: url)
    }

    private func noteRecent(_ url: URL) {
        recentProjects.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentProjects.insert(url, at: 0)
        recentProjects = Array(recentProjects.prefix(10))
        storeRecents()
    }

    private func storeRecents() {
        UserDefaults.standard.set(recentProjects.map(\.path), forKey: Self.recentsKey)
    }

    // MARK: Engine checks

    func runPing() {
        pingJob = jobs.submit(command: "ping", params: ["echo": .string("hello from AeroBench")], in: jobsRoot)
    }

    @discardableResult
    func runDummy(duration: Int, keepMesh: Bool) -> JobItem {
        jobs.submit(command: "dummy", params: ["duration": .int(duration)], keepMesh: keepMesh, in: jobsRoot)
    }

    // MARK: Lap Sim

    var lapSimFolder: URL? {
        project.map { ProjectStore.toolURL(for: $0.url, tool: "lapsim") }
    }

    func runLapSim() {
        if lapSim.track.kind == .csv {
            guard let url = lapSim.track.csvURL(lapsimFolder: lapSimFolder),
                  FileManager.default.fileExists(atPath: url.path)
            else {
                alert = AppAlert(title: "No track file", message: "Import a centreline CSV first.")
                return
            }
        }
        if lapSim.track.kind == .drawn, lapSim.track.drawn?.isUsable != true {
            alert = AppAlert(title: "No drawn track", message: "Open the track editor and copy a track to start from.")
            return
        }
        do {
            let params = try lapSim.jobParams(lapsimFolder: lapSimFolder)
            lapSimJob = jobs.submit(command: "lapsim", params: params, in: jobsRoot) { [weak self] item in
                self?.loadLapSimResult(from: item)
            }
        } catch {
            show("Could not start the lap sim", error)
        }
    }

    /// Copies a centreline CSV into the project (or references it in place
    /// when no project is open) and selects it.
    func importTrackCSV() {
        let panel = NSOpenPanel()
        panel.title = "Import Track Centreline"
        panel.message = "A CSV of x, y centreline points."
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            if let folder = lapSimFolder {
                let tracks = folder.appendingPathComponent("tracks")
                try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
                var dest = tracks.appendingPathComponent(source.lastPathComponent)
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = tracks.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(n).\(source.pathExtension)")
                    n += 1
                }
                try FileManager.default.copyItem(at: source, to: dest)
                lapSim.track.csvPath = "tracks/\(dest.lastPathComponent)"
            } else {
                lapSim.track.csvPath = source.path
            }
            lapSim.track.kind = .csv
        } catch {
            show("Could not import the track", error)
        }
    }

    private func loadLapSimResult(from item: JobItem) {
        guard item.status == .succeeded, let text = item.resultText else { return }
        do {
            let result = try LapSimResult.decode(resultFile: Data(text.utf8))
            lapSimOutput = LapSimOutput(jobID: item.id, result: result)
        } catch {
            item.append("error", "could not read the lap sim result: \(error.localizedDescription)")
            lapSimOutput = nil
        }
    }

    private func showLatestLapSim() {
        lapSimJob = jobs.jobs.first { $0.command == "lapsim" && $0.status == .succeeded }
        lapSimOutput = nil
        if let job = lapSimJob { loadLapSimResult(from: job) }
    }

    func show(_ title: String, _ error: Error) {
        alert = AppAlert(title: title, message: error.localizedDescription)
    }
}
