import Foundation

/// The engine shipped inside AeroBench.app (app/scripts/make_dmg.sh puts
/// its source and the data folder in Contents/Resources/AeroBench). It is
/// copied to Application Support and its Python environment made there with
/// uv, so the app bundle itself is never written to.
public enum BundledEngine {
    /// Resources/AeroBench in the app, if this build carries the engine.
    public static func source(in bundle: Bundle = .main) -> URL? {
        guard let res = bundle.resourceURL?.appendingPathComponent("AeroBench") else { return nil }
        return FileManager.default.fileExists(atPath: res.appendingPathComponent("engine/pyproject.toml").path) ? res : nil
    }

    /// ~/Library/Application Support/AeroBench: engine/, data/ and build/ (SU2) live here.
    public static var home: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AeroBench")
    }

    public static func version(_ folder: URL) -> String? {
        (try? String(contentsOf: folder.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The copy in `home` is missing or from another build.
    public static func needsInstall(source: URL, home: URL) -> Bool {
        version(source) == nil || version(source) != version(home)
            || !FileManager.default.fileExists(atPath: home.appendingPathComponent("engine/pyproject.toml").path)
    }

    /// Copies the engine and data into `home`. Keeps what was made or
    /// fetched there before: the Python environment (so uv sync only
    /// updates it), the airfoil library and SU2.
    public static func install(from source: URL, to home: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let engine = home.appendingPathComponent("engine")
        try fm.createDirectory(at: engine, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(atPath: engine.path) where item != ".venv" {
            try fm.removeItem(at: engine.appendingPathComponent(item))
        }
        let newEngine = source.appendingPathComponent("engine")
        for item in try fm.contentsOfDirectory(atPath: newEngine.path) where item != ".venv" {
            try fm.copyItem(at: newEngine.appendingPathComponent(item), to: engine.appendingPathComponent(item))
        }
        let data = home.appendingPathComponent("data")
        try fm.createDirectory(at: data.appendingPathComponent("airfoils"), withIntermediateDirectories: true)
        let newData = source.appendingPathComponent("data")
        for item in try fm.contentsOfDirectory(atPath: newData.path) where item != "airfoils" {
            let target = data.appendingPathComponent(item)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: newData.appendingPathComponent(item), to: target)
        }
        let version = home.appendingPathComponent("VERSION")
        if fm.fileExists(atPath: version.path) { try fm.removeItem(at: version) }
        try fm.copyItem(at: source.appendingPathComponent("VERSION"), to: version)
    }

    /// uv where Homebrew or its own installer puts it (a Finder-launched app
    /// does not see the shell's PATH).
    public static func uv(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"].map(URL.init(fileURLWithPath:))
            + [home.appendingPathComponent(".local/bin/uv"), home.appendingPathComponent(".cargo/bin/uv")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
