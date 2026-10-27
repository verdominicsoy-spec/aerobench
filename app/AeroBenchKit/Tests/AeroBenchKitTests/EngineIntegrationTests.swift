import XCTest
import simd
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

    func testLapSimResultDecodes() async throws {
        var setup = LapSimSetup()
        setup.compare = true
        setup.carB.cla += 1
        let job = try makeJob(JobSpec(command: "lapsim", params: try setup.jobParams(lapsimFolder: nil)))
        guard case .succeeded(let url) = await job.run(onEvent: { _ in }) else { return XCTFail() }
        let result = try LapSimResult.decode(resultFile: Data(contentsOf: url))
        XCTAssertEqual(result.track.name, "Test track")
        XCTAssertEqual(result.a.v.count, result.track.s.count)
        let b = try XCTUnwrap(result.b)
        XCTAssertLessThan(b.lapTime, result.a.lapTime)
        XCTAssertEqual(result.deltaT?.count, result.track.s.count)
        XCTAssertLessThan(try XCTUnwrap(result.a.sensitivity).dtDcla, 0)
        XCTAssertEqual(result.a.car, setup.carA)
    }

    /// Phase 2 acceptance check, automated: STEP through the engine to glb
    /// and into Swift, then measure known dimensions vertex to vertex.
    func testSTEPTessellatesAndMeasuresWithinATenthOfAMillimetre() async throws {
        let step = ModelLoaderTests.samples.appendingPathComponent("sample_car.step")
        let job = try makeJob(JobSpec(command: "tessellate", params: ["path": .string(step.path), "preset": .string("medium")]))
        guard case .succeeded = await job.run(onEvent: { _ in }) else { return XCTFail() }
        let model = try ModelLoader.load(job.workdir.appendingPathComponent("model.glb"))

        let root = try XCTUnwrap(model.roots.first)
        XCTAssertEqual(root.name, "Sample Car")
        XCTAssertEqual(root.children.map(\.name),
                       ["Chassis", "Wheel FL", "Wheel FR", "Wheel RL", "Wheel RR", "Front Wing", "Rear Wing"])
        XCTAssertEqual(model.meshes.count, 4)
        XCTAssertEqual(model.instances().count, 9)

        let chassis = try XCTUnwrap(model.instances().first { $0.node.name == "Chassis" })
        let corners = model.meshes[chassis.node.mesh!].positions.map { p -> SIMD3<Double> in
            let w = chassis.world * SIMD4<Float>(p, 1)
            return SIMD3(Double(w.x), Double(w.y), Double(w.z))
        }
        func corner(_ x: Double, _ y: Double, _ z: Double) throws -> SIMD3<Double> {
            try XCTUnwrap(corners.min { simd_distance($0, SIMD3(x, y, z)) < simd_distance($1, SIMD3(x, y, z)) })
        }
        let length = Measure.distance(try corner(0, 0, 0), try corner(1.5, 0, 0)) * 1000
        let diagonal = Measure.distance(try corner(0, 0, 0), try corner(1.5, 0.6, 0.3)) * 1000
        XCTAssertEqual(length, 1500, accuracy: 0.1)
        let size: SIMD3<Double> = [1500, 600, 300]
        let expectedDiagonal: Double = simd_length(size)
        XCTAssertEqual(diagonal, expectedDiagonal, accuracy: 0.1)
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
