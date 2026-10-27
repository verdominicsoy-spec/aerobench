import XCTest
@testable import AeroBenchKit

/// Runs the real Python engine. Set AEROBENCH_ENGINE to the repo's engine
/// folder (after `uv sync` there) to enable these; they are skipped otherwise.
/// They cover the Phase 0 acceptance checks at the job-runner level.
final class EngineIntegrationTests: XCTestCase {
    var executable: URL!
    var root: URL!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["AEROBENCH_ENGINE"] else {
            throw XCTSkip("AEROBENCH_ENGINE not set")
        }
        executable = EngineLocation.executable(inEngineDirectory: URL(fileURLWithPath: dir))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("aerobench-int-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeJob(_ spec: JobSpec) throws -> EngineProcess {
        let (_, url) = try JobFolder.create(in: root, spec: spec)
        return EngineProcess(executableURL: executable, command: spec.command,
                             inputURL: url.appendingPathComponent(JobFolder.jobFile), workdir: url)
    }

    func testPingRoundTrip() async throws {
        let job = try makeJob(JobSpec(command: "ping", params: ["echo": .string("hi")]))
        let outcome = await job.run(onEvent: { _ in })
        guard case .succeeded(let url) = outcome else { return XCTFail("\(outcome)") }
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let data = result["data"] as! [String: Any]
        XCTAssertEqual(data["pong"] as? Bool, true)
        XCTAssertEqual(data["echo"] as? String, "hi")
    }

    func testDummyStreamsProgressLiveAndCancelsCleanly() async throws {
        let job = try makeJob(JobSpec(command: "dummy", params: ["duration": .int(10)]))
        let seen = Box<[Double]>([])
        let run = Task { await job.run(onEvent: { if case .progress(let pct, _) = $0 { seen.mutate { $0.append(pct) } } }) }

        try await waitUntil { seen.value.count >= 3 }
        let cancelledAt = Date()
        job.cancel(grace: 3)
        let outcome = await run.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2.5, "SIGTERM should stop it before SIGKILL is needed")
        XCTAssertLessThan(seen.value.last ?? 100, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.workdir.appendingPathComponent("result.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.workdir.appendingPathComponent("scratch").path))
    }

    func testKilledEngineIsReportedAsFailure() async throws {
        let job = try makeJob(JobSpec(command: "dummy", params: ["duration": .int(10)]))
        let started = Box(false)
        let run = Task { await job.run(onEvent: { if case .progress = $0 { started.mutate { $0 = true } } }) }

        try await waitUntil { started.value }
        kill(job.processIdentifier, SIGKILL)
        let outcome = await run.value

        guard case .failed(let message, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.contains("killed"), message)
    }

    func testEngineErrorIsPassedThrough() async throws {
        let job = try makeJob(JobSpec(command: "dummy", params: ["duration": .double(0.2), "steps": .int(4), "fail_at_pct": .int(50)]))
        let outcome = await job.run(onEvent: { _ in })
        guard case .failed(let message, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.contains("failed on purpose"), message)
    }

    func testMissingEngineIsAMessageNotACrash() async throws {
        let (_, url) = try JobFolder.create(in: root, spec: JobSpec(command: "ping"))
        let job = EngineProcess(executableURL: URL(fileURLWithPath: "/nonexistent/aeroengine"), command: "ping",
                                inputURL: url.appendingPathComponent("job.json"), workdir: url)
        guard case .failed(let message, _) = await job.run(onEvent: { _ in }) else { return XCTFail() }
        XCTAssertTrue(message.contains("Engine not found"), message)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw TimedOut(seconds: timeout) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

struct TimedOut: Error { let seconds: TimeInterval }

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; f(&_value) }
}
