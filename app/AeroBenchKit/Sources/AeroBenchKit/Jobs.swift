import Foundation

public enum JobStatus: String, Codable, Sendable {
    case queued, running, succeeded, failed, cancelled

    public var isFinished: Bool {
        switch self {
        case .queued, .running: false
        case .succeeded, .failed, .cancelled: true
        }
    }
}

/// What the app writes to job.json for the engine to read.
public struct JobSpec: Codable, Equatable, Sendable {
    public struct Options: Codable, Equatable, Sendable {
        public var keepMesh: Bool
        public var cores: Int
        public var su2Path: String?

        public init(keepMesh: Bool = false, cores: Int = 1, su2Path: String? = nil) {
            self.keepMesh = keepMesh
            self.cores = cores
            self.su2Path = su2Path
        }

        enum CodingKeys: String, CodingKey {
            case keepMesh = "keep_mesh"
            case cores
            case su2Path = "su2_path"
        }
    }

    public var command: String
    public var params: [String: JSONValue]
    public var options: Options

    public init(command: String, params: [String: JSONValue] = [:], options: Options = Options()) {
        self.command = command
        self.params = params
        self.options = options
    }
}

/// The app's own record of a job, kept in status.json next to job.json.
public struct JobRecord: Codable, Equatable, Sendable {
    public var id: String
    public var command: String
    public var status: JobStatus
    public var created: Date
    public var started: Date?
    public var finished: Date?
    public var message: String?
    public var detail: String?
    public var resultPath: String?

    public init(id: String, command: String, status: JobStatus, created: Date) {
        self.id = id
        self.command = command
        self.status = status
        self.created = created
    }
}

/// Layout of one job folder: jobs/<timestamp-id>/
///   job.json     written by the app, read by the engine
///   status.json  written by the app
///   result.json  written by the engine on success
///   log.txt      written by the app when the job ends
public enum JobFolder {
    public static let jobFile = "job.json"
    public static let statusFile = "status.json"
    public static let resultFile = "result.json"
    public static let logFile = "log.txt"

    public static func makeID(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(format: "%04x", UInt16.random(in: .min ... .max))
        return "\(f.string(from: date))-\(suffix)"
    }

    /// Creates the job folder and writes job.json.
    public static func create(in jobsRoot: URL, spec: JobSpec) throws -> (id: String, url: URL) {
        let fm = FileManager.default
        try fm.createDirectory(at: jobsRoot, withIntermediateDirectories: true)
        var id = makeID()
        while fm.fileExists(atPath: jobsRoot.appendingPathComponent(id).path) {
            id = makeID()
        }
        let url = jobsRoot.appendingPathComponent(id)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        try AeroJSON.encoder().encode(spec).write(to: url.appendingPathComponent(jobFile), options: .atomic)
        return (id, url)
    }

    public static func write(_ record: JobRecord, to folder: URL) throws {
        try AeroJSON.encoder().encode(record).write(to: folder.appendingPathComponent(statusFile), options: .atomic)
    }

    /// Reads every job in a jobs folder, newest first. Jobs still marked as
    /// running from an earlier session are marked failed, since nothing is
    /// running them any more.
    public static func loadRecords(in jobsRoot: URL) -> [JobRecord] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: jobsRoot, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var records: [JobRecord] = []
        for folder in entries where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let statusURL = folder.appendingPathComponent(statusFile)
            guard let data = try? Data(contentsOf: statusURL),
                  var record = try? AeroJSON.decoder().decode(JobRecord.self, from: data)
            else { continue }
            if !record.status.isFinished {
                let was = record.status
                record.status = .failed
                record.message = "Interrupted: AeroBench quit while this job was \(was.rawValue)"
                record.finished = record.finished ?? record.started ?? record.created
                try? write(record, to: folder)
            }
            records.append(record)
        }
        return records.sorted { ($0.created, $0.id) > ($1.created, $1.id) }
    }
}
