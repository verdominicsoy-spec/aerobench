import Foundation

public enum EngineLocation {
    /// The engine runs straight from the uv-managed virtualenv in the repo's
    /// engine folder, not through `uv run`, so signals reach Python directly.
    public static func executable(inEngineDirectory dir: URL) -> URL {
        dir.appendingPathComponent(".venv/bin/aeroengine")
    }
}

/// Runs one engine job as a child process, streams its events and reports
/// how it ended. Cancel sends SIGTERM, then SIGKILL to the engine's process
/// group if it has not exited after the grace period.
public final class EngineProcess: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case succeeded(resultURL: URL)
        case failed(message: String, detail: String?)
        case cancelled
    }

    public let command: String
    public let workdir: URL
    private let executableURL: URL
    private let process = Process()
    private let lock = NSLock()
    private var cancelRequested = false
    private var launched = false

    public init(executableURL: URL, command: String, inputURL: URL, workdir: URL, environment: [String: String] = [:]) {
        self.command = command
        self.workdir = workdir
        self.executableURL = executableURL
        process.executableURL = executableURL
        process.arguments = [command, "--input", inputURL.path, "--workdir", workdir.path]
        process.currentDirectoryURL = workdir
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = Self.toolPath(env["PATH"])
        env.merge(environment) { _, new in new }
        process.environment = env
    }

    /// An app opened from Finder gets a bare PATH (/usr/bin:/bin:...), so the
    /// engine could not find Homebrew's tools: mpirun for running SU2 on
    /// several cores, and brew itself when installing SU2. Homebrew's folders
    /// go on the end, so anything already there wins.
    public static func toolPath(_ path: String?) -> String {
        var parts = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        if parts.isEmpty { parts = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] }
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !parts.contains(extra) {
            parts.append(extra)
        }
        return parts.joined(separator: ":")
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public var isCancelRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelRequested
    }

    /// Runs the job to completion. Events are delivered on a background
    /// thread in the order the engine printed them.
    public func run(
        onEvent: @escaping @Sendable (EngineEvent) -> Void,
        onStderr: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .failed(
                message: "Engine not found at \(executableURL.path)",
                detail: "Set the engine folder in Settings and run `uv sync` inside it."
            )
        }

        let process = self.process
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let exits = AsyncStream<(Process.TerminationReason, Int32)> { continuation in
            process.terminationHandler = { p in
                continuation.yield((p.terminationReason, p.terminationStatus))
                continuation.finish()
            }
        }

        if let early = launch() {
            return early
        }

        let state = StreamState()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await Self.readLines(stdout.fileHandleForReading) { line in
                    let event = EngineEvent.parse(line)
                    state.record(event)
                    onEvent(event)
                }
            }
            group.addTask {
                await Self.readLines(stderr.fileHandleForReading) { line in
                    state.recordStderr(line)
                    onStderr(line)
                }
            }
        }

        var reason = Process.TerminationReason.exit
        var status: Int32 = 0
        for await (r, s) in exits {
            reason = r
            status = s
        }
        return outcome(reason: reason, status: status, state: state)
    }

    public func cancel(grace: TimeInterval = 3) {
        lock.lock()
        cancelRequested = true
        let wasLaunched = launched
        lock.unlock()
        let process = self.process
        guard wasLaunched, process.isRunning else { return }

        let pid = process.processIdentifier
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            guard process.isRunning else { return }
            // The engine leads its own process group, so this also takes
            // down any solver it started.
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    private func outcome(reason: Process.TerminationReason, status: Int32, state: StreamState) -> Outcome {
        if reason == .exit, status == 0, let path = state.resultPath {
            return .succeeded(resultURL: workdir.appendingPathComponent(path))
        }
        if isCancelRequested {
            return .cancelled
        }
        if let error = state.error {
            return .failed(message: error.msg, detail: error.detail)
        }
        let tail = state.stderrTail
        if reason == .uncaughtSignal {
            return .failed(message: "Engine process was killed (signal \(status))", detail: tail)
        }
        if status == 143 {
            return .failed(message: "Engine was stopped from outside AeroBench (SIGTERM)", detail: tail)
        }
        if status != 0 {
            return .failed(message: "Engine exited with code \(status) without reporting an error", detail: tail)
        }
        return .failed(message: "Engine finished without producing a result", detail: tail)
    }

    /// Starts the process unless cancel came first. Returns an outcome only
    /// if the job ends here. Kept synchronous so the lock is never held
    /// across a suspension point.
    private func launch() -> Outcome? {
        lock.lock(); defer { lock.unlock() }
        if cancelRequested { return .cancelled }
        do {
            try process.run()
            launched = true
            return nil
        } catch {
            return .failed(message: "Could not start the engine", detail: error.localizedDescription)
        }
    }

    private static func readLines(_ handle: FileHandle, _ body: (String) -> Void) async {
        for await line in lines(of: handle) {
            body(line)
        }
    }

    /// Lines from a pipe as soon as each one arrives. FileHandle.bytes is not
    /// used because it holds pipe output back until its buffer fills, which
    /// stalls live progress.
    private static func lines(of handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = LineBuffer()
            handle.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    h.readabilityHandler = nil
                    if let rest = buffer.remainder() { continuation.yield(rest) }
                    continuation.finish()
                } else {
                    for line in buffer.append(data) { continuation.yield(line) }
                }
            }
        }
    }
}

/// Splits a byte stream into newline-terminated lines.
private final class LineBuffer: @unchecked Sendable {
    // Only touched from one handle's readabilityHandler, which runs serially.
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Self.decode(pending[pending.startIndex..<newline]))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    func remainder() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : Self.decode(pending[...])
    }

    private static func decode(_ bytes: Data.SubSequence) -> String {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }
}

private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var _resultPath: String?
    private var _error: (msg: String, detail: String?)?
    private var _stderr: [String] = []

    func record(_ event: EngineEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .result(let path): _resultPath = path
        case .error(let msg, let detail): _error = (msg, detail)
        default: break
        }
    }

    func recordStderr(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        _stderr.append(line)
        if _stderr.count > 40 { _stderr.removeFirst(_stderr.count - 40) }
    }

    var resultPath: String? { lock.lock(); defer { lock.unlock() }; return _resultPath }
    var error: (msg: String, detail: String?)? { lock.lock(); defer { lock.unlock() }; return _error }
    var stderrTail: String? {
        lock.lock(); defer { lock.unlock() }
        return _stderr.isEmpty ? nil : _stderr.joined(separator: "\n")
    }
}
