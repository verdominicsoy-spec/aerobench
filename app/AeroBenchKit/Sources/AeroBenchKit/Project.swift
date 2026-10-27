import Foundation

/// project.json at the root of a project folder.
public struct ProjectManifest: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var name: String
    public var created: Date
    public var modified: Date
    public var notes: String
    /// Per-tool state, keyed by tool folder name. Empty until the tools land.
    public var tools: [String: JSONValue]

    public init(name: String, date: Date = AeroJSON.now()) {
        schemaVersion = Self.currentSchema
        self.name = name
        created = date
        modified = date
        notes = ""
        tools = [:]
    }
}

public enum ProjectError: LocalizedError, Equatable {
    case notAProject(URL)
    case alreadyExists(URL)
    case newerSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .notAProject(let url): "\(url.lastPathComponent) is not an AeroBench project (no project.json)."
        case .alreadyExists(let url): "\(url.lastPathComponent) already exists and is not empty."
        case .newerSchema(let v): "This project was saved by a newer AeroBench (schema \(v))."
        }
    }
}

/// A project is a folder: project.json, one subfolder per tool, and jobs/.
public enum ProjectStore {
    public static let manifestName = "project.json"
    public static let toolFolders = ["wing", "cad", "flow", "lapsim"]
    public static let jobsFolder = "jobs"

    public static func jobsURL(for project: URL) -> URL {
        project.appendingPathComponent(jobsFolder)
    }

    public static func isProject(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(manifestName).path)
    }

    public static func create(at url: URL, name: String) throws -> ProjectManifest {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            if !contents.filter({ $0 != ".DS_Store" }).isEmpty { throw ProjectError.alreadyExists(url) }
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try ensureFolders(at: url)
        let manifest = ProjectManifest(name: name)
        try write(manifest, at: url)
        return manifest
    }

    public static func open(at url: URL) throws -> ProjectManifest {
        let manifestURL = url.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw ProjectError.notAProject(url) }
        let manifest = try AeroJSON.decoder().decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        if manifest.schemaVersion > ProjectManifest.currentSchema { throw ProjectError.newerSchema(manifest.schemaVersion) }
        try ensureFolders(at: url)
        return manifest
    }

    /// Writes project.json with a fresh modified date and returns what was saved.
    @discardableResult
    public static func save(_ manifest: ProjectManifest, at url: URL) throws -> ProjectManifest {
        var m = manifest
        m.modified = AeroJSON.now()
        try write(m, at: url)
        return m
    }

    private static func write(_ manifest: ProjectManifest, at url: URL) throws {
        let data = try AeroJSON.encoder().encode(manifest)
        try data.write(to: url.appendingPathComponent(manifestName), options: .atomic)
    }

    private static func ensureFolders(at url: URL) throws {
        for name in toolFolders + [jobsFolder] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }
}
