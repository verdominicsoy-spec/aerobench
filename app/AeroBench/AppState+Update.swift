import AppKit
import Foundation

/// A development checkout updating itself: at launch the app asks GitHub
/// whether the branch has moved on, and if so offers AeroBench.command, which
/// pulls, syncs the engine, rebuilds and reopens. A packaged app (no git
/// checkout behind its engine) never checks.
extension AppState {
    /// The checkout the engine folder sits in, if AeroBench.command is there to update it.
    var repoRoot: URL? {
        guard let engine = settings.engineDirectory else { return nil }
        let root = engine.deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent(".git").path),
              fm.fileExists(atPath: root.appendingPathComponent("AeroBench.command").path) else { return nil }
        return root
    }

    func checkForUpdates() {
        guard let root = repoRoot else { return }
        Task.detached(priority: .utility) {
            // Offline or no upstream: say nothing.
            guard Self.git(["fetch", "--quiet"], in: root) != nil,
                  let count = Self.git(["rev-list", "--count", "HEAD..@{u}"], in: root).flatMap({ Int($0) }) else { return }
            await MainActor.run { self.updatesBehind = count }
        }
    }

    /// Runs the launcher in Terminal; it quits this app (which saves the project) and opens the new build.
    func updateAndRestart() {
        guard let root = repoRoot else { return }
        NSWorkspace.shared.open(root.appendingPathComponent("AeroBench.command"))
    }

    /// git's trimmed output, or nil if it failed.
    nonisolated static func git(_ args: [String], in dir: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        p.environment = ["GIT_TERMINAL_PROMPT": "0", "PATH": "/usr/bin:/bin:/opt/homebrew/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
