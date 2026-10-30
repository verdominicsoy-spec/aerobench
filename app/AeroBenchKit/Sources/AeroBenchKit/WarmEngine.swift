import Foundation

/// A long-lived engine (aeroengine serve) for requests that take milliseconds
/// once NeuralFoil is loaded, such as the quick estimate while an element is
/// dragged. Started on the first request and again if it stops; it exits by
/// itself when the app goes away and its stdin closes.
public final class WarmEngine: @unchecked Sendable {
    public struct Failure: LocalizedError, Equatable {
        public var message: String
        public var detail: String?
        public var errorDescription: String? { message }
    }

    private let executableURL: URL
    private let environment: [String: String]
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]

    public init(executableURL: URL, environment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.environment = environment
    }

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// Sends one request and returns its reply line, which decodes like a
    /// job's result file (the answer is under "data").
    public func request(_ command: String, params: JSONValue) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            lock.lock()
            do {
                let handle = try startIfNeeded()
                let id = nextID
                nextID += 1
                let line = try JSONEncoder().encode(Request(id: id, command: command, params: params)) + Data([0x0A])
                pending[id] = c
                lock.unlock()
                do {
                    try handle.write(contentsOf: line)
                } catch {
                    take(id)?.resume(throwing: Failure(message: "Could not reach the engine", detail: error.localizedDescription))
                }
            } catch {
                lock.unlock()
                c.resume(throwing: error)
            }
        }
    }

    public func stop() {
        lock.lock()
        let p = process
        process = nil
        try? input?.close()
        input = nil
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
        failAll("The engine stopped")
    }

    private struct Request: Encodable {
        var id: Int
        var command: String
        var params: JSONValue
    }

    private struct Reply: Decodable {
        var type: String
        var id: Int?
        var error: String?
        var detail: String?
    }

    /// Call with the lock held.
    private func startIfNeeded() throws -> FileHandle {
        if let p = process, p.isRunning, let input { return input }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw Failure(message: "Engine not found at \(executableURL.path)", detail: nil)
        }
        signal(SIGPIPE, SIG_IGN)  // a write to an engine that just died must fail, not end the app
        let p = Process()
        p.executableURL = executableURL
        p.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = EngineProcess.toolPath(env["PATH"])
        env.merge(environment) { _, new in new }
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        let buffer = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            for line in buffer.append(data) { self?.handle(line) }
        }
        p.terminationHandler = { [weak self] ended in
            guard let self else { return }
            self.lock.lock()
            // A stopped engine already failed its requests; a replacement's are not this one's.
            let current = self.process === ended
            if current { self.process = nil; self.input = nil }
            self.lock.unlock()
            if current { self.failAll("The engine stopped (exit \(ended.terminationStatus))") }
        }
        do {
            try p.run()
        } catch {
            throw Failure(message: "Could not start the engine", detail: error.localizedDescription)
        }
        process = p
        input = stdin.fileHandleForWriting
        return stdin.fileHandleForWriting
    }

    private func handle(_ line: String) {
        let data = Data(line.utf8)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.type == "reply", let id = reply.id,
              let c = take(id) else { return }
        if let error = reply.error {
            c.resume(throwing: Failure(message: error, detail: reply.detail))
        } else {
            c.resume(returning: data)
        }
    }

    private func take(_ id: Int) -> CheckedContinuation<Data, Error>? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    private func failAll(_ message: String) {
        lock.lock()
        let waiting = pending
        pending = [:]
        lock.unlock()
        for c in waiting.values { c.resume(throwing: Failure(message: message, detail: nil)) }
    }
}
