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
    var project: OpenProject?
    var recentProjects: [URL] = []
    var alert: AppAlert?
    /// The most recent ping, shown on the project screen.
    var pingJob: JobItem?

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
        recentProjects = (UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { ProjectStore.isProject($0) }
        jobs.loadHistory(from: jobsRoot)
        showLatestLapSim()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, self.project?.isDirty == true { self.saveProject() }
                self?.jobs.stopAllForQuit()
            }
        }
    }

    // MARK: Where jobs go

    /// Jobs live in the open project's jobs/ folder, or in the app's cache
    /// when no project is open. Nothing is written anywhere else.
    var jobsRoot: URL {
        if let project { return ProjectStore.jobsURL(for: project.url) }
        return Self.cacheJobsRoot
    }

    static var cacheJobsRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "AeroBench")
            .appendingPathComponent("jobs")
    }

    // MARK: Projects

    func newProjectPanel() {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.nameFieldLabel = "Project name:"
        panel.nameFieldStringValue = "Untitled Project"
        panel.prompt = "Create"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = try ProjectStore.create(at: url, name: url.lastPathComponent)
            setProject(url: url, manifest: manifest)
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

    func saveProject() {
        guard let project else { return }
        do {
            try lapSim.save(toProject: project.url)
            let saved = try ProjectStore.save(project.manifest, at: project.url)
            self.project?.manifest = saved
            self.project?.isDirty = false
        } catch {
            show("Could not save project", error)
        }
    }

    func closeProject() {
        if project?.isDirty == true { saveProject() }
        project = nil
        pingJob = nil
        jobs.loadHistory(from: jobsRoot)
        showLatestLapSim()
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
        if project?.isDirty == true { saveProject() }
        project = OpenProject(url: url, manifest: manifest)
        pingJob = nil
        lapSim = LapSimSetup.load(fromProject: url) ?? LapSimSetup()
        project?.isDirty = false
        recentProjects.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentProjects.insert(url, at: 0)
        recentProjects = Array(recentProjects.prefix(10))
        storeRecents()
        jobs.loadHistory(from: jobsRoot)
        showLatestLapSim()
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
