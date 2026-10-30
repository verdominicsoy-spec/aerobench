import AeroBenchKit
import Foundation

/// A packaged app's first launch (or the first after an update): the engine
/// copied out of the app and its Python environment made with uv.
struct EngineSetup: Equatable {
    enum Phase: Equatable {
        case working(String)
        case needsUV
        case failed(String)
        case done
    }

    var phase: Phase
}

extension AppState {
    func setUpBundledEngineIfNeeded() {
        guard let source = BundledEngine.source() else { return }  // a development build: the repo's engine
        let home = BundledEngine.home
        let installed = home.appendingPathComponent("engine")
        // Settings point at another working engine (a git checkout): leave it alone.
        if let dir = settings.engineDirectory, dir.standardizedFileURL != installed.standardizedFileURL, settings.engineIsReady {
            return
        }
        if !BundledEngine.needsInstall(source: source, home: home) && settings.engineIsReady { return }
        runEngineSetup(source: source, home: home)
    }

    func runEngineSetup(source: URL, home: URL) {
        guard let uv = BundledEngine.uv() else {
            engineSetup = EngineSetup(phase: .needsUV)
            return
        }
        engineSetup = EngineSetup(phase: .working("Copying the engine out of the app"))
        let engine = home.appendingPathComponent("engine")
        Task.detached { [weak self] in
            do {
                try BundledEngine.install(from: source, to: home)
                await self?.setSetupPhase(.working("Making the engine's Python environment (a minute or two, once)"))
                let output = try Self.run(uv, ["sync", "--frozen"], in: engine)
                guard output.status == 0 else {
                    await self?.setSetupPhase(.failed("uv sync failed:\n" + output.text.suffix(1500)))
                    return
                }
                await self?.finishEngineSetup(engine)
            } catch {
                await self?.setSetupPhase(.failed(error.localizedDescription))
            }
        }
    }

    /// uv's own installer (astral.sh), into ~/.local/bin; then the setup again.
    func installUVAndSetUp() {
        guard let source = BundledEngine.source() else { return }
        engineSetup = EngineSetup(phase: .working("Installing uv"))
        Task.detached { [weak self] in
            let output = try? Self.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"],
                                       in: FileManager.default.homeDirectoryForCurrentUser)
            guard output?.status == 0, BundledEngine.uv() != nil else {
                await self?.setSetupPhase(.failed("uv could not be installed:\n" + (output?.text.suffix(1500) ?? "")))
                return
            }
            await self?.runEngineSetup(source: source, home: BundledEngine.home)
        }
    }

    private func setSetupPhase(_ phase: EngineSetup.Phase) {
        engineSetup = EngineSetup(phase: phase)
    }

    private func finishEngineSetup(_ engine: URL) {
        settings.enginePath = engine.path
        engineSetup = EngineSetup(phase: .done)
        wingLab.loadLibrary(engineDirectory: settings.engineDirectory)
    }

    nonisolated private static func run(_ tool: URL, _ arguments: [String], in folder: URL) throws -> (status: Int32, text: String) {
        let p = Process()
        p.executableURL = tool
        p.arguments = arguments
        p.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = EngineProcess.toolPath(env["PATH"])
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
