import AeroBench3D
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
        static let peekEnabled = "peekEnabled"
        static let peekDistanceCM = "peekDistanceCM"
        static let peekHFOVDegrees = "peekHFOVDegrees"
        static let peekSensitivity = "peekSensitivity"
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
    /// Hold Shift in the CAD viewer to peek with head tracking.
    var peekEnabled: Bool { didSet { defaults.set(peekEnabled, forKey: Key.peekEnabled) } }
    /// Eyes to screen, measured once by the user; the peek keeps this distance fixed.
    var peekDistanceCM: Double { didSet { defaults.set(peekDistanceCM, forKey: Key.peekDistanceCM) } }
    /// The webcam's horizontal field of view from calibration; 0 = not calibrated.
    var peekHFOVDegrees: Double { didSet { defaults.set(peekHFOVDegrees, forKey: Key.peekHFOVDegrees) } }
    /// How much the view moves for a head movement (1 = the head's own angle).
    var peekSensitivity: Double { didSet { defaults.set(peekSensitivity, forKey: Key.peekSensitivity) } }
    /// Used until the webcam is calibrated.
    static let assumedHFOVDegrees = 62.0

    var peekConfig: HeadPeek.Config {
        HeadPeek.Config(enabled: peekEnabled, distanceCM: peekDistanceCM,
                        hfovDegrees: peekHFOVDegrees > 0 ? peekHFOVDegrees : Self.assumedHFOVDegrees,
                        sensitivity: peekSensitivity)
    }

    init() {
        let defaults = UserDefaults.standard
        enginePath = defaults.string(forKey: Key.enginePath) ?? Self.engineNextToSource() ?? ""
        su2Path = defaults.string(forKey: Key.su2Path) ?? ""
        let parallel = defaults.integer(forKey: Key.maxParallelJobs)
        maxParallelJobs = parallel > 0 ? parallel : 2
        let cores = defaults.integer(forKey: Key.coresPerJob)
        coresPerJob = cores > 0 ? cores : Self.defaultCores
        let trials = defaults.integer(forKey: Key.parallelTrials)
        parallelTrials = trials > 0 ? trials : 1
        peekEnabled = defaults.bool(forKey: Key.peekEnabled)
        let distance = defaults.double(forKey: Key.peekDistanceCM)
        peekDistanceCM = distance > 0 ? distance : 55
        peekHFOVDegrees = defaults.double(forKey: Key.peekHFOVDegrees)
        let sensitivity = defaults.double(forKey: Key.peekSensitivity)
        peekSensitivity = sensitivity > 0 ? sensitivity : 2
    }

    var engineDirectory: URL? {
        let path = enginePath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    var engineExecutable: URL? {
        engineDirectory.map(EngineLocation.executable(inEngineDirectory:))
    }

    /// SU2_CFD where the engine will look for it: the setting (the binary or
    /// its folder), the repo's build/su2 (engine/scripts/install_su2.sh puts
    /// it there), or Homebrew's folders. A GUI app does not see the shell's
    /// PATH, so those are checked by name.
    var su2Executable: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        let setting = su2Path.trimmingCharacters(in: .whitespaces)
        if !setting.isEmpty {
            let url = URL(fileURLWithPath: (setting as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            candidates.append(isDir.boolValue ? url.appendingPathComponent("SU2_CFD") : url)
        }
        if let engine = engineDirectory {
            candidates.append(engine.deletingLastPathComponent().appendingPathComponent("build/su2/bin/SU2_CFD"))
        }
        candidates += ["/opt/homebrew/bin/SU2_CFD", "/usr/local/bin/SU2_CFD"].map(URL.init(fileURLWithPath:))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
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

    /// SU2 waits for its slowest core, and efficiency cores are slow: the performance cores and half
    /// the efficiency ones. On an 18-core Mac (6 + 12) a fine-mesh run took 90 s on 4, 57 s on 12, 67 s on 16.
    static var defaultCores: Int {
        func count(_ name: String) -> Int {
            var n: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &n, &size, nil, 0) == 0 ? Int(n) : 0
        }
        let fast = count("hw.perflevel0.physicalcpu"), slow = count("hw.perflevel1.physicalcpu")
        return fast > 0 ? max(fast + slow / 2, 2) : 4
    }
}
