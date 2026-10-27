import AeroBenchKit
import AppKit
import Observation

struct LogLine: Identifiable {
    let id: Int
    let level: String
    let text: String
}

@MainActor @Observable
final class JobItem: Identifiable {
    let id: String
    let command: String
    let workdir: URL
    let created: Date
    var status: JobStatus = .queued
    var started: Date?
    var finished: Date?
    var progress: Double = 0
    var progressMessage = ""
    var message: String?
    var detail: String?
    var resultText: String?
    var log: [LogLine] = []
    var cancelRequested = false
    @ObservationIgnored var process: EngineProcess?

    init(id: String, command: String, workdir: URL, created: Date) {
        self.id = id
        self.command = command
        self.workdir = workdir
        self.created = created
    }

    var record: JobRecord {
        var r = JobRecord(id: id, command: command, status: status, created: created)
        r.started = started
        r.finished = finished
        r.message = message
        r.detail = detail
        r.resultPath = status == .succeeded ? JobFolder.resultFile : nil
        return r
    }

    /// The "data" object from result.json, if the job succeeded.
    var resultData: [String: Any]? {
        guard let text = resultText, let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return obj["data"] as? [String: Any]
    }

    func apply(_ event: EngineEvent) {
        switch event {
        case .progress(let pct, let msg):
            progress = pct
            if !msg.isEmpty { progressMessage = msg }
        case .log(let level, let msg):
            append(level, msg)
        case .result(let path):
            append("result", path)
        case .error(let msg, let detail):
            append("error", msg)
            if let detail { append("error", detail) }
        case .unparsed(let line):
            append("stdout", line)
        }
    }

    func append(_ level: String, _ text: String) {
        log.append(LogLine(id: log.count, level: level, text: text))
    }

    var logText: String {
        log.map { "[\($0.level)] \($0.text)" }.joined(separator: "\n") + "\n"
    }
}

/// Queues jobs, runs at most `maxParallelJobs` at once, streams their events
/// into JobItems and records everything in each job folder.
@MainActor @Observable
final class JobManager {
    private(set) var jobs: [JobItem] = []
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    var runningCount: Int { jobs.filter { $0.status == .running }.count }

    @discardableResult
    func submit(command: String, params: [String: JSONValue] = [:], keepMesh: Bool = false, in jobsRoot: URL) -> JobItem {
        let su2 = settings.su2Path.trimmingCharacters(in: .whitespaces)
        let spec = JobSpec(
            command: command,
            params: params,
            options: .init(keepMesh: keepMesh, cores: settings.coresPerJob, su2Path: su2.isEmpty ? nil : su2)
        )
        let item: JobItem
        do {
            let (id, url) = try JobFolder.create(in: jobsRoot, spec: spec)
            item = JobItem(id: id, command: command, workdir: url, created: AeroJSON.now())
            persist(item)
        } catch {
            item = JobItem(id: "unsaved-\(UUID().uuidString.prefix(8))", command: command, workdir: jobsRoot, created: AeroJSON.now())
            item.status = .failed
            item.message = "Could not create the job folder"
            item.detail = error.localizedDescription
            item.finished = Date()
        }
        jobs.insert(item, at: 0)
        startQueued()
        return item
    }

    func cancel(_ item: JobItem) {
        switch item.status {
        case .queued:
            item.status = .cancelled
            item.message = "Cancelled before it started"
            item.finished = AeroJSON.now()
            persist(item)
        case .running:
            item.cancelRequested = true
            item.append("info", "cancel requested")
            item.process?.cancel(grace: 3)
        default:
            break
        }
    }

    /// Shows the jobs recorded in a jobs folder, keeping anything still running.
    func loadHistory(from jobsRoot: URL) {
        let active = jobs.filter { !$0.status.isFinished }
        let activeIDs = Set(active.map(\.id))
        let history: [JobItem] = JobFolder.loadRecords(in: jobsRoot)
            .filter { !activeIDs.contains($0.id) }
            .map { record in
                let folder = jobsRoot.appendingPathComponent(record.id)
                let item = JobItem(id: record.id, command: record.command, workdir: folder, created: record.created)
                item.status = record.status
                item.started = record.started
                item.finished = record.finished
                item.message = record.message
                item.detail = record.detail
                if record.status == .succeeded { item.progress = 100 }
                if let path = record.resultPath {
                    item.resultText = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
                }
                if let text = try? String(contentsOf: folder.appendingPathComponent(JobFolder.logFile), encoding: .utf8) {
                    for line in text.split(separator: "\n") { item.append("saved", String(line)) }
                }
                return item
            }
        jobs = active + history
    }

    /// Called as the app quits. SIGTERM lets each engine clean up its own
    /// intermediates; there is no time to wait for them.
    func stopAllForQuit() {
        for item in jobs where item.status == .running {
            item.process?.cancel(grace: 1)
        }
    }

    // MARK: Running

    private func startQueued() {
        while runningCount < max(1, settings.maxParallelJobs),
              let next = jobs.last(where: { $0.status == .queued }) {
            start(next)
        }
    }

    private func start(_ item: JobItem) {
        guard let executable = settings.engineExecutable else {
            item.status = .running  // so finish() records start and end
            finish(item, .failed(message: "No engine folder set", detail: "Open Settings (⌘,) and choose the repo's engine folder."))
            return
        }
        let cores = String(settings.coresPerJob)
        let process = EngineProcess(
            executableURL: executable,
            command: item.command,
            inputURL: item.workdir.appendingPathComponent(JobFolder.jobFile),
            workdir: item.workdir,
            environment: ["OMP_NUM_THREADS": cores, "AEROBENCH_CORES": cores]
        )
        item.process = process
        item.status = .running
        item.started = AeroJSON.now()
        persist(item)

        Task { @MainActor in
            let outcome = await process.run(
                onEvent: { event in
                    DispatchQueue.main.async { MainActor.assumeIsolated { item.apply(event) } }
                },
                onStderr: { line in
                    DispatchQueue.main.async { MainActor.assumeIsolated { item.append("stderr", line) } }
                }
            )
            // Events were queued on main before run() returned, so they have
            // all landed by the time this runs.
            self.finish(item, outcome)
        }
    }

    private func finish(_ item: JobItem, _ outcome: EngineProcess.Outcome) {
        switch outcome {
        case .succeeded(let url):
            item.status = .succeeded
            item.progress = 100
            item.resultText = try? String(contentsOf: url, encoding: .utf8)
        case .failed(let message, let detail):
            item.status = .failed
            item.message = message
            item.detail = detail
        case .cancelled:
            item.status = .cancelled
            item.message = "Cancelled"
        }
        item.finished = AeroJSON.now()
        item.process = nil
        persist(item)
        do {
            try item.logText.write(to: item.workdir.appendingPathComponent(JobFolder.logFile), atomically: true, encoding: .utf8)
        } catch {
            item.append("error", "could not write log.txt: \(error.localizedDescription)")
        }
        startQueued()
    }

    private func persist(_ item: JobItem) {
        do {
            try JobFolder.write(item.record, to: item.workdir)
        } catch {
            item.append("error", "could not write status.json: \(error.localizedDescription)")
        }
    }
}
