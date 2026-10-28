import AeroBenchKit
import Foundation
import Observation

@MainActor @Observable
final class AppSettings {
    private enum Key {
        static let enginePath = "enginePath"
        static let su2Path = "su2Path"
        static let maxParallelJobs = "maxParallelJobs"
        static let coresPerJob = "coresPerJob"
        static let parallelTrials = "parallelTrials"
    }

    private let defaults = UserDefaults.standard

    /// The repo's engine/ folder. The app runs engine/.venv/bin/aeroengine.
    var enginePath: String { didSet { defaults.set(enginePath, forKey: Key.enginePath) } }
    /// SU2_CFD binary, or the folder holding it. Used from Phase 4.
    var su2Path: String { didSet { defaults.set(su2Path, forKey: Key.su2Path) } }
    var maxParallelJobs: Int { didSet { defaults.set(maxParallelJobs, forKey: Key.maxParallelJobs) } }
    var coresPerJob: Int { didSet { defaults.set(coresPerJob, forKey: Key.coresPerJob) } }
    /// Wing Lab optimiser: trials run at once, each on coresPerJob cores.
    var parallelTrials: Int { didSet { defaults.set(parallelTrials, forKey: Key.parallelTrials) } }

    init() {
        let defaults = UserDefaults.standard
        enginePath = defaults.string(forKey: Key.enginePath) ?? Self.engineNextToSource() ?? ""
        su2Path = defaults.string(forKey: Key.su2Path) ?? ""
        let parallel = defaults.integer(forKey: Key.maxParallelJobs)
        maxParallelJobs = parallel > 0 ? parallel : 2
        let cores = defaults.integer(forKey: Key.coresPerJob)
        coresPerJob = cores > 0 ? cores : 4
        let trials = defaults.integer(forKey: Key.parallelTrials)
        parallelTrials = trials > 0 ? trials : 1
    }

    var engineDirectory: URL? {
        let path = enginePath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    var engineExecutable: URL? {
        engineDirectory.map(EngineLocation.executable(inEngineDirectory:))
    }

    var engineIsReady: Bool {
        engineExecutable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
    }

    /// In a development build the source tree is right there, so default the
    /// engine folder to <repo>/engine when it exists.
    private static func engineNextToSource() -> String? {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AeroBench/
            .deletingLastPathComponent()  // app/
            .deletingLastPathComponent()  // repo
        let engine = repo.appendingPathComponent("engine")
        return FileManager.default.fileExists(atPath: engine.appendingPathComponent("pyproject.toml").path) ? engine.path : nil
    }
}
